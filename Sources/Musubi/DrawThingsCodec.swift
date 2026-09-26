import Foundation

enum DrawThingsCodec {
    static func decode(_ payloads: [EmbeddedMetadataPayload]) -> CodecOutput {
        var output = CodecOutput()

        for (index, payload) in payloads.enumerated() where payload.kind == .xmp {
            guard let text = payload.text,
                let fields = XMPGenerationFields.parse(text),
                fields.creatorTool?.localizedCaseInsensitiveContains("Draw Things") == true,
                let userComment = fields.userComment
            else { continue }

            do {
                let json = try JSONDecoder().decodeJSONValue(from: userComment)
                guard let object = json.objectValue else { continue }
                let summary = generationSummary(from: object)
                output.interpretations.append(
                    .init(
                        format: .drawThings,
                        producer: fields.creatorTool.map { MetadataProducer(name: $0) },
                        payloadIndices: [index],
                        generations: [summary]
                    )
                )
            } catch {
                output.diagnostics.append(
                    .init(severity: .warning, message: "Draw Things XMP contains invalid UserComment JSON")
                )
            }
        }
        return output
    }

    private static func generationSummary(from object: [String: JSONValue]) -> GenerationRecord {
        let version2 = object["v2"]?.objectValue ?? [:]
        let dimensions = dimensions(
            size: object["size"]?.stringValue,
            width: version2["width"]?.intValue,
            height: version2["height"]?.intValue
        )

        var resources = drawThingsResources(version2["loras"], kind: .lora)
        resources += drawThingsResources(version2["controls"], kind: .control)

        return GenerationRecord(
            // A present but empty prompt is an explicitly empty prompt.
            positivePrompt: object["c"]?.stringValue,
            negativePrompt: object["uc"]?.stringValue,
            model: object["model"]?.stringValue?.nonEmpty ?? version2["model"]?.stringValue?.nonEmpty,
            sampler: object["sampler"]?.stringValue?.nonEmpty,
            steps: object["steps"]?.intValue ?? version2["steps"]?.intValue,
            cfgScale: object["scale"]?.doubleValue ?? version2["guidanceScale"]?.doubleValue,
            seed: object["seed"]?.stringValue ?? version2["seed"]?.stringValue,
            dimensions: dimensions,
            denoise: object["strength"]?.doubleValue ?? version2["strength"]?.doubleValue,
            resources: resources
        )
    }

    private static func dimensions(size: String?, width: Int?, height: Int?) -> PixelDimensions? {
        if let size {
            let pieces = size.lowercased().split(separator: "x", maxSplits: 1)
            if pieces.count == 2, let width = Int(pieces[0]), let height = Int(pieces[1]) {
                return PixelDimensions(width: width, height: height)
            }
        }
        guard let width, let height else { return nil }
        return PixelDimensions(width: width, height: height)
    }

    private static func drawThingsResources(
        _ value: JSONValue?,
        kind: GenerationResourceKind
    ) -> [GenerationResource] {
        value?.arrayValue?.compactMap { item in
            guard let object = item.objectValue else { return nil }
            return GenerationResource(
                kind: kind,
                name: object["file"]?.stringValue?.nonEmpty,
                weight: object["weight"]?.doubleValue
            )
        } ?? []
    }
}

private final class XMPGenerationFields: NSObject, XMLParserDelegate {
    private(set) var creatorTool: String?
    private(set) var userComment: String?
    private var capturedElement: String?
    private var capturedText = ""

    static func parse(_ text: String) -> XMPGenerationFields? {
        let fields = XMPGenerationFields()
        let parser = XMLParser(data: Data(text.utf8))
        parser.delegate = fields
        parser.shouldResolveExternalEntities = false
        return parser.parse() ? fields : nil
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let localName = elementName.split(separator: ":").last.map(String.init)
        if localName == "CreatorTool" || localName == "UserComment" {
            capturedElement = localName
            capturedText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturedElement != nil { capturedText += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let localName = elementName.split(separator: ":").last.map(String.init)
        guard localName == capturedElement else { return }
        let value = capturedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if localName == "CreatorTool" { creatorTool = value }
        if localName == "UserComment" { userComment = value }
        capturedElement = nil
        capturedText = ""
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
