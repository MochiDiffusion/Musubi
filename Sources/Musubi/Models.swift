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

/// The application or metadata convention recognized in a payload.
public enum GenerationSource: String, Codable, Sendable {
    case drawThings
    case comfyUI
    case civitai
    case automatic1111
    case mochiDiffusion
}

/// The role of a model or auxiliary resource in image generation.
public enum GenerationResourceKind: String, Codable, Sendable {
    case checkpoint
    case lora
    case vae
    case textEncoder
    case upscaler
    case control
    case other
}

/// A model or auxiliary resource referenced by generation metadata.
///
/// Identity fields are independent because a source may provide a display
/// name, hash, AIR identifier, Civitai model version ID, or any combination of
/// them.
public struct GenerationResource: Codable, Equatable, Sendable {
    public let kind: GenerationResourceKind
    public let name: String?
    public let weight: Double?
    public let hash: String?
    public let air: String?
    public let civitaiModelVersionID: Int?

    public init(
        kind: GenerationResourceKind,
        name: String? = nil,
        weight: Double? = nil,
        hash: String? = nil,
        air: String? = nil,
        civitaiModelVersionID: Int? = nil
    ) {
        self.kind = kind
        self.name = name
        self.weight = weight
        self.hash = hash
        self.air = air
        self.civitaiModelVersionID = civitaiModelVersionID
    }
}

/// A source-neutral projection of one image-generation operation.
///
/// Fields are optional because metadata formats have different capabilities
/// and incomplete records are common. `seed` is text so clients do not have to
/// choose a numeric width.
public struct GenerationRecord: Codable, Equatable, Sendable {
    public var positivePrompt: String?
    public var negativePrompt: String?
    public var model: String?
    public var sampler: String?
    public var scheduler: String?
    public var steps: Int?
    public var guidance: Double?
    public var seed: String?
    public var dimensions: PixelDimensions?
    public var denoise: Double?
    public var resources: [GenerationResource]
    public var additionalValues: [String: String]

    public init(
        positivePrompt: String? = nil,
        negativePrompt: String? = nil,
        model: String? = nil,
        sampler: String? = nil,
        scheduler: String? = nil,
        steps: Int? = nil,
        guidance: Double? = nil,
        seed: String? = nil,
        dimensions: PixelDimensions? = nil,
        denoise: Double? = nil,
        resources: [GenerationResource] = [],
        additionalValues: [String: String] = [:]
    ) {
        self.positivePrompt = positivePrompt
        self.negativePrompt = negativePrompt
        self.model = model
        self.sampler = sampler
        self.scheduler = scheduler
        self.steps = steps
        self.guidance = guidance
        self.seed = seed
        self.dimensions = dimensions
        self.denoise = denoise
        self.resources = resources
        self.additionalValues = additionalValues
    }
}

/// One source-specific interpretation of one or more embedded payloads.
///
/// An image can have several interpretations, such as a ComfyUI workflow and
/// an A1111-compatible payload added for Civitai.
public struct MetadataInterpretation: Codable, Equatable, Sendable {
    public let source: GenerationSource
    public let sourceVersion: String?
    public let payloadIndices: [Int]
    public let generations: [GenerationRecord]

    public init(
        source: GenerationSource,
        sourceVersion: String? = nil,
        payloadIndices: [Int],
        generations: [GenerationRecord]
    ) {
        self.source = source
        self.sourceVersion = sourceVersion
        self.payloadIndices = payloadIndices
        self.generations = generations
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
