import Foundation

enum MochiLegacyCodec {
    private static let labels = [
        "Include in Image",
        "Exclude from Image",
        "Model",
        "Steps",
        "Guidance Scale",
        "Seed",
        "Size",
        "Quality",
        "Starting Image",
        "ControlNet Image",
        "Input Images",
        "Scheduler",
        "ML Compute Unit",
        "Generator",
    ]

    /// Labels only the version 2 caption writes.
    private static let versionTwoLabels = ["Engine", "Model Key"]

    /// The first line of a version 2 caption names its version under this label.
    private static let versionLabel = "Metadata Version"

    static func decode(_ payloads: [EmbeddedMetadataPayload]) -> CodecOutput {
        var output = CodecOutput()

        for (index, payload) in payloads.enumerated() where payload.kind == .xmp {
            // The description written beside a native record is not a caption.
            guard let xmp = payload.text, !xmp.contains(MochiNativeCodec.namespace),
                let caption = XMPDescription.parse(xmp),
                let parsed = parseCaption(caption)
            else { continue }

            output.interpretations.append(
                MetadataInterpretation(
                    format: .mochiDiffusionLegacyCaption,
                    producer: MetadataProducer(name: "Mochi Diffusion", version: parsed.version),
                    payloadIndices: [index],
                    generations: [parsed.summary]
                )
            )
        }

        return output
    }

