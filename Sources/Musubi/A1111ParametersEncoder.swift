import Foundation

/// The result of projecting a generation into AUTOMATIC1111-compatible text.
public struct A1111ParametersEncoding: Equatable, Sendable {
    /// The `parameters` text, or `nil` when no safe projection exists. A reader
    /// would take a wrong value from an unsafe projection, so none is written.
    public let text: String?
    /// Every value the text leaves out or changes, and why.
    public let diagnostics: [MetadataDiagnostic]

    public init(text: String?, diagnostics: [MetadataDiagnostic]) {
        self.text = text
        self.diagnostics = diagnostics
    }
}

/// Writes the AUTOMATIC1111 infotext that Civitai and other readers parse.
///
/// The text has prompt lines, an optional `Negative prompt:` section and one
/// settings line. Only values that the generation records are written: this
/// encoder never adds a step count, CFG scale, sampler, seed or resource
/// identity to satisfy a reader. The format cannot carry every prompt exactly,
/// so ``MochiNativeCodec`` stays the exact record.
///
/// Each named LoRA is appended to the prompt line as a `<lora:name:weight>`
/// tag, the form the WebUI itself writes and readers recognize. The tags exist
/// only in this text. The generation's prompt, and so the native record, stays
/// as the user typed it.
public enum A1111ParametersEncoder {
    /// The largest text the encoder writes, in UTF-8 bytes.
    public static let maximumTextSize = 1_024 * 1_024

    /// Readers treat a final line with fewer settings than this as prompt text.
    static let minimumSettingsCount = 3

    /// Projects `generation` into AUTOMATIC1111-compatible text.
    ///
    /// - Parameter producer: Written as the `Software` setting.
    public static func encode(
        _ generation: GenerationRecord,
        producer: MetadataProducer?
    ) -> A1111ParametersEncoding {
        var diagnostics: [MetadataDiagnostic] = []
        func omit(_ message: String) {
            diagnostics.append(MetadataDiagnostic(severity: .warning, message: message))
        }
        func refuse(_ message: String) -> A1111ParametersEncoding {
            omit(message)
            return A1111ParametersEncoding(text: nil, diagnostics: diagnostics)
        }

        let typedPrompt = generation.positivePrompt ?? ""
        let negativePrompt = generation.negativePrompt ?? ""
        if let marker = reservedMarker(in: typedPrompt) ?? reservedMarker(in: negativePrompt) {
            return refuse("A prompt line starts with \"\(marker)\", so readers would misread the settings")
        }
        if changesUnderLineTrimming(typedPrompt) || changesUnderLineTrimming(negativePrompt) {
            omit("Readers trim whitespace at the ends of prompt lines")
        }

        var settings: [String] = []
        func add(_ key: String, _ value: String?) {
            if let value { settings.append("\(key): \(quoted(value))") }
        }
        func add(_ key: String, number value: Double?) {
            guard let value else { return }
            guard value.isFinite else { return omit("\(key) is not a finite number") }
            settings.append("\(key): \(value)")
        }

        add("Steps", generation.steps.map(String.init))
        add("Sampler", generation.sampler)
        add("Schedule type", generation.scheduler)
        add("CFG scale", number: generation.cfgScale)
        add("Seed", generation.seed)
        add("Size", generation.dimensions.map { "\($0.width)x\($0.height)" })
        add("Model", generation.model)
        add("Model hash", modelHash(generation.resources))
        add("Denoising strength", number: generation.denoise)
        add("Lora hashes", loraHashes(generation.resources))
        add("Software", producer.map { [$0.name, $0.version].compactMap { $0 }.joined(separator: " ") })
        for resource in generation.resources where !isProjected(resource) {
            omit("The \(resource.kind.rawValue) resource \(resource.name ?? "without a name") has no supported field")
        }
        // Unquoted JSON, as Civitai writes it, and last, because readers that do
        // not parse JSON values stop at its first comma.
        if let resources = civitaiResources(generation.resources) {
            settings.append("Civitai resources: \(resources)")
        }

        guard settings.count >= minimumSettingsCount else {
            return refuse(
                "Fewer than \(minimumSettingsCount) settings are known, so readers would read them as prompt text")
        }

        let tags = generation.resources.compactMap(loraTag)
        let prompt = ([typedPrompt].filter { !$0.isEmpty } + tags).joined(separator: " ")
        var lines = [prompt]
        if !negativePrompt.isEmpty { lines.append("Negative prompt: \(negativePrompt)") }
        lines.append(settings.joined(separator: ", "))
        let text = lines.joined(separator: "\n")

        guard !text.contains("\0") else {
            return refuse("The text contains a NUL character, which the format cannot carry")
        }
        let size = text.utf8.count
        guard size <= maximumTextSize else {
            return refuse("The text is \(size) bytes, over the \(maximumTextSize)-byte limit")
        }
        return A1111ParametersEncoding(text: text, diagnostics: diagnostics)
    }

