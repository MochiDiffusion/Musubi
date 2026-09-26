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

    static func decode(_ payloads: [EmbeddedMetadataPayload]) -> CodecOutput {
        var output = CodecOutput()

        for (index, payload) in payloads.enumerated() where payload.kind == .xmp {
            guard let xmp = payload.text,
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

    private struct ParsedCaption {
        let version: String?
        let summary: GenerationRecord
    }

    private static func parseCaption(_ caption: String) -> ParsedCaption? {
        let fields = fields(in: caption)
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

    /// The caption's fields in caption order.
    private static func fields(in caption: String) -> [(label: String, value: String)] {
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
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        return parser.parse() ? delegate.value : nil
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
