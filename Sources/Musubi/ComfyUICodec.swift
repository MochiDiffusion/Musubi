import Foundation

enum ComfyUICodec {
    static func decode(_ payloads: [EmbeddedMetadataPayload]) -> CodecOutput {
        var output = CodecOutput()

        for (index, payload) in payloads.enumerated() where payload.keyword == "prompt" {
            guard let text = payload.text else { continue }
            do {
                let json = try UntrustedJSON.decode(text)
                guard let object = json.objectValue else { continue }
                guard object.count <= InputLimits.graphNodes else {
                    output.diagnostics.append(
                        .init(
                            severity: .warning,
                            message: "ComfyUI graph has more than \(InputLimits.graphNodes) nodes and was not read"))
                    continue
                }
                guard let nodes = nodes(from: object), !nodes.isEmpty else { continue }

                let generations = generationSummaries(from: nodes, diagnostics: &output.diagnostics)
                output.interpretations.append(
                    .init(
                        format: .comfyUI, payloadIndices: comfyPayloadIndices(primary: index, payloads: payloads),
                        generations: generations)
                )
                if generations.isEmpty {
                    output.diagnostics.append(
                        .init(
                            severity: .warning,
                            message: "ComfyUI graph was preserved but no supported sampler could be normalized")
                    )
                }
            } catch {
                output.diagnostics.append(
                    .init(severity: .warning, message: "ComfyUI prompt JSON was not read: \(error)")
                )
            }
        }
        return output
    }

    private struct Node {
        let id: String
        let classType: String
        let inputs: [String: JSONValue]
    }

    private static func nodes(from object: [String: JSONValue]) -> [String: Node]? {
        var result: [String: Node] = [:]
        for (id, value) in object {
            guard let node = value.objectValue,
                let classType = node["class_type"]?.stringValue,
                let inputs = node["inputs"]?.objectValue
            else { continue }
            result[id] = Node(id: id, classType: classType, inputs: inputs)
        }
        return result.isEmpty ? nil : result
    }

    private static func generationSummaries(
        from nodes: [String: Node],
        diagnostics: inout [MetadataDiagnostic]
    ) -> [GenerationRecord] {
        let outputNodes = nodes.values.filter { isOutputNode($0.classType) }
        let reachable =
            outputNodes.isEmpty
            ? Set(nodes.keys)
            : Set(outputNodes.flatMap { upstreamNodeIDs(from: $0.id, nodes: nodes) })
        let samplers = nodes.values
            .filter { reachable.contains($0.id) && isGenerationSampler($0.classType) }
            .sorted { numericAwareLessThan($0.id, $1.id) }

        return samplers.map { sampler in
            sampler.classType.lowercased() == "samplercustomadvanced"
                ? advancedSamplerSummary(sampler, nodes: nodes, diagnostics: &diagnostics)
                : directSamplerSummary(sampler, nodes: nodes, diagnostics: &diagnostics)
        }
    }

    private static func directSamplerSummary(
        _ sampler: Node,
        nodes: [String: Node],
        diagnostics: inout [MetadataDiagnostic]
    ) -> GenerationRecord {
        let ancestors = Set(upstreamNodeIDs(from: sampler.id, nodes: nodes))
        let positive = sampler.inputs["positive"]
            .flatMap(referencedNodeID)
            .flatMap { promptText(from: $0, nodes: nodes) }
        let negative = sampler.inputs["negative"]
            .flatMap(referencedNodeID)
            .flatMap { promptText(from: $0, nodes: nodes) }

        return GenerationRecord(
            positivePrompt: positive,
            negativePrompt: negative,
            model: modelName(
                in: upstreamIDs(for: "model", of: sampler, nodes: nodes), sampler: sampler, nodes: nodes,
                diagnostics: &diagnostics),
            sampler: sampler.inputs["sampler_name"]?.stringValue,
            scheduler: sampler.inputs["scheduler"]?.stringValue,
            steps: sampler.inputs["steps"]?.intValue,
            cfgScale: sampler.inputs["cfg"]?.doubleValue,
            seed: exactSeed(sampler.inputs["seed"], diagnostics: &diagnostics),
            dimensions: latentSize(of: sampler, nodes: nodes),
            denoise: sampler.inputs["denoise"]?.doubleValue,
            resources: graphResources(in: ancestors, nodes: nodes)
        )
    }

