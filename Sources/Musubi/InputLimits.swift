import Foundation

/// Bounds on the work Musubi does for one image.
///
/// Image metadata is untrusted. Every structure that grows with the input has a
/// limit here, and exceeding one produces a diagnostic or an error instead of
/// unbounded memory use or recursion.
enum InputLimits {
    /// Metadata bytes read from one container, before decompression.
    static let containerMetadataBytes = 16 * 1_024 * 1_024
    /// Decompressed bytes for one container, across all compressed payloads.
    static let decompressedBytes = 32 * 1_024 * 1_024
    /// Metadata payloads kept from one container.
    static let payloadCount = 1_024
    /// Decoded text interpreted from one list of payloads: the most that one
    /// container read can yield.
    static let interpretedTextBytes = containerMetadataBytes + decompressedBytes
    /// Nesting depth of JSON and XML.
    static let nestingDepth = 64
    /// Nodes in one ComfyUI graph.
    static let graphNodes = 4_096
    /// Nested Exif directories followed below the first.
    static let exifDirectoryDepth = 4
}

/// Why untrusted JSON or XML was not decoded.
enum UntrustedInputProblem: Error, Equatable, CustomStringConvertible {
    case tooDeep
    case duplicateKey(String)
    case documentTypeDeclaration
    case malformed

    var description: String {
        switch self {
        case .tooDeep: "nesting exceeds \(InputLimits.nestingDepth) levels"
        case .duplicateKey(let key): "the key \"\(key)\" repeats"
        case .documentTypeDeclaration: "XML document type declarations are not accepted"
        case .malformed: "the text is malformed"
        }
    }
}

/// Decodes untrusted JSON after checking its structure.
///
/// The nesting check runs first, without recursion, so deeply nested input
/// cannot exhaust the stack in the recursive decoder. A repeated key is
/// rejected, because the decoder would silently keep only one of its values.
enum UntrustedJSON {
    static func decode(_ text: String) throws(UntrustedInputProblem) -> JSONValue {
        let data = Data(text.utf8)
        if let problem = JSONStructureScanner.problem(in: data) { throw problem }
        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw .malformed
        }
    }
}

/// Parses untrusted XML such as an XMP packet.
///
/// A document type declaration is rejected, which rules out entity expansion,
/// and nesting is checked in a first pass so the delegate never sees a
/// document deeper than the limit.
enum UntrustedXML {
    static func parse(
        _ xml: String,
        delegate: XMLParserDelegate,
        processNamespaces: Bool = false
    ) throws(UntrustedInputProblem) {
        let data = Data(xml.utf8)
        if xml.range(of: "<!DOCTYPE", options: .caseInsensitive) != nil
            || xml.range(of: "<!ENTITY", options: .caseInsensitive) != nil
        {
            throw .documentTypeDeclaration
        }

        let depth = XMLDepthCounter()
        let precheck = XMLParser(data: data)
        precheck.delegate = depth
        precheck.shouldResolveExternalEntities = false
        precheck.parse()
        if depth.exceeded { throw .tooDeep }

        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = processNamespaces
        parser.shouldReportNamespacePrefixes = processNamespaces
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw .malformed }
    }
}

private final class XMLDepthCounter: NSObject, XMLParserDelegate {
    private var depth = 0
    private(set) var exceeded = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        depth += 1
        if depth > InputLimits.nestingDepth {
            exceeded = true
            parser.abortParsing()
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        depth -= 1
    }
}
