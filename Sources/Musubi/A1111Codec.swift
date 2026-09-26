import Foundation

enum A1111Codec {
    static func decode(_ payloads: [EmbeddedMetadataPayload]) -> CodecOutput {
        var output = CodecOutput()
        // Images from Civitai's own generator carry an Exif Artist of "ai".
        let civitaiArtistPresent = payloads.contains {
            $0.keyword == "Artist" && $0.text?.lowercased() == "ai"
        }

        for (index, payload) in payloads.enumerated() {
            guard let text = payload.text,
                payload.keyword == "parameters" || payload.keyword == "UserComment" || payload.kind == .jpegComment,
                let parsed = parse(text)
            else { continue }

            output.interpretations.append(
                .init(
                    format: .automatic1111,
                    producer: parsed.producer ?? (civitaiArtistPresent ? civitaiProducer : nil),
                    payloadIndices: [index],
                    generations: [parsed.summary]
                )
            )
        }
        return output
    }

    private static let civitaiProducer = MetadataProducer(name: "Civitai")

    private struct ParsedParameters {
        let summary: GenerationRecord
        let producer: MetadataProducer?
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
            let hashes = values["Model hash"]?.nonEmpty.map { [modelHash($0)] } ?? []
            resources.insert(.init(kind: .checkpoint, name: model, hashes: hashes), at: 0)
        }

        let summary = GenerationRecord(
            positivePrompt: positivePrompt.nonEmpty,
            negativePrompt: negativePrompt?.nonEmpty,
            model: values["Model"]?.nonEmpty,
            sampler: values["Sampler"]?.nonEmpty,
            scheduler: values["Schedule type"]?.nonEmpty,
            steps: values["Steps"].flatMap(Int.init),
            cfgScale: values["CFG scale"].flatMap(Double.init),
            seed: values["Seed"]?.nonEmpty,
            dimensions: parseDimensions(values["Size"]),
            denoise: values["Denoising strength"].flatMap(Double.init),
            resources: resources
        )
        return ParsedParameters(summary: summary, producer: producer(values))
    }

    /// The writer named by a `Software` setting. Civitai's generator names
    /// itself only through its `Civitai metadata` extension. Other Civitai
    /// fields, such as `Civitai resources`, are written by many applications
    /// and do not identify the producer.
    private static func producer(_ values: [String: String]) -> MetadataProducer? {
        if let software = values["Software"]?.nonEmpty {
            return softwareProducer(software)
        }
        return values["Civitai metadata"] != nil ? civitaiProducer : nil
    }

    /// Splits a trailing version from a `Software` value such as
    /// `Mochi Diffusion 6.2`. A value without a trailing version is all name.
    private static func softwareProducer(_ software: String) -> MetadataProducer {
        guard let space = software.lastIndex(of: " ") else { return MetadataProducer(name: software) }
        let name = software[..<space].trimmingCharacters(in: .whitespaces)
        let version = String(software[software.index(after: space)...])
        let versionStart = version.first == "v" ? version.dropFirst() : Substring(version)
        guard !name.isEmpty, versionStart.first?.isNumber == true else {
            return MetadataProducer(name: software)
        }
        return MetadataProducer(name: name, version: version)
    }

    /// AUTOMATIC1111 writes a short model hash whose length identifies its
    /// algorithm. Any other length stays unidentified.
    private static func modelHash(_ value: String) -> ResourceHash {
        let algorithm: ResourceHashAlgorithm? =
            switch value.count {
            case 8: .a1111AutoV1
            case 10: .a1111AutoV2
            case 64: .sha256
            default: nil
            }
        return ResourceHash(algorithm: algorithm, value: value)
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
        guard let value = value?.nonEmpty else { return .other }
        switch value.lowercased() {
        case "checkpoint", "model": return .checkpoint
        case "lora": return .lora
        case "vae": return .vae
        case "embedding", "textualinversion": return .embedding
        case "upscaler": return .upscaler
        case "controlnet", "control": return .control
        default: return GenerationResourceKind(rawValue: value)
        }
    }
}
