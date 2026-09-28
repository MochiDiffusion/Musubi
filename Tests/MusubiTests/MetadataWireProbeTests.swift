import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Musubi

/// A carrier experiment, not a production encoder. Optional fixture export lets
/// independent readers inspect the exact bytes checked by these tests.
@Suite("Metadata wire contract probe")
struct MetadataWireProbeTests {
    private static let namespace = "https://github.com/MochiDiffusion/MochiDiffusion/ns/metadata/1.0/"
    private static let nativePath = "mochi:Generation"

    /// A fixture image's payloads. Records that Mochi can write come from the
    /// production encoders, so the external readers check their actual output.
    /// The two limitation probes are hand-written, because the encoder refuses
    /// to produce them.
    struct Example: Sendable {
        let name: String
        let snapshot: MochiGenerationSnapshot
        /// The complete parameters text of a limitation probe.
        let handWrittenParameters: String?
        /// What the external readers must parse; see ``ReaderExpectations``.
        let readers: ReaderExpectations

        init(
            name: String, generation: GenerationRecord, engine: String = "coreml", handWrittenParameters: String? = nil,
            readers: ReaderExpectations
        ) {
            self.name = name
            self.snapshot = MochiGenerationSnapshot(
                producer: MetadataProducer(name: "Mochi Diffusion", version: "wire-probe"),
                generation: generation,
                details: MochiGenerationDetails(engine: engine, modelKey: "example")
            )
            self.handWrittenParameters = handWrittenParameters
            self.readers = readers
        }

        var parameters: String {
            get throws {
                if let handWrittenParameters { return handWrittenParameters }
                return try #require(
                    A1111ParametersEncoder.encode(snapshot.generation, producer: snapshot.producer).text)
            }
        }

