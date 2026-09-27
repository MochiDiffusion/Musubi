import Foundation

/// The metadata payloads to place in a PNG.
///
/// `nil` means the image has no such payload: an existing chunk of that kind
/// that Musubi owns is removed, so no stale copy remains.
public struct PNGMetadataPayloads: Equatable, Sendable {
    /// A complete XMP packet, such as one from
    /// ``MochiNativeCodec/encodeXMPPacket(_:)``.
    public var nativeXMPPacket: String?
    /// AUTOMATIC1111-compatible text, such as from ``A1111ParametersEncoder``.
    public var parameters: String?

    public init(nativeXMPPacket: String? = nil, parameters: String? = nil) {
        self.nativeXMPPacket = nativeXMPPacket
        self.parameters = parameters
    }
}

/// Why a PNG could not be rewritten. The input data is never modified.
public enum PNGMetadataWriterError: Error, Equatable, Sendable {
    /// The data is not a PNG, or its chunk structure is truncated or invalid.
    case malformedPNG(String)
    /// A payload is larger than its limit.
    case payloadTooLarge(String, Int)
    /// A payload contains a character its carrier cannot hold.
    case unrepresentablePayload(String)
    /// The image has XMP that holds more than Mochi's native record. Musubi
    /// does not own that packet, so it neither replaces nor merges it.
    case foreignXMP
    /// The image already has a different generation record, and the caller did
    /// not ask to replace it.
    case existingRecord(String)
}

/// Inserts or replaces Musubi's metadata chunks in an encoded PNG.
///
/// The writer owns two carriers: the `parameters` text chunk, in any of its
/// `tEXt`, `zTXt` or `iTXt` forms, and an XMP chunk that holds only Mochi's
/// native record. It copies every other chunk, the encoded pixel data and any
/// bytes after `IEND` exactly as they were. New chunks are uncompressed UTF-8
/// `iTXt` placed directly after `IHDR`, the placement the pinned external
/// readers were tested with. Writing the same payloads again gives the same
/// bytes.
public enum PNGMetadataWriter {
    static let xmpKeyword = "XML:com.adobe.xmp"
    static let parametersKeyword = "parameters"
    private static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// Returns `png` with `payloads` as its only owned metadata chunks.
    ///
    /// - Parameter replacingExistingRecords: When false, an owned chunk that
    ///   holds something other than the new payload is an error instead of
    ///   being replaced. An identical chunk is not a conflict.
    /// - Throws: ``PNGMetadataWriterError``. Nothing is returned on failure.
    public static func write(
        _ payloads: PNGMetadataPayloads,
        into png: Data,
        replacingExistingRecords: Bool
    ) throws -> Data {
        let newParameters = try payloads.parameters.map {
            try internationalTextChunk(
                keyword: parametersKeyword, text: $0, limit: A1111ParametersEncoder.maximumTextSize)
        }
        let newXMP = try payloads.nativeXMPPacket.map {
            try internationalTextChunk(keyword: xmpKeyword, text: $0, limit: MochiNativeCodec.maximumPacketSize)
        }

        let file = try PNGChunkFile(png)
        var kept: [Data] = []
        for chunk in file.chunks.dropFirst() {
            switch try ownership(of: chunk) {
            case .unowned:
                kept.append(chunk.bytes)
            case .foreignXMP:
                guard newXMP == nil else { throw PNGMetadataWriterError.foreignXMP }
                kept.append(chunk.bytes)
            case .parameters:
                if !replacingExistingRecords, chunk.bytes != newParameters {
                    throw PNGMetadataWriterError.existingRecord("parameters")
                }
            case .nativeXMP:
                if !replacingExistingRecords, chunk.bytes != newXMP {
                    throw PNGMetadataWriterError.existingRecord("native XMP")
                }
            }
        }

        var output = Data(signature)
        output.append(file.chunks[0].bytes)
        if let newXMP { output.append(newXMP) }
        if let newParameters { output.append(newParameters) }
        for chunk in kept { output.append(chunk) }
        output.append(file.trailingBytes)
        return output
    }

    // MARK: - Ownership

    private enum Ownership {
        case unowned
        case parameters
        case nativeXMP
        case foreignXMP
    }

    private static func ownership(of chunk: PNGChunkFile.Chunk) throws -> Ownership {
        guard ["tEXt", "zTXt", "iTXt"].contains(chunk.type), let keyword = keyword(of: chunk.payload) else {
            return .unowned
        }
        switch keyword {
        case parametersKeyword:
            return .parameters
        case xmpKeyword:
            return isOwnedXMP(chunk) ? .nativeXMP : .foreignXMP
        default:
            return .unowned
        }
    }

    private static func keyword(of payload: Data) -> String? {
        guard let separator = payload.firstIndex(of: 0) else { return nil }
        return String(data: payload[payload.startIndex..<separator], encoding: .isoLatin1)
    }

