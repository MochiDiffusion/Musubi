import Compression
import Foundation
import Testing

@testable import Musubi

@Suite("Parsing hardening")
struct HardeningTests {
    // MARK: - AUTOMATIC1111 text

    private static func a1111(
        _ text: String,
        keyword: String = "parameters"
    ) throws -> (interpretation: MetadataInterpretation, diagnostics: [MetadataDiagnostic]) {
        let payload = EmbeddedMetadataPayload(kind: .pngText, keyword: keyword, data: Data(text.utf8), text: text)
        let result = MetadataInspector.interpret([payload])
        return (try #require(result.interpretations.first), result.diagnostics)
    }

    private static func generation(_ text: String) throws -> GenerationRecord {
        try #require(a1111(text).interpretation.generations.first)
    }

    @Test("Quoted values are unquoted, including commas, colons, quotes and backslashes")
    func quotedValues() throws {
        let record = try Self.generation(
            #"a cube"# + "\n" + #"Steps: 8, Seed: 1, Model: "a, b: \"c\" \\ d", Sampler: Euler"#)

        #expect(record.model == #"a, b: "c" \ d"#)
        #expect(record.sampler == "Euler")
    }

    @Test("Empty prompts stay empty and a missing negative prompt stays missing")
    func emptyPrompts() throws {
        let empty = try Self.generation("\nNegative prompt: \nSteps: 8, Seed: 1, Size: 8x8")
        let missing = try Self.generation("Steps: 8, Seed: 1, Size: 8x8")

        #expect(empty.positivePrompt == "")
        #expect(empty.negativePrompt == "")
        #expect(missing.positivePrompt == "")
        #expect(missing.negativePrompt == nil)
    }

    @Test("Sparse text without Steps is read from parameters but not from a general comment")
    func sparseSettings() throws {
        let text = "a cube\nSize: 32x32, Model: hosted, Software: Mochi Diffusion 6.2"
        let payload = EmbeddedMetadataPayload(
            kind: .exifValue, keyword: "UserComment", data: Data(text.utf8), text: text)

        let record = try Self.generation(text)

        #expect(record.steps == nil)
        #expect(record.dimensions == PixelDimensions(width: 32, height: 32))
        #expect(MetadataInspector.interpret([payload]).interpretations.isEmpty)
    }

    @Test("A photo comment with three unrelated settings is not generation text")
    func unrelatedCommentIsIgnored() {
        let text = "Camera: X100, Lens: 23mm, ISO: 200"
        let payload = EmbeddedMetadataPayload(kind: .jpegComment, keyword: "Comment", data: Data(text.utf8), text: text)

        #expect(MetadataInspector.interpret([payload]).interpretations.isEmpty)
    }

    @Test("Invalid and non-finite numbers are reported and kept as raw parameters")
    func invalidNumbers() throws {
        let result = try Self.a1111("a cube\nSteps: -3, CFG scale: nan, Seed: 12e3, Size: 0x8, Model: m")
        let record = try #require(result.interpretation.generations.first)

        #expect(record.steps == nil)
        #expect(record.cfgScale == nil)
        #expect(record.seed == nil)
        #expect(record.dimensions == nil)
        #expect(
            record.parameters == [
                GenerationParameter(key: "Steps", value: "-3"),
                GenerationParameter(key: "CFG scale", value: "nan"),
                GenerationParameter(key: "Seed", value: "12e3"),
                GenerationParameter(key: "Size", value: "0x8"),
            ])
        #expect(result.diagnostics.count == 4)
    }

    @Test("A common setting with conflicting values is left out and every value is kept")
    func conflictingDuplicateSettings() throws {
        let result = try Self.a1111("a cube\nSteps: 8, Seed: 1, Seed: 2, Seed: 1, Size: 8x8")
        let record = try #require(result.interpretation.generations.first)

        #expect(record.seed == nil)
        #expect(
            record.parameters == [
                GenerationParameter(key: "Seed", value: "1"),
                GenerationParameter(key: "Seed", value: "2"),
            ])
        #expect(result.diagnostics.map(\.message) == ["Seed appears with different values"])
    }

    @Test("A repeated setting with the same value is not a conflict")
    func agreeingDuplicateSettings() throws {
        #expect(try Self.generation("a cube\nSteps: 8, Seed: 1, Seed: 1").seed == "1")
    }