    private static func advancedSamplerSummary(
        _ sampler: Node,
        nodes: [String: Node],
        diagnostics: inout [MetadataDiagnostic]
    ) -> GenerationRecord {
        let ancestors = Set(upstreamNodeIDs(from: sampler.id, nodes: nodes))
        let guiderIDs = upstreamIDs(for: "guider", of: sampler, nodes: nodes)
        let samplerIDs = upstreamIDs(for: "sampler", of: sampler, nodes: nodes)
        let schedulerIDs = upstreamIDs(for: "sigmas", of: sampler, nodes: nodes)
        let noiseIDs = upstreamIDs(for: "noise", of: sampler, nodes: nodes)
        let guider = sampler.inputs["guider"].flatMap(referencedNodeID).flatMap { nodes[$0] }
        let positive = guider?.inputs["positive"]
            .flatMap(referencedNodeID)
            .flatMap { promptText(from: $0, nodes: nodes) }
        let negative = guider?.inputs["negative"]
            .flatMap(referencedNodeID)
            .flatMap { promptText(from: $0, nodes: nodes) }

        return GenerationRecord(
            positivePrompt: positive,
            negativePrompt: negative,
            model: modelName(
                in: guider.map { upstreamIDs(for: "model", of: $0, nodes: nodes) } ?? [], sampler: sampler,
                nodes: nodes, diagnostics: &diagnostics),
            sampler: scalarValue(
                named: "sampler_name", in: samplerIDs, sampler: sampler, nodes: nodes, diagnostics: &diagnostics),
            scheduler: scalarValue(
                named: "scheduler", in: schedulerIDs, sampler: sampler, nodes: nodes, diagnostics: &diagnostics),
            steps: scalarValue(
                named: "steps", in: schedulerIDs, sampler: sampler, nodes: nodes, diagnostics: &diagnostics
            ).flatMap(Int.init),
            cfgScale: guider?.inputs["cfg"]?.doubleValue
                ?? scalarValue(
                    named: "cfg", in: guiderIDs, sampler: sampler, nodes: nodes, diagnostics: &diagnostics
                ).flatMap(Double.init),
            seed: exactSeed(
                scalarJSON(
                    named: "noise_seed", in: noiseIDs, sampler: sampler, nodes: nodes, diagnostics: &diagnostics),
                diagnostics: &diagnostics),
            dimensions: latentSize(of: sampler, nodes: nodes),
            denoise: scalarValue(
                named: "denoise", in: schedulerIDs, sampler: sampler, nodes: nodes, diagnostics: &diagnostics
            ).flatMap(Double.init),
            resources: graphResources(in: ancestors, nodes: nodes)
        )
    }

    private static func comfyPayloadIndices(
        primary: Int,
        payloads: [EmbeddedMetadataPayload]
    ) -> [Int] {
        [primary] + payloads.indices.filter { $0 != primary && payloads[$0].keyword == "workflow" }
    }

    private static func upstreamNodeIDs(from startingID: String, nodes: [String: Node]) -> [String] {
        var pending = [startingID]
        var visited = Set<String>()
        while let id = pending.popLast() {
            guard visited.insert(id).inserted, let node = nodes[id] else { continue }
            pending.append(contentsOf: node.inputs.values.compactMap(referencedNodeID))
        }
        return Array(visited)
    }

    private static func referencedNodeID(_ value: JSONValue) -> String? {
        guard let connection = value.arrayValue, connection.count >= 2 else { return nil }
        return connection[0].stringValue
    }

    private static func promptText(from startingID: String, nodes: [String: Node]) -> String? {
        var visited = Set<String>()
        return resolvedText(from: startingID, nodes: nodes, visited: &visited)?.trimmedNonEmpty
    }

    private static func resolvedText(
        from nodeID: String,
        nodes: [String: Node],
        visited: inout Set<String>
    ) -> String? {
        // Each recursion visits a new node, so capping the visited count also
        // caps the recursion depth.
        guard visited.count < InputLimits.nestingDepth, visited.insert(nodeID).inserted, let node = nodes[nodeID]
        else { return nil }
        let classType = node.classType.lowercased()
        if classType.contains("conditioningzeroout") { return nil }

        if let text = node.inputs["text"] {
            return resolvedText(from: text, nodes: nodes, visited: &visited)
        }

        if classType.contains("concatenat") || classType.contains("stringfunction") {
            let first = node.inputs["string_a"] ?? node.inputs["text_a"]
            let second = node.inputs["string_b"] ?? node.inputs["text_b"]
            let delimiter = node.inputs["delimiter"]
            return [
                first.flatMap { resolvedText(from: $0, nodes: nodes, visited: &visited) },
                delimiter.flatMap { resolvedText(from: $0, nodes: nodes, visited: &visited) },
                second.flatMap { resolvedText(from: $0, nodes: nodes, visited: &visited) },
            ]
            .compactMap { $0 }
            .joined()
        }

        return nil
    }

    private static func resolvedText(
        from value: JSONValue,
        nodes: [String: Node],
        visited: inout Set<String>
    ) -> String? {
        if let nodeID = referencedNodeID(value) {
            return resolvedText(from: nodeID, nodes: nodes, visited: &visited)
        }
        return value.stringValue
    }

    /// The model loaded upstream of a sampler's model link.
    private static func modelName(
        in nodeIDs: Set<String>,
        sampler: Node,
        nodes: [String: Node],
        diagnostics: inout [MetadataDiagnostic]
    ) -> String? {
        single("model", in: nodeIDs, sampler: sampler, nodes: nodes, diagnostics: &diagnostics) { node in
            ["ckpt_name", "unet_name", "model_name"].lazy.compactMap { node.inputs[$0]?.stringValue?.nonEmpty }.first
        }
    }

