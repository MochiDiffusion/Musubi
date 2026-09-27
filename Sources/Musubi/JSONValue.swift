import Foundation

enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case integer(Int64)
    /// An integer above `Int64.max`.
    case unsigned(UInt64)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(UInt64.self) {
            self = .unsigned(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .unsigned(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        switch self {
        case .string(let value): value
        case .integer(let value): String(value)
        case .unsigned(let value): String(value)
        case .number(let value): String(value)
        default: nil
        }
    }

    /// The largest magnitude at which every integer has an exact `Double`.
    private static let exactDoubleIntegerLimit = 9_007_199_254_740_992.0

    /// The decimal text of an integer that was decoded exactly, or `nil`.
    ///
    /// JSON numbers beyond 64-bit integers decode as `Double`, which rounds
    /// large integers. Such a value has no exact text here, so a seed is never
    /// reported as a rounded number.
    var exactIntegerText: String? {
        switch self {
        case .integer(let value): String(value)
        case .unsigned(let value): String(value)
        case .number(let value)
        where value.rounded() == value && abs(value) < Self.exactDoubleIntegerLimit:
            String(Int64(value))
        case .string(let value) where value.isDecimalInteger: value
        default: nil
        }
    }

    /// A number that may have been rounded while decoding.
    var isInexactInteger: Bool {
        guard case .number(let value) = self else { return false }
        return value.isFinite && value.rounded() == value && abs(value) >= Self.exactDoubleIntegerLimit
    }

    var intValue: Int? {
        switch self {
        case .integer(let value): Int(exactly: value)
        case .unsigned(let value): Int(exactly: value)
        case .number(let value) where value.rounded() == value: Int(exactly: value)
        case .string(let value): Int(value)
        default: nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .integer(let value): Double(value)
        case .unsigned(let value): Double(value)
        case .number(let value): value
        case .string(let value): Double(value).flatMap { $0.isFinite ? $0 : nil }
        default: nil
        }
    }
}

extension String {
    /// Decimal digits with an optional leading minus sign.
    var isDecimalInteger: Bool {
        let digits = hasPrefix("-") ? dropFirst() : Substring(self)
        return !digits.isEmpty && digits.allSatisfy { ("0"..."9").contains($0) }
    }
}

/// The seed text of a JSON value, reporting a number that cannot be read
/// exactly. The raw payload keeps the original digits.
func exactSeed(_ value: JSONValue?, diagnostics: inout [MetadataDiagnostic]) -> String? {
    guard let value else { return nil }
    if let text = value.exactIntegerText { return text }
    if value.isInexactInteger {
        diagnostics.append(
            MetadataDiagnostic(
                severity: .warning,
                message: "A seed is too large to decode exactly and was left out; the raw payload keeps it"))
    }
    return nil
}
