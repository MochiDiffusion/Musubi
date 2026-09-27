import Foundation

/// Reads and writes Mochi Diffusion's native generation record, version 1.
///
/// The record is JSON, stored as the simple string XMP property `Generation`
/// in the ``namespace`` namespace. `Docs/MetadataWireContract.md` defines the
/// format. The JSON shape is private to this codec, so it does not change when
/// the public Swift types change.
public enum MochiNativeCodec {
    /// The XMP namespace of the native property.
    public static let namespace = "https://github.com/MochiDiffusion/MochiDiffusion/ns/metadata/1.0/"
    /// The local name of the native property.
    public static let propertyName = "Generation"
    /// The record version this codec writes and reads.
    public static let version = 1
    /// The largest XMP packet the codec writes, in bytes.
    public static let maximumPacketSize = 60 * 1_024

    static let formatName = "mochi-diffusion"

    // MARK: - Encoding

    /// Encodes `snapshot` as native JSON.
    ///
    /// The output is deterministic: keys are sorted and absent values are left
    /// out. `generatedAt` is stored to the millisecond.
    /// - Throws: ``MochiNativeCodecError`` when a value cannot be represented.
    public static func encodeJSON(_ snapshot: MochiGenerationSnapshot) throws -> String {
        let record = try WireRecord(snapshot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(record)
        return String(decoding: data, as: UTF8.self)
    }

    /// Encodes `snapshot` as a complete XMP packet that holds only the native
    /// property.
    /// - Throws: ``MochiNativeCodecError/packetTooLarge(_:)`` when the packet
    ///   exceeds ``maximumPacketSize``, or another error when a value cannot be
    ///   represented.
    public static func encodeXMPPacket(_ snapshot: MochiGenerationSnapshot) throws -> String {
        let json = try encodeJSON(snapshot)
        let packet = """
            <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
             <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
              <rdf:Description rdf:about="" xmlns:mochi="\(namespace)">
               <mochi:\(propertyName)>\(escapeXML(json))</mochi:\(propertyName)>
              </rdf:Description>
             </rdf:RDF>
            </x:xmpmeta>
            <?xpacket end="w"?>
            """
        let size = packet.utf8.count
        guard size <= maximumPacketSize else { throw MochiNativeCodecError.packetTooLarge(size) }
        return packet
    }

    // MARK: - Decoding

    /// Decodes native JSON.
    /// - Throws: ``MochiNativeCodecError`` when the JSON is not a supported,
    ///   valid native record.
    public static func decodeJSON(_ json: String) throws -> MochiGenerationSnapshot {
        let data = Data(json.utf8)
        if let key = JSONStructureScanner.firstDuplicateKey(in: data) {
            throw MochiNativeCodecError.duplicateKey(key)
        }
        let decoder = JSONDecoder()
        let header: WireHeader
        do {
            header = try decoder.decode(WireHeader.self, from: data)
        } catch {
            throw MochiNativeCodecError.invalidRecord("The record has no format and version")
        }
        guard header.format == formatName else {
            throw MochiNativeCodecError.invalidRecord("The format is not \(formatName)")
        }
        guard header.version == version else { throw MochiNativeCodecError.unsupportedVersion(header.version) }
        do {
            return try decoder.decode(WireRecord.self, from: data).snapshot()
        } catch let error as MochiNativeCodecError {
            throw error
        } catch {
            throw MochiNativeCodecError.invalidRecord("A value has the wrong type or is missing")
        }
    }

    /// Finds and decodes the native property in an XMP packet.
    /// - Returns: The snapshot, or `nil` when the packet has no native property.
    /// - Throws: ``MochiNativeCodecError`` when the packet cannot be read, has
    ///   more than one native property, or holds an unsupported record.
    public static func decodeXMPPacket(_ xmp: String) throws -> MochiGenerationSnapshot? {
        guard let json = try NativePropertyReader.value(in: xmp) else { return nil }
        return try decodeJSON(json)
    }

    /// Interprets every XMP payload that holds a native record.
    static func decode(_ payloads: [EmbeddedMetadataPayload]) -> CodecOutput {
        var output = CodecOutput()
        for (index, payload) in payloads.enumerated() where payload.kind == .xmp {
            guard let text = payload.text, text.contains(namespace) else { continue }
            do {
                guard let snapshot = try decodeXMPPacket(text) else { continue }
                output.interpretations.append(
                    MetadataInterpretation(
                        format: .mochiDiffusion,
                        producer: snapshot.producer,
                        payloadIndices: [index],
                        generations: [normalizedRecord(snapshot)]
                    )
                )
            } catch {
                output.diagnostics.append(
                    .init(severity: .warning, message: "Mochi Diffusion native record was not read: \(error)")
                )
            }
        }
        return output
    }

    /// The snapshot as a source-neutral record. Mochi's details become
    /// parameters, ahead of the engine's own parameters.
    static func normalizedRecord(_ snapshot: MochiGenerationSnapshot) -> GenerationRecord {
        var record = snapshot.generation
        let details = snapshot.details
        var parameters: [GenerationParameter] = []
        func append(_ key: String, _ value: String?) {
            if let value { parameters.append(GenerationParameter(key: key, value: value)) }
        }
        append("Engine", details.engine)
        append("Model Key", details.modelKey)
        append("Quality", details.quality)
        append("Compute Unit", details.computeUnit)
        append("Starting Image", details.startingImage)
        append("ControlNet Image", details.controlNetImage)
        for image in details.inputImages ?? [] { append("Input Image", image) }
        record.parameters = parameters + record.parameters
        return record
    }

    private static func escapeXML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Why a native record could not be written or read.
public enum MochiNativeCodecError: Error, Equatable, Sendable {
    /// A number is NaN or infinite.
    case nonFiniteValue(String)
    /// A value breaks a rule of the format, such as a seed that is not a
    /// decimal integer or a hash with no algorithm.
    case invalidValue(String)
    /// The XMP packet is larger than ``MochiNativeCodec/maximumPacketSize``.
    case packetTooLarge(Int)
    /// The record's version is not one this codec reads.
    case unsupportedVersion(Int)
    /// A JSON object repeats a key.
    case duplicateKey(String)
    /// The JSON or XMP is not a valid native record.
    case invalidRecord(String)
    /// The XMP packet holds more than one native property.
    case multipleRecords
}

extension MochiNativeCodecError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .nonFiniteValue(let field): "\(field) is not a finite number"
        case .invalidValue(let reason): reason
        case .packetTooLarge(let size):
            "The XMP packet is \(size) bytes, over the \(MochiNativeCodec.maximumPacketSize)-byte limit"
        case .unsupportedVersion(let version): "Version \(version) is not supported"
        case .duplicateKey(let key): "The key \"\(key)\" repeats"
        case .invalidRecord(let reason): reason
        case .multipleRecords: "The XMP packet has more than one native record"
        }
    }
}

