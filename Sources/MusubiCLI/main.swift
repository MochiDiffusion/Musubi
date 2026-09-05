import Darwin
import Foundation
import Musubi

@main
struct MusubiCommand {
    static func main() {
        let arguments = CommandLine.arguments.dropFirst()
        if arguments.count == 1, let argument = arguments.first, ["--help", "-h"].contains(argument) {
            print(
                "Inspect image-generation metadata without decoding image pixels."
                    + "\n\nUsage: musubi-inspect <image-or-directory> […]"
            )
            return
        }
        guard !arguments.isEmpty else {
            writeError("Usage: musubi-inspect <image-or-directory> […]\n")
            exit(64)
        }

        let urls = arguments.flatMap { inspectableURLs(at: URL(fileURLWithPath: $0)) }
        var failed = false
        for url in urls {
            do {
                let inspection = try MetadataInspector.inspect(contentsOf: url)
                printInspection(inspection, for: url)
            } catch {
                failed = true
                writeError("\(url.path): \(error)\n")
            }
        }
        if failed { exit(1) }
    }

    private static func inspectableURLs(at url: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return [url]
        }
        guard isDirectory.boolValue else { return [url] }

        let keys: [URLResourceKey] = [.isRegularFileKey]
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )) ?? []
        return
            files
            .filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func printInspection(_ inspection: MetadataInspection, for url: URL) {
        print("\n\(url.lastPathComponent)")
        print(
            "  Image: \(inspection.container.rawValue.uppercased()) \(inspection.imageDimensions.width)×\(inspection.imageDimensions.height)"
        )
        print("  Payloads: \(inspection.payloads.map(payloadLabel).joined(separator: ", ").nonEmpty ?? "none")")

        if inspection.interpretations.isEmpty {
            print("  Generation metadata: none recognized")
        }
        for interpretation in inspection.interpretations {
            let version = interpretation.sourceVersion.map { " \($0)" } ?? ""
            print("  Source: \(sourceLabel(interpretation.source))\(version)")
            if interpretation.generations.isEmpty {
                print("    Raw data preserved; no generation summary extracted")
            }
            for (index, generation) in interpretation.generations.enumerated() {
                if interpretation.generations.count > 1 { print("    Generation \(index + 1):") }
                printField("Prompt", generation.positivePrompt)
                printField("Negative prompt", generation.negativePrompt)
                printField("Model", generation.model)
                printField("Sampler", generation.sampler)
                printField("Scheduler", generation.scheduler)
                printField("Steps", generation.steps.map { String($0) })
                printField("Guidance", generation.guidance.map { String($0) })
                printField("Seed", generation.seed)
                printField("Denoise", generation.denoise.map { String($0) })
                if let dimensions = generation.dimensions {
                    printField("Generation size", "\(dimensions.width)×\(dimensions.height)")
                }
                if !generation.resources.isEmpty {
                    print("    Resources:")
                    for resource in generation.resources {
                        let identity =
                            resource.name
                            ?? resource.air
                            ?? resource.civitaiModelVersionID.map { String($0) }
                            ?? "unknown"
                        let weight = resource.weight.map { " @ \($0)" } ?? ""
                        print("      \(resource.kind.rawValue): \(identity)\(weight)")
                    }
                }
                if !generation.additionalValues.isEmpty {
                    print("    Additional values:")
                    for key in generation.additionalValues.keys.sorted() {
                        printField(key, generation.additionalValues[key], indentation: "      ")
                    }
                }
            }
        }

        for diagnostic in inspection.diagnostics {
            print("  \(diagnostic.severity.rawValue.capitalized): \(diagnostic.message)")
        }
    }

    private static func printField(_ label: String, _ value: String?, indentation: String = "    ") {
        guard let value else { return }
        let singleLine = value.replacingOccurrences(of: "\n", with: " ↩︎ ")
        let clipped = singleLine.count > 180 ? String(singleLine.prefix(180)) + "…" : singleLine
        print("\(indentation)\(label): \(clipped)")
    }

    private static func payloadLabel(_ payload: EmbeddedMetadataPayload) -> String {
        payload.keyword.map { "\(payload.kind.rawValue)[\($0)]" } ?? payload.kind.rawValue
    }

    private static func sourceLabel(_ source: GenerationSource) -> String {
        switch source {
        case .drawThings: "Draw Things"
        case .comfyUI: "ComfyUI"
        case .civitai: "Civitai"
        case .automatic1111: "Automatic1111-compatible"
        case .mochiDiffusion: "Mochi Diffusion"
        }
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }
}

extension String {
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}