    /// Mochi's details among a caption's fields that have no common meaning.
    static func details(_ parameters: [GenerationParameter]) -> MochiGenerationDetails {
        func value(_ key: String) -> String? {
            parameters.first { $0.key == key }?.value
        }
        let listed = parameters.filter { $0.key == "Input Image" }.map(\.value)
        let joined = value("Input Images").map { images in
            images.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return MochiGenerationDetails(
            engine: value("Engine"),
            modelKey: value("Model Key"),
            quality: value("Quality"),
            computeUnit: value("ML Compute Unit"),
            startingImage: value("Starting Image"),
            controlNetImage: value("ControlNet Image"),
            inputImages: listed.isEmpty ? joined : listed
        )
    }

    private struct ParsedCaption {
        let version: String?
        let summary: GenerationRecord
    }

    private static func parseCaption(_ caption: String) -> ParsedCaption? {
        let fields: [(label: String, value: String)]
        switch captionVersion(caption) {
        case nil: fields = semicolonFields(in: caption)
        case 2: fields = lineFields(in: caption)
        default: return nil
        }
        let values = Dictionary(fields.map { ($0.label, $0.value) }) { first, _ in first }
        guard let generator = values["Generator"], generator.hasPrefix("Mochi Diffusion"),
            values["Include in Image"] != nil
        else { return nil }

        let version =
            generator
            .dropFirst("Mochi Diffusion".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        let normalizedLabels: Set<String> = [
            "Include in Image", "Exclude from Image", "Model", "Steps",
            "Guidance Scale", "Seed", "Size", "Scheduler", "Generator",
        ]

        return ParsedCaption(
            version: version,
            summary: GenerationRecord(
                // A present but empty prompt is an explicitly empty prompt.
                positivePrompt: values["Include in Image"],
                negativePrompt: values["Exclude from Image"],
                model: values["Model"]?.nonEmpty,
                // Mochi's "Scheduler" names the sampling method, such as
                // DPM-Solver++. The caption records no separate schedule.
                sampler: values["Scheduler"]?.nonEmpty,
                steps: values["Steps"].flatMap(Int.init),
                cfgScale: values["Guidance Scale"].flatMap(Double.init),
                seed: values["Seed"]?.nonEmpty,
                dimensions: dimensions(values["Size"]),
                parameters:
                    fields
                    .filter { !normalizedLabels.contains($0.label) }
                    .map { GenerationParameter(key: $0.label, value: $0.value) }
            )
        )
    }

    /// The version a caption declares on its first line, or `nil` for the
    /// version 1 caption, which declares none.
    private static func captionVersion(_ caption: String) -> Int? {
        let firstLine = caption.components(separatedBy: "\n")[0]
        guard firstLine.hasPrefix("\(versionLabel): ") else { return nil }
        return Int(firstLine.dropFirst(versionLabel.count + 2).trimmingCharacters(in: .whitespaces)) ?? 0
    }

    /// The fields of a version 2 caption, written by Mochi Diffusion 6.1
    /// through 6.1.2, in caption order.
    ///
    /// Each line is one `Label: value` field, and a value escapes backslash,
    /// line feed and carriage return. `Input Images` repeats once per image, so
    /// each becomes its own `Input Image` field. Unknown labels are skipped.
    private static func lineFields(in caption: String) -> [(label: String, value: String)] {
        caption.components(separatedBy: "\n").compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let label = String(line[..<colon])
            guard labels.contains(label) || versionTwoLabels.contains(label) else { return nil }
            var value = line[line.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
            return (label == "Input Images" ? "Input Image" : label, unescape(value))
        }
    }

    /// Reverses the version 2 escapes. A malformed escape is kept as written.
    private static func unescape(_ value: Substring) -> String {
        var result = ""
        var scalars = value.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            guard scalar == "\\" else {
                result.unicodeScalars.append(scalar)
                continue
            }
            switch scalars.next() {
            case "n": result += "\n"
            case "r": result += "\r"
            case "\\": result += "\\"
            case let other?:
                result += "\\"
                result.unicodeScalars.append(other)
            case nil: result += "\\"
            }
        }
        return result
    }

    /// The fields of a version 1 caption, written by Mochi Diffusion 2.2
    /// through 6.0, in caption order. Fields are joined by `"; "` and values
    /// are not escaped, so a field ends at the next `"; "` that is followed by
    /// a known label.
    private static func semicolonFields(in caption: String) -> [(label: String, value: String)] {
        var result: [(label: String, value: String)] = []
        var cursor = caption.startIndex

        while cursor < caption.endIndex {
            guard
                let label = labels.first(where: {
                    caption[cursor...].hasPrefix("\($0): ")
                })
            else { break }

            let valueStart = caption.index(cursor, offsetBy: label.count + 2)
            let nextField = labels.compactMap { nextLabel -> Range<String.Index>? in
                caption.range(of: "; \(nextLabel): ", range: valueStart..<caption.endIndex)
            }
            .min { $0.lowerBound < $1.lowerBound }
            let valueEnd = nextField?.lowerBound ?? caption.endIndex
            result.append((label, String(caption[valueStart..<valueEnd])))

            guard let nextField else { break }
            cursor = caption.index(nextField.lowerBound, offsetBy: 2)
        }

        return result
    }

    private static func dimensions(_ value: String?) -> PixelDimensions? {
        guard let parts = value?.lowercased().split(separator: "x", maxSplits: 1),
            parts.count == 2,
            let width = Int(parts[0]),
            let height = Int(parts[1])
        else { return nil }
        return PixelDimensions(width: width, height: height)
    }
}

private final class XMPDescription: NSObject, XMLParserDelegate {
    private(set) var value: String?
    private var isCapturing = false
    private var text = ""

    static func parse(_ xmp: String) -> String? {
        let xml: Substring
        if let start = xmp.range(of: "<x:xmpmeta"),
            let end = xmp.range(of: "</x:xmpmeta>", range: start.lowerBound..<xmp.endIndex)
        {
            xml = xmp[start.lowerBound..<end.upperBound]
        } else {
            xml = xmp[...]
        }
        let delegate = XMPDescription()
        guard (try? UntrustedXML.parse(String(xml), delegate: delegate)) != nil else { return nil }
        return delegate.value
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName.split(separator: ":").last == "description" else { return }
        isCapturing = true
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isCapturing { text += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard isCapturing, elementName.split(separator: ":").last == "description" else {
            return
        }
        value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        isCapturing = false
    }
}
