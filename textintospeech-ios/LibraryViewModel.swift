import Combine
import Foundation

/// State for the **Books** tab: the library plus the single-book reader. A book is read one
/// chapter at a time (so the engine's queue stays bounded even for long books) and auto-advances
/// to the next chapter via `SpeechController.completed`. The reading position is saved so a book
/// can be resumed.
@MainActor
final class LibraryViewModel: ObservableObject {

    let speech: SpeechController
    let repo: BookRepository

    struct ImportState: Equatable {
        var busy = false
        var error: String? = nil
    }

    struct ReaderState {
        var book: Book? = nil
        var chapterIndex = 0
        var chapterText = ""
        var chapterStart = 0
        var loading = false
    }

    @Published private(set) var importState = ImportState()
    @Published private(set) var reader = ReaderState()
    @Published private(set) var progress: Double = 0
    @Published private(set) var sleepRemaining: TimeInterval?

    private var content = ""
    private var currentGlobalOffset = 0
    private var sleepTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    init(speech: SpeechController, repo: BookRepository) {
        self.speech = speech
        self.repo = repo

        // Track the live reading position (for progress + resume) and auto-advance chapters.
        speech.$playback
            .sink { [weak self] p in
                guard let self, let b = self.reader.book else { return }
                if p.sourceId == Self.source(of: b), p.highlightStart >= 0 {
                    self.currentGlobalOffset = self.reader.chapterStart + p.highlightStart
                    self.progress = Double(self.currentGlobalOffset) / Double(max(b.totalChars, 1))
                }
            }
            .store(in: &cancellables)

        speech.completed
            .sink { [weak self] src in
                guard let self, let b = self.reader.book else { return }
                if src == Self.source(of: b) { self.onChapterFinished() }
            }
            .store(in: &cancellables)
    }

    static func source(of book: Book) -> String { "book:\(book.id)" }

    var books: [Book] { repo.books }

    // MARK: - Library

    func importBook(pickedURL: URL) {
        importState = ImportState(busy: true)
        Task {
            do {
                let local = try await Task.detached(priority: .userInitiated) {
                    try copyIntoCache(pickedURL, subdirectory: "imported")
                }.value
                _ = try await repo.importBook(from: local)
                importState = ImportState()
            } catch {
                let message = (error as? UserMessageError)?.message
                    ?? "Couldn't open this file: \(error.localizedDescription)"
                importState = ImportState(error: message)
            }
        }
    }

    func dismissImportError() { importState = ImportState() }

    func deleteBook(_ book: Book) {
        if reader.book?.id == book.id { closeBook() }
        repo.delete(book)
    }

    // MARK: - Reader

    func openBook(_ bookId: String) {
        guard let book = repo.books.first(where: { $0.id == bookId }) else { return }
        if reader.book?.id == bookId, !content.isEmpty { return }
        reader = ReaderState(book: book, loading: true)
        Task {
            content = await repo.loadContent(book)
            currentGlobalOffset = min(max(book.lastOffset, 0), book.totalChars)
            progress = Double(currentGlobalOffset) / Double(max(book.totalChars, 1))
            let chapter = book.chapterIndex(forOffset: book.lastOffset)
            reader = ReaderState(
                book: book,
                chapterIndex: chapter,
                chapterText: chapterText(of: book, index: chapter),
                chapterStart: book.chapterRange(chapter).lowerBound,
                loading: false
            )
        }
    }

    func closeBook() {
        let b = reader.book
        saveProgress()
        if let b, speech.playback.sourceId == Self.source(of: b) { speech.stop() }
        cancelSleepTimer()
        reader = ReaderState()
        content = ""
    }

    func playPause() {
        guard let b = reader.book else { return }
        switch speech.playback.state {
        case .speaking:
            speech.pause()
            saveProgress()
        case .paused:
            speech.resume()
        case .ready:
            let within = max(b.lastOffset - reader.chapterStart, 0)
            speakChapter(reader.chapterIndex, within: within)
        default:
            break
        }
    }