        var native: String {
            get throws { try MochiNativeCodec.encodeJSON(snapshot) }
        }
    }

    private static func generation(
        prompt: String = "a red cube",
        seed: String = "42",
        model: String = "Example",
        configure: (inout GenerationRecord) -> Void = { _ in }
    ) -> GenerationRecord {
        var record = GenerationRecord(
            positivePrompt: prompt, negativePrompt: "blur", model: model, sampler: "Euler", steps: 8, cfgScale: 4.5,
            seed: seed, dimensions: PixelDimensions(width: 32, height: 32),
            generatedAt: Date(timeIntervalSince1970: 1_788_998_400)
        )
        configure(&record)
        return record
    }

    private static let hosted = GenerationRecord(
        positivePrompt: "a red cube", model: "hosted-example", dimensions: PixelDimensions(width: 32, height: 32),
        generatedAt: Date(timeIntervalSince1970: 1_788_998_400)
    )

    /// The values every complete diffusion fixture shares.
    private static let diffusionA1111: [String: JSONValue] = [
        "Steps": "8", "Sampler": "Euler", "CFG scale": "4.5", "Size-1": "32", "Size-2": "32", "Model": "Example",
        "Negative prompt": "blur",
    ]
    private static let diffusionCivitai: [String: JSONValue] = [
        "generator": "automatic1111", "raw.steps": 8, "raw.sampler": "Euler", "raw.cfgScale": 4.5, "raw.width": 32,
        "raw.height": 32, "raw.negativePrompt": "blur",
    ]

    static let examples: [Example] = [
        .init(
            name: "diffusion",
            generation: generation(seed: "4294967296") {
                $0.scheduler = "Normal"
                $0.denoise = 0.42
            },
            readers: ReaderExpectations(
                a1111: diffusionA1111.merging([
                    "Prompt": "a red cube", "Seed": "4294967296", "Schedule type": "Normal",
                    "Denoising strength": "0.42",
                ]) { $1 },
                civitai: diffusionCivitai.merging([
                    "raw.prompt": "a red cube", "raw.seed": 4_294_967_296, "raw.Schedule type": "Normal",
                    "raw.Model": "Example", "civitai.generation.denoise": 0.42,
                ]) { $1 })),
        .init(
            name: "unicode",
            generation: generation(prompt: "a café, 猫 🐈\nsecond line: \"blue\" \\ path", model: "café, \"猫\""),
            readers: ReaderExpectations(
                a1111: diffusionA1111.merging([
                    "Prompt": "a café, 猫 🐈\nsecond line: \"blue\" \\ path", "Model": "café, \"猫\"",
                ]) { $1 },
                civitai: diffusionCivitai.merging([
                    "raw.prompt": "a café, 猫 🐈\nsecond line: \"blue\" \\ path", "raw.Model": "café, \"猫\"",
                ]) { $1 })),
        // Hosted images without Steps are not recognized by the Civitai reader.
        .init(
            name: "hosted", generation: hosted, engine: "openai",
            readers: ReaderExpectations(
                a1111: [
                    "Prompt": "a red cube", "Size-1": "32", "Size-2": "32", "Model": "hosted-example", "Steps": nil,
                    "Seed": nil, "CFG scale": nil,
                ],
                civitai: ["generator": nil, "raw": [:]])),
        // A1111 treats a details line of only two fields as prompt text.
        .init(
            name: "two-fields", generation: hosted, engine: "openai",
            handWrittenParameters: "a red cube\nModel: hosted-example, Size: 32x32",
            readers: ReaderExpectations(
                a1111: [
                    "Prompt": "a red cube\nModel: hosted-example, Size: 32x32", "Model": nil, "Steps": nil,
                    "Seed": nil, "CFG scale": nil,
                ],
                civitai: ["generator": nil, "raw": [:]])),
        // Section markers inside a prompt change what both readers take as the
        // prompt and settings.
        .init(
            name: "markers",
            generation: generation(
                prompt:
                    "a cube\nNegative prompt: these words are part of the positive prompt\nSteps: 99, Model: imagined, Seed: 123"
            ),
            handWrittenParameters: """
                a cube
                Negative prompt: these words are part of the positive prompt
                Steps: 99, Model: imagined, Seed: 123
                Negative prompt: blur
                Steps: 8, Sampler: Euler, CFG scale: 4.5, Seed: 42, Size: 32x32, Model: Example
                """,
            readers: ReaderExpectations(
                a1111: ["Prompt": "a cube", "Steps": "8"],
                civitai: ["raw.prompt": "a cube", "raw.steps": 99])),
        // Resource hashes, IDs and weights are extracted; no real resource is
        // looked up.
        .init(
            name: "resources",
            generation: generation {
                $0.resources = [
                    GenerationResource(
                        kind: .checkpoint, name: "Example",
                        hashes: [ResourceHash(algorithm: .a1111AutoV2, value: "0123456789")]),
                    GenerationResource(
                        kind: .lora, name: "detail", weight: 0.75,
                        hashes: [ResourceHash(algorithm: .a1111AutoV2, value: "abcdef0123")],
                        civitaiModelVersionID: 123456),
                ]
            },
            readers: ReaderExpectations(
                a1111: diffusionA1111.merging([
                    "Prompt": "a red cube <lora:detail:0.75>", "Lora hashes": "detail: abcdef0123",
                ]) { $1 },
                civitai: diffusionCivitai.merging([
                    "raw.prompt": "a red cube <lora:detail:0.75>", "raw.hashes.model": "0123456789",
                    "raw.hashes.lora:detail": "abcdef0123",
                    "raw.civitaiResources": [["type": "lora", "weight": 0.75, "modelVersionId": 123456]],
                    // The prompt's <lora:> tag joins the LoRA's name, weight, hash
                    // and version ID into one resource.
                    "civitai.generation.prompt": "a red cube",
                    "civitai.generation.resources.0.kind": "lora",
                    "civitai.generation.resources.0.name": "detail",
                    "civitai.generation.resources.0.weight": 0.75,
                    "civitai.generation.resources.0.hash": "abcdef0123",
                    "civitai.generation.resources.0.modelVersionId": 123456,
                ]) { $1 })),
    ]

    @Test("The encoder refuses the records that the limitation probes describe")
    func limitationProbesAreRefused() throws {
        let twoFields = GenerationRecord(model: "hosted-example", dimensions: PixelDimensions(width: 32, height: 32))
        let markers = try #require(Self.examples.first { $0.name == "markers" }).snapshot

        #expect(A1111ParametersEncoder.encode(twoFields, producer: nil).text == nil)
        #expect(A1111ParametersEncoder.encode(markers.generation, producer: markers.producer).text == nil)
    }

    @Test("ImageIO retains native XMP and compatibility carriers", arguments: examples)
    func carriers(example: Example) throws {
        let native = try example.native
        let parameters = try example.parameters
        for type in [UTType.png, .jpeg, .heic] {
            var bytes: Data
            if type == .png {
                // The production writer adds both carriers to a PNG with no metadata.
                bytes = try PNGMetadataWriter.write(
                    PNGMetadataPayloads(
                        nativeXMPPacket: MochiNativeCodec.encodeXMPPacket(example.snapshot), parameters: parameters),
                    into: Self.encode(type: .png, native: nil, parameters: nil),
                    replacingExistingRecords: false)
            } else {
                bytes = try Self.encode(type: type, native: native, parameters: nil)
            }
            if type == .jpeg { bytes = try Self.addJPEGComment(parameters, toFreshImage: bytes) }

            let source = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
            #expect(CGImageSourceCreateImageAtIndex(source, 0, nil) != nil)
            let metadata = try #require(CGImageSourceCopyMetadataAtIndex(source, 0, nil))
            let restored = CGImageMetadataCopyStringValueWithPath(metadata, nil, Self.nativePath as CFString) as String?
            #expect(restored == native)

            if type != .heic {
                let inspection = try MetadataInspector.inspect(bytes)
                let xmp = try #require(inspection.payloads.first { $0.kind == .xmp })
                let rawMetadata = try #require(CGImageMetadataCreateFromXMPData(xmp.data as CFData))
                #expect(
                    CGImageMetadataCopyStringValueWithPath(rawMetadata, nil, Self.nativePath as CFString) as String?
                        == native)
                let keyword = type == .png ? "parameters" : "UserComment"
                #expect(inspection.payloads.contains { $0.keyword == keyword && $0.text == parameters })
            }

            if let directory = ProcessInfo.processInfo.environment["MUSUBI_WIRE_PROBE_DIR"] {
                let root = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let filename = "\(example.name).\(type.preferredFilenameExtension!)"
                try bytes.write(to: root.appendingPathComponent(filename), options: .atomic)
                let expectation = FixtureExpectation(
                    parameters: parameters, native: native, a1111: example.readers.a1111,
                    civitai: example.readers.civitai)
                try expectation.write(to: root.appendingPathComponent("\(example.name).expected.json"))
                if type == .jpeg, example.name == "unicode" {
                    let control = try Self.encode(type: type, native: native, parameters: parameters)
                    try control.write(to: root.appendingPathComponent("unicode-imageio.jpeg"), options: .atomic)
                }
            }
        }
    }

    @Test("A native XMP value comfortably exceeds legacy caption limits")
    func longNative() throws {
        let text = String(repeating: "猫🧩, quote\"\\\r\n\0", count: 1000)
        // Only the native record is checked, so no external reader sees it.
        let example = Example(
            name: "long", generation: GenerationRecord(positivePrompt: text),
            readers: ReaderExpectations(a1111: [:], civitai: [:]))
        let native = try example.native
        for type in [UTType.png, .jpeg, .heic] {
            let bytes = try Self.encode(type: type, native: native, parameters: nil)
            let source = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
            let metadata = try #require(CGImageSourceCopyMetadataAtIndex(source, 0, nil))
            #expect(
                CGImageMetadataCopyStringValueWithPath(metadata, nil, Self.nativePath as CFString) as String? == native)
        }
    }

    @Test("JPEG UserComment checks its actual encoded segment size")
    func jpegLimit() throws {
        let jpeg = try Self.encode(type: .jpeg, native: Self.examples[0].native, parameters: nil)
        let maximum = String(repeating: "x", count: 32_725)
        let bytes = try Self.addJPEGComment(maximum, toFreshImage: jpeg)
        let inspection = try MetadataInspector.inspect(bytes)
        #expect(inspection.payloads.contains { $0.keyword == "UserComment" && $0.text == maximum })
        #expect(throws: ProbeError.commentTooLong) {
            try Self.addJPEGComment(maximum + "x", toFreshImage: jpeg)
        }
    }

    @Test("Native XMP rejects an oversized serialized packet before encoding")
    func nativeLimit() throws {
        #expect(throws: ProbeError.nativeTooLong) {
            try Self.encode(type: .jpeg, native: String(repeating: "x", count: 61_440), parameters: nil)
        }
    }

    @Test("Released Mochi captions retain a library parsing route in all current formats")
    func legacyCarriers() throws {
        let captions = [
            "6.0":
                "Include in Image: a cube; Model: Example; Seed: 42; Steps: 8; Size: 32x32; Generator: Mochi Diffusion 6.0",
            "6.1.2": """
            Metadata Version: 2
            Include in Image: a cube
            Model: Example
            Seed: 42
            Steps: 8
            Size: 32x32
            Generator: Mochi Diffusion 6.1.2
            """,
        ]
        var report: [[String: Any]] = []
        let cases = captions.sorted { $0.key < $1.key }.flatMap { release, caption in
            ["released", "caption-only"].map { (release: release, caption: caption, variant: $0) }
        }
        for (release, caption, variant) in cases {
            var legacyProperties = [kCGImagePropertyIPTCCaptionAbstract: caption]
            if variant == "released" {
                legacyProperties[kCGImagePropertyIPTCOriginatingProgram] = "Mochi Diffusion"
                legacyProperties[kCGImagePropertyIPTCProgramVersion] = release
            }
            for type in [UTType.png, .jpeg, .heic] {
                let bytes = try Self.encode(
                    type: type, native: nil, parameters: nil, legacyProperties: legacyProperties)
                let source = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
                let metadata = try #require(CGImageSourceCopyMetadataAtIndex(source, 0, nil))
                let xmp = try #require(CGImageMetadataCreateXMPData(metadata, nil)) as Data
                let output = MetadataInspector.interpret([
                    .init(kind: .xmp, data: xmp, text: String(decoding: xmp, as: UTF8.self))
                ])
                let generation = try #require(output.interpretations.first?.generations.first)
                #expect(generation.positivePrompt == "a cube")
                #expect(generation.seed == "42")
                let direct =
                    try type != .heic
                    && MetadataInspector.inspect(bytes).interpretations.contains {
                        $0.format == .mochiDiffusionLegacyCaption
                    }
                if variant == "released", type != .heic { #expect(direct) }
                report.append([
                    "release": release, "variant": variant,
                    "format": type.preferredFilenameExtension!, "imageIOBridge": true,
                    "directMusubi": direct,
                ])
            }
        }
        if let directory = ProcessInfo.processInfo.environment["MUSUBI_WIRE_PROBE_DIR"] {
            let root = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("legacy-results.json"), options: .atomic)
        }
    }

    private static func encode(
        type: UTType, native: String?, parameters: String?, legacyProperties: [CFString: String]? = nil
    ) throws
        -> Data
    {
        let pixels = Data(repeating: 128, count: 32 * 32 * 4)
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let image = try #require(
            CGImage(
                width: 32, height: 32, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 128,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
            ))
        let metadata = CGImageMetadataCreateMutable()
        if let native {
            try #require(
                CGImageMetadataRegisterNamespaceForPrefix(metadata, namespace as CFString, "mochi" as CFString, nil))
            try #require(CGImageMetadataSetValueWithPath(metadata, nil, nativePath as CFString, native as CFString))
            let packet = try #require(CGImageMetadataCreateXMPData(metadata, nil)) as Data
            guard packet.count <= 60 * 1024 else { throw ProbeError.nativeTooLong }
        }
        if let parameters {
            try #require(
                CGImageMetadataSetValueMatchingImageProperty(
                    metadata, kCGImagePropertyExifDictionary, kCGImagePropertyExifUserComment, parameters as CFString
                ))
        }
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
        if let legacyProperties {
            // Reproduce released Mochi's property-dictionary API, not the new XMP API.
            let properties = [
                kCGImagePropertyIPTCDictionary: legacyProperties
            ]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        } else {
            CGImageDestinationAddImageAndMetadata(destination, image, metadata, nil)
        }
        try #require(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// Replaces only ImageIO's fresh, synthetic Exif. It is a probe helper, not a
    /// JPEG writer, and does not preserve a foreign TIFF/Exif tree.
    private static func addJPEGComment(_ parameters: String, toFreshImage jpeg: Data) throws -> Data {
        let comment = Data("UNICODE\0".utf8) + (try #require(parameters.data(using: .utf16BigEndian)))
        var tiff = Data("MM".utf8) + integer(UInt16(42)) + integer(UInt32(8))
        tiff += integer(UInt16(1))
        // IFD0 points to an Exif IFD with UserComment and actual pixel dimensions.
        tiff += integer(UInt16(0x8769)) + integer(UInt16(4)) + integer(UInt32(1)) + integer(UInt32(26))
        tiff += integer(UInt32(0)) + integer(UInt16(3))
        tiff += integer(UInt16(0x9286)) + integer(UInt16(7)) + integer(UInt32(comment.count)) + integer(UInt32(68))
        for tag: UInt16 in [0xA002, 0xA003] {
            tiff += integer(tag) + integer(UInt16(4)) + integer(UInt32(1)) + integer(UInt32(32))
        }
        tiff += integer(UInt32(0)) + comment
        let body = Data("Exif\0\0".utf8) + tiff
        guard let length = UInt16(exactly: body.count + 2) else { throw ProbeError.commentTooLong }
        let segment = Data([0xFF, 0xE1]) + integer(length) + body
        var offset = 2
        while offset + 4 <= jpeg.count, jpeg[offset] == 0xFF, jpeg[offset + 1] != 0xDA {
            let size = Int(jpeg[offset + 2]) * 256 + Int(jpeg[offset + 3])
            let end = offset + 2 + size
            try #require(size >= 2 && end <= jpeg.count)
            if jpeg[offset + 1] == 0xE1, jpeg[offset + 4..<end].starts(with: Data("Exif\0\0".utf8)) {
                return jpeg.prefix(offset) + segment + jpeg.dropFirst(end)
            }
            offset = end
        }
        // ImageIO currently emits Exif dimensions even when only XMP was supplied.
        throw ProbeError.missingFreshExif
    }

    private static func integer<T: FixedWidthInteger>(_ value: T) -> Data {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }

    private enum ProbeError: Error { case missingFreshExif, commentTooLong, nativeTooLong }
}
