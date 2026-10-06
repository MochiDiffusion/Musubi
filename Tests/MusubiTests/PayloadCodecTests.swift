import Foundation
import ImageIO
import Testing

@testable import Musubi

@Suite("Payload codecs")
struct PayloadCodecTests {
    private static let producer = MetadataProducer(name: "Mochi Diffusion", version: "6.2")

    private static let diffusion = GenerationRecord(
        positivePrompt: "a red cube",
        negativePrompt: "blur",
        model: "Example",
        sampler: "DPM++ 2M",
        scheduler: "Karras",
        steps: 30,
        cfgScale: 7.5,
        seed: "4294967296",
        dimensions: PixelDimensions(width: 1024, height: 768),
        denoise: 0.42,
        generatedAt: Date(timeIntervalSince1970: 1_790_000_000.25),
        resources: [GenerationResource(kind: .control, name: "canny")],
        parameters: [GenerationParameter(key: "Architecture", value: "SDXL")]
    )

    private static let details = MochiGenerationDetails(
        engine: "coreml",
        modelKey: "example",
        computeUnit: "CPU & GPU",
        startingImage: "start.png",
        controlNetImage: "edges.png"
    )

    // MARK: - AUTOMATIC1111 text

    @Test("A complete diffusion record writes every known setting in order")
    func completeDiffusionText() {
        let encoding = A1111ParametersEncoder.encode(Self.diffusion, producer: Self.producer)

        #expect(
            encoding.text == """
                a red cube
                Negative prompt: blur
                Steps: 30, Sampler: DPM++ 2M, Schedule type: Karras, CFG scale: 7.5, Seed: 4294967296, \
                Size: 1024x768, Model: Example, Denoising strength: 0.42, Software: Mochi Diffusion 6.2
                """)
        #expect(encoding.diagnostics.map(\.message) == ["The control resource canny has no supported field"])
    }

    @Test("Resource fields use the forms the pinned external readers accept")
    func resourceTextMatchesOracleFixture() {
        let generation = GenerationRecord(
            positivePrompt: "a red cube",
            negativePrompt: "blur",
            model: "Example",
            sampler: "Euler",
            steps: 8,
            cfgScale: 4.5,
            seed: "42",
            dimensions: PixelDimensions(width: 32, height: 32),
            resources: [
                GenerationResource(
                    kind: .checkpoint, name: "Example",
                    hashes: [ResourceHash(algorithm: .a1111AutoV2, value: "0123456789")]),
                GenerationResource(
                    kind: .lora, name: "detail", weight: 0.75,
                    hashes: [ResourceHash(algorithm: .a1111AutoV2, value: "abcdef0123")],
                    civitaiModelVersionID: 123456),
            ]
        )

        let encoding = A1111ParametersEncoder.encode(generation, producer: nil)

        #expect(
            encoding.text == """
                a red cube <lora:detail:0.75>
                Negative prompt: blur
                Steps: 8, Sampler: Euler, CFG scale: 4.5, Seed: 42, Size: 32x32, Model: Example, \
                Model hash: 0123456789, Lora hashes: "detail: abcdef0123", \
                Civitai resources: [{"type":"lora","modelVersionId":123456,"weight":0.75}]
                """)
        #expect(encoding.diagnostics.isEmpty)
    }

    @Test("Unicode, multiline prompts and punctuated names are carried or quoted")
    func unicodeAndQuotedValues() {
        var generation = Self.diffusion
        generation.positivePrompt = "猫 on a café table\nsecond line"
        generation.model = #"café, "猫""#
        generation.resources = []

        let text = A1111ParametersEncoder.encode(generation, producer: nil).text

        #expect(text?.hasPrefix("猫 on a café table\nsecond line\nNegative prompt: blur\n") == true)
        #expect(text?.contains(#"Model: "café, \"猫\"""#) == true)
    }

    @Test(
        "A prompt line that a reader would take for a section marker blocks the projection",
        arguments: ["a cube\nNegative prompt: blur", "a cube\n  Steps: 3, Seed: 1"]
    )
    func reservedMarkerRefusesProjection(prompt: String) throws {
        var generation = Self.diffusion
        generation.positivePrompt = prompt

        let encoding = A1111ParametersEncoder.encode(generation, producer: Self.producer)
        let snapshot = MochiGenerationSnapshot(producer: Self.producer, generation: generation)

        #expect(encoding.text == nil)
        #expect(encoding.diagnostics.contains { $0.message.contains("misread") })
        #expect(try MochiNativeCodec.decodeJSON(MochiNativeCodec.encodeJSON(snapshot)) == snapshot)
    }

    @Test("Whitespace that readers trim is reported and the text is still written")
    func trimmedWhitespaceIsReported() {
        var generation = Self.diffusion
        generation.positivePrompt = "a cube  \n  indented"

        let encoding = A1111ParametersEncoder.encode(generation, producer: Self.producer)

        #expect(encoding.text != nil)
        #expect(encoding.diagnostics.contains { $0.message.contains("whitespace") })
    }

    @Test("A sparse record writes only the settings it has")
    func sparseRecord() {
        let hosted = GenerationRecord(
            positivePrompt: "a cube",
            model: "hosted-example",
            dimensions: PixelDimensions(width: 32, height: 32)
        )

        let withProducer = A1111ParametersEncoder.encode(hosted, producer: Self.producer)
        let withoutProducer = A1111ParametersEncoder.encode(hosted, producer: nil)

        #expect(withProducer.text == "a cube\nSize: 32x32, Model: hosted-example, Software: Mochi Diffusion 6.2")
        #expect(withoutProducer.text == nil)
        #expect(withoutProducer.diagnostics.contains { $0.message.contains("prompt text") })
    }

    @Test("A non-finite value is reported, not written")
    func nonFiniteValueIsReported() {
        var generation = Self.diffusion
        generation.cfgScale = .nan
        generation.resources = []

        let encoding = A1111ParametersEncoder.encode(generation, producer: Self.producer)

        #expect(encoding.text?.contains("CFG scale") == false)
        #expect(encoding.diagnostics.map(\.message) == ["CFG scale is not a finite number"])
    }

    @Test("Named LoRAs are appended to the prompt line as tags, and the typed prompt stays exact")
    func loraTags() throws {
        var generation = Self.diffusion
        generation.resources = [
            GenerationResource(kind: .lora, name: "style", weight: -0.5),
            GenerationResource(kind: .lora, name: "detail"),
            GenerationResource(kind: .lora, name: "bad:name", weight: 1),
        ]
        let snapshot = MochiGenerationSnapshot(producer: Self.producer, generation: generation)

        let encoding = A1111ParametersEncoder.encode(generation, producer: Self.producer)
        let decoded = try MochiNativeCodec.decodeJSON(MochiNativeCodec.encodeJSON(snapshot))

        #expect(encoding.text?.hasPrefix("a red cube <lora:style:-0.5> <lora:detail>\nNegative prompt: blur\n") == true)
        #expect(encoding.diagnostics.map(\.message) == ["The lora resource bad:name has no supported field"])
        #expect(decoded.generation.positivePrompt == "a red cube")
    }

    @Test("LoRA tags alone form the prompt line when the typed prompt is empty")
    func loraTagsWithoutPrompt() {
        var generation = Self.diffusion
        generation.positivePrompt = ""
        generation.resources = [GenerationResource(kind: .lora, name: "style", weight: 0.8)]

        #expect(
            A1111ParametersEncoder.encode(generation, producer: Self.producer).text?
                .hasPrefix("<lora:style:0.8>\nNegative prompt:") == true)
    }

    @Test("A NUL character blocks the projection")
    func nulRefusesProjection() {
        var generation = Self.diffusion
        generation.negativePrompt = "a\0b"

        #expect(A1111ParametersEncoder.encode(generation, producer: Self.producer).text == nil)
    }

    // MARK: - Native record

    @Test("The native JSON matches the bytes the pinned external readers accepted")
    func nativeJSONMatchesOracleFixture() throws {
        let snapshot = MochiGenerationSnapshot(
            producer: MetadataProducer(name: "Mochi Diffusion", version: "wire-probe"),
            generation: GenerationRecord(
                positivePrompt: "a red cube",
                negativePrompt: "blur",
                model: "Example",
                sampler: "Euler",
                steps: 8,
                cfgScale: 4.5,
                seed: "42",
                dimensions: PixelDimensions(width: 32, height: 32),
                generatedAt: Date(timeIntervalSince1970: 1_788_998_400),
                resources: [
                    GenerationResource(
                        kind: .checkpoint, name: "Example",
                        hashes: [ResourceHash(algorithm: .a1111AutoV2, value: "0123456789")]),
                    GenerationResource(
                        kind: .lora, name: "detail", weight: 0.75,
                        hashes: [ResourceHash(algorithm: .a1111AutoV2, value: "abcdef0123")],
                        civitaiModelVersionID: 123456),
                ]
            ),
            details: MochiGenerationDetails(engine: "coreml", modelKey: "example")
        )

        #expect(
            try MochiNativeCodec.encodeJSON(snapshot)
                == #"{"format":"mochi-diffusion","generation":{"cfgScale":4.5,"generatedAt":"2026-09-10T00:00:00Z","#
                + #""height":32,"model":"Example","negativePrompt":"blur","prompt":"a red cube","resources":"#
                + #"[{"hashes":[{"algorithm":"a1111-auto-v2","value":"0123456789"}],"kind":"checkpoint","name":"Example"},"#
                + #"{"civitaiModelVersionID":"123456","hashes":[{"algorithm":"a1111-auto-v2","value":"abcdef0123"}],"#
                + #""kind":"lora","name":"detail","weight":0.75}],"sampler":"Euler","seed":"42","steps":8,"width":32},"#
                + #""mochi":{"engine":"coreml","modelKey":"example"},"#
                + #""producer":{"application":"Mochi Diffusion","version":"wire-probe"},"version":1}"#)
    }

    @Test("The XMP packet restores the full snapshot", arguments: [1_790_000_000.25, 1_790_000_000])
    func nativeRoundTrip(timestamp: Double) throws {
        var generation = Self.diffusion
        generation.generatedAt = Date(timeIntervalSince1970: timestamp)
        generation.positivePrompt = "line one\r\n  line two <&> \"quoted\"\0"
        var details = Self.details
        details.inputImages = ["first.png", "", "third.png"]
        let snapshot = MochiGenerationSnapshot(producer: Self.producer, generation: generation, details: details)

        let packet = try MochiNativeCodec.encodeXMPPacket(snapshot)

        #expect(try MochiNativeCodec.decodeXMPPacket(packet) == snapshot)
    }

    @Test("LoRA names and weights are read from the native record, not the compatibility text")
    func nativeLoRAs() throws {
        let loras = [
            GenerationResource(kind: .lora, name: "style", weight: 0.8),
            GenerationResource(kind: .lora, name: "detail", weight: -0.5),
            GenerationResource(kind: .lora, name: "unweighted"),
        ]
        let generation = GenerationRecord(positivePrompt: "a red cube", steps: 8, seed: "42", resources: loras)
        let xmp = try MochiNativeCodec.encodeXMPPacket(
            MochiGenerationSnapshot(producer: Self.producer, generation: generation))
        let parameters = try #require(A1111ParametersEncoder.encode(generation, producer: Self.producer).text)

        let result = MetadataInspector.interpret([
            EmbeddedMetadataPayload(kind: .xmp, data: Data(xmp.utf8), text: xmp),
            EmbeddedMetadataPayload(
                kind: .pngText, keyword: "parameters", data: Data(parameters.utf8), text: parameters),
        ])

        #expect(result.selection == .selected(GenerationReference(interpretation: 0, generation: 0)))
        let selected = try #require(result.interpretations.first)
        #expect(selected.format == .mochiDiffusion)
        #expect(selected.generations.first?.resources == loras)
        #expect(selected.generations.first?.positivePrompt == "a red cube")
    }

    @Test("Empty values stay distinct from absent ones")
    func emptyIsNotAbsent() throws {
        let empty = MochiGenerationSnapshot(
            producer: Self.producer,
            generation: GenerationRecord(positivePrompt: "", negativePrompt: ""),
            details: MochiGenerationDetails(inputImages: [])
        )
        let absent = MochiGenerationSnapshot(producer: Self.producer, generation: GenerationRecord())

        let emptyJSON = try MochiNativeCodec.encodeJSON(empty)
        let absentJSON = try MochiNativeCodec.encodeJSON(absent)

        #expect(try MochiNativeCodec.decodeJSON(emptyJSON) == empty)
        #expect(try MochiNativeCodec.decodeJSON(absentJSON) == absent)
        #expect(emptyJSON.contains(#""negativePrompt":"""#))
        #expect(!absentJSON.contains("negativePrompt"))
        #expect(!absentJSON.contains(#""mochi":"#))
    }

    @Test(
        "Values the format cannot represent fail the encoding",
        arguments: [
            (GenerationRecord(cfgScale: .infinity), MochiNativeCodecError.nonFiniteValue("cfgScale")),
            (GenerationRecord(seed: "12e3"), .invalidValue("The seed is not a decimal integer")),
            (GenerationRecord(steps: 0), .invalidValue("steps must be positive")),
            (
                GenerationRecord(resources: [
                    GenerationResource(kind: .lora, hashes: [ResourceHash(algorithm: nil, value: "ab")])
                ]),
                .invalidValue("A resource hash has no algorithm")
            ),
        ]
    )
    func unrepresentableValues(generation: GenerationRecord, error: MochiNativeCodecError) {
        let snapshot = MochiGenerationSnapshot(producer: Self.producer, generation: generation)

        #expect(throws: error) { try MochiNativeCodec.encodeJSON(snapshot) }
    }

    @Test(
        "A description XML cannot carry, or one that overfills the packet, is left out",
        arguments: ["a\u{1}b", String(repeating: "x", count: MochiNativeCodec.maximumPacketSize)])
    func omittedDescription(description: String) throws {
        let snapshot = MochiGenerationSnapshot(producer: Self.producer, generation: Self.diffusion)

        let packet = try MochiNativeCodec.encodeXMPPacket(snapshot, description: description)

        #expect(packet == (try MochiNativeCodec.encodeXMPPacket(snapshot)))
    }

    @Test("A packet over the size limit is refused")
    func oversizedPacket() {
        let snapshot = MochiGenerationSnapshot(
            producer: Self.producer,
            generation: GenerationRecord(
                positivePrompt: String(repeating: "x", count: MochiNativeCodec.maximumPacketSize))
        )

        #expect(throws: MochiNativeCodecError.self) { try MochiNativeCodec.encodeXMPPacket(snapshot) }
    }

    @Test(
        "Malformed native JSON is rejected",
        arguments: [
            (
                #"{"format":"mochi-diffusion","version":2,"producer":{"application":"x"},"generation":{}}"#,
                MochiNativeCodecError.unsupportedVersion(2)
            ),
            (
                #"{"format":"mochi-diffusion","version":1,"producer":{"application":"x"},"generation":{"seed":"1","seed":"2"}}"#,
                .duplicateKey("seed")
            ),
            (
                #"{"format":"mochi-diffusion","version":1,"producer":{"application":"x"},"generation":{"seed":"1","seed":"2"}}"#,
                .duplicateKey("seed")
            ),
            (
                #"{"format":"mochi-diffusion","version":1,"producer":{"application":"x"},"generation":{"steps":"8"}}"#,
                .invalidRecord("A value has the wrong type or is missing")
            ),
            (#"{"format":"other","version":1}"#, .invalidRecord("The format is not mochi-diffusion")),
        ]
    )
    func malformedNativeJSON(json: String, error: MochiNativeCodecError) {
        #expect(throws: error) { try MochiNativeCodec.decodeJSON(json) }
    }

    @Test("Keys that repeat only in different objects are not duplicates")
    func sameKeyInSeparateObjects() throws {
        let json =
            #"{"format":"mochi-diffusion","version":1,"producer":{"application":"x","version":"1"},"#
            + #""generation":{"resources":[{"kind":"lora","name":"a"},{"kind":"lora","name":"b"}]}}"#

        #expect(try MochiNativeCodec.decodeJSON(json).generation.resources.count == 2)
    }

    // MARK: - Reading and ImageIO

    @Test("A future native version leaves the compatibility interpretation readable")
    func futureVersionFallsBack() throws {
        let future = #"{"format":"mochi-diffusion","version":2}"#
        let xmp = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
            <rdf:Description xmlns:mochi="\(MochiNativeCodec.namespace)"><mochi:Generation>\(future)</mochi:Generation>\
            </rdf:Description></rdf:RDF></x:xmpmeta>
            """
        let parameters = "a cube\nSteps: 8, Seed: 42, Size: 32x32"

        let result = MetadataInspector.interpret([
            EmbeddedMetadataPayload(kind: .xmp, keyword: "XML:com.adobe.xmp", data: Data(xmp.utf8), text: xmp),
            EmbeddedMetadataPayload(
                kind: .pngText, keyword: "parameters", data: Data(parameters.utf8), text: parameters),
        ])

        #expect(result.interpretations.map(\.format) == [.automatic1111])
        #expect(
            result.diagnostics.map(\.message) == [
                "Mochi Diffusion native record was not read: Version 2 is not supported"
            ])
    }

    @Test("A native record is interpreted with its producer and Mochi details")
    func nativeInterpretation() throws {
        let snapshot = MochiGenerationSnapshot(
            producer: Self.producer, generation: Self.diffusion, details: Self.details)
        let packet = try MochiNativeCodec.encodeXMPPacket(snapshot)

        let result = MetadataInspector.interpret([
            EmbeddedMetadataPayload(kind: .xmp, keyword: "XML:com.adobe.xmp", data: Data(packet.utf8), text: packet)
        ])
        let interpretation = try #require(result.interpretations.first)

        #expect(result.interpretations.count == 1)
        #expect(interpretation.format == .mochiDiffusion)
        #expect(interpretation.producer == Self.producer)
        #expect(interpretation.generations.first?.seed == "4294967296")
        #expect(
            interpretation.generations.first?.parameters == [
                GenerationParameter(key: "Engine", value: "coreml"),
                GenerationParameter(key: "Model Key", value: "example"),
                GenerationParameter(key: "Compute Unit", value: "CPU & GPU"),
                GenerationParameter(key: "Starting Image", value: "start.png"),
                GenerationParameter(key: "ControlNet Image", value: "edges.png"),
                GenerationParameter(key: "Architecture", value: "SDXL"),
            ])
    }

    @Test("ImageIO reads the packet Musubi writes")
    func imageIOReadsPacket() throws {
        let snapshot = MochiGenerationSnapshot(
            producer: Self.producer, generation: Self.diffusion, details: Self.details)
        let packet = try MochiNativeCodec.encodeXMPPacket(snapshot)

        let metadata = try #require(imageIOMetadata(fromXMPPacket: Data(packet.utf8)))
        let value = CGImageMetadataCopyStringValueWithPath(metadata, nil, "mochi:Generation" as CFString)

        #expect(value as String? == (try MochiNativeCodec.encodeJSON(snapshot)))
    }

    @Test("Musubi reads the packet ImageIO writes")
    func musubiReadsImageIOPacket() throws {
        let snapshot = MochiGenerationSnapshot(
            producer: Self.producer, generation: Self.diffusion, details: Self.details)
        let metadata = CGImageMetadataCreateMutable()
        try #require(
            CGImageMetadataRegisterNamespaceForPrefix(
                metadata, MochiNativeCodec.namespace as CFString, "mochi" as CFString, nil))
        try #require(
            CGImageMetadataSetValueWithPath(
                metadata, nil, "mochi:Generation" as CFString, try MochiNativeCodec.encodeJSON(snapshot) as CFString))
        let packet = try #require(CGImageMetadataCreateXMPData(metadata, nil)) as Data

        #expect(try MochiNativeCodec.decodeXMPPacket(String(decoding: packet, as: UTF8.self)) == snapshot)
    }
}

/// Parses `packet` with `CGImageMetadataCreateFromXMPData`.
///
/// On macOS 15 that function returns nil for data wrapped in `<?xpacket?>`
/// processing instructions, although ImageIO's image readers accept the same
/// wrapped packet inside a file. Only the `x:xmpmeta` element is passed, which
/// every supported macOS parses.
func imageIOMetadata(fromXMPPacket packet: Data) -> CGImageMetadata? {
    let text = String(decoding: packet, as: UTF8.self)
    guard let start = text.range(of: "<x:xmpmeta"), let end = text.range(of: "</x:xmpmeta>") else {
        return CGImageMetadataCreateFromXMPData(packet as CFData)
    }
    return CGImageMetadataCreateFromXMPData(Data(text[start.lowerBound..<end.upperBound].utf8) as CFData)
}
