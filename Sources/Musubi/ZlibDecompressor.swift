import Compression
import Foundation

enum ZlibDecompressor {
    static let defaultLimit = 16 * 1_024 * 1_024

    static func decompress(_ data: Data, limit: Int = defaultLimit) throws -> Data {
        guard !data.isEmpty else { return Data() }
        var capacity = min(max(data.count * 4, 64 * 1_024), limit)

        while capacity <= limit {
            var output = [UInt8](repeating: 0, count: capacity)
            let decodedSize = data.withUnsafeBytes { sourceBuffer in
                output.withUnsafeMutableBytes { outputBuffer in
                    compression_decode_buffer(
                        outputBuffer.bindMemory(to: UInt8.self).baseAddress!,
                        capacity,
                        sourceBuffer.bindMemory(to: UInt8.self).baseAddress!,
                        data.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }
            guard decodedSize > 0 else {
                throw MetadataInspectionError.malformedContainer("Invalid zlib metadata stream")
            }
            if decodedSize < capacity { return Data(output.prefix(decodedSize)) }
            guard capacity < limit else {
                throw MetadataInspectionError.metadataLimitExceeded(
                    "Decompressed metadata reaches the \(limit)-byte limit"
                )
            }
            capacity = min(capacity * 2, limit)
        }

        throw MetadataInspectionError.metadataLimitExceeded(
            "Decompressed metadata exceeds \(limit) bytes"
        )
    }
}
