import Compression
import Foundation
import Testing

@testable import Musubi

@Suite("Metadata inspector")
struct MetadataInspectorTests {
    @Test("Draw Things XMP is decoded without losing its raw payload")
    func drawThingsXMP() throws {
        let configuration =
            #"{"c":"a red cube","uc":"blue","model":"model.ckpt","sampler":"Euler A","scale":4.5,"seed":2441935286,"size":"64x32","steps":8,"strength":1,"v2":{"loras":[{"file":"detail.ckpt","weight":0.8,"mode":"all"}]}}"#
        let xmp = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
              <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
                <rdf:Description xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:exif="http://ns.adobe.com/exif/1.0/">
                  <xmp:CreatorTool>Draw Things</xmp:CreatorTool>
                  <exif:UserComment><rdf:Alt><rdf:li xml:lang="x-default">\(configuration)</rdf:li></rdf:Alt></exif:UserComment>
                </rdf:Description>
              </rdf:RDF>
            </x:xmpmeta>
            """
        let image = PNGTestImage.make(
            width: 64,
            height: 32,
            chunks: [PNGTestImage.internationalText(keyword: "XML:com.adobe.xmp", text: xmp)]
        )

        let inspection = try MetadataInspector.inspect(image)
        let interpretation = try #require(inspection.interpretations.first)
        let generation = try #require(interpretation.generations.first)

        #expect(inspection.container == .png)
        #expect(inspection.imageDimensions == PixelDimensions(width: 64, height: 32))
        #expect(inspection.payloads.count == 1)
        #expect(interpretation.format == .drawThings)
        #expect(interpretation.producer == MetadataProducer(name: "Draw Things"))
        #expect(generation.positivePrompt == "a red cube")
        #expect(generation.negativePrompt == "blue")
        #expect(generation.seed == "2441935286")
        #expect(
            generation.resources == [
                GenerationResource(kind: .lora, name: "detail.ckpt", weight: 0.8)
            ])
    }

    @Test("Mochi legacy ImageIO caption is normalized from XMP")
    func mochiLegacyXMP() throws {
        let caption =
            "Include in Image: a red; blue cube; Exclude from Image: blurry; Model: Example; Steps: 8; Guidance Scale: 4.5; Seed: 42; Size: 64x32; Quality: high; Input Images: first.png, second.png; Scheduler: DPM-Solver++; ML Compute Unit: CPU & GPU; Generator: Mochi Diffusion 6.0"
        let xmp = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
              <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
                <rdf:Description xmlns:dc="http://purl.org/dc/elements/1.1/">
                  <dc:description><rdf:Alt><rdf:li xml:lang="x-default">\(caption.replacingOccurrences(of: "&", with: "&amp;"))</rdf:li></rdf:Alt></dc:description>
                </rdf:Description>
              </rdf:RDF>
            </x:xmpmeta>
            """
        let image = PNGTestImage.make(
            width: 64,
            height: 32,
            chunks: [PNGTestImage.internationalText(keyword: "XML:com.adobe.xmp", text: xmp)]
        )

        let inspection = try MetadataInspector.inspect(image)
        let interpretation = try #require(
            inspection.interpretations.first { $0.format == .mochiDiffusionLegacyCaption }
        )
        let generation = try #require(interpretation.generations.first)