// MARK: - Wire format

private struct WireHeader: Decodable {
    let format: String
    let version: Int
}

private struct WireRecord: Codable {
    let format: String
    let version: Int
    let producer: WireProducer
    let generation: WireGeneration
    let mochi: WireMochi?

    init(_ snapshot: MochiGenerationSnapshot) throws {
        format = MochiNativeCodec.formatName
        version = MochiNativeCodec.version
        producer = WireProducer(application: snapshot.producer.name, version: snapshot.producer.version)
        generation = try WireGeneration(snapshot.generation)
        let mochi = WireMochi(snapshot.details, parameters: snapshot.generation.parameters)
        self.mochi = mochi.isEmpty ? nil : mochi
    }

    func snapshot() throws -> MochiGenerationSnapshot {
        var record = try generation.record()
        record.parameters = mochi?.parameters?.map { GenerationParameter(key: $0.key, value: $0.value) } ?? []
        return MochiGenerationSnapshot(
            producer: MetadataProducer(name: producer.application, version: producer.version),
            generation: record,
            details: mochi?.details ?? MochiGenerationDetails()
        )
    }
}

private struct WireProducer: Codable {
    let application: String
    let version: String?
}

private struct WireGeneration: Codable {
    let prompt: String?
    let negativePrompt: String?
    let model: String?
    let sampler: String?
    let scheduler: String?
    let steps: Int?
    let cfgScale: Double?
    let denoise: Double?
    let seed: String?
    let width: Int?
    let height: Int?
    let generatedAt: String?
    let resources: [WireResource]?