    // MARK: - Prompts

    /// Readers start the negative prompt at a line that begins with
    /// `Negative prompt:`, and Civitai takes a line that begins with `Steps:` as
    /// the settings line. A prompt line with either prefix is misread.
    private static func reservedMarker(in prompt: String) -> String? {
        for line in prompt.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for marker in ["Negative prompt:", "Steps:"] where trimmed.hasPrefix(marker) {
                return marker
            }
        }
        return nil
    }

    private static func changesUnderLineTrimming(_ prompt: String) -> Bool {
        prompt.split(separator: "\n", omittingEmptySubsequences: false).contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) != $0
        }
    }

    // MARK: - Values

    /// Quotes a value the way AUTOMATIC1111 does: as a JSON string when it
    /// contains a comma, colon or line break. A value that starts with a quote
    /// or has whitespace at either end is quoted too, because readers would
    /// otherwise change it.
    static func quoted(_ value: String) -> String {
        let needsQuotes =
            value.contains(",") || value.contains(":") || value.contains("\n") || value.contains("\r")
            || value.hasPrefix("\"") || value.trimmingCharacters(in: .whitespaces) != value
        return needsQuotes ? jsonString(value) : value
    }

    /// A JSON string literal that keeps non-ASCII characters as they are, like
    /// Python's `json.dumps(ensure_ascii=False)`.
    private static func jsonString(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            case let control where control.value < 0x20:
                result += String(format: "\\u%04x", control.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    // MARK: - Resources

    /// The fields below match the forms that the pinned AUTOMATIC1111 and
    /// Civitai readers were tested with. A resource they do not cover is
    /// reported, not written in an untested form.
    private static func isProjected(_ resource: GenerationResource) -> Bool {
        switch resource.kind {
        case .checkpoint: true
        case .lora:
            loraTag(resource) != nil || shortHash(resource) != nil || resource.civitaiModelVersionID != nil
        default: false
        }
    }

    /// `<lora:name:weight>`, or `<lora:name>` when the weight is unknown. A
    /// name that contains a colon, `>` or a line break would end the tag early,
    /// so it has no tag.
    private static func loraTag(_ resource: GenerationResource) -> String? {
        guard resource.kind == .lora, let name = resource.name, !name.isEmpty,
            !name.contains(where: { ":>\n\r".contains($0) })
        else { return nil }
        guard let weight = resource.weight, weight.isFinite else { return "<lora:\(name)>" }
        return "<lora:\(name):\(weight)>"
    }

    private static func shortHash(_ resource: GenerationResource) -> String? {
        resource.hashes.first { $0.algorithm == .a1111AutoV2 }?.value
            ?? resource.hashes.first { $0.algorithm == .a1111AutoV1 }?.value
    }

    private static func modelHash(_ resources: [GenerationResource]) -> String? {
        resources.first { $0.kind == .checkpoint }.flatMap(shortHash)
    }

    private static func loraHashes(_ resources: [GenerationResource]) -> String? {
        let entries = resources.compactMap { resource -> String? in
            guard resource.kind == .lora, let name = resource.name, let hash = shortHash(resource) else { return nil }
            return "\(name): \(hash)"
        }
        return entries.isEmpty ? nil : entries.joined(separator: ", ")
    }

    private static func civitaiResources(_ resources: [GenerationResource]) -> String? {
        let entries = resources.compactMap { resource -> String? in
            guard resource.kind == .lora, let versionID = resource.civitaiModelVersionID else { return nil }
            var fields = ["\"type\":\"lora\"", "\"modelVersionId\":\(versionID)"]
            if let weight = resource.weight, weight.isFinite { fields.append("\"weight\":\(weight)") }
            return "{" + fields.joined(separator: ",") + "}"
        }
        return entries.isEmpty ? nil : "[" + entries.joined(separator: ",") + "]"
    }
}
