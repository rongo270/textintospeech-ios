import Foundation

/// Minimal .docx reader: a .docx is a zip whose main text lives in word/document.xml. Pulls the
/// text of every w:t run, turning paragraphs, tabs and breaks into plain whitespace.
nonisolated enum DocxParser {

    static func parse(fileURL: URL) throws -> String {
        guard let zip = ZipArchive(url: fileURL),
              let xml = zip.extract(named: "word/document.xml") else {
            throw UserMessageError(message: "word/document.xml missing - not a valid .docx file")
        }
        let delegate = DocumentXmlDelegate()
        let parser = XMLParser(data: xml)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        return delegate.text
    }

    private nonisolated final class DocumentXmlDelegate: NSObject, XMLParserDelegate {
        var text = ""
        private var inText = false

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName: String?, attributes: [String: String]
        ) {
            switch elementName {
            case "t": inText = true
            case "tab": text.append("\t")
            case "br", "cr": text.append("\n")
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText { text.append(string) }
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String,
            namespaceURI: String?, qualifiedName: String?
        ) {
            switch elementName {
            case "t": inText = false
            case "p": text.append("\n")
            default: break
            }
        }
    }
}