    init(_ record: GenerationRecord) throws {
        prompt = record.positivePrompt
        negativePrompt = record.negativePrompt
        model = record.model
        sampler = record.sampler
        scheduler = record.scheduler
        steps = try Self.positive(record.steps, "steps")
        cfgScale = try Self.finite(record.cfgScale, "cfgScale")
        denoise = try Self.finite(record.denoise, "denoise")
        seed = try Self.decimal(record.seed)
        width = try Self.positive(record.dimensions?.width, "width")
        height = try Self.positive(record.dimensions?.height, "height")
        generatedAt = record.generatedAt.map(Self.timestamp)
        resources = record.resources.isEmpty ? nil : try record.resources.map(WireResource.init)
    }

    func record() throws -> GenerationRecord {
        let dimensions: PixelDimensions?
        switch (try Self.positive(width, "width"), try Self.positive(height, "height")) {
        case (nil, nil): dimensions = nil
        case (let width?, let height?): dimensions = PixelDimensions(width: width, height: height)
        default: throw MochiNativeCodecError.invalidRecord("The record has only one dimension")
        }
        return GenerationRecord(
            positivePrompt: prompt,
            negativePrompt: negativePrompt,
            model: model,
            sampler: sampler,
            scheduler: scheduler,
            steps: try Self.positive(steps, "steps"),
            cfgScale: cfgScale,
            seed: try Self.decimal(seed),
            dimensions: dimensions,
            denoise: denoise,
            generatedAt: try generatedAt.map(Self.date),
            resources: try resources?.map { try $0.resource() } ?? []
        )
    }

    private static func positive(_ value: Int?, _ field: String) throws -> Int? {
        guard let value else { return nil }
        guard value > 0 else { throw MochiNativeCodecError.invalidValue("\(field) must be positive") }
        return value
    }

    static func finite(_ value: Double?, _ field: String) throws -> Double? {
        guard let value else { return nil }
        guard value.isFinite else { throw MochiNativeCodecError.nonFiniteValue(field) }
        return value
    }

    /// Seeds are decimal strings of any length, so no integer width limits them.
    private static func decimal(_ seed: String?) throws -> String? {
        guard let seed else { return nil }
        let digits = seed.hasPrefix("-") ? seed.dropFirst() : Substring(seed)
        guard !digits.isEmpty, digits.allSatisfy({ ("0"..."9").contains($0) }) else {
            throw MochiNativeCodecError.invalidValue("The seed is not a decimal integer")
        }
        return seed
    }

    /// UTC RFC 3339, with milliseconds only when the time has a fraction of a
    /// second.
    private static func timestamp(_ date: Date) -> String {
        let whole = date.timeIntervalSince1970.rounded(.down) == date.timeIntervalSince1970
        return date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: !whole))
    }

    private static func date(_ text: String) throws -> Date {
        let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        if let date = try? withFraction.parse(text) { return date }
        if let date = try? Date.ISO8601FormatStyle().parse(text) { return date }
        throw MochiNativeCodecError.invalidValue("generatedAt is not an RFC 3339 timestamp")
    }
}

private struct WireResource: Codable {
    let kind: String
    let name: String?
    let weight: Double?
    let hashes: [WireHash]?
    let air: String?
    let civitaiModelVersionID: String?

