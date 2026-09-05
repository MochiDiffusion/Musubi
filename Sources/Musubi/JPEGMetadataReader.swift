import Foundation

enum JPEGMetadataReader {
    private static let metadataByteLimit = 16 * 1_024 * 1_024
    private static let exifPrefix = Data([0x45, 0x78, 0x69, 0x66, 0, 0])
    private static let xmpPrefix = Data("http://ns.adobe.com/xap/1.0/\0".utf8)

    static func read(_ data: Data) throws -> ContainerReadResult {
        guard data.hasPrefix([0xFF, 0xD8]) else {
            throw MetadataInspectionError.malformedContainer("Invalid JPEG signature")
        }

        let reader = BinaryReader(data: data)
        var offset = 2
        var dimensions: PixelDimensions?
        var payloads: [EmbeddedMetadataPayload] = []
        let diagnostics: [MetadataDiagnostic] = []
        var inspectedMetadataBytes = 0

        while offset < data.count {
            guard reader.byte(at: offset) == 0xFF else {
                throw MetadataInspectionError.malformedContainer("Expected a JPEG marker")
            }
            while reader.byte(at: offset) == 0xFF { offset += 1 }
            guard let marker = reader.byte(at: offset) else {
                throw MetadataInspectionError.malformedContainer("Truncated JPEG marker")
            }
            offset += 1

            if marker == 0xD9 || marker == 0xDA { break }
            if marker == 0x01 || (0xD0...0xD7).contains(marker) { continue }

            guard let segmentLength = reader.uint16(at: offset, endian: .big), segmentLength >= 2 else {
                throw MetadataInspectionError.malformedContainer("Invalid JPEG segment length")
            }
            let payloadStart = offset + 2
            let payloadLength = Int(segmentLength) - 2
            let (payloadEnd, overflow) = payloadStart.addingReportingOverflow(payloadLength)
            guard !overflow, let segmentData = reader.bytes(in: payloadStart..<payloadEnd) else {
                throw MetadataInspectionError.malformedContainer("Truncated JPEG segment")
            }

            if isStartOfFrame(marker), segmentData.count >= 5,
                let height = BinaryReader(data: segmentData).uint16(at: 1, endian: .big),
                let width = BinaryReader(data: segmentData).uint16(at: 3, endian: .big)
            {
                dimensions = PixelDimensions(width: Int(width), height: Int(height))
            }

            if marker == 0xE1 {
                inspectedMetadataBytes += segmentData.count
                guard inspectedMetadataBytes <= metadataByteLimit else {
                    throw MetadataInspectionError.metadataLimitExceeded(
                        "JPEG metadata exceeds \(metadataByteLimit) bytes")
                }
                if segmentData.starts(with: exifPrefix) {
                    let tiff = segmentData.dropFirst(exifPrefix.count)
                    payloads.append(.init(kind: .jpegExif, data: segmentData))
                    payloads.append(
                        contentsOf: TIFFMetadataReader.textValues(in: tiff).map {
                            .init(kind: .exifValue, keyword: $0.keyword, data: $0.data, text: $0.text)
                        })
                } else if segmentData.starts(with: xmpPrefix) {
                    let xmp = segmentData.dropFirst(xmpPrefix.count)
                    let text = String(data: xmp, encoding: .utf8)
                    payloads.append(.init(kind: .xmp, keyword: "XML:com.adobe.xmp", data: segmentData, text: text))
                }
            } else if marker == 0xFE {
                inspectedMetadataBytes += segmentData.count
                guard inspectedMetadataBytes <= metadataByteLimit else {
                    throw MetadataInspectionError.metadataLimitExceeded(
                        "JPEG metadata exceeds \(metadataByteLimit) bytes")
                }
                let text =
                    String(data: segmentData, encoding: .utf8)
                    ?? String(data: segmentData, encoding: .isoLatin1)
                payloads.append(.init(kind: .jpegComment, keyword: "Comment", data: segmentData, text: text))
            }

            offset = payloadEnd
        }

        guard let dimensions else {
            throw MetadataInspectionError.malformedContainer("JPEG has no supported start-of-frame segment")
        }
        return ContainerReadResult(
            format: .jpeg,
            dimensions: dimensions,
            payloads: payloads,
            diagnostics: diagnostics
        )
    }

    private static func isStartOfFrame(_ marker: UInt8) -> Bool {
        [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF]
            .contains(marker)
    }
}
