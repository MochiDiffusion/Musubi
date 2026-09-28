import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Musubi

@Suite("PNG metadata writer")
struct PNGMetadataWriterTests {
    private static let snapshot = MochiGenerationSnapshot(
        producer: MetadataProducer(name: "Mochi Diffusion", version: "6.2"),
        generation: GenerationRecord(
            positivePrompt: "a red cube", model: "Example", sampler: "Euler", steps: 8, seed: "42",
            dimensions: PixelDimensions(width: 4, height: 4))
    )

    private static var payloads: PNGMetadataPayloads {
        get throws {
            PNGMetadataPayloads(
                nativeXMPPacket: try MochiNativeCodec.encodeXMPPacket(snapshot),
                parameters: A1111ParametersEncoder.encode(snapshot.generation, producer: snapshot.producer).text)
        }
    }

    /// A real PNG from ImageIO, with no metadata.
    private static func imageIOPNG() throws -> Data {
        let pixels = Data(repeating: 200, count: 4 * 4 * 4)
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let image = try #require(
            CGImage(
                width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private static func chunks(_ png: Data) throws -> [PNGChunkFile.Chunk] {
        try PNGChunkFile(png).chunks
    }

    private static func xmpChunk(_ xmp: String) -> PNGTestImage.Chunk {
        PNGTestImage.internationalText(keyword: "XML:com.adobe.xmp", text: xmp)
    }

    @Test("Both payloads are written after IHDR and read back by Musubi and ImageIO")
    func writesBothPayloads() throws {
        let original = try Self.imageIOPNG()

        let written = try PNGMetadataWriter.write(Self.payloads, into: original, replacingExistingRecords: false)
        let inspection = try MetadataInspector.inspect(written)
        let source = try #require(CGImageSourceCreateWithData(written as CFData, nil))
        let metadata = try #require(CGImageSourceCopyMetadataAtIndex(source, 0, nil))

        #expect(try Self.chunks(written).prefix(3).map(\.type) == ["IHDR", "iTXt", "iTXt"])
        #expect(CGImageSourceCreateImageAtIndex(source, 0, nil) != nil)
        #expect(
            CGImageMetadataCopyStringValueWithPath(metadata, nil, "mochi:Generation" as CFString) as String?
                == (try MochiNativeCodec.encodeJSON(Self.snapshot)))
        #expect(inspection.interpretations.map(\.format) == [.mochiDiffusion, .automatic1111])
        #expect(inspection.selection == .selected(GenerationReference(interpretation: 0, generation: 0)))
        #expect(inspection.diagnostics.isEmpty)
    }

    @Test("The description is Finder's and is ignored as generation metadata")
    func description() throws {
        let description = "a red cube <&>\r\nSteps: 8, Seed: 42"
        let payloads = PNGMetadataPayloads(
            nativeXMPPacket: try MochiNativeCodec.encodeXMPPacket(Self.snapshot, description: description),
            parameters: try Self.payloads.parameters)

        let written = try PNGMetadataWriter.write(payloads, into: Self.imageIOPNG(), replacingExistingRecords: false)
        let inspection = try MetadataInspector.inspect(written)
        let source = try #require(CGImageSourceCreateWithData(written as CFData, nil))
        let metadata = try #require(CGImageSourceCopyMetadataAtIndex(source, 0, nil))

        #expect(
            CGImageMetadataCopyStringValueWithPath(metadata, nil, "dc:description" as CFString) as String?
                == description)
        #expect(inspection.interpretations.map(\.format) == [.mochiDiffusion, .automatic1111])
        #expect(inspection.selection == .selected(GenerationReference(interpretation: 0, generation: 0)))
        #expect(inspection.diagnostics.isEmpty)
        #expect(throws: Never.self) {
            try PNGMetadataWriter.write(Self.payloads, into: written, replacingExistingRecords: true)
        }
    }

    @Test("Pixel data and every unowned chunk keep their exact bytes and order")
    func preservesUnownedChunks() throws {
        let foreignXMP = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
            <rdf:Description xmlns:dc="http://purl.org/dc/elements/1.1/" dc:format="image/png"/></rdf:RDF></x:xmpmeta>
            """
        let original = PNGTestImage.make(
            width: 4, height: 4,
            chunks: [
                PNGTestImage.Chunk(type: "iCCP", data: Data("icc\0\0profile".utf8), corruptCRC: false),
                PNGTestImage.text(keyword: "Comment", text: "first"),
                PNGTestImage.text(keyword: "Comment", text: "second"),
                PNGTestImage.Chunk(type: "eXIf", data: Data("MM\0*".utf8), corruptCRC: false),
                PNGTestImage.Chunk(type: "prVt", data: Data([1, 2, 3]), corruptCRC: true),
                Self.xmpChunk(foreignXMP),
            ],
            imageData: Data(repeating: 0xA5, count: 64),
            trailingChunks: [PNGTestImage.text(keyword: "Comment", text: "after pixels")])
        let parameters = PNGMetadataPayloads(parameters: "a cube\nSteps: 8, Seed: 1, Size: 4x4")

        let written = try PNGMetadataWriter.write(parameters, into: original, replacingExistingRecords: false)

        let before = try Self.chunks(original).dropFirst()
        let after = try Self.chunks(written).dropFirst()
        #expect(after.first?.type == "iTXt")
        #expect(Array(after.dropFirst().map(\.bytes)) == before.map(\.bytes))
    }

    @Test("Owned parameters in every text encoding are replaced by one chunk")
    func replacesOwnedParameters() throws {
        let original = PNGTestImage.make(
            width: 4, height: 4,
            chunks: [
                PNGTestImage.text(keyword: "parameters", text: "old tEXt\nSteps: 1, Seed: 1, Size: 4x4"),
                PNGTestImage.compressedText(keyword: "parameters", text: "old zTXt\nSteps: 1, Seed: 1, Size: 4x4"),
                PNGTestImage.internationalText(keyword: "parameters", text: "old iTXt\nSteps: 1, Seed: 1, Size: 4x4"),
                PNGTestImage.text(keyword: "Comment", text: "kept"),
            ])

        let written = try PNGMetadataWriter.write(Self.payloads, into: original, replacingExistingRecords: true)
        let inspection = try MetadataInspector.inspect(written)

        #expect(inspection.payloads.filter { $0.keyword == "parameters" }.count == 1)
        #expect(inspection.payloads.contains { $0.keyword == "Comment" && $0.text == "kept" })
        #expect(inspection.interpretations.first { $0.format == .automatic1111 }?.generations.first?.seed == "42")
    }

    @Test("Writing the same payloads again gives the same bytes")
    func idempotent() throws {
        let once = try PNGMetadataWriter.write(Self.payloads, into: Self.imageIOPNG(), replacingExistingRecords: false)

        let twice = try PNGMetadataWriter.write(Self.payloads, into: once, replacingExistingRecords: false)

        #expect(twice == once)
    }

    @Test("A different existing record is replaced only when the caller asks")
    func existingRecordNeedsPermission() throws {
        let original = PNGTestImage.make(
            width: 4, height: 4,
            chunks: [PNGTestImage.text(keyword: "parameters", text: "someone else\nSteps: 1, Seed: 9, Size: 4x4")])

        #expect(throws: PNGMetadataWriterError.existingRecord("parameters")) {
            try PNGMetadataWriter.write(Self.payloads, into: original, replacingExistingRecords: false)
        }
        #expect(throws: Never.self) {
            try PNGMetadataWriter.write(Self.payloads, into: original, replacingExistingRecords: true)
        }
    }

    @Test("Mochi's own XMP is replaced, and foreign XMP is never overwritten")
    func xmpOwnership() throws {
        let foreign = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
            <rdf:Description xmlns:mochi="\(MochiNativeCodec.namespace)" xmlns:xmp="http://ns.adobe.com/xap/1.0/" \
            mochi:Generation="{}" xmp:CreatorTool="Editor"/></rdf:RDF></x:xmpmeta>
            """
        let other = MochiGenerationSnapshot(producer: Self.snapshot.producer, generation: GenerationRecord(seed: "1"))
        let owned = PNGTestImage.make(
            width: 4, height: 4, chunks: [Self.xmpChunk(try MochiNativeCodec.encodeXMPPacket(other))])
        let withForeign = PNGTestImage.make(width: 4, height: 4, chunks: [Self.xmpChunk(foreign)])

        let replaced = try PNGMetadataWriter.write(Self.payloads, into: owned, replacingExistingRecords: true)

        #expect(try MetadataInspector.inspect(replaced).payloads.filter { $0.kind == .xmp }.count == 1)
        #expect(
            try MetadataInspector.inspect(replaced).interpretations.first?.generations.first?.seed == "42")
        #expect(throws: PNGMetadataWriterError.foreignXMP) {
            try PNGMetadataWriter.write(Self.payloads, into: withForeign, replacingExistingRecords: true)
        }
    }

    @Test(
        "Payloads a carrier cannot hold are refused",
        arguments: [
            (
                PNGMetadataPayloads(
                    parameters: String(repeating: "x", count: A1111ParametersEncoder.maximumTextSize + 1)),
                PNGMetadataWriterError.payloadTooLarge("parameters", A1111ParametersEncoder.maximumTextSize + 1)
            ),
            (
                PNGMetadataPayloads(
                    nativeXMPPacket: String(repeating: "x", count: MochiNativeCodec.maximumPacketSize + 1)),
                .payloadTooLarge("XML:com.adobe.xmp", MochiNativeCodec.maximumPacketSize + 1)
            ),
            (PNGMetadataPayloads(parameters: "a\0b"), .unrepresentablePayload("parameters")),
        ]
    )
    func refusedPayloads(payloads: PNGMetadataPayloads, error: PNGMetadataWriterError) throws {
        let original = try Self.imageIOPNG()

        #expect(throws: error) {
            try PNGMetadataWriter.write(payloads, into: original, replacingExistingRecords: true)
        }
    }

    @Test("Malformed input is refused")
    func malformedInput() throws {
        let valid = try Self.imageIOPNG()
        let noIHDRFirst = PNGTestImage.make(width: 4, height: 4, chunks: []).replacingIHDRType()

        for data in [Data("not a png".utf8), valid.prefix(valid.count - 6), noIHDRFirst] {
            #expect(throws: PNGMetadataWriterError.self) {
                try PNGMetadataWriter.write(Self.payloads, into: data, replacingExistingRecords: true)
            }
        }
    }

    @Test("Bytes after IEND are kept")
    func trailingBytes() throws {
        let original = try Self.imageIOPNG() + Data("trailer".utf8)

        let written = try PNGMetadataWriter.write(Self.payloads, into: original, replacingExistingRecords: false)

        #expect(written.suffix(7) == Data("trailer".utf8))
    }
}

extension Data {
    /// The same PNG with its first chunk renamed, so `IHDR` is no longer first.
    fileprivate func replacingIHDRType() -> Data {
        var copy = self
        copy.replaceSubrange(12..<16, with: Data("iHDR".utf8))
        return copy
    }
}