    init(_ resource: GenerationResource) throws {
        kind = resource.kind.rawValue
        name = resource.name
        weight = try WireGeneration.finite(resource.weight, "weight")
        hashes =
            resource.hashes.isEmpty
            ? nil
            : try resource.hashes.map { hash in
                guard let algorithm = hash.algorithm else {
                    throw MochiNativeCodecError.invalidValue("A resource hash has no algorithm")
                }
                return WireHash(algorithm: algorithm.rawValue, value: hash.value)
            }
        air = resource.air
        civitaiModelVersionID = resource.civitaiModelVersionID.map(String.init)
    }

    func resource() throws -> GenerationResource {
        let versionID = try civitaiModelVersionID.map { text in
            guard let value = Int(text), value >= 0 else {
                throw MochiNativeCodecError.invalidValue("civitaiModelVersionID is not a decimal integer")
            }
            return value
        }
        return GenerationResource(
            kind: GenerationResourceKind(rawValue: kind),
            name: name,
            weight: weight,
            hashes: hashes?.map {
                ResourceHash(algorithm: ResourceHashAlgorithm(rawValue: $0.algorithm), value: $0.value)
            } ?? [],
            air: air,
            civitaiModelVersionID: versionID
        )
    }
}

private struct WireHash: Codable {
    let algorithm: String
    let value: String
}

private struct WireParameter: Codable {
    let key: String
    let value: String
}

private struct WireMochi: Codable {
    let engine: String?
    let modelKey: String?
    let quality: String?
    let computeUnit: String?
    let startingImage: String?
    let controlNetImage: String?
    let inputImages: [String]?
    let parameters: [WireParameter]?

    init(_ details: MochiGenerationDetails, parameters: [GenerationParameter]) {
        engine = details.engine
        modelKey = details.modelKey
        quality = details.quality
        computeUnit = details.computeUnit
        startingImage = details.startingImage
        controlNetImage = details.controlNetImage
        inputImages = details.inputImages
        self.parameters = parameters.isEmpty ? nil : parameters.map { WireParameter(key: $0.key, value: $0.value) }
    }

    var isEmpty: Bool {
        details == MochiGenerationDetails() && parameters == nil
    }

    var details: MochiGenerationDetails {
        MochiGenerationDetails(
            engine: engine,
            modelKey: modelKey,
            quality: quality,
            computeUnit: computeUnit,
            startingImage: startingImage,
            controlNetImage: controlNetImage,
            inputImages: inputImages
        )
    }
}

// MARK: - XMP

/// Finds the native property in an XMP packet by namespace URI and local name,
/// whatever prefix the packet uses. XMP writes a simple property either as an
/// element or as an attribute of `rdf:Description`, so both forms are read.
private final class NativePropertyReader: NSObject, XMLParserDelegate {
    private var prefixes: [String: [String]] = [:]
    private var values: [String] = []
    private var capturing = false
    private var captured = ""

    static func value(in xmp: String) throws -> String? {
        let xml: Substring
        if let start = xmp.range(of: "<x:xmpmeta"),
            let end = xmp.range(of: "</x:xmpmeta>", range: start.lowerBound..<xmp.endIndex)
        {
            xml = xmp[start.lowerBound..<end.upperBound]
        } else {
            xml = xmp[...]
        }
        let reader = NativePropertyReader()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = reader
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw MochiNativeCodecError.invalidRecord("The XMP packet is not valid XML") }
        guard reader.values.count <= 1 else { throw MochiNativeCodecError.multipleRecords }
        return reader.values.first
    }

    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
        prefixes[prefix, default: []].append(namespaceURI)
    }

    func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
        prefixes[prefix]?.removeLast()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        for (name, value) in attributeDict {
            let parts = name.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[1] == MochiNativeCodec.propertyName,
                prefixes[String(parts[0])]?.last == MochiNativeCodec.namespace
            else { continue }
            values.append(value)
        }
        if namespaceURI == MochiNativeCodec.namespace, elementName == MochiNativeCodec.propertyName {
            capturing = true
            captured = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { captured += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard capturing, namespaceURI == MochiNativeCodec.namespace, elementName == MochiNativeCodec.propertyName
        else { return }
        values.append(captured)
        capturing = false
    }
}
