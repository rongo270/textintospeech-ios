import Foundation

/// Lightweight HTML-to-plain-text converter for EPUB chapters and .html files: strips
/// scripts/styles, turns block ends and <br> into newlines, drops all other tags and decodes
/// the common entities. Deliberately regex-based (no WebKit) so it is fast and can run off
/// the main thread.
nonisolated enum HtmlText {

    static func toPlainText(_ html: String) -> String {
        var s = html
        s = replace(s, pattern: "<!--.*?-->", with: " ")
        s = replace(s, pattern: "<(script|style)[^>]*>.*?</\\1>", with: " ")
        s = replace(s, pattern: "<br[^>]*>", with: "\n")
        s = replace(s, pattern: "<li[^>]*>", with: "\n• ")
        s = replace(s, pattern: "</(p|div|h[1-6]|li|tr|table|ul|ol|blockquote|section|article|header|footer|figcaption|dd|dt)>", with: "\n")
        s = replace(s, pattern: "<[^>]+>", with: " ")
        s = decodeEntities(s)

        // Tidy whitespace: collapse runs of spaces/tabs, trim line ends, cap blank lines.
        s = replace(s, pattern: "[ \\t\\u{00A0}]+", with: " ")
        s = replace(s, pattern: " ?\\n ?", with: "\n")
        s = replace(s, pattern: "\\n{3,}", with: "\n\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replace(_ input: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return input }
        return regex.stringByReplacingMatches(
            in: input, range: NSRange(location: 0, length: (input as NSString).length),
            withTemplate: template
        )
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "shy": "", "hellip": "…", "mdash": "—", "ndash": "–",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "copy": "©", "reg": "®", "trade": "™", "bull": "•", "middot": "·",
        "laquo": "«", "raquo": "»", "deg": "°", "sect": "§", "times": "×",
    ]

    static func decodeEntities(_ input: String) -> String {
        guard input.contains("&") else { return input }
        var out = String()
        out.reserveCapacity(input.count)
        var i = input.startIndex
        while i < input.endIndex {
            let c = input[i]
            if c == "&", let semi = input[i...].prefix(12).firstIndex(of: ";") {
                let body = String(input[input.index(after: i)..<semi])
                var decoded: String?
                if body.hasPrefix("#x") || body.hasPrefix("#X") {
                    if let v = UInt32(body.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(v) {
                        decoded = String(Character(scalar))
                    }
                } else if body.hasPrefix("#") {
                    if let v = UInt32(body.dropFirst()), let scalar = Unicode.Scalar(v) {
                        decoded = String(Character(scalar))
                    }
                } else {
                    decoded = named[body.lowercased()]
                }
                if let decoded {
                    out += decoded
                    i = input.index(after: semi)
                    continue
                }
            }
            out.append(c)
            i = input.index(after: i)
        }
        return out
    }
}
