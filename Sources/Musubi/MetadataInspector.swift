import Foundation

/// Inspects encoded images for generation metadata without decoding pixels.
public enum MetadataInspector {
    /// Inspects an encoded PNG or JPEG.
    ///
    /// - Parameter data: Complete encoded image data.
    /// - Returns: Ordered raw payloads, format interpretations, and diagnostics.
    /// - Throws: ``MetadataInspectionError`` when the container is unsupported
    ///   or cannot be scanned safely.
    public static func inspect(_ data: Data) throws -> MetadataInspection {
        let container = try readContainer(data)
        let result = interpret(container.payloads)

        return MetadataInspection(
            container: container.format,
            imageDimensions: container.dimensions,
            payloads: container.payloads,
            interpretations: result.interpretations,
            diagnostics: container.diagnostics + result.diagnostics
        )
    }

    /// Reads and inspects an encoded PNG or JPEG at `url`.
    public static func inspect(contentsOf url: URL) throws -> MetadataInspection {
        try inspect(Data(contentsOf: url, options: .mappedIfSafe))
    }

    /// Interprets payloads that were extracted from a container Musubi does not
    /// read itself.
    ///
    /// A client can read metadata with another framework, for example an XMP
    /// packet from a HEIC image through ImageIO, and pass it here to use the
    /// same codecs as ``inspect(_:)``. Payload indices in the result refer to
    /// `payloads`.
    public static func interpret(_ payloads: [EmbeddedMetadataPayload]) -> PayloadInterpretation {
        let codecOutputs = [
            MochiNativeCodec.decode(payloads),
            DrawThingsCodec.decode(payloads),
            MochiLegacyCodec.decode(payloads),
            ComfyUICodec.decode(payloads),
            A1111Codec.decode(payloads),
        ]
        return PayloadInterpretation(
            interpretations: codecOutputs.flatMap(\.interpretations),
            diagnostics: codecOutputs.flatMap(\.diagnostics)
        )
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
