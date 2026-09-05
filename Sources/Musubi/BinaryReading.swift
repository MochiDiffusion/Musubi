import Foundation

struct BinaryReader {
    let data: Data

    init(data: Data) {
        // Data slices retain their source indices. Rebase them so byte offsets in
        // container formats always start at zero.
        self.data = Data(data)
    }

    func byte(at offset: Int) -> UInt8? {
        guard data.indices.contains(offset) else { return nil }
        return data[offset]
    }

    func bytes(in range: Range<Int>) -> Data? {
        guard range.lowerBound >= 0, range.upperBound <= data.count else { return nil }
        return data.subdata(in: range)
    }

    func uint16(at offset: Int, endian: Endian) -> UInt16? {
        guard let first = byte(at: offset), let second = byte(at: offset + 1) else { return nil }
        switch endian {
        case .big: return UInt16(first) << 8 | UInt16(second)
        case .little: return UInt16(second) << 8 | UInt16(first)
        }
    }

    func uint32(at offset: Int, endian: Endian) -> UInt32? {
        guard
            let first = byte(at: offset),
            let second = byte(at: offset + 1),
            let third = byte(at: offset + 2),
            let fourth = byte(at: offset + 3)
        else { return nil }

        switch endian {
        case .big:
            return UInt32(first) << 24 | UInt32(second) << 16 | UInt32(third) << 8 | UInt32(fourth)
        case .little:
            return UInt32(fourth) << 24 | UInt32(third) << 16 | UInt32(second) << 8 | UInt32(first)
        }
    }
}

enum Endian {
    case big
    case little
}

extension Data {
    func hasPrefix(_ bytes: [UInt8]) -> Bool {
        count >= bytes.count && zip(prefix(bytes.count), bytes).allSatisfy(==)
    }

    func firstIndex(of byte: UInt8, in range: Range<Int>) -> Int? {
        guard range.lowerBound >= 0, range.upperBound <= count else { return nil }
        return range.first { self[$0] == byte }
    }
}
