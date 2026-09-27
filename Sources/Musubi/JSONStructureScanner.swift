import Foundation

/// Checks JSON structure that Foundation's decoders do not report.
///
/// `JSONDecoder` keeps one value when an object repeats a key, so a record with
/// conflicting values would decode without error. The scanner walks the text
/// once and compares decoded key strings, so `"a"` and `"a"` count as the
/// same key.
enum JSONStructureScanner {
    /// The first repeated key in any object, or `nil` when no key repeats or
    /// the text is not well-formed enough to scan. Malformed JSON is left for
    /// the decoder to reject.
    static func firstDuplicateKey(in data: Data) -> String? {
        let bytes = [UInt8](data)
        var index = 0
        // One entry per open container: the keys seen so far, or nil for an array.
        var containers: [Set<String>?] = []
        var expectingKey = false

        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "{"):
                containers.append([])
                expectingKey = true
            case UInt8(ascii: "["):
                containers.append(nil)
                expectingKey = false
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                guard !containers.isEmpty else { return nil }
                containers.removeLast()
                expectingKey = false
            case UInt8(ascii: ","):
                expectingKey = containers.last.map { $0 != nil } ?? false
            case UInt8(ascii: "\""):
                guard let end = stringEnd(in: bytes, from: index) else { return nil }
                if expectingKey, containers.last != nil, var keys = containers.last! {
                    guard
                        let key = try? JSONSerialization.jsonObject(
                            with: Data(bytes[index...end]), options: .fragmentsAllowed) as? String
                    else { return nil }
                    if !keys.insert(key).inserted { return key }
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