        #expect(interpretation.producer == MetadataProducer(name: "Mochi Diffusion", version: "6.0"))
        #expect(generation.positivePrompt == "a red; blue cube")
        #expect(generation.negativePrompt == "blurry")
        #expect(generation.model == "Example")
        #expect(generation.steps == 8)
        #expect(generation.cfgScale == 4.5)
        #expect(generation.seed == "42")
        #expect(generation.dimensions == PixelDimensions(width: 64, height: 32))
        #expect(generation.sampler == "DPM-Solver++")
        #expect(generation.scheduler == nil)
        #expect(generation.resources.isEmpty)
        #expect(
            generation.parameters == [
                GenerationParameter(key: "Quality", value: "high"),
                GenerationParameter(key: "Input Images", value: "first.png, second.png"),
                GenerationParameter(key: "ML Compute Unit", value: "CPU & GPU"),
            ])
    }

    @Test("Mochi 6.1 line caption is normalized from XMP")
    func mochiLineCaptionXMP() throws {
        let caption = """
            Metadata Version: 2
            Include in Image: a red; blue cube\\nsecond line
            Exclude from Image: back\\\\slash
            Model: Example
            Engine: coreml
            Model Key: example-model
            Steps: 8
            Guidance Scale: 4.5
            Seed: 42
            Size: 64x32
            Input Images: first, one.png
            Input Images: second.png
            Scheduler: DPM-Solver++
            ML Compute Unit: CPU & GPU
            Generator: Mochi Diffusion 6.1.2
            """
        let generation = try #require(legacyGeneration(caption: caption))

        #expect(generation.producer == MetadataProducer(name: "Mochi Diffusion", version: "6.1.2"))
        #expect(generation.record.positivePrompt == "a red; blue cube\nsecond line")
        #expect(generation.record.negativePrompt == "back\\slash")
        #expect(generation.record.model == "Example")
        #expect(generation.record.steps == 8)
        #expect(generation.record.cfgScale == 4.5)
        #expect(generation.record.seed == "42")
        #expect(generation.record.dimensions == PixelDimensions(width: 64, height: 32))
        #expect(generation.record.sampler == "DPM-Solver++")
        #expect(
            generation.record.parameters == [
                GenerationParameter(key: "Engine", value: "coreml"),
                GenerationParameter(key: "Model Key", value: "example-model"),
                GenerationParameter(key: "Input Image", value: "first, one.png"),
                GenerationParameter(key: "Input Image", value: "second.png"),
                GenerationParameter(key: "ML Compute Unit", value: "CPU & GPU"),
            ])
    }

    @Test("A Mochi caption of an unknown version is not read")
    func mochiUnknownCaptionVersion() throws {
        let caption = """
            Metadata Version: 3
            Include in Image: a cube
            Generator: Mochi Diffusion 7.0
            """
        #expect(legacyGeneration(caption: caption) == nil)
    }

    private func legacyGeneration(caption: String) -> (
        producer: MetadataProducer?, record: GenerationRecord
    )? {
        guard let (interpretation, _) = legacyInterpretation(caption: caption),
            let record = interpretation.generations.first
        else { return nil }
        return (interpretation.producer, record)
    }

    /// The legacy caption interpretation of `caption` in an ImageIO-style XMP
    /// packet, and the payloads it indexes.
    private func legacyInterpretation(caption: String) -> (MetadataInterpretation, [EmbeddedMetadataPayload])? {
        let escaped =
            caption
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        let xmp = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
              <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
                <rdf:Description xmlns:dc="http://purl.org/dc/elements/1.1/">
                  <dc:description><rdf:Alt><rdf:li xml:lang="x-default">\(escaped)</rdf:li></rdf:Alt></dc:description>
                </rdf:Description>
              </rdf:RDF>
            </x:xmpmeta>
            """
        let payloads = [EmbeddedMetadataPayload(kind: .xmp, data: Data(xmp.utf8), text: xmp)]
        guard
            let interpretation = MetadataInspector.interpret(payloads).interpretations.first(where: {
                $0.format == .mochiDiffusionLegacyCaption
            })
        else { return nil }
        return (interpretation, payloads)
    }

    @Test("A 6.0 caption's Mochi details include its comma-joined input images")
    func mochiSemicolonCaptionDetails() throws {
        let caption =
            "Include in Image: a cube; Quality: high; Starting Image: start.png; Input Images: first.png, second.png; ML Compute Unit: CPU & GPU; Generator: Mochi Diffusion 6.0"
        let (interpretation, payloads) = try #require(legacyInterpretation(caption: caption))

        #expect(
            MochiGenerationDetails(interpretation, payloads: payloads)
                == MochiGenerationDetails(
                    quality: "high", computeUnit: "CPU & GPU", startingImage: "start.png",
                    inputImages: ["first.png", "second.png"]))
    }

    @Test("A 6.1 caption's Mochi details list each input image")
    func mochiLineCaptionDetails() throws {
        let caption = """
            Metadata Version: 2
            Include in Image: a cube
            Engine: coreml
            Model Key: example-model
            ControlNet Image: edges.png
            Input Images: first, one.png
            Input Images: second.png
            Generator: Mochi Diffusion 6.1.2
            """
        let (interpretation, payloads) = try #require(legacyInterpretation(caption: caption))

        #expect(
            MochiGenerationDetails(interpretation, payloads: payloads)
                == MochiGenerationDetails(
                    engine: "coreml", modelKey: "example-model", controlNetImage: "edges.png",
                    inputImages: ["first, one.png", "second.png"]))
    }

    @Test("A native record's Mochi details are its own, and other formats have none")
    func nativeDetails() throws {
        let details = MochiGenerationDetails(
            engine: "iris", modelKey: "flux-klein", inputImages: ["cat.png", "", "dog.png"])
        let snapshot = MochiGenerationSnapshot(
            producer: MetadataProducer(name: "Mochi Diffusion", version: "6.2"),
            generation: GenerationRecord(positivePrompt: "a fox", steps: 4, seed: "9"),
            details: details)
        let image = try PNGMetadataWriter.write(
            PNGMetadataPayloads(
                nativeXMPPacket: MochiNativeCodec.encodeXMPPacket(snapshot),
                parameters: "a fox\nSteps: 4, Seed: 9, Size: 8x8"),
            into: PNGTestImage.make(width: 8, height: 8, chunks: []),
            replacingExistingRecords: false)

        let inspection = try MetadataInspector.inspect(image)
        let native = try #require(inspection.interpretations.first { $0.format == .mochiDiffusion })
        let compatible = try #require(inspection.interpretations.first { $0.format == .automatic1111 })

        #expect(MochiGenerationDetails(native, payloads: inspection.payloads) == details)
        #expect(MochiGenerationDetails(compatible, payloads: inspection.payloads) == nil)
    }

    @Test("Mochi legacy JPEG accepts ImageIO XMP packet wrappers")
    func mochiLegacyJPEGXMPPacket() throws {
        let caption = "Include in Image: a cube; Seed: 42; Size: 64x32; Generator: Mochi Diffusion 6.0"
        let xmp = """
            <?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
              <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
                <rdf:Description xmlns:dc="http://purl.org/dc/elements/1.1/">
                  <dc:description><rdf:Alt><rdf:li xml:lang="x-default">\(caption)</rdf:li></rdf:Alt></dc:description>
                </rdf:Description>
              </rdf:RDF>
            </x:xmpmeta>
            <?xpacket end="w"?>
            """
        let image = JPEGTestImage.makeXMP(width: 64, height: 32, xmp: xmp)

        let inspection = try MetadataInspector.inspect(image)
        let interpretation = try #require(
            inspection.interpretations.first { $0.format == .mochiDiffusionLegacyCaption }
        )

        #expect(interpretation.producer?.version == "6.0")
        #expect(interpretation.generations.first?.positivePrompt == "a cube")
    }

    @Test("ComfyUI core graph follows conditioning and model links")
    func comfyUICoreGraph() throws {
        let prompt =
            #"{"3":{"class_type":"KSampler","inputs":{"seed":1234567890123,"steps":7,"cfg":1,"sampler_name":"euler","scheduler":"simple","denoise":1,"model":["16",0],"positive":["6",0],"negative":["7",0],"latent_image":["5",0]}},"5":{"class_type":"EmptyLatentImage","inputs":{"width":64,"height":32}},"6":{"class_type":"CLIPTextEncode","inputs":{"text":"a red cube"}},"7":{"class_type":"CLIPTextEncode","inputs":{"text":"blue"}},"9":{"class_type":"SaveImage","inputs":{"images":["8",0]}},"8":{"class_type":"VAEDecode","inputs":{"samples":["3",0]}},"16":{"class_type":"UNETLoader","inputs":{"unet_name":"model.safetensors"}}}"#
        let workflow = #"{"version":1,"nodes":[]}"#
        let image = PNGTestImage.make(
            width: 64,
            height: 32,
            chunks: [
                PNGTestImage.text(keyword: "prompt", text: prompt),
                PNGTestImage.text(keyword: "workflow", text: workflow),
            ]
        )

        let inspection = try MetadataInspector.inspect(image)
        let interpretation = try #require(inspection.interpretations.first)
        let generation = try #require(interpretation.generations.first)

        #expect(interpretation.format == .comfyUI)
        #expect(interpretation.producer == nil)
        #expect(interpretation.payloadIndices == [0, 1])
        #expect(generation.positivePrompt == "a red cube")
        #expect(generation.negativePrompt == "blue")
        #expect(generation.model == "model.safetensors")
        #expect(generation.seed == "1234567890123")
        #expect(generation.dimensions == PixelDimensions(width: 64, height: 32))
    }

    @Test("ComfyUI advanced sampler resolves connected settings and zeroed conditioning")
    func comfyUIAdvancedSampler() throws {
        let prompt =
            #"{"1":{"class_type":"SamplerCustomAdvanced","inputs":{"noise":["2",0],"guider":["3",0],"sampler":["4",0],"sigmas":["5",0],"latent_image":["6",0]}},"2":{"class_type":"RandomNoise","inputs":{"noise_seed":987654321}},"3":{"class_type":"CFGGuider","inputs":{"cfg":3.5,"model":["9",0],"positive":["7",0],"negative":["8",0]}},"4":{"class_type":"KSamplerSelect","inputs":{"sampler_name":"euler_ancestral"}},"5":{"class_type":"BasicScheduler","inputs":{"scheduler":"normal","steps":20,"denoise":0.75,"model":["9",0]}},"6":{"class_type":"EmptyLatentImage","inputs":{"width":80,"height":48}},"7":{"class_type":"CLIPTextEncode","inputs":{"text":["10",0]}},"8":{"class_type":"ConditioningZeroOut","inputs":{"conditioning":["11",0]}},"9":{"class_type":"UNETLoader","inputs":{"unet_name":"advanced.safetensors"}},"10":{"class_type":"StringConcatenate","inputs":{"string_a":"red","delimiter":" ","string_b":"cube"}},"11":{"class_type":"CLIPTextEncode","inputs":{"text":"this must not become the negative prompt"}},"12":{"class_type":"VAEDecode","inputs":{"samples":["1",0]}},"13":{"class_type":"SaveImage","inputs":{"images":["12",0]}}}"#
        let image = PNGTestImage.make(
            width: 80,
            height: 48,
            chunks: [PNGTestImage.text(keyword: "prompt", text: prompt)]
        )

        let inspection = try MetadataInspector.inspect(image)
        let generation = try #require(inspection.interpretations.first?.generations.first)

        #expect(generation.positivePrompt == "red cube")
        #expect(generation.negativePrompt == nil)
        #expect(generation.model == "advanced.safetensors")
        #expect(generation.sampler == "euler_ancestral")
        #expect(generation.scheduler == "normal")
        #expect(generation.steps == 20)
        #expect(generation.cfgScale == 3.5)
        #expect(generation.seed == "987654321")
        #expect(generation.denoise == 0.75)
        #expect(generation.dimensions == PixelDimensions(width: 80, height: 48))
    }

    @Test("Civitai JPEG decodes UTF-16BE UserComment and resources")
    func civitaiJPEG() throws {
        let text = """
            a red cube
            Negative prompt: blue
            Steps: 12, Sampler: Euler, CFG scale: 1, Seed: 391201976, Size: 64x32, Civitai resources: [{"type":"checkpoint","modelVersionId":42,"modelName":"Example","weight":1}], Civitai metadata: {"workflow":"txt2img"}
            """
        let image = JPEGTestImage.make(width: 64, height: 32, userComment: text)

        let inspection = try MetadataInspector.inspect(image)
        let interpretation = try #require(inspection.interpretations.first)
        let generation = try #require(interpretation.generations.first)

        #expect(inspection.container == .jpeg)
        #expect(interpretation.format == .automatic1111)
        #expect(interpretation.producer == MetadataProducer(name: "Civitai"))
        #expect(generation.positivePrompt == "a red cube")
        #expect(generation.negativePrompt == "blue")
        #expect(generation.steps == 12)
        #expect(
            generation.resources == [
                GenerationResource(
                    kind: .checkpoint,
                    name: "Example",
                    weight: 1,
                    civitaiModelVersionID: 42
                )
            ])
    }

    @Test("A Software setting names the producer and Civitai resources do not")
    func a1111ProducerAttribution() throws {
        let text = """
            a red cube
            Steps: 8, Sampler: DPM++ 2M, CFG scale: 7, Seed: 42, Size: 64x32, Software: Mochi Diffusion 6.2, Civitai resources: [{"type":"checkpoint","modelVersionId":42}]
            """
        let image = PNGTestImage.make(
            width: 64,
            height: 32,
            chunks: [PNGTestImage.internationalText(keyword: "parameters", text: text)]
        )

        let interpretation = try #require(MetadataInspector.inspect(image).interpretations.first)

        #expect(interpretation.format == .automatic1111)
        #expect(interpretation.producer == MetadataProducer(name: "Mochi Diffusion", version: "6.2"))
    }

    @Test("AUTOMATIC1111 text without a producer setting names no producer")
    func a1111UnknownProducer() throws {
        let text = """
            a red cube
            Steps: 8, Sampler: Euler, CFG scale: 7, Seed: 42, Size: 64x32, Civitai resources: [{"type":"lora","modelVersionId":7}]
            """
        let image = PNGTestImage.make(
            width: 64,
            height: 32,
            chunks: [PNGTestImage.text(keyword: "parameters", text: text)]
        )

        let interpretation = try #require(MetadataInspector.inspect(image).interpretations.first)

        #expect(interpretation.producer == nil)
    }

    @Test(
        "An AUTOMATIC1111 model hash keeps the algorithm its length identifies",
        arguments: [
            ("0123abcd", ResourceHashAlgorithm?.some(.a1111AutoV1)),
            ("0123456789", .a1111AutoV2),
            (String(repeating: "a", count: 64), .sha256),
            ("0123456789ab", nil),
        ]
    )
    func a1111ModelHashAlgorithm(hash: String, algorithm: ResourceHashAlgorithm?) throws {
        let text = "a red cube\nSteps: 8, Sampler: Euler, Seed: 42, Model hash: \(hash), Model: Example"
        let image = PNGTestImage.make(
            width: 64,
            height: 32,
            chunks: [PNGTestImage.text(keyword: "parameters", text: text)]
        )

        let generation = try #require(MetadataInspector.inspect(image).interpretations.first?.generations.first)

        #expect(
            generation.resources == [
                GenerationResource(
                    kind: .checkpoint,
                    name: "Example",
                    hashes: [ResourceHash(algorithm: algorithm, value: hash)]
                )
            ])
    }

    @Test("Civitai resource kinds keep embeddings distinct and unknown spellings intact")
    func civitaiResourceKinds() throws {
        let text = """
            a red cube
            Steps: 8, Sampler: Euler, Seed: 42, Civitai resources: [{"type":"textualinversion","modelName":"bad-hands"},{"type":"LoCon","modelName":"style","weight":-0.5},{"modelName":"untyped"}]
            """
        let image = PNGTestImage.make(
            width: 64,
            height: 32,
            chunks: [PNGTestImage.text(keyword: "parameters", text: text)]
        )

        let generation = try #require(MetadataInspector.inspect(image).interpretations.first?.generations.first)

        #expect(
            generation.resources == [
                GenerationResource(kind: .embedding, name: "bad-hands"),
                GenerationResource(kind: GenerationResourceKind(rawValue: "LoCon"), name: "style", weight: -0.5),
                GenerationResource(kind: .other, name: "untyped"),
            ])
    }

    @Test("Extensible identifiers encode as their plain source spelling")
    func extensibleIdentifierCoding() throws {
        let resource = GenerationResource(
            kind: GenerationResourceKind(rawValue: "LoCon"),
            hashes: [ResourceHash(algorithm: .a1111AutoV2, value: "0123456789")]
        )

        let data = try JSONEncoder().encode(resource)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hash = try #require((object["hashes"] as? [[String: Any]])?.first)

        #expect(object["kind"] as? String == "LoCon")
        #expect(hash["algorithm"] as? String == "a1111-auto-v2")
        #expect(try JSONDecoder().decode(GenerationResource.self, from: data) == resource)
    }

    @Test("An empty legacy negative prompt stays empty and a missing one stays missing")
    func mochiLegacyEmptyPrompt() throws {
        func negativePrompt(in caption: String) throws -> String? {
            let xmp = """
                <x:xmpmeta xmlns:x="adobe:ns:meta/">
                  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
                    <rdf:Description xmlns:dc="http://purl.org/dc/elements/1.1/">
                      <dc:description><rdf:Alt><rdf:li xml:lang="x-default">\(caption)</rdf:li></rdf:Alt></dc:description>
                    </rdf:Description>
                  </rdf:RDF>
                </x:xmpmeta>
                """
            let payload = EmbeddedMetadataPayload(kind: .xmp, data: Data(xmp.utf8), text: xmp)
            let generation = MetadataInspector.interpret([payload]).interpretations.first?.generations.first
            return try #require(generation).negativePrompt
        }

        #expect(
            try negativePrompt(
                in: "Include in Image: a cube; Exclude from Image: ; Seed: 42; Generator: Mochi Diffusion 6.0") == "")
        #expect(try negativePrompt(in: "Include in Image: a cube; Seed: 42; Generator: Mochi Diffusion 6.0") == nil)
    }

    @Test("Payloads read by another framework use the same codecs as inspection")
    func interpretExtractedPayloads() throws {
        let caption = "Include in Image: a cube; Seed: 42; Size: 64x32; Generator: Mochi Diffusion 6.0"
        let xmp = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
              <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
                <rdf:Description xmlns:dc="http://purl.org/dc/elements/1.1/">
                  <dc:description><rdf:Alt><rdf:li xml:lang="x-default">\(caption)</rdf:li></rdf:Alt></dc:description>
                </rdf:Description>
              </rdf:RDF>
            </x:xmpmeta>
            """
        let payload = EmbeddedMetadataPayload(kind: .xmp, data: Data(xmp.utf8), text: xmp)
        let image = JPEGTestImage.makeXMP(width: 64, height: 32, xmp: xmp)

        let extracted = MetadataInspector.interpret([payload])
        let inspected = try MetadataInspector.inspect(image)

        #expect(extracted.interpretations.first?.generations == inspected.interpretations.first?.generations)
        #expect(extracted.interpretations.first?.payloadIndices == [0])
        #expect(extracted.interpretations.first?.generations.first?.seed == "42")
    }

    @Test("Ordinary PNG metadata is not attributed to a generator")
    func noGenerationMetadata() throws {
        let image = PNGTestImage.make(
            width: 16,
            height: 16,
            chunks: [PNGTestImage.text(keyword: "Description", text: "vacation photo")]
        )

        let inspection = try MetadataInspector.inspect(image)

        #expect(inspection.payloads.count == 1)
        #expect(inspection.interpretations.isEmpty)
    }

    @Test("Bad PNG CRC is visible but does not hide readable metadata")
    func badCRCProducesDiagnostic() throws {
        let image = PNGTestImage.make(
            width: 16,
            height: 16,
            chunks: [PNGTestImage.text(keyword: "Description", text: "readable", corruptCRC: true)]
        )

        let inspection = try MetadataInspector.inspect(image)

        #expect(inspection.payloads.first?.text == "readable")
        #expect(inspection.diagnostics.count == 1)
    }

    @Test("PNG pixel data is opaque to metadata inspection")
    func pngPixelDataIsOpaque() throws {
        let image = PNGTestImage.make(
            width: 16,
            height: 16,
            chunks: [],
            imageData: Data(repeating: 0xA5, count: 1_024),
            corruptImageDataCRC: true,
            trailingChunks: [PNGTestImage.text(keyword: "Description", text: "after pixels")]
        )

        let inspection = try MetadataInspector.inspect(image)

        #expect(inspection.payloads.first?.text == "after pixels")
        #expect(inspection.diagnostics.isEmpty)
    }

    @Test("Compressed PNG text carriers are decoded")
    func compressedPNGText() throws {
        let image = PNGTestImage.make(
            width: 16,
            height: 16,
            chunks: [
                PNGTestImage.compressedText(keyword: "Comment", text: "café"),
                PNGTestImage.compressedInternationalText(
                    keyword: "Description",
                    text: "こんにちは"
                ),
            ]
        )

        let inspection = try MetadataInspector.inspect(image)

        #expect(inspection.payloads.map(\.text) == ["café", "こんにちは"])
    }

    @Test("Unknown bytes report an unsupported container")
    func unsupportedContainer() {
        #expect(throws: MetadataInspectionError.unsupportedContainer) {
            try MetadataInspector.inspect(Data("not an image".utf8))
        }
    }
}