    /// Nodes whose output latent has the size of their input latent.
    private static let sizePreservingLatentNodes: Set<String> = [
        "ksampler", "ksampleradvanced", "samplercustom", "samplercustomadvanced",
    ]

    /// The size of the latent a sampler starts from.
    ///
    /// The walk follows the latent link to the nearest node that sets a width
    /// and height, passing only through samplers, which keep the size. Any
    /// other node, such as a scale-by upscale or an encoded image, stops the
    /// walk, because the size it produces is not stated in the graph.
    private static func latentSize(of sampler: Node, nodes: [String: Node]) -> PixelDimensions? {
        var current = sampler.inputs["latent_image"].flatMap(referencedNodeID).flatMap { nodes[$0] }
        var steps = 0
        while let node = current, steps < InputLimits.nestingDepth {
            if let width = node.inputs["width"]?.intValue, let height = node.inputs["height"]?.intValue {
                return width > 0 && height > 0 ? PixelDimensions(width: width, height: height) : nil
            }
            guard sizePreservingLatentNodes.contains(node.classType.lowercased()) else { return nil }
            current = node.inputs["latent_image"].flatMap(referencedNodeID).flatMap { nodes[$0] }
            steps += 1
        }
        return nil
    }

    private static func graphResources(in nodeIDs: Set<String>, nodes: [String: Node]) -> [GenerationResource] {
        nodeIDs.sorted(by: numericAwareLessThan).compactMap { id in
            guard let node = nodes[id], node.classType.localizedCaseInsensitiveContains("lora") else { return nil }
            let name =
                node.inputs["lora_name"]?.stringValue
                ?? node.inputs["lora"]?.stringValue
                ?? node.inputs["file"]?.stringValue
            guard name != nil else { return nil }
            return GenerationResource(
                kind: .lora,
                name: name,
                weight: node.inputs["strength_model"]?.doubleValue
                    ?? node.inputs["strength"]?.doubleValue
                    ?? node.inputs["weight"]?.doubleValue
            )
        }
    }

    private static func scalarValue(
        named key: String,
        in nodeIDs: Set<String>,
        sampler: Node,
        nodes: [String: Node],
        diagnostics: inout [MetadataDiagnostic]
    ) -> String? {
        scalarJSON(named: key, in: nodeIDs, sampler: sampler, nodes: nodes, diagnostics: &diagnostics)?.stringValue
    }

    /// The scalar input named `key` among `nodeIDs`. Links are not scalars.
    private static func scalarJSON(
        named key: String,
        in nodeIDs: Set<String>,
        sampler: Node,
        nodes: [String: Node],
        diagnostics: inout [MetadataDiagnostic]
    ) -> JSONValue? {
        single(key, in: nodeIDs, sampler: sampler, nodes: nodes, diagnostics: &diagnostics) { node in
            node.inputs[key].flatMap { $0.stringValue != nil ? $0 : nil }
        }
    }

    /// The one distinct value that `value` finds among `nodeIDs`.
    ///
    /// Node IDs carry no meaning, so when several nodes give different values
    /// none is chosen: the field stays unset and a diagnostic names it.
    private static func single<Value: Equatable>(
        _ field: String,
        in nodeIDs: Set<String>,
        sampler: Node,
        nodes: [String: Node],
        diagnostics: inout [MetadataDiagnostic],
        value: (Node) -> Value?
    ) -> Value? {
        var found: [Value] = []
        for id in nodeIDs.sorted(by: numericAwareLessThan) {
            guard let node = nodes[id], let candidate = value(node), !found.contains(candidate) else { continue }
            found.append(candidate)
        }
        guard found.count <= 1 else {
            diagnostics.append(
                .init(
                    severity: .warning,
                    message: "ComfyUI sampler \(sampler.id) has several \(field) values upstream; none was chosen"))
            return nil
        }
        return found.first
    }

    private static func upstreamIDs(
        for input: String,
        of node: Node,
        nodes: [String: Node]
    ) -> Set<String> {
        guard let id = node.inputs[input].flatMap(referencedNodeID) else { return [] }
        return Set(upstreamNodeIDs(from: id, nodes: nodes))
    }

    private static func isOutputNode(_ classType: String) -> Bool {
        let lowered = classType.lowercased()
        return lowered.contains("saveimage") || lowered.contains("image saver") || lowered == "previewimage"
    }

    private static func isGenerationSampler(_ classType: String) -> Bool {
        let lowered = classType.lowercased()
        return lowered == "ksampler"
            || lowered == "ksampleradvanced"
            || lowered == "samplercustom"
            || lowered == "samplercustomadvanced"
            || lowered.contains("ultimatesdupscale")
    }

    private static func numericAwareLessThan(_ left: String, _ right: String) -> Bool {
        if let leftNumber = Int(left), let rightNumber = Int(right) { return leftNumber < rightNumber }
        return left < right
    }
}

extension String {
    fileprivate var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
