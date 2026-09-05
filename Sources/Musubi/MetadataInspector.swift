import Foundation

/// Inspects encoded images for generation metadata without decoding pixels.
public enum MetadataInspector {
    /// Inspects an encoded PNG or JPEG.
    ///
    /// - Parameter data: Complete encoded image data.
    /// - Returns: Ordered raw payloads, source interpretations, and diagnostics.
    /// - Throws: ``MetadataInspectionError`` when the container is unsupported
    ///   or cannot be scanned safely.
    public static func inspect(_ data: Data) throws -> MetadataInspection {
        let container = try readContainer(data)
        let codecOutputs = [
            DrawThingsCodec.decode(container.payloads),
            MochiLegacyCodec.decode(container.payloads),
            ComfyUICodec.decode(container.payloads),
            A1111Codec.decode(container.payloads),
        ]

        return MetadataInspection(
            container: container.format,
            imageDimensions: container.dimensions,
            payloads: container.payloads,
            interpretations: codecOutputs.flatMap(\.interpretations),
            diagnostics: container.diagnostics + codecOutputs.flatMap(\.diagnostics)
        )
    }

    /// Reads and inspects an encoded PNG or JPEG at `url`.
    public static func inspect(contentsOf url: URL) throws -> MetadataInspection {
        try inspect(Data(contentsOf: url, options: .mappedIfSafe))
    }

    private static func readContainer(_ data: Data) throws -> ContainerReadResult {
        if data.hasPrefix([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return try PNGMetadataReader.read(data)
        }
        if data.hasPrefix([0xFF, 0xD8]) {
            return try JPEGMetadataReader.read(data)
        }
        throw MetadataInspectionError.unsupportedContainer
    }
}
