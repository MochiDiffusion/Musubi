import Foundation

/// A JSON value in a fixture's expectation file.
enum JSONValue: Sendable, Encodable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
    case string(String)
    case number(Double)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
    init(nilLiteral: ()) { self = .null }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

/// What the pinned external readers in `Tools/MetadataWireProbe` must parse
/// from one fixture.
///
/// `a1111` maps a key of AUTOMATIC1111's parsed parameters to its expected
/// string. `civitai` maps a dot-separated path into the Civitai reader's result,
/// such as `raw.steps` or `civitai.generation.resources.0.name`, to its expected
/// JSON value. `null` means the key is absent.
struct ReaderExpectations: Sendable {
    let a1111: [String: JSONValue]
    let civitai: [String: JSONValue]
}

/// The contents of a fixture's `.expected.json` file.
struct FixtureExpectation: Encodable {
    let parameters: String?
    let native: String?
    let a1111: [String: JSONValue]
    let civitai: [String: JSONValue]

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
