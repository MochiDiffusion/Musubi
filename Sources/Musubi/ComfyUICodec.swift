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
            model: modelName(in: ancestors, nodes: nodes),
            sampler: sampler.inputs["sampler_name"]?.stringValue,
            scheduler: sampler.inputs["scheduler"]?.stringValue,
            steps: sampler.inputs["steps"]?.intValue,
            cfgScale: sampler.inputs["cfg"]?.doubleValue,
            seed: exactSeed(sampler.inputs["seed"], diagnostics: &diagnostics),
            dimensions: graphDimensions(in: ancestors, nodes: nodes),
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
        let latentIDs = upstreamIDs(for: "latent_image", of: sampler, nodes: nodes)
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
            model: modelName(in: ancestors, nodes: nodes),
            sampler: scalarValue(named: "sampler_name", in: samplerIDs, nodes: nodes),
            scheduler: scalarValue(named: "scheduler", in: schedulerIDs, nodes: nodes),
            steps: scalarValue(named: "steps", in: schedulerIDs, nodes: nodes).flatMap(Int.init),
            cfgScale: guider?.inputs["cfg"]?.doubleValue
                ?? scalarValue(named: "cfg", in: guiderIDs, nodes: nodes).flatMap(Double.init),
            seed: exactSeed(scalarJSON(named: "noise_seed", in: noiseIDs, nodes: nodes), diagnostics: &diagnostics),
            dimensions: graphDimensions(in: latentIDs, nodes: nodes),
            denoise: scalarValue(named: "denoise", in: schedulerIDs, nodes: nodes).flatMap(Double.init),
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

    private static func modelName(in nodeIDs: Set<String>, nodes: [String: Node]) -> String? {
        for id in nodeIDs.sorted(by: numericAwareLessThan) {
            guard let inputs = nodes[id]?.inputs else { continue }
            for key in ["ckpt_name", "unet_name", "model_name"] {
                if let value = inputs[key]?.stringValue?.nonEmpty { return value }
            }
        }
        return nil
    }

    private static func graphDimensions(in nodeIDs: Set<String>, nodes: [String: Node]) -> PixelDimensions? {
        for id in nodeIDs.sorted(by: numericAwareLessThan) {
            guard let inputs = nodes[id]?.inputs,
                let width = inputs["width"]?.intValue,
                let height = inputs["height"]?.intValue
            else { continue }
            return PixelDimensions(width: width, height: height)
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
        nodes: [String: Node]
    ) -> String? {
        scalarJSON(named: key, in: nodeIDs, nodes: nodes)?.stringValue
    }

    /// The first scalar input named `key`, in node order. Links are not scalars.
    private static func scalarJSON(
        named key: String,
        in nodeIDs: Set<String>,
        nodes: [String: Node]
    ) -> JSONValue? {
        for id in nodeIDs.sorted(by: numericAwareLessThan) {
            if let value = nodes[id]?.inputs[key], value.stringValue != nil { return value }
        }
        return nil
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
