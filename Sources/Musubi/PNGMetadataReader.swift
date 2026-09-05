import Foundation

enum PNGMetadataReader {
    private static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    private static let metadataByteLimit = 16 * 1_024 * 1_024

    static func read(_ data: Data) throws -> ContainerReadResult {
        guard data.hasPrefix(signature) else {
            throw MetadataInspectionError.malformedContainer("Invalid PNG signature")
        }

        let reader = BinaryReader(data: data)
        var offset = signature.count
        var dimensions: PixelDimensions?
        var payloads: [EmbeddedMetadataPayload] = []
        var diagnostics: [MetadataDiagnostic] = []
        var inspectedMetadataBytes = 0

        while offset <= data.count - 12 {
            guard let lengthValue = reader.uint32(at: offset, endian: .big) else {
                throw MetadataInspectionError.malformedContainer("Missing PNG chunk length")
            }
            let length = Int(lengthValue)
            let (chunkEnd, overflow) = offset.addingReportingOverflow(12 + length)
            guard !overflow, chunkEnd <= data.count,
                let typeData = reader.bytes(in: offset + 4..<offset + 8),
                let chunkData = reader.bytes(in: offset + 8..<offset + 8 + length),
                let expectedCRC = reader.uint32(at: offset + 8 + length, endian: .big)
            else {
                throw MetadataInspectionError.malformedContainer("Truncated PNG chunk")
            }

            let type = String(data: typeData, encoding: .ascii) ?? "????"
            if CRC32.checksum(type: typeData, payload: chunkData) != expectedCRC {
                diagnostics.append(.init(severity: .warning, message: "PNG \(type) chunk has an invalid CRC"))
            }

            switch type {
            case "IHDR":
                guard length == 13,
                    let width = BinaryReader(data: chunkData).uint32(at: 0, endian: .big),
                    let height = BinaryReader(data: chunkData).uint32(at: 4, endian: .big),
                    let widthInt = Int(exactly: width),
                    let heightInt = Int(exactly: height),
                    widthInt > 0,
                    heightInt > 0
                else {
                    throw MetadataInspectionError.malformedContainer("Invalid PNG dimensions")
                }
                dimensions = PixelDimensions(width: widthInt, height: heightInt)
            case "tEXt", "zTXt", "iTXt":
                inspectedMetadataBytes += length
                guard inspectedMetadataBytes <= metadataByteLimit else {
                    throw MetadataInspectionError.metadataLimitExceeded(
                        "PNG metadata exceeds \(metadataByteLimit) bytes")
                }
                do {
                    payloads.append(try decodeTextChunk(type: type, data: chunkData))
                } catch let error as MetadataInspectionError {
                    diagnostics.append(.init(severity: .warning, message: String(describing: error)))
                }
            case "eXIf":
                inspectedMetadataBytes += length
                guard inspectedMetadataBytes <= metadataByteLimit else {
                    throw MetadataInspectionError.metadataLimitExceeded(
                        "PNG metadata exceeds \(metadataByteLimit) bytes")
                }
                payloads.append(.init(kind: .pngExif, data: chunkData))
                payloads.append(contentsOf: exifTextPayloads(in: chunkData))
            case "IEND":
                guard let dimensions else {
                    throw MetadataInspectionError.malformedContainer("PNG has no IHDR chunk")
                }
                return ContainerReadResult(
                    format: .png,
                    dimensions: dimensions,
                    payloads: payloads,
                    diagnostics: diagnostics
                )
            default:
                break
            }
            offset = chunkEnd
        }

        throw MetadataInspectionError.malformedContainer("PNG has no IEND chunk")
    }

    private static func decodeTextChunk(type: String, data: Data) throws -> EmbeddedMetadataPayload {
        guard let separator = data.firstIndex(of: 0, in: 0..<data.count), separator > 0 else {
            throw MetadataInspectionError.malformedContainer("PNG \(type) chunk has no keyword separator")
        }
        let keywordData = data.subdata(in: 0..<separator)
        guard let keyword = String(data: keywordData, encoding: .isoLatin1) else {
            throw MetadataInspectionError.malformedContainer("PNG \(type) chunk has an invalid keyword")
        }

        let textData: Data
        let encoding: String.Encoding
        switch type {
        case "tEXt":
            textData = data.subdata(in: separator + 1..<data.count)
            encoding = .isoLatin1
        case "zTXt":
            guard separator + 2 <= data.count, data[separator + 1] == 0 else {
                throw MetadataInspectionError.malformedContainer("PNG zTXt chunk has an unsupported compression method")
            }
            textData = try ZlibDecompressor.decompress(data.subdata(in: separator + 2..<data.count))
            encoding = .isoLatin1
        case "iTXt":
            textData = try decodeInternationalText(data, afterKeyword: separator)
            encoding = .utf8
        default:
            throw MetadataInspectionError.malformedContainer("Unsupported PNG text chunk")
        }

        guard let text = String(data: textData, encoding: encoding) else {
            throw MetadataInspectionError.malformedContainer("PNG \(type) chunk has invalid text encoding")
        }
        let kind: EmbeddedMetadataKind = keyword == "XML:com.adobe.xmp" ? .xmp : .pngText
        return EmbeddedMetadataPayload(kind: kind, keyword: keyword, data: data, text: text)
    }

    private static func decodeInternationalText(_ data: Data, afterKeyword separator: Int) throws -> Data {
        guard separator + 3 <= data.count else {
            throw MetadataInspectionError.malformedContainer("Truncated PNG iTXt header")
        }
        let compressionFlag = data[separator + 1]
        let compressionMethod = data[separator + 2]
        guard compressionFlag <= 1, compressionMethod == 0 else {
            throw MetadataInspectionError.malformedContainer("PNG iTXt chunk has unsupported compression")
        }

        let languageStart = separator + 3
        guard let languageEnd = data.firstIndex(of: 0, in: languageStart..<data.count) else {
            throw MetadataInspectionError.malformedContainer("PNG iTXt chunk has no language separator")
        }
        let translatedKeywordStart = languageEnd + 1
        guard let translatedKeywordEnd = data.firstIndex(of: 0, in: translatedKeywordStart..<data.count) else {
            throw MetadataInspectionError.malformedContainer("PNG iTXt chunk has no translated-keyword separator")
        }
        let encodedText = data.subdata(in: translatedKeywordEnd + 1..<data.count)
        return compressionFlag == 1 ? try ZlibDecompressor.decompress(encodedText) : encodedText
    }

    private static func exifTextPayloads(in data: Data) -> [EmbeddedMetadataPayload] {
        TIFFMetadataReader.textValues(in: data).map {
            EmbeddedMetadataPayload(kind: .exifValue, keyword: $0.keyword, data: $0.data, text: $0.text)
        }
    }
}
