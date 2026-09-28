import Foundation

/// Everything Mochi Diffusion records about one generated image.
///
/// Mochi builds one snapshot per output image. ``MochiNativeCodec`` writes it as
/// the native record, and ``A1111ParametersEncoder`` projects its `generation`
/// into AUTOMATIC1111-compatible text, so both payloads describe the same
/// values.
public struct MochiGenerationSnapshot: Equatable, Sendable {
    /// The application that wrote the record.
    public var producer: MetadataProducer
    /// The generation settings. Engine settings that have no common field go in
    /// `generation.parameters`.
    public var generation: GenerationRecord
    public var details: MochiGenerationDetails

    public init(
        producer: MetadataProducer,
        generation: GenerationRecord,
        details: MochiGenerationDetails = MochiGenerationDetails()
    ) {
        self.producer = producer
        self.generation = generation
        self.details = details
    }
}

/// Mochi-specific facts about a generation.
///
/// `nil` means the value does not apply or is unknown. Image names are file
/// basenames, never paths.
public struct MochiGenerationDetails: Equatable, Sendable {
    /// Mochi's identifier for the engine that ran the generation.
    public var engine: String?
    /// The engine's own key for the model.
    public var modelKey: String?
    public var quality: String?
    public var computeUnit: String?
    public var startingImage: String?
    public var controlNetImage: String?
    /// Reference images in the order the engine used them. An empty string
    /// stands for a reference that had no filename, so the count stays true.
    public var inputImages: [String]?

    public init(
        engine: String? = nil,
        modelKey: String? = nil,
        quality: String? = nil,
        computeUnit: String? = nil,
        startingImage: String? = nil,
        controlNetImage: String? = nil,
        inputImages: [String]? = nil
    ) {
        self.engine = engine
        self.modelKey = modelKey
        self.quality = quality
        self.computeUnit = computeUnit
        self.startingImage = startingImage
        self.controlNetImage = controlNetImage
        self.inputImages = inputImages
    }
}

extension MochiGenerationDetails {
    /// The Mochi details that `interpretation` records, or `nil` when it is not
    /// a Mochi Diffusion record.
    ///
    /// A native record's details are read from its payload. A released caption's
    /// details come from its fields. The 6.1 caption lists each input image
    /// separately; earlier captions join them with commas, so a name that
    /// contains a comma cannot be recovered from them.
    /// - Parameters:
    ///   - interpretation: An interpretation of `payloads`.
    ///   - payloads: The payloads the interpretation indexes, such as
    ///     ``MetadataInspection/payloads``.
    public init?(_ interpretation: MetadataInterpretation, payloads: [EmbeddedMetadataPayload]) {
        switch interpretation.format {
        case .mochiDiffusion:
            guard let index = interpretation.payloadIndices.first, payloads.indices.contains(index),
                let text = payloads[index].text,
                let snapshot = try? MochiNativeCodec.decodeXMPPacket(text)
            else { return nil }
            self = snapshot.details
        case .mochiDiffusionLegacyCaption:
            guard let generation = interpretation.generations.first else { return nil }
            self = MochiLegacyCodec.details(generation.parameters)
        case .automatic1111, .comfyUI, .drawThings:
            return nil
        }
    }
}
