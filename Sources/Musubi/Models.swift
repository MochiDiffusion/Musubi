import Foundation

/// An image container that Musubi knows how to inspect.
public enum ImageContainerFormat: String, Codable, Sendable {
    case png
    case jpeg
}

/// Pixel dimensions reported by an image container or generation payload.
public struct PixelDimensions: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// The physical carrier from which an embedded metadata payload was read.
public enum EmbeddedMetadataKind: String, Codable, Sendable {
    case pngText
    case pngExif
    case jpegExif
    case jpegComment
    case xmp
    case exifValue
}

/// An ordered metadata payload found inside an image container.
///
/// Musubi preserves the carrier bytes in `data`, even when it can also expose a
/// decoded `text` representation. Payloads remain in file order and may have
/// duplicate keywords.
public struct EmbeddedMetadataPayload: Codable, Equatable, Sendable {
    public let kind: EmbeddedMetadataKind
    public let keyword: String?
    public let data: Data
    public let text: String?

    public init(
        kind: EmbeddedMetadataKind,
        keyword: String? = nil,
        data: Data,
        text: String? = nil
    ) {
        self.kind = kind
        self.keyword = keyword
        self.data = data
        self.text = text
    }
}

/// The metadata dialect that a codec recognized in one or more payloads.
///
/// A format describes how the metadata is written, not which application wrote
/// it. Several applications write AUTOMATIC1111-compatible text, for example.
/// See ``MetadataInterpretation/producer`` for the writing application.
public enum MetadataFormat: String, Codable, Sendable {
    /// AUTOMATIC1111-compatible `parameters` text, including Civitai extensions.
    case automatic1111
    /// A ComfyUI execution graph.
    case comfyUI
    /// Draw Things XMP with a JSON configuration.
    case drawThings
    /// The IPTC caption written by Mochi Diffusion 2.2 through 6.1.2: fields
    /// joined by `"; "` through 6.0, and one escaped field per line from 6.1.
    case mochiDiffusionLegacyCaption
    /// Mochi Diffusion's versioned native record. See ``MochiNativeCodec``.
    case mochiDiffusion
}

/// The application that the metadata names as its writer.
///
/// Musubi reports a producer only when the metadata names one. It does not infer
/// the producer from the format.
public struct MetadataProducer: Codable, Equatable, Sendable {
    public let name: String
    public let version: String?

    public init(name: String, version: String? = nil) {
        self.name = name
        self.version = version
    }
}

/// The role of a model or auxiliary resource in image generation.
///
/// Sources use open-ended vocabularies, so a kind is a string. The static
/// members are the kinds Musubi normalizes. A source spelling that Musubi does
/// not recognize is kept as it was written.
public struct GenerationResourceKind: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let checkpoint = Self(rawValue: "checkpoint")
    public static let lora = Self(rawValue: "lora")
    public static let vae = Self(rawValue: "vae")
    /// A text encoder model, such as a CLIP or T5 checkpoint.
    public static let textEncoder = Self(rawValue: "textEncoder")
    /// A textual-inversion embedding. This is not a text encoder.
    public static let embedding = Self(rawValue: "embedding")
    public static let upscaler = Self(rawValue: "upscaler")
    public static let control = Self(rawValue: "control")
    /// A resource whose source gives no kind.
    public static let other = Self(rawValue: "other")
}

/// The algorithm that produced a resource hash.
///
/// Hashes from different algorithms are not interchangeable, even when their
/// values look alike.
public struct ResourceHashAlgorithm: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// The full SHA-256 of the resource file, as 64 hexadecimal digits.
    public static let sha256 = Self(rawValue: "sha256")
    /// AUTOMATIC1111's original short model hash, 8 hexadecimal digits.
    public static let a1111AutoV1 = Self(rawValue: "a1111-auto-v1")
    /// AUTOMATIC1111's current short model hash: the first 10 hexadecimal
    /// digits of the file's SHA-256.
    public static let a1111AutoV2 = Self(rawValue: "a1111-auto-v2")
}

/// One hash that a source gives for a resource.
public struct ResourceHash: Codable, Equatable, Sendable {
    /// The algorithm, or `nil` when the source does not identify it.
    public let algorithm: ResourceHashAlgorithm?
    public let value: String

    public init(algorithm: ResourceHashAlgorithm?, value: String) {
        self.algorithm = algorithm
        self.value = value
    }
}

/// A model or auxiliary resource referenced by generation metadata.
///
/// Identity fields are independent because a source may provide a display
/// name, hashes, an AIR identifier, a Civitai model version ID, or any
/// combination of them. They are separate evidence, not lookup keys for each
/// other.
public struct GenerationResource: Codable, Equatable, Sendable {
    public let kind: GenerationResourceKind
    public let name: String?
    public let weight: Double?
    public let hashes: [ResourceHash]
    public let air: String?
    public let civitaiModelVersionID: Int?

    public init(
        kind: GenerationResourceKind,
        name: String? = nil,
        weight: Double? = nil,
        hashes: [ResourceHash] = [],
        air: String? = nil,
        civitaiModelVersionID: Int? = nil
    ) {
        self.kind = kind
        self.name = name
        self.weight = weight
        self.hashes = hashes
        self.air = air
        self.civitaiModelVersionID = civitaiModelVersionID
    }
}

