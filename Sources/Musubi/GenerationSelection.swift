import Foundation

/// One generation record within a list of interpretations.
public struct GenerationReference: Codable, Hashable, Sendable {
    /// The index in `interpretations`.
    public let interpretation: Int
    /// The index in that interpretation's `generations`.
    public let generation: Int

    public init(interpretation: Int, generation: Int) {
        self.interpretation = interpretation
        self.generation = generation
    }
}

/// The generation an image most likely records, when one can be chosen
/// without guessing.
///
/// Selection is a convenience. It never merges records and never discards an
/// interpretation: every alternative stays in `interpretations`.
///
/// A format that belongs to one application, such as a ComfyUI graph or Mochi
/// Diffusion's native record, is a primary source. AUTOMATIC1111 text is often
/// a compatibility copy that the same application added. So:
///
/// - One primary generation is selected, even when AUTOMATIC1111 text is also
///   present. A native record that could not be read produces no
///   interpretation, so its compatibility text is then selected instead.
/// - Several primary generations are ambiguous: a graph with more than one
///   sampler, or records from two applications.
/// - Without a primary source, one AUTOMATIC1111 generation is selected and
///   several are ambiguous.
public enum GenerationSelection: Equatable, Sendable {
    /// The metadata records no generation.
    case none
    case selected(GenerationReference)
    /// Several generations could describe the image. They are listed in order.
    case ambiguous([GenerationReference])

    public init(_ interpretations: [MetadataInterpretation]) {
        var primary: [GenerationReference] = []
        var compatibility: [GenerationReference] = []
        for (index, interpretation) in interpretations.enumerated() {
            let references = interpretation.generations.indices.map {
                GenerationReference(interpretation: index, generation: $0)
            }
            if interpretation.format == .automatic1111 {
                compatibility += references
            } else {
                primary += references
            }
        }

        let candidates = primary.isEmpty ? compatibility : primary
        switch candidates.count {
        case 0: self = .none
        case 1: self = .selected(candidates[0])
        default: self = .ambiguous(candidates)
        }
    }
}

extension MetadataInspection {
    /// The generation this image most likely records. See ``GenerationSelection``.
    public var selection: GenerationSelection { GenerationSelection(interpretations) }
}

extension PayloadInterpretation {
    /// The generation these payloads most likely record. See ``GenerationSelection``.
    public var selection: GenerationSelection { GenerationSelection(interpretations) }
}