    func nextChapter() {
        guard let b = reader.book, reader.chapterIndex < b.chapterCount - 1 else { return }
        saveProgress()
        speakChapter(reader.chapterIndex + 1, within: 0)
    }

    func prevChapter() {
        guard reader.chapterIndex > 0 else { return }
        saveProgress()
        speakChapter(reader.chapterIndex - 1, within: 0)
    }

    func jumpToChapter(_ index: Int) {
        guard let b = reader.book, (0..<b.chapterCount).contains(index) else { return }
        saveProgress()
        speakChapter(index, within: 0)
    }

    func skipPreviousSentence() { speech.skipPrevious() }
    func skipNextSentence() { speech.skipNext() }

    /// Tap-a-line in the reader: begin reading from `withinChapterOffset`, a char offset into the
    /// chapter currently on screen. Seeks if this book is already playing/paused, otherwise
    /// starts the shown chapter from that point.
    func readFrom(withinChapterOffset: Int) {
        guard let b = reader.book else { return }
        let offset = min(max(withinChapterOffset, 0), reader.chapterText.utf16Count)
        let ours = speech.playback.sourceId == Self.source(of: b)
        switch speech.playback.state {
        case .speaking:
            if ours { speech.seekTo(offset) } else { speakChapter(reader.chapterIndex, within: offset) }
        case .paused:
            if ours {
                speech.seekTo(offset)
                speech.resume()
            } else {
                speakChapter(reader.chapterIndex, within: offset)
            }
        default:
            speakChapter(reader.chapterIndex, within: offset)
        }
    }

    func seekToFraction(_ fraction: Double) {
        guard let b = reader.book else { return }
        let global = min(max(Int(fraction * Double(b.totalChars)), 0), b.totalChars)
        let chapter = b.chapterIndex(forOffset: global)
        let within = max(global - b.chapterRange(chapter).lowerBound, 0)
        let state = speech.playback.state
        if chapter == reader.chapterIndex, state == .speaking || state == .paused {
            speech.seekTo(within)
        } else {
            speakChapter(chapter, within: within)
        }
    }

    private func speakChapter(_ index: Int, within: Int) {
        guard let b = reader.book else { return }
        let text = chapterText(of: b, index: index)
        reader.chapterIndex = index
        reader.chapterText = text
        reader.chapterStart = b.chapterRange(index).lowerBound
        speech.speak(text, startOffset: min(max(within, 0), text.utf16Count), source: Self.source(of: b))
    }

    private func onChapterFinished() {
        guard let b = reader.book else { return }
        if reader.chapterIndex < b.chapterCount - 1 {
            speakChapter(reader.chapterIndex + 1, within: 0)
        } else {
            currentGlobalOffset = b.totalChars
            progress = 1
            saveProgress()
        }
    }

    private func chapterText(of book: Book, index: Int) -> String {
        let range = book.chapterRange(index)
        let ns = content as NSString
        let start = min(max(range.lowerBound, 0), ns.length)
        let end = min(max(range.upperBound, start), ns.length)
        return ns.substring(with: NSRange(location: start, length: end - start))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveProgress() {
        guard let b = reader.book else { return }
        let progress = Double(currentGlobalOffset) / Double(max(b.totalChars, 1))
        repo.updateProgress(id: b.id, lastOffset: currentGlobalOffset, progress: progress)
        var updated = b
        updated.lastOffset = currentGlobalOffset
        updated.progress = progress
        reader.book = updated
    }

    // MARK: - Sleep timer

    func startSleepTimer(minutes: Int) {
        sleepTimer?.invalidate()
        sleepRemaining = TimeInterval(minutes * 60)
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let remaining = self.sleepRemaining else { return }
                let next = remaining - 1
                if next <= 0 {
                    self.speech.pause()
                    self.saveProgress()
                    self.cancelSleepTimer()
                } else {
                    self.sleepRemaining = next
                }
            }
        }
    }

    func cancelSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepRemaining = nil
    }
}