/// A source-specific setting that has no common field.
///
/// Parameters stay in source order, and a key can repeat.
public struct GenerationParameter: Codable, Equatable, Sendable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// A source-neutral projection of one image-generation operation.
///
/// Fields are optional because metadata formats have different capabilities
/// and incomplete records are common. `nil` means the source did not record a
/// value. `seed` is text so clients do not have to choose a numeric width.
public struct GenerationRecord: Codable, Equatable, Sendable {
    public var positivePrompt: String?
    public var negativePrompt: String?
    public var model: String?
    /// The sampling method, such as `DPM++ 2M` or `euler`.
    public var sampler: String?
    /// The noise schedule or step spacing, such as `Karras`, when the source
    /// records it separately from the sampler.
    public var scheduler: String?
    public var steps: Int?
    /// The classifier-free guidance scale. Other kinds of guidance, such as a
    /// distilled guidance embedding, are not stored here.
    public var cfgScale: Double?
    public var seed: String?
    /// The generation size that the metadata claims. The encoded image size is
    /// ``MetadataInspection/imageDimensions``.
    public var dimensions: PixelDimensions?
    public var denoise: Double?
    /// When the image was generated, if the metadata records it. This is not a
    /// file modification time.
    public var generatedAt: Date?
    public var resources: [GenerationResource]
    public var parameters: [GenerationParameter]

    public init(
        positivePrompt: String? = nil,
        negativePrompt: String? = nil,
        model: String? = nil,
        sampler: String? = nil,
        scheduler: String? = nil,
        steps: Int? = nil,
        cfgScale: Double? = nil,
        seed: String? = nil,
        dimensions: PixelDimensions? = nil,
        denoise: Double? = nil,
        generatedAt: Date? = nil,
        resources: [GenerationResource] = [],
        parameters: [GenerationParameter] = []
    ) {
        self.positivePrompt = positivePrompt
        self.negativePrompt = negativePrompt
        self.model = model
        self.sampler = sampler
        self.scheduler = scheduler
        self.steps = steps
        self.cfgScale = cfgScale
        self.seed = seed
        self.dimensions = dimensions
        self.denoise = denoise
        self.generatedAt = generatedAt
        self.resources = resources
        self.parameters = parameters
    }
}

/// One format-specific interpretation of one or more embedded payloads.
///
/// An image can have several interpretations, such as a ComfyUI workflow and
/// an AUTOMATIC1111-compatible payload added for Civitai.
public struct MetadataInterpretation: Codable, Equatable, Sendable {
    public let format: MetadataFormat
    /// The application that the metadata names as its writer, or `nil` when it
    /// names none.
    public let producer: MetadataProducer?
    public let payloadIndices: [Int]
    public let generations: [GenerationRecord]

    public init(
        format: MetadataFormat,
        producer: MetadataProducer? = nil,
        payloadIndices: [Int],
        generations: [GenerationRecord]
    ) {
        self.format = format
        self.producer = producer
        self.payloadIndices = payloadIndices
        self.generations = generations
    }
}

/// The interpretations of a list of payloads, without a container.
///
/// Returned by ``MetadataInspector/interpret(_:)``.
public struct PayloadInterpretation: Codable, Equatable, Sendable {
    public let interpretations: [MetadataInterpretation]
    public let diagnostics: [MetadataDiagnostic]

    public init(interpretations: [MetadataInterpretation], diagnostics: [MetadataDiagnostic]) {
        self.interpretations = interpretations
        self.diagnostics = diagnostics
    }
}

/// The importance of a non-fatal issue discovered during inspection.
public enum MetadataDiagnosticSeverity: String, Codable, Sendable {
    case warning
    case error
}

/// A problem that did not prevent Musubi from returning an inspection result.
public struct MetadataDiagnostic: Codable, Equatable, Sendable {
    public let severity: MetadataDiagnosticSeverity
    public let message: String

    public init(severity: MetadataDiagnosticSeverity, message: String) {
        self.severity = severity
        self.message = message
    }
}

/// The complete result of inspecting one encoded image.
///
/// Raw payloads and normalized interpretations are both returned so clients
/// can present useful fields without losing source-specific information.
public struct MetadataInspection: Codable, Equatable, Sendable {
    public let container: ImageContainerFormat
    public let imageDimensions: PixelDimensions
    public let payloads: [EmbeddedMetadataPayload]
    public let interpretations: [MetadataInterpretation]
    public let diagnostics: [MetadataDiagnostic]

    public init(
        container: ImageContainerFormat,
        imageDimensions: PixelDimensions,
        payloads: [EmbeddedMetadataPayload],
        interpretations: [MetadataInterpretation],
        diagnostics: [MetadataDiagnostic]
    ) {
        self.container = container
        self.imageDimensions = imageDimensions
        self.payloads = payloads
        self.interpretations = interpretations
        self.diagnostics = diagnostics
    }
}

/// An error that prevents an encoded image from being inspected safely.
public enum MetadataInspectionError: Error, Equatable, Sendable {
    case unsupportedContainer
    case malformedContainer(String)
    case metadataLimitExceeded(String)
}

extension MetadataInspectionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedContainer:
            "Unsupported image container"
        case .malformedContainer(let reason), .metadataLimitExceeded(let reason):
            reason
        }
    }
}
