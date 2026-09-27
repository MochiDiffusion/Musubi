import Foundation

/// Reads AUTOMATIC1111-compatible `parameters` text.
///
/// The reading follows the WebUI's own parser: the last line holds the
/// settings when it has at least three of them, each earlier line is trimmed,
/// and a line that starts with `Negative prompt:` begins the negative prompt.
/// Quoted values are unquoted as JSON strings. Settings without a common field
/// stay in the record's parameters, in order.
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
                // Only the `parameters` keyword names generation text. In a
                // general comment carrier, a Steps setting is also required.
                let parsed = parse(text, requireSteps: payload.keyword != "parameters")
            else { continue }

            output.diagnostics += parsed.diagnostics
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
    private static let mochiProducerName = "Mochi Diffusion"

    /// Settings that readers use to recognize generation text.
    private static let generationKeys: Set<String> = ["Steps", "Sampler", "CFG scale", "Seed", "Size", "Model"]

    /// Settings that map to common fields. All others become parameters.
    private static let commonKeys: Set<String> = [
        "Steps", "Sampler", "Schedule type", "CFG scale", "Seed", "Size", "Model", "Model hash",
        "Denoising strength", "Lora hashes", "Civitai resources", "Software",
    ]

    private struct ParsedParameters {
        let summary: GenerationRecord
        let producer: MetadataProducer?
        let diagnostics: [MetadataDiagnostic]
    }

    private static func parse(_ text: String, requireSteps: Bool) -> ParsedParameters? {
        var lines =
            text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n")
        guard let settingsLine = lines.popLast() else { return nil }
        let settings = SettingsLine.parse(settingsLine)
        let keys = Set(settings.map(\.key))
        guard settings.count >= A1111ParametersEncoder.minimumSettingsCount,
            !keys.isDisjoint(with: generationKeys),
            !requireSteps || keys.contains("Steps")
        else { return nil }

        var diagnostics: [MetadataDiagnostic] = []
        var values = SettingValues(settings, commonKeys: commonKeys, diagnostics: &diagnostics)
        let producer = producer(values)
        let (positive, negative) = prompts(lines)

        let loraTags = LoRATag.all(in: positive)
        let prompt = producer?.name == mochiProducerName ? LoRATag.removingTrailing(from: positive) : positive
        let summary = GenerationRecord(
            positivePrompt: prompt,
            negativePrompt: negative,
            model: values.text("Model"),
            sampler: values.text("Sampler"),
            scheduler: values.text("Schedule type"),
            steps: values.positiveInteger("Steps", diagnostics: &diagnostics),
            cfgScale: values.finiteNumber("CFG scale", diagnostics: &diagnostics),
            seed: values.seed(diagnostics: &diagnostics),
            dimensions: values.size(diagnostics: &diagnostics),
            denoise: values.finiteNumber("Denoising strength", diagnostics: &diagnostics),
            resources: resources(values, loraTags: loraTags, diagnostics: &diagnostics),
            parameters: values.parameters
        )
        return ParsedParameters(summary: summary, producer: producer, diagnostics: diagnostics)
    }

    /// The prompt and negative prompt, read as the WebUI reads them. The prompt
    /// is always present, possibly empty. The negative prompt is `nil` when
    /// the text has no `Negative prompt:` line.
    private static func prompts(_ lines: [String]) -> (String, String?) {
        let marker = "Negative prompt:"
        var positive: [String] = []
        var negative: [String]?
        for line in lines {
            var line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(marker) {
                negative = negative ?? []
                line = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            }
            if negative != nil {
                negative?.append(line)
            } else {
                positive.append(line)
            }
        }
        return (positive.joined(separator: "\n"), negative?.joined(separator: "\n"))
    }

    // MARK: - Producer

    /// The writer named by a `Software` setting. Civitai's generator names
    /// itself only through its `Civitai metadata` extension. Other Civitai
    /// fields, such as `Civitai resources`, are written by many applications
    /// and do not identify the producer.
    private static func producer(_ values: SettingValues) -> MetadataProducer? {
        if let software = values.text("Software") {
            return softwareProducer(software)
        }
        return values.contains("Civitai metadata") ? civitaiProducer : nil
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

    // MARK: - Resources

    /// The checkpoint, then LoRAs from prompt tags with their `Lora hashes`,
    /// then `Lora hashes` entries without a tag, then Civitai resources. A
    /// Civitai LoRA whose name matches a tag joins that tag's resource.
    private static func resources(
        _ values: SettingValues,
        loraTags: [LoRATag],
        diagnostics: inout [MetadataDiagnostic]
    ) -> [GenerationResource] {
        var resources: [GenerationResource] = []
        if let model = values.text("Model") {
            let hashes = values.text("Model hash").map { [modelHash($0)] } ?? []
            resources.append(.init(kind: .checkpoint, name: model, hashes: hashes))
        }

        var loraHashes = loraHashEntries(values.text("Lora hashes"))
        var civitai = civitaiResources(values.text("Civitai resources"), diagnostics: &diagnostics)
        for tag in loraTags {
            let hash = loraHashes.first { $0.name == tag.name }
            loraHashes.removeAll { $0.name == tag.name }
            let match = civitai.firstIndex { $0.kind == .lora && $0.name == tag.name }
            let versionID = match.flatMap { civitai[$0].civitaiModelVersionID }
            let air = match.flatMap { civitai[$0].air }
            if let match { civitai.remove(at: match) }
            resources.append(
                .init(
                    kind: .lora, name: tag.name, weight: tag.weight,
                    hashes: hash.map { [modelHash($0.hash)] } ?? [], air: air, civitaiModelVersionID: versionID))
        }
        resources += loraHashes.map { .init(kind: .lora, name: $0.name, hashes: [modelHash($0.hash)]) }
        return resources + civitai
    }

    /// AUTOMATIC1111 writes a short hash whose length identifies its
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

    /// `name: hash, name: hash`, as the WebUI writes `Lora hashes`.
    private static func loraHashEntries(_ value: String?) -> [(name: String, hash: String)] {
        guard let value else { return [] }
        return value.components(separatedBy: ",").compactMap { entry in
            guard let colon = entry.lastIndex(of: ":") else { return nil }
            let name = entry[..<colon].trimmingCharacters(in: .whitespaces)
            let hash = entry[entry.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return name.isEmpty || hash.isEmpty ? nil : (name, hash)
        }
    }

    private static func civitaiResources(
        _ value: String?,
        diagnostics: inout [MetadataDiagnostic]
    ) -> [GenerationResource] {
        guard let value else { return [] }
        let json: JSONValue
        do {
            json = try UntrustedJSON.decode(value)
        } catch {
            diagnostics.append(.init(severity: .warning, message: "Civitai resources JSON was not read: \(error)"))
            return []
        }
        guard let items = json.arrayValue else { return [] }

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

// MARK: - Settings line

/// Splits a settings line into `key: value` pairs.
///
/// A value is a JSON string when it starts with a quote, a JSON array or
/// object when it starts with a bracket, and otherwise runs to the next comma.
/// A key must match the WebUI's pattern: a word character followed by word
/// characters, spaces, hyphens or slashes.
private enum SettingsLine {
    static func parse(_ line: String) -> [(key: String, value: String)] {
        let characters = Array(line)
        var index = 0
        var result: [(key: String, value: String)] = []

        while index < characters.count {
            while index < characters.count, characters[index] == " " { index += 1 }
            let keyStart = index
            while index < characters.count, characters[index] != ":", characters[index] != "," { index += 1 }
            guard index < characters.count, characters[index] == ":" else {
                index += 1
                continue
            }
            let key = String(characters[keyStart..<index]).trimmingCharacters(in: .whitespaces)
            index += 1
            while index < characters.count, characters[index] == " " { index += 1 }

            let valueStart = index
            if index < characters.count, characters[index] == "\"" {
                index = stringEnd(characters, from: index) + 1
            } else if index < characters.count, characters[index] == "[" || characters[index] == "{" {
                index = containerEnd(characters, from: index) + 1
            }
            while index < characters.count, characters[index] != "," { index += 1 }
            let value = String(characters[valueStart..<min(index, characters.count)])
                .trimmingCharacters(in: .whitespaces)
            index += 1

            if isValidKey(key) { result.append((key, unquoted(value))) }
        }
        return result
    }

    private static func isValidKey(_ key: String) -> Bool {
        guard let first = key.first, key.count >= 2, first.isLetter || first.isNumber || first == "_" else {
            return false
        }
        return key.allSatisfy { $0.isLetter || $0.isNumber || "_ -/".contains($0) }
    }

    /// The WebUI unquotes a value that starts and ends with a quote as a JSON
    /// string, and keeps it as written when that fails.
    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, value.first == "\"", value.last == "\"",
            let text = try? JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed)
                as? String
        else { return value }
        return text
    }

    /// The index of the closing quote, or the last index when there is none.
    private static func stringEnd(_ characters: [Character], from start: Int) -> Int {
        var index = start + 1
        while index < characters.count {
            if characters[index] == "\\" {
                index += 2
                continue
            }
            if characters[index] == "\"" { return index }
            index += 1
        }
        return characters.count - 1
    }

    /// The index that closes the JSON container, or the last index when it is
    /// never closed. Strings inside it are skipped.
    private static func containerEnd(_ characters: [Character], from start: Int) -> Int {
        var depth = 0
        var index = start
        while index < characters.count {
            switch characters[index] {
            case "\"": index = stringEnd(characters, from: index)
            case "[", "{": depth += 1
            case "]", "}":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
            index += 1
        }
        return characters.count - 1
    }
}

/// The settings of one line, with checks for the common fields.
private struct SettingValues {
    private var values: [String: String] = [:]
    private var conflicting: Set<String> = []
    private(set) var parameters: [GenerationParameter] = []

    /// A common setting that repeats with a different value is reported, left
    /// out of the common fields, and kept as parameters with every value.
    init(
        _ settings: [(key: String, value: String)],
        commonKeys: Set<String>,
        diagnostics: inout [MetadataDiagnostic]
    ) {
        for (key, value) in settings {
            guard commonKeys.contains(key) else {
                parameters.append(GenerationParameter(key: key, value: value))
                continue
            }
            if let existing = values[key], existing != value {
                if conflicting.insert(key).inserted {
                    diagnostics.append(.init(severity: .warning, message: "\(key) appears with different values"))
                    parameters.append(GenerationParameter(key: key, value: existing))
                }
                parameters.append(GenerationParameter(key: key, value: value))
            }
            values[key] = values[key] ?? value
        }
    }

    func contains(_ key: String) -> Bool {
        values[key] != nil || parameters.contains { $0.key == key }
    }

    /// The value of a common setting, or `nil` when it is absent, empty or
    /// given conflicting values.
    func text(_ key: String) -> String? {
        guard !conflicting.contains(key) else { return nil }
        return values[key]?.nonEmpty
    }

    mutating func positiveInteger(_ key: String, diagnostics: inout [MetadataDiagnostic]) -> Int? {
        checked(key, diagnostics: &diagnostics) { Int($0).flatMap { $0 > 0 ? $0 : nil } }
    }

    mutating func finiteNumber(_ key: String, diagnostics: inout [MetadataDiagnostic]) -> Double? {
        checked(key, diagnostics: &diagnostics) { Double($0).flatMap { $0.isFinite ? $0 : nil } }
    }

    mutating func seed(diagnostics: inout [MetadataDiagnostic]) -> String? {
        checked("Seed", diagnostics: &diagnostics) { $0.isDecimalInteger ? $0 : nil }
    }

    mutating func size(diagnostics: inout [MetadataDiagnostic]) -> PixelDimensions? {
        checked("Size", diagnostics: &diagnostics) { value in
            let pieces = value.lowercased().split(separator: "x", maxSplits: 1)
            guard pieces.count == 2, let width = Int(pieces[0]), let height = Int(pieces[1]), width > 0, height > 0
            else { return nil }
            return PixelDimensions(width: width, height: height)
        }
    }

    /// Converts a common setting. An invalid value is reported and kept as a
    /// parameter, so the raw text is still available.
    private mutating func checked<T>(
        _ key: String,
        diagnostics: inout [MetadataDiagnostic],
        convert: (String) -> T?
    ) -> T? {
        guard let value = text(key) else { return nil }
        if let converted = convert(value) { return converted }
        diagnostics.append(.init(severity: .warning, message: "\(key) has an invalid value"))
        parameters.append(GenerationParameter(key: key, value: value))
        return nil
    }
}

// MARK: - LoRA tags

/// A `<lora:name>` or `<lora:name:weight>` tag in a prompt. Extra fields, such
/// as a separate text-encoder weight, are ignored.
private struct LoRATag {
    let name: String
    let weight: Double?

    private static let pattern = try! NSRegularExpression(pattern: #"<lora:([^:>\n]+)((?::[^:>\n]*)*)>"#)

    static func all(in prompt: String) -> [LoRATag] {
        let range = NSRange(prompt.startIndex..., in: prompt)
        return pattern.matches(in: prompt, range: range).compactMap { match in
            guard let nameRange = Range(match.range(at: 1), in: prompt),
                let argumentsRange = Range(match.range(at: 2), in: prompt)
            else { return nil }
            let arguments = prompt[argumentsRange].split(separator: ":", omittingEmptySubsequences: false).dropFirst()
            let weight = arguments.first.flatMap { Double($0) }.flatMap { $0.isFinite ? $0 : nil }
            return LoRATag(name: String(prompt[nameRange]), weight: weight)
        }
    }

    /// The prompt without the run of tags that ``A1111ParametersEncoder``
    /// appends: each tag preceded by one space, at the very end. A tag that is
    /// not preceded by a space was typed by the user, so removal stops there.
    static func removingTrailing(from prompt: String) -> String {
        var result = Substring(prompt)
        while result.hasSuffix(">"), let start = result.range(of: "<lora:", options: .backwards)?.lowerBound {
            let tag = result[start...]
            guard tag.firstIndex(of: ">") == tag.index(before: tag.endIndex), all(in: String(tag)).count == 1
            else { break }
            let before = result[..<start]
            if before.isEmpty {
                result = before
                break
            }
            guard before.hasSuffix(" ") else { break }
            result = before.dropLast()
        }
        return String(result)
    }
}