    @Test("Unrecognized settings stay in order as parameters")
    func unrecognizedSettings() throws {
        let record = try Self.generation(
            #"a cube"# + "\n"
                + #"Steps: 8, Clip skip: 2, Seed: 1, Hires upscale: 2, Version: v1.10.1, Hashes: {"a": "b, c"}"#)

        #expect(
            record.parameters == [
                GenerationParameter(key: "Clip skip", value: "2"),
                GenerationParameter(key: "Hires upscale", value: "2"),
                GenerationParameter(key: "Version", value: "v1.10.1"),
                GenerationParameter(key: "Hashes", value: #"{"a": "b, c"}"#),
            ])
    }

    @Test("Prompt lines that start with a section marker are read as the WebUI reads them")
    func reservedMarkerText() throws {
        let record = try Self.generation(
            "a cube\nNegative prompt: typed words\nSteps: 99, Model: imagined\nNegative prompt: blur\n"
                + "Steps: 8, Sampler: Euler, Seed: 42, Size: 32x32")

        #expect(record.positivePrompt == "a cube")
        #expect(record.negativePrompt == "typed words\nSteps: 99, Model: imagined\nblur")
        #expect(record.steps == 8)
    }

    @Test("A seed longer than any integer type stays exact")
    func longTextualSeed() throws {
        #expect(
            try Self.generation("a\nSteps: 8, Seed: 123456789012345678901234567890, Size: 8x8").seed
                == "123456789012345678901234567890")
    }

    // MARK: - LoRA tags

    @Test("Tags in another producer's prompt stay in the prompt and become resources")
    func foreignLoRATags() throws {
        let record = try Self.generation(
            #"a castle <lora:watercolor:0.8>, soft light <lora:detail>"# + "\n"
                + #"Steps: 8, Seed: 1, Lora hashes: "watercolor: 0123456789, extra: abcdef0123", "#
                + #"Civitai resources: [{"type":"lora","modelName":"detail","modelVersionId":7}]"#)

        #expect(record.positivePrompt == "a castle <lora:watercolor:0.8>, soft light <lora:detail>")
        #expect(
            record.resources == [
                GenerationResource(
                    kind: .lora, name: "watercolor", weight: 0.8,
                    hashes: [ResourceHash(algorithm: .a1111AutoV2, value: "0123456789")]),
                GenerationResource(kind: .lora, name: "detail", civitaiModelVersionID: 7),
                GenerationResource(
                    kind: .lora, name: "extra", hashes: [ResourceHash(algorithm: .a1111AutoV2, value: "abcdef0123")]),
            ])
    }

    @Test("Mochi's own trailing tags are removed from the prompt and kept as resources")
    func mochiLoRATagsRoundTrip() throws {
        let generation = GenerationRecord(
            positivePrompt: "a red cube", steps: 8, seed: "42",
            resources: [
                GenerationResource(kind: .lora, name: "style", weight: -0.5),
                GenerationResource(kind: .lora, name: "detail"),
            ]
        )
        let text = try #require(
            A1111ParametersEncoder.encode(
                generation, producer: MetadataProducer(name: "Mochi Diffusion", version: "6.2")
            )
            .text)

        let record = try Self.generation(text)

