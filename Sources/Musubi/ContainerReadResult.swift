import Foundation

struct ContainerReadResult {
    let format: ImageContainerFormat
    let dimensions: PixelDimensions
    var payloads: [EmbeddedMetadataPayload]
    var diagnostics: [MetadataDiagnostic]
}