    /// An XMP packet is Musubi's to replace only when its sole property is
    /// Mochi's native record. A packet that cannot be read is not Musubi's.
    private static func isOwnedXMP(_ chunk: PNGChunkFile.Chunk) -> Bool {
        var budget = InputLimits.decompressedBytes
        guard
            let payload = try? PNGMetadataReader.decodeTextChunk(
                type: chunk.type, data: Data(chunk.payload), budget: &budget),
            let text = payload.text
        else { return false }
        let properties = XMPPropertyNames()
        guard (try? UntrustedXML.parse(text, delegate: properties, processNamespaces: true)) != nil else {
            return false
        }
        return properties.names == [MochiNativeCodec.namespace + MochiNativeCodec.propertyName]
    }

    // MARK: - Encoding

    /// An uncompressed UTF-8 `iTXt` chunk with no language tag.
    private static func internationalTextChunk(keyword: String, text: String, limit: Int) throws -> Data {
        let size = text.utf8.count
        guard size <= limit else { throw PNGMetadataWriterError.payloadTooLarge(keyword, size) }
        guard !text.contains("\0") else { throw PNGMetadataWriterError.unrepresentablePayload(keyword) }

        var payload = Data(keyword.utf8)
        payload.append(contentsOf: [0, 0, 0, 0, 0])
        payload.append(Data(text.utf8))
        return try PNGChunkFile.chunk(type: "iTXt", payload: payload)
    }
}

/// The properties an XMP packet sets, as namespace URI plus local name.
///
/// Properties are the children and attributes of `rdf:Description`. The
/// structural RDF and packet names are not properties.
private final class XMPPropertyNames: NSObject, XMLParserDelegate {
    private static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    private(set) var names: Set<String> = []
    private var prefixes: [String: [String]] = [:]
    private var descriptionDepth: Int?
    private var depth = 0

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
        depth += 1
        if namespaceURI == Self.rdf, elementName == "Description" {
            descriptionDepth = depth
            for name in attributeDict.keys {
                let parts = name.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, parts[0] != "xmlns", let uri = prefixes[String(parts[0])]?.last,
                    uri != Self.rdf
                else { continue }
                names.insert(uri + parts[1])
            }
        } else if let descriptionDepth, depth == descriptionDepth + 1 {
            names.insert((namespaceURI ?? "") + elementName)
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if depth == descriptionDepth { descriptionDepth = nil }
        depth -= 1
    }
}

/// A PNG split into its chunks, each kept as its exact bytes.
struct PNGChunkFile {
    struct Chunk {
        let type: String
        /// The complete chunk: length, type, data and CRC.
        let bytes: Data
        /// The chunk data alone.
        let payload: Data
    }

    /// Every chunk from `IHDR` through `IEND`, in file order.
    let chunks: [Chunk]
    /// Bytes after `IEND`, kept so the rewrite changes nothing it does not own.
    let trailingBytes: Data

    private static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    init(_ data: Data) throws {
        let data = Data(data)
        guard data.hasPrefix(Self.signature) else { throw PNGMetadataWriterError.malformedPNG("No PNG signature") }
        let reader = BinaryReader(data: data)
        var offset = Self.signature.count
        var chunks: [Chunk] = []

        while true {
            guard let length = reader.uint32(at: offset, endian: .big).map(Int.init),
                let typeData = reader.bytes(in: offset + 4..<offset + 8)
            else { throw PNGMetadataWriterError.malformedPNG("Truncated chunk header") }
            let (end, overflow) = offset.addingReportingOverflow(12 + length)
            guard length <= Int(Int32.max), !overflow, end <= data.count,
                let bytes = reader.bytes(in: offset..<end)
            else { throw PNGMetadataWriterError.malformedPNG("Truncated chunk") }
            let type = String(decoding: typeData, as: UTF8.self)
            chunks.append(Chunk(type: type, bytes: bytes, payload: bytes.subdata(in: 8..<8 + length)))
            offset = end
            if type == "IEND" { break }
        }

        guard chunks.first?.type == "IHDR" else { throw PNGMetadataWriterError.malformedPNG("IHDR is not first") }
        self.chunks = chunks
        self.trailingBytes = data.subdata(in: offset..<data.count)
    }

    /// A complete chunk with its length and CRC.
    static func chunk(type: String, payload: Data) throws -> Data {
        guard payload.count <= Int(Int32.max) else {
            throw PNGMetadataWriterError.payloadTooLarge(type, payload.count)
        }
        let typeData = Data(type.utf8)
        var bytes = Data()
        bytes.append(contentsOf: withUnsafeBytes(of: UInt32(payload.count).bigEndian, Array.init))
        bytes.append(typeData)
        bytes.append(payload)
        bytes.append(
            contentsOf: withUnsafeBytes(of: CRC32.checksum(type: typeData, payload: payload).bigEndian, Array.init))
        return bytes
    }
}
