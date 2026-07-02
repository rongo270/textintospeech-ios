import AVFoundation
import Combine
import Foundation
import UIKit

/// Copies a picked (possibly security-scoped) file into our own cache so it stays readable for
/// as long as we need it. Returns the local copy's URL.
nonisolated func copyIntoCache(_ url: URL, subdirectory: String) throws -> URL {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(subdirectory, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let target = dir.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
    try FileManager.default.copyItem(at: url, to: target)
    return target
}

/// State for the **Read** tab: loads documents/pictures into the editor and drives the shared
/// speech engine - the port of the Android ReaderViewModel.
@MainActor
final class ReaderViewModel: ObservableObject {

    static let sourceRead = "read"
    static let sourcePdf = "pdf"

    let speech: SpeechController

    /// `version` bumps each time a new document replaces the editor text.
    struct DocState: Equatable {
        var version = 0
        var status: String? = nil
        var busy = false
    }

    /// A picture and where each OCR line sits in it, so the photo reader can highlight lines.
    struct PhotoDoc: Equatable {
        let url: URL
        let lines: [OcrLine]
        static func == (a: PhotoDoc, b: PhotoDoc) -> Bool { a.url == b.url }
    }

    /// The source PDF (and its name), so the Read tab can show the real pages full-screen.
    struct PdfDoc: Equatable {
        let url: URL
        let name: String
    }

    @Published private(set) var doc = DocState()
    @Published private(set) var photo: PhotoDoc?
    @Published private(set) var pdf: PdfDoc?

    /// Base reading direction for the editor, chosen per document: opening a file/picture
    /// detects it from the text's own script, and the reader's direction button overrides it.
    /// `.auto` (a blank or hand-typed editor) defers to the global Settings choice.
    @Published private(set) var readingDir = ReadingDirection.auto

    /// Non-nil once when voices for the app's languages are missing (the one-time setup offer).
    @Published var voiceSetup: [String]?
    private var voiceSetupOffered = false

    /// Fires when text/a document is opened or shared in, so the UI can show the Read tab.
    let openRead = PassthroughSubject<Void, Never>()
    /// Fires when a photo finishes OCR (or is re-opened), to show the full-screen photo reader.
    let openPhotoReader = PassthroughSubject<Void, Never>()

    /// Canonical editor text; the screen keeps it in sync on every edit.
    var editorText: String = ""

    /// Languages the app targets; a missing voice triggers the one-time setup dialog.
    private let requiredLanguages = ["he", "en"]

    init(speech: SpeechController) {
        self.speech = speech
        if !voiceSetupOffered {
            let missing = requiredLanguages.filter { !speech.hasVoiceFor($0) }
            if !missing.isEmpty {
                voiceSetupOffered = true
                voiceSetup = missing
            }
        }
    }

    /// The direction button: pins an explicit LTR/RTL for the current document.
    func setReadingDirection(_ dir: ReadingDirection) { readingDir = dir }

    /// Orient a freshly loaded document to its own script; the button can still override afterwards.
    private func detectReadingDirection(_ text: String) {
        readingDir = isRtlText(text) ? .rtl : .ltr
    }

    func voiceSetupShown() { voiceSetup = nil }

    // MARK: - Opening documents

    func openDocument(pickedURL: URL) {
        speech.stop()
        photo = nil
        pdf = nil
        openRead.send()
        doc.busy = true
        doc.status = "Opening file…"
        Task {
            do {
                let local = try await Task.detached(priority: .userInitiated) {
                    try copyIntoCache(pickedURL, subdirectory: "imported")
                }.value
                let result = try await Task.detached(priority: .userInitiated) {
                    try TextExtractor.extract(url: local) { message in
                        Task { @MainActor [weak self] in self?.doc.status = message }
                    }
                }.value
                editorText = result.text
                detectReadingDirection(result.text)
                // A PDF keeps its source so the Read tab can offer the full-screen page view.
                pdf = result.isPdf ? PdfDoc(url: local, name: result.fileName) : nil
                var status = "Loaded \(result.fileName) · \(result.method) · \(formatCount(result.text.utf16Count)) characters"
                if let language = detectAndSwitchVoice(result.text) {
                    status += " · detected \(language) - voice switched"
                }
                doc = DocState(version: doc.version + 1, status: status, busy: false)
            } catch {
                doc.busy = false
                doc.status = friendlyMessage(error)
            }
        }
    }

    /// Opens a photo with line positions, so the app can show the picture and light up each line
    /// as it is read. Used by the camera/gallery → crop flow. `localURL` must already be ours.
    func openPhoto(localURL: URL) {
        speech.stop()
        photo = nil
        pdf = nil
        openRead.send()
        doc.busy = true
        doc.status = "Scanning the picture (on-device OCR)…"
        Task {
            do {
                let layout = try await Task.detached(priority: .userInitiated) {
                    try TextExtractor.ocrImageWithLayout(at: localURL)
                }.value
                if layout.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw UserMessageError(message: "No readable text was found in this picture.")
                }
                editorText = layout.text
                detectReadingDirection(layout.text)
                photo = PhotoDoc(url: localURL, lines: layout.lines)
                var status = "Loaded photo · on-device OCR · \(formatCount(layout.text.utf16Count)) characters"
                if let language = detectAndSwitchVoice(layout.text) {
                    status += " · detected \(language) - voice switched"
                }
                doc = DocState(version: doc.version + 1, status: status, busy: false)
                openPhotoReader.send()
            } catch {
                photo = nil
                doc.busy = false
                doc.status = friendlyMessage(error)
            }
        }
    }

    /// Text shared into the app (e.g. paste-from-elsewhere flows).
    func setSharedText(_ text: String) {
        speech.stop()
        photo = nil
        pdf = nil
        editorText = text
        detectReadingDirection(text)
        openRead.send()
        doc = DocState(version: doc.version + 1, status: nil, busy: false)
        _ = detectAndSwitchVoice(text)
    }

    /// Tap-a-line on the photo: read starting from character `offset`. Seeks if already
    /// playing/paused, otherwise starts a fresh reading of `text`.
    func readFrom(offset: Int, text: String) {
        switch speech.playback.state {
        case .speaking:
            speech.seekTo(offset)
        case .paused:
            speech.seekTo(offset)
            speech.resume()
        case .ready:
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                editorText = text
                speech.speak(text, startOffset: offset, source: Self.sourceRead)
            }
        default:
            break
        }
    }

    /// Re-opens the full-screen photo reader for the current photo (the Read tab button).
    func requestPhotoReader() {
        if photo != nil { openPhotoReader.send() }
    }

    /// Reads one PDF page's text aloud, tagged `sourcePdf` so only the in-page PDF reader lights
    /// up. Deliberately does **not** touch `editorText`: the Read-tab editor keeps the whole
    /// document, not the single page being shown.
    func pdfReadPage(_ pageText: String, startOffset: Int = 0) {
        if !pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            speech.speak(pageText, startOffset: startOffset, source: Self.sourcePdf)
        }
    }

    @discardableResult
    private func detectAndSwitchVoice(_ text: String) -> String? {
        guard let lang = LanguageDetect.detect(text) else { return nil }
        let before = speech.selectedVoice
        guard let match = speech.selectVoiceForLanguage(lang) else { return nil }
        guard match.identifier != before?.identifier else { return nil }
        return SpeechController.displayLanguage(lang)
    }

    // MARK: - Editing & playback

    /// Editing invalidates the sentence positions (and the photo's line boxes), so stop reading.
    func onEditorChanged(_ text: String) {
        editorText = text
        photo = nil   // hand-edited text no longer lines up with the OCR boxes
        let state = speech.playback.state
        if state == .speaking || state == .paused { speech.stop() }
    }

    func clear() {
        speech.stop()
        photo = nil
        pdf = nil
        editorText = ""
        readingDir = .auto
        doc = DocState(version: doc.version + 1, status: nil, busy: false)
    }

    func playPauseClicked(currentText: String) {
        switch speech.playback.state {
        case .speaking:
            speech.pause()
        case .paused:
            speech.resume()
        case .ready:
            if currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                doc.status = "Nothing to read yet - open a file or type some text first."
            } else {
                editorText = currentText
                speech.speak(currentText, source: Self.sourceRead)
            }
        default:
            break
        }
    }

    func stopClicked() { speech.stop() }

    private func friendlyMessage(_ error: Error) -> String {
        if let user = error as? UserMessageError { return user.message }
        return "Couldn't open this file: \(error.localizedDescription)"
    }

    private func formatCount(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
