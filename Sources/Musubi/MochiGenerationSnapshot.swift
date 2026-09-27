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
