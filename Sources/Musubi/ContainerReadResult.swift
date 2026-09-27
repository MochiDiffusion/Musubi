import Foundation

struct ContainerReadResult {
    let format: ImageContainerFormat
    let dimensions: PixelDimensions
    var payloads: [EmbeddedMetadataPayload]
    var diagnostics: [MetadataDiagnostic]
}

/// Keeps payloads up to ``InputLimits/payloadCount`` and reports, once, that
/// later ones were dropped.
func append(
    _ newPayloads: [EmbeddedMetadataPayload],
    to payloads: inout [EmbeddedMetadataPayload],
    diagnostics: inout [MetadataDiagnostic]
) {
    let room = max(0, InputLimits.payloadCount - payloads.count)
    if newPayloads.count > room, !diagnostics.contains(where: { $0.message == payloadLimitMessage }) {
        diagnostics.append(MetadataDiagnostic(severity: .warning, message: payloadLimitMessage))
    }
    payloads.append(contentsOf: newPayloads.prefix(room))
}

let payloadLimitMessage = "Metadata payloads beyond the first \(InputLimits.payloadCount) were ignored"
