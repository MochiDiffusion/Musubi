import Foundation

enum CRC32 {
    static func checksum(type: Data, payload: Data) -> UInt32 {
        var value = UInt32.max
        for byte in type + payload {
            value ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = 0 &- (value & 1)
                value = (value >> 1) ^ (0xEDB8_8320 & mask)
            }
        }
        return value ^ UInt32.max
    }
}