        #expect(record.positivePrompt == "a red cube")
        #expect(record.resources == generation.resources)
    }

    @Test(
        "Removing Mochi's tags stops at a tag the user typed",
        arguments: [
            ("glued<lora:typed:1> <lora:added:1>", "glued<lora:typed:1>"),
            ("<lora:added:1>", ""),
            ("a <lora:a:1> b", "a <lora:a:1> b"),
        ]
    )
    func mochiTagRemovalBoundary(prompt: String, expected: String) throws {
        let record = try Self.generation("\(prompt)\nSteps: 8, Seed: 1, Software: Mochi Diffusion 6.2")

        #expect(record.positivePrompt == expected)
    }

    // MARK: - Exact seeds

    @Test(
        "JSON seeds are exact up to 64 bits and left out beyond",
        arguments: [
            ("18446744073709551615", "18446744073709551615" as String?),
            ("4294967296", "4294967296"),
            ("18446744073709551616", nil),
        ]
    )
    func jsonSeedExactness(literal: String, expected: String?) throws {
        let prompt =
            #"{"1":{"class_type":"KSampler","inputs":{"seed":"# + literal
            + #","steps":8,"positive":["2",0]}},"2":{"class_type":"CLIPTextEncode","inputs":{"text":"a"}}}"#
        let payload = EmbeddedMetadataPayload(kind: .pngText, keyword: "prompt", data: Data(prompt.utf8), text: prompt)

        let result = MetadataInspector.interpret([payload])

        #expect(result.interpretations.first?.generations.first?.seed == expected)
        #expect(result.diagnostics.contains { $0.message.contains("too large") } == (expected == nil))
    }

    // MARK: - Limits

    @Test("Deeply nested JSON is rejected without recursion, and a valid sibling survives")
    func deepJSON() throws {
        let deep = String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000)
        let parameters = "a cube\nSteps: 8, Seed: 1, Size: 8x8"

        let result = MetadataInspector.interpret([
            EmbeddedMetadataPayload(kind: .pngText, keyword: "prompt", data: Data(deep.utf8), text: deep),
            EmbeddedMetadataPayload(
                kind: .pngText, keyword: "parameters", data: Data(parameters.utf8), text: parameters),
        ])

        #expect(result.interpretations.map(\.format) == [.automatic1111])
        #expect(result.diagnostics.contains { $0.message.contains("nesting") })
    }

    @Test("Deeply nested XML and entity declarations are rejected")
    func hostileXML() {
        let deep =
            #"<x:xmpmeta xmlns:x="adobe:ns:meta/">"# + String(repeating: "<a>", count: 10_000)
            + "Generator: Mochi Diffusion 6.0" + String(repeating: "</a>", count: 10_000) + "</x:xmpmeta>"
        let entities = """
            <?xml version="1.0"?><!DOCTYPE x [<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;&a;">]>
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:description>&b;</dc:description>
            </rdf:Description></rdf:RDF></x:xmpmeta>
            """

        for xmp in [deep, entities] {
            #expect(throws: UntrustedInputProblem.self) { try UntrustedXML.parse(xmp, delegate: XMLParserStub()) }
            let payload = EmbeddedMetadataPayload(kind: .xmp, data: Data(xmp.utf8), text: xmp)
            #expect(MetadataInspector.interpret([payload]).interpretations.isEmpty)
        }
    }

    @Test("A ComfyUI prompt that links to itself terminates")
    func cyclicComfyUIGraph() throws {
        let prompt =
            #"{"1":{"class_type":"KSampler","inputs":{"seed":1,"positive":["2",0]}},"#
            + #""2":{"class_type":"StringConcatenate","inputs":{"string_a":["2",0],"string_b":"x"}}}"#
        let payload = EmbeddedMetadataPayload(kind: .pngText, keyword: "prompt", data: Data(prompt.utf8), text: prompt)

        let record = try #require(MetadataInspector.interpret([payload]).interpretations.first?.generations.first)

        #expect(record.positivePrompt == "x")
    }

    @Test("A ComfyUI graph over the node limit is reported, not traversed")
    func oversizedComfyUIGraph() {
        let nodes = (0...InputLimits.graphNodes).map { #""\#($0)":{"class_type":"Note","inputs":{}}"# }
        let prompt = "{" + nodes.joined(separator: ",") + "}"
        let payload = EmbeddedMetadataPayload(kind: .pngText, keyword: "prompt", data: Data(prompt.utf8), text: prompt)

        let result = MetadataInspector.interpret([payload])

        #expect(result.interpretations.isEmpty)
        #expect(result.diagnostics.contains { $0.message.contains("nodes") })
    }

    @Test("Payloads beyond the count limit are dropped with one diagnostic")
    func payloadCountLimit() throws {
        let chunks = (0..<(InputLimits.payloadCount + 10)).map {
            PNGTestImage.text(keyword: "Comment", text: "\($0)")
        }
        let inspection = try MetadataInspector.inspect(PNGTestImage.make(width: 1, height: 1, chunks: chunks))

        #expect(inspection.payloads.count == InputLimits.payloadCount)
        #expect(inspection.diagnostics.map(\.message) == [payloadLimitMessage])
    }

    @Test("Decompression stops at the container budget and earlier payloads survive")
    func decompressionBudget() throws {
        let megabyte = String(repeating: "a", count: 1_024 * 1_024)
        let chunkCount = InputLimits.decompressedBytes / megabyte.utf8.count + 2
        let chunks = (0..<chunkCount).map { _ in PNGTestImage.compressedText(keyword: "Comment", text: megabyte) }

        let inspection = try MetadataInspector.inspect(PNGTestImage.make(width: 1, height: 1, chunks: chunks))

        #expect(inspection.payloads.count < chunkCount)
        #expect(inspection.payloads.count >= InputLimits.decompressedBytes / megabyte.utf8.count - 1)
        #expect(inspection.diagnostics.contains { $0.message.contains("exceeds") || $0.message.contains("limit") })
    }

    @Test("Exif entries that repeat one large value are copied at most once")
    func exifCopyBudget() throws {
        let value = Data("ASCII\0\0\0".utf8) + Data(repeating: 0x61, count: 1_024 * 1_024)
        let entryCount = 2_000
        var tiff = Data("MM".utf8) + bigEndian(UInt16(42)) + bigEndian(UInt32(8)) + bigEndian(UInt16(entryCount))
        let valueOffset = UInt32(8 + 2 + entryCount * 12 + 4)
        for _ in 0..<entryCount {
            tiff +=
                bigEndian(UInt16(0x9286)) + bigEndian(UInt16(7)) + bigEndian(UInt32(value.count))
                + bigEndian(valueOffset)
        }
        tiff += bigEndian(UInt32(0)) + value
        let image = PNGTestImage.make(
            width: 1, height: 1, chunks: [PNGTestImage.Chunk(type: "eXIf", data: tiff, corruptCRC: false)])

        let inspection = try MetadataInspector.inspect(image)

        #expect(inspection.payloads.filter { $0.keyword == "UserComment" }.count == 1)
    }

    /// Comment values after their 8-byte character code, and the text each should read as.
    private static let userComments: [(value: Data, text: String)] = [
        // Cameras and editors often write a blank comment as a header and nothing but padding.
        (Data("ASCII\0\0\0".utf8) + Data(repeating: 0, count: 64), ""),
        (Data("ASCII\0\0\0".utf8) + Data("hi".utf8), "hi"),
        (Data("ASCII\0\0\0".utf8) + Data("a longer comment\0\0\0".utf8), "a longer comment"),
        (Data("UNICODE\0".utf8) + Data(repeating: 0, count: 64), ""),
        (Data("UNICODE\0".utf8) + Data([0, 0x41, 0, 0x42, 0, 0, 0, 0]), "AB"),
    ]

    @Test("UserComment trailing nulls are trimmed within the comment body", arguments: userComments)
    func userCommentTrailingNulls(value: Data, expected: String) throws {
        var tiff = Data("MM".utf8) + bigEndian(UInt16(42)) + bigEndian(UInt32(8)) + bigEndian(UInt16(1))
        tiff +=
            bigEndian(UInt16(0x9286)) + bigEndian(UInt16(7)) + bigEndian(UInt32(value.count))
            + bigEndian(UInt32(8 + 2 + 12 + 4))
        tiff += bigEndian(UInt32(0)) + value
        let image = PNGTestImage.make(
            width: 1, height: 1, chunks: [PNGTestImage.Chunk(type: "eXIf", data: tiff, corruptCRC: false)])

        let inspection = try MetadataInspector.inspect(image)

        #expect(inspection.payloads.first { $0.keyword == "UserComment" }?.text == expected)
    }

    // MARK: - Review gaps

    @Test("interpret(_:) applies the payload count limit to caller payloads")
    func interpretPayloadCount() {
        let text = "a\nSteps: 8, Seed: 1, Size: 8x8"
        let payloads = (0..<(InputLimits.payloadCount + 5)).map { _ in Self.payload("parameters", text) }

        let result = MetadataInspector.interpret(payloads)

        #expect(result.interpretations.count == InputLimits.payloadCount)
        #expect(result.diagnostics.contains { $0.message.contains("exceed the limits") })
    }

    @Test("interpret(_:) applies the text size limit to caller payloads")
    func interpretTextBytes() {
        let huge =
            "a" + String(repeating: " ", count: InputLimits.interpretedTextBytes) + "\nSteps: 8, Seed: 1, Size: 8x8"

        let result = MetadataInspector.interpret([Self.payload("parameters", huge)])

        #expect(result.interpretations.isEmpty)
        #expect(result.diagnostics.contains { $0.message.contains("exceed the limits") })
    }

    @Test("The native decoders refuse input over the byte limit")
    func nativeDecoderSizeLimit() {
        let huge = String(repeating: " ", count: InputLimits.containerMetadataBytes + 1)

        #expect(throws: MochiNativeCodecError.self) { try MochiNativeCodec.decodeJSON(huge) }
        #expect(throws: MochiNativeCodecError.self) { try MochiNativeCodec.decodeXMPPacket(huge) }
    }

    private static func comfy(_ graph: String) -> PayloadInterpretation {
        MetadataInspector.interpret([Self.payload("prompt", graph)])
    }

    @Test("Two checkpoints merged into one model leave the model unset")
    func mergedModelIsUnset() throws {
        let result = Self.comfy(
            #"{"1":{"class_type":"KSampler","inputs":{"seed":1,"model":["2",0],"latent_image":["5",0]}},"#
                + #""2":{"class_type":"ModelMergeSimple","inputs":{"model1":["3",0],"model2":["4",0],"ratio":0.5}},"#
                + #""3":{"class_type":"CheckpointLoaderSimple","inputs":{"ckpt_name":"a.safetensors"}},"#
                + #""4":{"class_type":"CheckpointLoaderSimple","inputs":{"ckpt_name":"b.safetensors"}},"#
                + #""5":{"class_type":"EmptyLatentImage","inputs":{"width":64,"height":32}}}"#)
        let record = try #require(result.interpretations.first?.generations.first)

        #expect(record.model == nil)
        #expect(record.dimensions == PixelDimensions(width: 64, height: 32))
        #expect(
            result.diagnostics.map(\.message) == [
                "ComfyUI sampler 1 has several model values upstream; none was chosen"
            ])
    }

    @Test("A pixel-upscale hires pass takes its model from the model link and states no size")
    func hiresPixelUpscale() throws {
        let result = Self.comfy(
            #"{"1":{"class_type":"UpscaleModelLoader","inputs":{"model_name":"4x.pth"}},"#
                + #""2":{"class_type":"CheckpointLoaderSimple","inputs":{"ckpt_name":"base.safetensors"}},"#
                + #""3":{"class_type":"EmptyLatentImage","inputs":{"width":512,"height":512}},"#
                + #""4":{"class_type":"KSampler","inputs":{"seed":1,"model":["2",0],"latent_image":["3",0]}},"#
                + #""5":{"class_type":"VAEDecode","inputs":{"samples":["4",0]}},"#
                + #""6":{"class_type":"ImageUpscaleWithModel","inputs":{"upscale_model":["1",0],"image":["5",0]}},"#
                + #""7":{"class_type":"VAEEncode","inputs":{"pixels":["6",0]}},"#
                + #""8":{"class_type":"KSampler","inputs":{"seed":2,"model":["2",0],"latent_image":["7",0]}},"#
                + #""9":{"class_type":"SaveImage","inputs":{"images":["8",0]}}}"#)
        let generations = try #require(result.interpretations.first?.generations)

        #expect(generations.map(\.model) == ["base.safetensors", "base.safetensors"])
        #expect(generations.map(\.dimensions) == [PixelDimensions(width: 512, height: 512), nil])
    }

    @Test("A latent hires pass takes the upscale size, or no size when only a scale factor is given")
    func hiresLatentUpscale() throws {
        func secondPassSize(_ upscale: String) throws -> PixelDimensions? {
            let result = Self.comfy(
                #"{"1":{"class_type":"EmptyLatentImage","inputs":{"width":512,"height":512}},"#
                    + #""2":{"class_type":"KSampler","inputs":{"seed":1,"latent_image":["1",0]}},"#
                    + #""3":"# + upscale + ","
                    + #""4":{"class_type":"KSampler","inputs":{"seed":2,"latent_image":["3",0]}},"#
                    + #""5":{"class_type":"KSampler","inputs":{"seed":3,"latent_image":["4",0]}},"#
                    + #""6":{"class_type":"SaveImage","inputs":{"images":["5",0]}}}"#)
            let generations = try #require(result.interpretations.first?.generations)
            #expect(generations.first?.dimensions == PixelDimensions(width: 512, height: 512))
            #expect(generations[1].dimensions == generations[2].dimensions)
            return generations[1].dimensions
        }

        #expect(
            try secondPassSize(
                #"{"class_type":"LatentUpscale","inputs":{"samples":["2",0],"width":1024,"height":768}}"#)
                == PixelDimensions(width: 1024, height: 768))
        #expect(
            try secondPassSize(#"{"class_type":"LatentUpscaleBy","inputs":{"samples":["2",0],"scale_by":1.5}}"#)
                == nil)
    }

    @Test("SDXL conditioning sizes do not become the generation size")
    func sdxlConditioningSize() throws {
        let result = Self.comfy(
            #"{"1":{"class_type":"KSampler","inputs":{"seed":1,"positive":["2",0],"latent_image":["3",0]}},"#
                + #""2":{"class_type":"CLIPTextEncodeSDXL","inputs":{"width":4096,"height":4096,"text_g":"a"}},"#
                + #""3":{"class_type":"EmptyLatentImage","inputs":{"width":1024,"height":1024}}}"#)

        #expect(
            result.interpretations.first?.generations.first?.dimensions == PixelDimensions(width: 1024, height: 1024))
    }

    // MARK: - Selection

    private static let comfyTwoSamplers =
        #"{"1":{"class_type":"KSampler","inputs":{"seed":1,"positive":["3",0]}},"#
        + #""2":{"class_type":"KSampler","inputs":{"seed":2,"positive":["3",0],"latent_image":["1",0]}},"#
        + #""3":{"class_type":"CLIPTextEncode","inputs":{"text":"a"}},"#
        + #""4":{"class_type":"SaveImage","inputs":{"images":["2",0]}}}"#

    private static func payload(_ keyword: String, _ text: String, kind: EmbeddedMetadataKind = .pngText)
        -> EmbeddedMetadataPayload
    {
        EmbeddedMetadataPayload(kind: kind, keyword: keyword, data: Data(text.utf8), text: text)
    }

    @Test("A Mochi native record is selected over its conflicting compatibility text, and both are kept")
    func nativeIsSelected() throws {
        let snapshot = MochiGenerationSnapshot(
            producer: MetadataProducer(name: "Mochi Diffusion", version: "6.2"),
            generation: GenerationRecord(positivePrompt: "native", seed: "1"))
        let packet = try MochiNativeCodec.encodeXMPPacket(snapshot)

        let result = MetadataInspector.interpret([
            Self.payload("parameters", "compatibility\nSteps: 8, Seed: 2, Size: 8x8"),
            Self.payload("XML:com.adobe.xmp", packet, kind: .xmp),
        ])

        #expect(result.interpretations.count == 2)
        #expect(result.selection == .selected(GenerationReference(interpretation: 0, generation: 0)))
        #expect(result.interpretations[0].format == .mochiDiffusion)
        #expect(result.interpretations[0].generations[0].seed == "1")
    }

    @Test("Several samplers in one graph are ambiguous")
    func multipleSamplersAreAmbiguous() {
        let result = MetadataInspector.interpret([Self.payload("prompt", Self.comfyTwoSamplers)])

        #expect(
            result.selection
                == .ambiguous([
                    GenerationReference(interpretation: 0, generation: 0),
                    GenerationReference(interpretation: 0, generation: 1),
                ]))
    }

    @Test("A single-sampler graph is selected over AUTOMATIC1111 text written beside it")
    func graphIsSelectedOverCompatibilityText() {
        let graph =
            #"{"1":{"class_type":"KSampler","inputs":{"seed":1,"positive":["2",0]}},"#
            + #""2":{"class_type":"CLIPTextEncode","inputs":{"text":"a"}}}"#

        let result = MetadataInspector.interpret([
            Self.payload("parameters", "a\nSteps: 8, Seed: 1, Size: 8x8"),
            Self.payload("prompt", graph),
        ])

        #expect(result.selection == .selected(GenerationReference(interpretation: 0, generation: 0)))
        #expect(result.interpretations[0].format == .comfyUI)
    }

    @Test("No generation metadata selects nothing")
    func nothingToSelect() {
        #expect(MetadataInspector.interpret([Self.payload("Comment", "hello")]).selection == .none)
    }
}

private final class XMLParserStub: NSObject, XMLParserDelegate {}

private func bigEndian(_ value: UInt16) -> Data { Data([UInt8(value >> 8), UInt8(value & 0xFF)]) }

private func bigEndian(_ value: UInt32) -> Data {
    Data([UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
}
