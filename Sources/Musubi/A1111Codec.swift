import Foundation

enum A1111Codec {
    static func decode(_ payloads: [EmbeddedMetadataPayload]) -> CodecOutput {
        var output = CodecOutput()
        let civitaiMarkerPresent = payloads.contains {
            $0.keyword == "Artist" && $0.text?.lowercased() == "ai"
        }

        for (index, payload) in payloads.enumerated() {
            guard let text = payload.text,
                payload.keyword == "parameters" || payload.keyword == "UserComment" || payload.kind == .jpegComment,
                let parsed = parse(text)
            else { continue }

            let source: GenerationSource = parsed.isCivitai || civitaiMarkerPresent ? .civitai : .automatic1111
            output.interpretations.append(
                .init(source: source, payloadIndices: [index], generations: [parsed.summary])
            )
        }
        return output
    }

    private struct ParsedParameters {
        let summary: GenerationRecord
        let isCivitai: Bool
    }

    private static func parse(_ text: String) -> ParsedParameters? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard let detailsRange = normalized.range(of: "\nSteps:", options: .backwards) else { return nil }

        let promptSection = String(normalized[..<detailsRange.lowerBound])
        let details = String(normalized[normalized.index(after: detailsRange.lowerBound)...])
        let negativeMarker = "\nNegative prompt:"
        let positivePrompt: String
        let negativePrompt: String?
        if let negativeRange = promptSection.range(of: negativeMarker, options: .backwards) {
            positivePrompt = String(promptSection[..<negativeRange.lowerBound]).trimmingCharacters(
                in: .whitespacesAndNewlines)
            negativePrompt = String(promptSection[negativeRange.upperBound...]).trimmingCharacters(
                in: .whitespacesAndNewlines)
        } else {
            positivePrompt = promptSection.trimmingCharacters(in: .whitespacesAndNewlines)
            negativePrompt = nil
        }

        let values = detailsValues(details)
        var resources = civitaiResources(values["Civitai resources"])
        if let model = values["Model"]?.nonEmpty {
            resources.insert(
                .init(kind: .checkpoint, name: model, hash: values["Model hash"]?.nonEmpty),
                at: 0
            )
        }

        let summary = GenerationRecord(
            positivePrompt: positivePrompt.nonEmpty,
            negativePrompt: negativePrompt?.nonEmpty,
            model: values["Model"]?.nonEmpty,
            sampler: values["Sampler"]?.nonEmpty,
            scheduler: values["Schedule type"]?.nonEmpty,
            steps: values["Steps"].flatMap(Int.init),
            guidance: values["CFG scale"].flatMap(Double.init),
            seed: values["Seed"]?.nonEmpty,
            dimensions: parseDimensions(values["Size"]),
            denoise: values["Denoising strength"].flatMap(Double.init),
            resources: resources
        )
        return ParsedParameters(
            summary: summary,
            isCivitai: values["Civitai resources"] != nil || values["Civitai metadata"] != nil
        )
    }

    private static func detailsValues(_ details: String) -> [String: String] {
        var result: [String: String] = [:]
        for component in splitTopLevel(details) {
            guard let colon = component.firstIndex(of: ":") else { continue }
            let key = component[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = component[component.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    private static func splitTopLevel(_ text: String) -> [String] {
        var result: [String] = []
        var start = text.startIndex
        var index = text.startIndex
        var depth = 0
        var quoted = false
        var escaped = false

        while index < text.endIndex {
            let character = text[index]
            if escaped {
                escaped = false
            } else if character == "\\" && quoted {
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
            } else if !quoted {
                if "[{(".contains(character) { depth += 1 }
                if "]})".contains(character) { depth = max(0, depth - 1) }
                if character == "," && depth == 0 {
                    result.append(String(text[start..<index]))
                    start = text.index(after: index)
                }
            }
            index = text.index(after: index)
        }
        result.append(String(text[start..<text.endIndex]))
        return result
    }

    private static func parseDimensions(_ value: String?) -> PixelDimensions? {
        guard let pieces = value?.lowercased().split(separator: "x", maxSplits: 1),
            pieces.count == 2,
            let width = Int(pieces[0]),
            let height = Int(pieces[1])
        else { return nil }
        return PixelDimensions(width: width, height: height)
    }

    private static func civitaiResources(_ value: String?) -> [GenerationResource] {
        guard let value,
            let json = try? JSONDecoder().decodeJSONValue(from: value),
            let items = json.arrayValue
        else { return [] }

        return items.compactMap { item in
            guard let object = item.objectValue else { return nil }
            return GenerationResource(
                kind: resourceKind(object["type"]?.stringValue),
                name: object["modelName"]?.stringValue ?? object["modelVersionName"]?.stringValue,
                weight: object["weight"]?.doubleValue ?? object["strength"]?.doubleValue,
                air: object["air"]?.stringValue,
                civitaiModelVersionID: object["modelVersionId"]?.intValue
            )
        }
    }

    private static func resourceKind(_ value: String?) -> GenerationResourceKind {
        switch value?.lowercased() {
        case "checkpoint", "model": .checkpoint
        case "lora": .lora
        case "vae": .vae
        case "embedding", "textualinversion": .textEncoder
        case "upscaler": .upscaler
        case "controlnet", "control": .control
        default: .other
        }
    }
}