enum PNGTestImage {
    struct Chunk {
        let type: String
        let data: Data
        let corruptCRC: Bool
    }

    static func make(
        width: UInt32,
        height: UInt32,
        chunks: [Chunk],
        imageData: Data = Data(),
        corruptImageDataCRC: Bool = false,
        trailingChunks: [Chunk] = []
    ) -> Data {
        var image = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var header = Data()
        header.appendBigEndian(width)
        header.appendBigEndian(height)
        header.append(contentsOf: [8, 2, 0, 0, 0])
        image.append(chunk(type: "IHDR", data: header))
        for item in chunks {
            image.append(
                chunk(type: item.type, data: item.data, corruptCRC: item.corruptCRC)
            )
        }
        image.append(chunk(type: "IDAT", data: imageData, corruptCRC: corruptImageDataCRC))
        for item in trailingChunks {
            image.append(
                chunk(type: item.type, data: item.data, corruptCRC: item.corruptCRC)
            )
        }
        image.append(chunk(type: "IEND", data: Data()))
        return image
    }

    static func text(keyword: String, text: String, corruptCRC: Bool = false) -> Chunk {
        var data = Data(keyword.utf8)
        data.append(0)
        data.append(Data(text.utf8))
        return Chunk(type: "tEXt", data: data, corruptCRC: corruptCRC)
    }

