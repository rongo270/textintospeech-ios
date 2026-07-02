import Foundation
import PDFKit
import UIKit
import Vision

/// Result of turning a document into plain text.
nonisolated struct ExtractResult {
    let text: String
    let fileName: String
    let method: String
    let isPdf: Bool
}

/// One OCR text line: its UTF-16 character range in `OcrLayout.text` and its box in the
/// picture, normalised to 0..1 (top-left origin) so it maps onto any display size.
nonisolated struct OcrLine {
    let start: Int
    let end: Int
    let left: CGFloat
    let top: CGFloat
    let right: CGFloat
    let bottom: CGFloat
}

/// OCR text that also remembers where each line sits in the picture (for the photo view).
nonisolated struct OcrLayout {
    let text: String
    let lines: [OcrLine]
}

/// Turns documents and pictures into plain text - entirely on the device:
///  - PDF: PDFKit text layer; scanned PDFs fall back to rendering pages and running Vision OCR.
///  - Pictures: Vision OCR (Hebrew + English requested together, so one photo can mix scripts).
///  - .docx / RTF / HTML / EPUB / plain text: lightweight built-in parsers.
///
/// Vision returns text in logical (reading) order - including right-to-left Hebrew - so it is
/// stored exactly as returned; never reverse OCR output.
nonisolated enum TextExtractor {

    static let maxChars = 500_000
    static let maxOcrPages = 40

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "bmp", "heic", "heif", "gif", "tiff", "tif"]
    static let textExtensions: Set<String> = ["txt", "md", "markdown", "log", "csv", "json", "srt", "vtt", "xml"]

    /// Extracts plain text from the file at `url`. Heavy work - call from a background task.
    static func extract(url: URL, onProgress: @escaping @Sendable (String) -> Void) throws -> ExtractResult {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()

        onProgress("Extracting text…")
        var isPdf = false
        let raw: String
        let method: String

        switch ext {
        case "pdf":
            isPdf = true
            (raw, method) = try extractPdf(url: url, onProgress: onProgress)
        case "docx":
            raw = try DocxParser.parse(fileURL: url)
            method = "Word document"
        case "doc":
            throw UserMessageError(message: "Old .doc files aren't supported - save the file as .docx or PDF and try again.")
        case _ where imageExtensions.contains(ext):
            onProgress("Scanning the picture (on-device OCR)…")
            raw = try ocrImage(at: url)
            method = "picture · on-device OCR"
        case "rtf":
            let data = try Data(contentsOf: url)
            let attributed = try NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            )
            raw = attributed.string
            method = "RTF"
        case "html", "htm":
            let data = try Data(contentsOf: url)
            raw = HtmlText.toPlainText(String(data: data, encoding: .utf8) ?? "")
            method = "HTML"
        case "epub":
            let parsed = try EpubParser.parse(fileURL: url)
            raw = parsed.chapters.map(\.text).joined(separator: "\n\n")
            method = "EPUB"
        case _ where textExtensions.contains(ext):
            raw = try String(contentsOf: url, encoding: .utf8)
            method = "plain text"
        default:
            let data = try Data(contentsOf: url)
            if data.prefix(2048).contains(0) {
                throw UserMessageError(message: "This file type isn't supported.")
            }
            raw = String(data: data, encoding: .utf8) ?? ""
            method = "plain text"
        }

        var clean = raw
            .replacingOccurrences(of: "\u{0000}", with: " ")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty {
            throw UserMessageError(message: "No readable text was found in this file.")
        }
        if clean.utf16Count > maxChars {
            let ns = clean as NSString
            clean = ns.substring(to: maxChars) + "\n\n[The text was very long and has been shortened.]"
        }
        return ExtractResult(text: clean, fileName: name, method: method, isPdf: isPdf)
    }

    // MARK: - PDF

    private static func extractPdf(url: URL, onProgress: @escaping @Sendable (String) -> Void) throws -> (String, String) {
        guard let doc = PDFDocument(url: url) else {
            throw UserMessageError(message: "Couldn't open this PDF.")
        }
        if doc.isLocked || doc.isEncrypted {
            throw UserMessageError(message: "This PDF is password-protected and can't be read.")
        }
        let text = (0..<doc.pageCount)
            .compactMap { doc.page(at: $0)?.string }
            .joined(separator: "\n\n")
        let letterCount = text.unicodeScalars.lazy
            .filter { $0.properties.isAlphabetic || (48...57).contains($0.value) }
            .prefix(50).count
        if letterCount >= 50 {
            return (text, "PDF text")
        }

        // Little or no text layer: probably a scanned PDF - OCR the rendered pages.
        let pages = min(doc.pageCount, maxOcrPages)
        var out = ""
        for i in 0..<pages {
            onProgress("Reading page \(i + 1) of \(pages) (on-device OCR)…")
            guard let page = doc.page(at: i), let cg = renderPage(page, targetWidth: 1600) else { continue }
            let pageText = (try? recognizeText(cgImage: cg)) ?? ""
            if !pageText.isEmpty { out += pageText + "\n\n" }
        }
        return (out, "scanned PDF · on-device OCR")
    }

    /// Renders one PDF page to a bitmap for OCR or display.
    static func renderPage(_ page: PDFPage, targetWidth: CGFloat) -> CGImage? {
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let size = CGSize(width: targetWidth, height: targetWidth * bounds.height / bounds.width)
        let image = page.thumbnail(of: size, for: .cropBox)
        return image.cgImage
    }

    // MARK: - Vision OCR

    /// OCR on a single picture file, upright per its EXIF orientation.
    static func ocrImage(at url: URL) throws -> String {
        guard let image = UIImage(contentsOfFile: url.path), let cg = image.cgImage else {
            throw UserMessageError(message: "Couldn't open this picture.")
        }
        return try recognizeText(cgImage: cg, orientation: CGImagePropertyOrientation(image.imageOrientation))
    }

    /// Like `ocrImage` but also returns the on-image rectangle of every text line, so the UI can
    /// show the original photo and light up each line as it is read aloud.
    static func ocrImageWithLayout(at url: URL) throws -> OcrLayout {
        guard let image = UIImage(contentsOfFile: url.path), let cg = image.cgImage else {
            throw UserMessageError(message: "Couldn't open this picture.")
        }
        return try recognizeLayout(cgImage: cg, orientation: CGImagePropertyOrientation(image.imageOrientation))
    }

    static func recognizeText(cgImage: CGImage, orientation: CGImagePropertyOrientation = .up) throws -> String {
        let observations = try recognize(cgImage: cgImage, orientation: orientation)
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// OCR with per-line boxes, in logical (reading) order, so the character offsets line up
    /// exactly with the boxes - and Hebrew stays correct (never reverse it).
    static func recognizeLayout(cgImage: CGImage, orientation: CGImagePropertyOrientation = .up) throws -> OcrLayout {
        let observations = try recognize(cgImage: cgImage, orientation: orientation)
        var text = ""
        var lines: [OcrLine] = []
        for obs in observations {
            guard let candidate = obs.topCandidates(1).first else { continue }
            let line = candidate.string.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let box = obs.boundingBox   // normalized, bottom-left origin
            let start = text.utf16Count
            text += line
            lines.append(OcrLine(
                start: start, end: text.utf16Count,
                left: box.minX, top: 1 - box.maxY, right: box.maxX, bottom: 1 - box.minY
            ))
            text += "\n"
        }
        if text.hasSuffix("\n") { text.removeLast() }
        return OcrLayout(text: text, lines: lines)
    }

    private static func recognize(cgImage: CGImage, orientation: CGImagePropertyOrientation) throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Hebrew and English together, so a single photo can contain either or both; languages
        // the installed Vision version doesn't support are dropped.
        let wanted = ["he-IL", "en-US"]
        if let supported = try? request.supportedRecognitionLanguages() {
            let usable = wanted.filter { w in supported.contains { SpeechController.sameLanguage($0, w) } }
            if !usable.isEmpty { request.recognitionLanguages = usable }
        } else {
            request.recognitionLanguages = wanted
        }
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
        try handler.perform([request])
        let results = request.results ?? []
        // Keep Vision's reading order within a row, but make top-to-bottom explicit (stable sort).
        return results.enumerated().sorted { a, b in
            let topA = 1 - a.element.boundingBox.maxY
            let topB = 1 - b.element.boundingBox.maxY
            if abs(topA - topB) > 0.008 { return topA < topB }
            return a.offset < b.offset
        }.map(\.element)
    }
}

nonisolated extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
