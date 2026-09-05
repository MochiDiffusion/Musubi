import Foundation

enum TIFFMetadataReader {
    struct TextValue {
        let keyword: String
        let data: Data
        let text: String
    }

    static func textValues(in data: Data) -> [TextValue] {
        let reader = BinaryReader(data: data)
        guard data.count >= 8 else { return [] }

        let endian: Endian
        if data.hasPrefix([0x49, 0x49]) {
            endian = .little
        } else if data.hasPrefix([0x4D, 0x4D]) {
            endian = .big
        } else {
            return []
        }

        guard reader.uint16(at: 2, endian: endian) == 42,
            let firstIFD = reader.uint32(at: 4, endian: endian)
        else { return [] }

        var values: [TextValue] = []
        var visitedOffsets = Set<Int>()
        readIFD(
            at: Int(firstIFD),
            reader: reader,
            endian: endian,
            visitedOffsets: &visitedOffsets,
            values: &values
        )
        return values
    }

    private static func readIFD(
        at offset: Int,
        reader: BinaryReader,
        endian: Endian,
        visitedOffsets: inout Set<Int>,
        values: inout [TextValue]
    ) {
        guard visitedOffsets.insert(offset).inserted,
            let entryCount = reader.uint16(at: offset, endian: endian),
            entryCount <= 2_048
        else { return }

        let entriesStart = offset + 2
        guard entriesStart <= reader.data.count - Int(entryCount) * 12 else { return }

        for index in 0..<Int(entryCount) {
            let entryOffset = entriesStart + index * 12
            guard let tag = reader.uint16(at: entryOffset, endian: endian),
                let type = reader.uint16(at: entryOffset + 2, endian: endian),
                let count = reader.uint32(at: entryOffset + 4, endian: endian),
                let byteCount = byteCount(type: type, count: count)
            else { continue }

            guard
                let valueData = valueData(
                    entryOffset: entryOffset,
                    byteCount: byteCount,
                    reader: reader,
                    endian: endian
                )
            else { continue }

            if tag == 0x8769,
                let nestedOffset = reader.uint32(at: entryOffset + 8, endian: endian)
            {
                readIFD(
                    at: Int(nestedOffset),
                    reader: reader,
                    endian: endian,
                    visitedOffsets: &visitedOffsets,
                    values: &values
                )
                continue
            }

            guard let keyword = keyword(for: tag),
                let text = decode(tag: tag, type: type, data: valueData, endian: endian)
            else { continue }
            values.append(TextValue(keyword: keyword, data: valueData, text: text))
        }
    }

    private static func byteCount(type: UInt16, count: UInt32) -> Int? {
        let width: UInt32
        switch type {
        case 1, 2, 7: width = 1
        case 3: width = 2
        case 4, 9: width = 4
        case 5, 10: width = 8
        default: return nil
        }
        let (size, overflow) = count.multipliedReportingOverflow(by: width)
        guard !overflow, size <= 16 * 1_024 * 1_024 else { return nil }
        return Int(size)
    }

    private static func valueData(
        entryOffset: Int,
        byteCount: Int,
        reader: BinaryReader,
        endian: Endian
    ) -> Data? {
        if byteCount <= 4 {
            return reader.bytes(in: entryOffset + 8..<entryOffset + 8 + byteCount)
        }
        guard let valueOffset = reader.uint32(at: entryOffset + 8, endian: endian) else { return nil }
        let start = Int(valueOffset)
        let (end, overflow) = start.addingReportingOverflow(byteCount)
        guard !overflow else { return nil }
        return reader.bytes(in: start..<end)
    }

    private static func keyword(for tag: UInt16) -> String? {
        switch tag {
        case 0x010E: "ImageDescription"
        case 0x010F: "Make"
        case 0x0110: "Model"
        case 0x0131: "Software"
        case 0x013B: "Artist"
        case 0x9286: "UserComment"
        default: nil
        }
    }

    private static func decode(tag: UInt16, type: UInt16, data: Data, endian: Endian) -> String? {
        if tag == 0x9286 {
            return decodeUserComment(data, tiffEndian: endian)
        }
        guard type == 2 else { return nil }
        return String(data: data.trimmingTrailingNulls(), encoding: .utf8)
            ?? String(data: data.trimmingTrailingNulls(), encoding: .isoLatin1)
    }

    private static func decodeUserComment(_ data: Data, tiffEndian: Endian) -> String? {
        let body: Data
        let encoding: String.Encoding
        if data.hasPrefix(Array("ASCII\0\0\0".utf8)) {
            body = data.dropFirst(8).trimmingTrailingNulls()
            encoding = .utf8
        } else if data.hasPrefix(Array("UNICODE\0".utf8)) {
            body = data.dropFirst(8).trimmingTrailingNullPairs()
            encoding = unicodeEncoding(for: body, fallback: tiffEndian)
        } else {
            body = data.trimmingTrailingNulls()
            encoding = .utf8
        }
        return String(data: body, encoding: encoding)
            ?? String(data: body, encoding: .isoLatin1)
    }

    private static func unicodeEncoding(for data: Data, fallback: Endian) -> String.Encoding {
        if data.hasPrefix([0xFE, 0xFF]) { return .utf16BigEndian }
        if data.hasPrefix([0xFF, 0xFE]) { return .utf16LittleEndian }

        let sample = data.prefix(128)
        let evenNulls = sample.enumerated().count { $0.offset.isMultiple(of: 2) && $0.element == 0 }
        let oddNulls = sample.enumerated().count { !$0.offset.isMultiple(of: 2) && $0.element == 0 }
        if evenNulls != oddNulls {
            return evenNulls > oddNulls ? .utf16BigEndian : .utf16LittleEndian
        }
        return fallback == .big ? .utf16BigEndian : .utf16LittleEndian
    }
}

extension Data {
    fileprivate func trimmingTrailingNulls() -> Data {
        var end = count
        while end > 0, self[end - 1] == 0 { end -= 1 }
        return prefix(end)
    }

    fileprivate func trimmingTrailingNullPairs() -> Data {
        var end = count
        while end >= 2, self[end - 1] == 0, self[end - 2] == 0 { end -= 2 }
        return prefix(end)
    }
}