    static func internationalText(keyword: String, text: String) -> Chunk {
        var data = Data(keyword.utf8)
        data.append(contentsOf: [0, 0, 0, 0, 0])
        data.append(Data(text.utf8))
        return Chunk(type: "iTXt", data: data, corruptCRC: false)
    }

    static func compressedText(keyword: String, text: String) -> Chunk {
        var data = Data(keyword.utf8)
        data.append(contentsOf: [0, 0])
        data.append(compress(text.data(using: .isoLatin1)!))
        return Chunk(type: "zTXt", data: data, corruptCRC: false)
    }

    static func compressedInternationalText(keyword: String, text: String) -> Chunk {
        var data = Data(keyword.utf8)
        data.append(contentsOf: [0, 1, 0, 0, 0])
        data.append(compress(Data(text.utf8)))
        return Chunk(type: "iTXt", data: data, corruptCRC: false)
    }

    private static func compress(_ input: Data) -> Data {
        let capacity = max(64, input.count * 2)
        var output = [UInt8](repeating: 0, count: capacity)
        let encodedCount = input.withUnsafeBytes { inputBuffer in
            output.withUnsafeMutableBytes { outputBuffer in
                compression_encode_buffer(
                    outputBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    capacity,
                    inputBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    input.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        precondition(encodedCount > 0)
        return Data(output.prefix(encodedCount))
    }

    private static func chunk(type: String, data: Data, corruptCRC: Bool = false) -> Data {
        let typeData = Data(type.utf8)
        var result = Data()
        result.appendBigEndian(UInt32(data.count))
        result.append(typeData)
        result.append(data)
        let crc = CRC32.checksum(type: typeData, payload: data) ^ (corruptCRC ? 1 : 0)
        result.appendBigEndian(crc)
        return result
    }
}

enum JPEGTestImage {
    static func make(width: UInt16, height: UInt16, userComment: String) -> Data {
        let comment = Data("UNICODE\0".utf8) + userComment.data(using: .utf16BigEndian)!
        var tiff = Data([0x4D, 0x4D, 0, 42, 0, 0, 0, 8])
        tiff.appendBigEndian(UInt16(1))
        tiff.appendBigEndian(UInt16(0x8769))
        tiff.appendBigEndian(UInt16(4))
        tiff.appendBigEndian(UInt32(1))
        tiff.appendBigEndian(UInt32(26))
        tiff.appendBigEndian(UInt32(0))
        tiff.appendBigEndian(UInt16(1))
        tiff.appendBigEndian(UInt16(0x9286))
        tiff.appendBigEndian(UInt16(7))
        tiff.appendBigEndian(UInt32(comment.count))
        tiff.appendBigEndian(UInt32(44))
        tiff.appendBigEndian(UInt32(0))
        tiff.append(comment)

        var image = Data([0xFF, 0xD8])
        image.append(segment(marker: 0xE1, data: Data("Exif\0\0".utf8) + tiff))
        var frame = Data([8])
        frame.appendBigEndian(height)
        frame.appendBigEndian(width)
        image.append(segment(marker: 0xC0, data: frame))
        image.append(contentsOf: [0xFF, 0xDA, 0xFF, 0xD9])
        return image
    }

    static func makeXMP(width: UInt16, height: UInt16, xmp: String) -> Data {
        var image = Data([0xFF, 0xD8])
        let prefix = Data("http://ns.adobe.com/xap/1.0/\0".utf8)
        image.append(segment(marker: 0xE1, data: prefix + Data(xmp.utf8)))
        var frame = Data([8])
        frame.appendBigEndian(height)
        frame.appendBigEndian(width)
        image.append(segment(marker: 0xC0, data: frame))
        image.append(contentsOf: [0xFF, 0xDA, 0xFF, 0xD9])
        return image
    }

    private static func segment(marker: UInt8, data: Data) -> Data {
        var result = Data([0xFF, marker])
        result.appendBigEndian(UInt16(data.count + 2))
        result.append(data)
        return result
    }
}

extension Data {
    fileprivate mutating func appendBigEndian(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xFF))
    }

    fileprivate mutating func appendBigEndian(_ value: UInt32) {
        append(UInt8(value >> 24))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}
