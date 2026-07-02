import Foundation

/// A small, on-device EPUB reader. Walks META-INF/container.xml → the OPF package document →
/// the spine (reading order), turning each chapter's XHTML into plain text via `HtmlText`.
/// Chapter titles come from the EPUB's table of contents (EPUB3 nav doc or EPUB2 toc.ncx), with
/// sensible fallbacks. The cover image, if any, is returned as raw bytes for the library to store.
nonisolated enum EpubParser {

    struct Chapter { let title: String; let text: String }

    struct ParsedBook {
        let title: String?
        let author: String?
        let coverData: Data?
        let coverExtension: String?
        let chapters: [Chapter]
        let direction: String?   // "rtl"/"ltr" from the spine's page-progression-direction, or nil
    }

    private struct Opf {
        var title: String?
        var author: String?
        var manifest: [String: String] = [:]     // id -> href
        var mediaTypes: [String: String] = [:]   // id -> media-type
        var spine: [String] = []                  // ordered idrefs
        var ncxId: String?                        // spine@toc
        var navId: String?                        // manifest item properties=nav
        var coverId: String?                      // <meta name=cover> or properties=cover-image
        var direction: String?                    // spine@page-progression-direction
    }

    static func parse(fileURL: URL) throws -> ParsedBook {
        guard let zip = ZipArchive(url: fileURL) else {
            throw UserMessageError(message: "This file isn't a readable EPUB.")
        }
        guard let containerXml = zip.extract(named: "META-INF/container.xml"),
              let opfPath = readOpfPath(containerXml) else {
            throw UserMessageError(message: "This EPUB has no package document.")
        }
        let opfDir = opfPath.contains("/") ? String(opfPath[..<opfPath.lastIndex(of: "/")!]) : ""
        guard let opfData = zip.extract(named: opfPath) else {
            throw UserMessageError(message: "This EPUB's package document is unreadable.")
        }
        let opf = readOpf(opfData)

        let tocTitles = readTocTitles(zip: zip, opfDir: opfDir, opf: opf)

        var chapters: [Chapter] = []
        for idref in opf.spine {
            guard let href = opf.manifest[idref] else { continue }
            let path = resolve(dir: opfDir, href: String(href.split(separator: "#").first ?? ""))
            guard let entryData = zip.extract(named: path),
                  let html = String(data: entryData, encoding: .utf8)
                    ?? String(data: entryData, encoding: .isoLatin1) else { continue }
            let text = HtmlText.toPlainText(html)
            if text.isEmpty { continue }
            let title = tocTitles[path] ?? firstHeading(html) ?? ""
            chapters.append(Chapter(title: title, text: text))
        }

        let (coverData, coverExt) = readCover(zip: zip, opfDir: opfDir, opf: opf)
        return ParsedBook(
            title: opf.title?.trimmingCharacters(in: .whitespacesAndNewlines),
            author: opf.author?.trimmingCharacters(in: .whitespacesAndNewlines),
            coverData: coverData,
            coverExtension: coverExt,
            chapters: chapters,
            direction: opf.direction?.lowercased()
        )
    }

    // MARK: - container.xml → OPF path

    private static func readOpfPath(_ data: Data) -> String? {
        let delegate = ContainerDelegate()
        runParser(data, delegate)
        return delegate.opfPath
    }

    private nonisolated final class ContainerDelegate: NSObject, XMLParserDelegate {
        var opfPath: String?
        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName: String?, attributes: [String: String]
        ) {
            if local(elementName) == "rootfile", opfPath == nil {
                opfPath = attributes["full-path"]
            }
        }
    }

    // MARK: - OPF package document

    private static func readOpf(_ data: Data) -> Opf {
        let delegate = OpfDelegate()
        runParser(data, delegate)
        return delegate.opf
    }

    private nonisolated final class OpfDelegate: NSObject, XMLParserDelegate {
        var opf = Opf()
        private var capture: String?
        private var buffer = ""

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName: String?, attributes: [String: String]
        ) {
            switch local(elementName) {
            case "title": capture = "title"; buffer = ""
            case "creator": capture = "creator"; buffer = ""
            case "item":
                if let id = attributes["id"], let href = attributes["href"] {
                    opf.manifest[id] = href
                    if let type = attributes["media-type"] { opf.mediaTypes[id] = type }
                    let props = attributes["properties"] ?? ""
                    if props.contains("nav") { opf.navId = id }
                    if props.contains("cover-image") { opf.coverId = id }
                }
            case "itemref":
                if let idref = attributes["idref"] { opf.spine.append(idref) }
            case "spine":
                if let toc = attributes["toc"] { opf.ncxId = toc }
                opf.direction = attributes["page-progression-direction"]
            case "meta":
                if attributes["name"] == "cover", let content = attributes["content"] {
                    opf.coverId = content
                }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if capture != nil { buffer += string }
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String,
            namespaceURI: String?, qualifiedName: String?
        ) {
            switch local(elementName) {
            case "title":
                if opf.title == nil { opf.title = buffer.trimmingCharacters(in: .whitespacesAndNewlines) }
                capture = nil
            case "creator":
                if opf.author == nil { opf.author = buffer.trimmingCharacters(in: .whitespacesAndNewlines) }
                capture = nil
            default: break
            }
        }
    }

    // MARK: - table of contents (nav doc or ncx) → path -> title

    private static func readTocTitles(zip: ZipArchive, opfDir: String, opf: Opf) -> [String: String] {
        if let navId = opf.navId, let navHref = opf.manifest[navId] {
            let path = resolve(dir: opfDir, href: String(navHref.split(separator: "#").first ?? ""))
            if let data = zip.extract(named: path) {
                let base = path.contains("/") ? String(path[..<path.lastIndex(of: "/")!]) : ""
                let delegate = NavDelegate(baseDir: base)
                runParser(data, delegate)
                return delegate.titles
            }
        }
        let ncxHref = opf.ncxId.flatMap { opf.manifest[$0] }
            ?? opf.mediaTypes.first { $0.value == "application/x-dtbncx+xml" }.flatMap { opf.manifest[$0.key] }
        if let ncxHref {
            let path = resolve(dir: opfDir, href: String(ncxHref.split(separator: "#").first ?? ""))
            if let data = zip.extract(named: path) {
                let base = path.contains("/") ? String(path[..<path.lastIndex(of: "/")!]) : ""
                let delegate = NcxDelegate(baseDir: base)
                runParser(data, delegate)
                return delegate.titles
            }
        }
        return [:]
    }

    /// EPUB2 toc.ncx: navPoint → navLabel/text + content@src.
    private nonisolated final class NcxDelegate: NSObject, XMLParserDelegate {
        var titles: [String: String] = [:]
        private let baseDir: String
        private var inText = false
        private var buffer = ""
        private var pendingTitle: String?

        init(baseDir: String) { self.baseDir = baseDir }

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName: String?, attributes: [String: String]
        ) {
            switch local(elementName) {
            case "text": inText = true; buffer = ""
            case "content":
                if let src = attributes["src"]?.split(separator: "#").first.map(String.init),
                   let title = pendingTitle, !title.isEmpty {
                    titles[EpubParser.resolve(dir: baseDir, href: src)] = title
                }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText { buffer += string }
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String,
            namespaceURI: String?, qualifiedName: String?
        ) {
            if local(elementName) == "text" {
                pendingTitle = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                inText = false
            }
        }
    }

    /// EPUB3 nav doc: every <a href> anchor's text becomes that file's title.
    private nonisolated final class NavDelegate: NSObject, XMLParserDelegate {
        var titles: [String: String] = [:]
        private let baseDir: String
        private var href: String?
        private var buffer = ""

        init(baseDir: String) { self.baseDir = baseDir }

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName: String?, attributes: [String: String]
        ) {
            if local(elementName) == "a" {
                href = attributes["href"]?.split(separator: "#").first.map(String.init)
                buffer = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            buffer += string
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String,
            namespaceURI: String?, qualifiedName: String?
        ) {
            if local(elementName) == "a" {
                let title = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if let h = href, !title.isEmpty {
                    let key = EpubParser.resolve(dir: baseDir, href: h)
                    if titles[key] == nil { titles[key] = title }
                }
                href = nil
            }
        }
    }

    // MARK: - cover

    private static func readCover(zip: ZipArchive, opfDir: String, opf: Opf) -> (Data?, String?) {
        guard let id = opf.coverId, let href = opf.manifest[id] else { return (nil, nil) }
        let path = resolve(dir: opfDir, href: href)
        guard let bytes = zip.extract(named: path) else { return (nil, nil) }
        let ext = path.contains(".") ? String(path.split(separator: ".").last!).lowercased() : "jpg"
        return (bytes, ext)
    }

    // MARK: - helpers

    private static func runParser(_ data: Data, _ delegate: XMLParserDelegate) {
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
    }

    /// "opf:title" → "title": XMLParser reports prefixed names when namespaces are off.
    fileprivate static func local(_ name: String) -> String {
        name.contains(":") ? String(name.split(separator: ":").last ?? "") : name
    }

    /// Resolves `href` relative to `dir`, handling "./", "../" and percent-encoding.
    static func resolve(dir: String, href: String) -> String {
        let decoded = href.trimmingCharacters(in: .whitespaces).removingPercentEncoding
            ?? href.trimmingCharacters(in: .whitespaces)
        let joined = dir.isEmpty ? decoded : "\(dir)/\(decoded)"
        var parts: [String] = []
        for seg in joined.split(separator: "/", omittingEmptySubsequences: false) {
            switch seg {
            case "", ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(String(seg))
            }
        }
        return parts.joined(separator: "/")
    }

    private static func firstHeading(_ html: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "<h[1-6][^>]*>(.*?)</h[1-6]>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }
        let ns = html as NSString
        guard let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        let text = HtmlText.toPlainText(ns.substring(with: match.range(at: 1)))
        let clipped = String(text.prefix(80))
        return clipped.isEmpty ? nil : clipped
    }
}

/// Free-function alias used by the nested XMLParser delegates (their `local` calls).
private nonisolated func local(_ name: String) -> String { EpubParser.local(name) }
