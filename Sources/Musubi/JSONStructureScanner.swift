import Foundation

/// Checks JSON structure that Foundation's decoders do not report.
///
/// The scanner walks the text once, without recursion. It finds nesting deeper
/// than ``InputLimits/nestingDepth`` and keys that repeat within one object.
/// `JSONDecoder` keeps one value when an object repeats a key, so a record with
/// conflicting values would otherwise decode without error. Keys are compared
/// after decoding their escapes, so `"a"` and `"a"` are the same key.
enum JSONStructureScanner {
    /// The first structural problem, or `nil`. Malformed JSON that is not too
    /// deep and repeats no key is left for the decoder to reject.
    static func problem(in data: Data) -> UntrustedInputProblem? {
        let bytes = [UInt8](data)
        var index = 0
        // One entry per open container: the keys seen so far, or nil for an array.
        var containers: [Set<String>?] = []
        var expectingKey = false

        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                let isObject = bytes[index] == UInt8(ascii: "{")
                containers.append(isObject ? [] : nil)
                guard containers.count <= InputLimits.nestingDepth else { return .tooDeep }
                expectingKey = isObject
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                guard !containers.isEmpty else { return nil }
                containers.removeLast()
                expectingKey = false
            case UInt8(ascii: ","):
                expectingKey = containers.last.map { $0 != nil } ?? false
            case UInt8(ascii: "\""):
                guard let end = stringEnd(in: bytes, from: index) else { return nil }
                if expectingKey, let open = containers.last, var keys = open {
                    guard
                        let key = try? JSONSerialization.jsonObject(
                            with: Data(bytes[index...end]), options: .fragmentsAllowed) as? String
                    else { return nil }
                    if !keys.insert(key).inserted { return .duplicateKey(key) }
                    containers[containers.count - 1] = keys
                    expectingKey = false
                }
                index = end
            default:
                break
            }
            index += 1
        }
        return nil
    }

    /// The index of the quote that closes the string starting at `start`.
    private static func stringEnd(in bytes: [UInt8], from start: Int) -> Int? {
        var index = start + 1
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "\\"): index += 2
            case UInt8(ascii: "\""): return index
            default: index += 1
            }
        }
        return nil
    }
}
