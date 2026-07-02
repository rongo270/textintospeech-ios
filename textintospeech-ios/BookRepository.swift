import Combine
import Foundation

/// The Books library: imports book files into app-private storage, keeps a JSON index (no
/// database needed) and persists each book's reading position. The full text of each book lives
/// in books/<id>/content.txt; chapter boundaries are stored as character offsets in the index.
@MainActor
final class BookRepository: ObservableObject {

    static let maxChars = 1_500_000

    @Published private(set) var books: [Book] = []

    private let booksDir: URL
    private let indexFile: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        booksDir = support.appendingPathComponent("books", isDirectory: true)
        indexFile = support.appendingPathComponent("books.json")
        try? FileManager.default.createDirectory(at: booksDir, withIntermediateDirectories: true)
        books = Self.loadIndex(from: indexFile)
    }

    func contentURL(for book: Book) -> URL {
        booksDir.appendingPathComponent(book.id, isDirectory: true).appendingPathComponent("content.txt")
    }

    func coverURL(for book: Book) -> URL? {
        guard let file = book.coverFile else { return nil }
        return booksDir.appendingPathComponent(book.id, isDirectory: true).appendingPathComponent(file)
    }

    func loadContent(_ book: Book) async -> String {
        let url = contentURL(for: book)
        return await Task.detached(priority: .userInitiated) {
            (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }.value
    }

    func importBook(from url: URL) async throws -> Book {
        let id = UUID().uuidString
        let dir = booksDir.appendingPathComponent(id, isDirectory: true)
        let maxChars = Self.maxChars
        do {
            let book = try await Task.detached(priority: .userInitiated) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let name = url.lastPathComponent
                let ext = url.pathExtension.lowercased()
                let baseTitle = (name as NSString).deletingPathExtension.isEmpty
                    ? name : (name as NSString).deletingPathExtension
                if ext == "epub" {
                    return try Self.importEpub(url: url, id: id, dir: dir, baseTitle: baseTitle, maxChars: maxChars)
                } else {
                    return try Self.importViaExtractor(url: url, id: id, dir: dir, baseTitle: baseTitle, maxChars: maxChars)
                }
            }.value
            addOrReplace(book)
            return book
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    private nonisolated static func importEpub(
        url: URL, id: String, dir: URL, baseTitle: String, maxChars: Int
    ) throws -> Book {
        let parsed = try EpubParser.parse(fileURL: url)
        if parsed.chapters.isEmpty {
            throw UserMessageError(message: "No readable text was found in this file.")
        }

        var content = ""
        var titles: [String] = []
        var offsets: [Int] = []
        for (i, chapter) in parsed.chapters.enumerated() {
            if content.utf16Count >= maxChars { break }
            offsets.append(content.utf16Count)
            titles.append(chapter.title.isEmpty ? "Chapter \(i + 1)" : chapter.title)
            content += chapter.text + "\n\n"
        }
        while content.hasSuffix("\n") { content.removeLast() }

        try content.write(to: dir.appendingPathComponent("content.txt"), atomically: true, encoding: .utf8)

        var coverFile: String?
        if let coverData = parsed.coverData {
            let file = "cover.\(parsed.coverExtension ?? "jpg")"
            try? coverData.write(to: dir.appendingPathComponent(file))
            coverFile = file
        }

        // The EPUB may declare its reading direction (page-progression-direction); otherwise
        // fall back to sniffing the script of the text itself.
        let declared = parsed.direction
        let direction = (declared == "rtl" || declared == "ltr") ? declared! : (isRtlText(content) ? "rtl" : "ltr")

        let title = parsed.title?.isEmpty == false ? parsed.title! : baseTitle
        return Book(
            id: id,
            title: title,
            author: parsed.author?.isEmpty == false ? parsed.author : nil,
            format: "epub",
            coverFile: coverFile,
            chapterTitles: titles,
            chapterOffsets: offsets,
            totalChars: content.utf16Count,
            direction: direction
        )
    }

    private nonisolated static func importViaExtractor(
        url: URL, id: String, dir: URL, baseTitle: String, maxChars: Int
    ) throws -> Book {
        let result = try TextExtractor.extract(url: url) { _ in }
        let ns = result.text as NSString
        let content = ns.length > maxChars ? ns.substring(to: maxChars) : result.text
        let title = (result.fileName as NSString).deletingPathExtension.isEmpty
            ? baseTitle : (result.fileName as NSString).deletingPathExtension
        try content.write(to: dir.appendingPathComponent("content.txt"), atomically: true, encoding: .utf8)
        return Book(
            id: id,
            title: title,
            author: nil,
            format: result.isPdf ? "pdf" : "text",
            coverFile: nil,
            chapterTitles: [title],
            chapterOffsets: [0],
            totalChars: content.utf16Count,
            direction: isRtlText(content) ? "rtl" : "ltr"
        )
    }

    func delete(_ book: Book) {
        try? FileManager.default.removeItem(at: booksDir.appendingPathComponent(book.id, isDirectory: true))
        books.removeAll { $0.id == book.id }
        saveIndex()
    }

    /// Persists the reading position; called on pause/stop/chapter change, not every word.
    func updateProgress(id: String, lastOffset: Int, progress: Double) {
        guard let i = books.firstIndex(where: { $0.id == id }) else { return }
        books[i].lastOffset = lastOffset
        books[i].progress = min(max(progress, 0), 1)
        saveIndex()
    }

    private func addOrReplace(_ book: Book) {
        books.removeAll { $0.id == book.id }
        books.insert(book, at: 0)
        saveIndex()
    }

    // MARK: - JSON index

    private nonisolated static func loadIndex(from url: URL) -> [Book] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Book].self, from: data)) ?? []
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(books) else { return }
        try? data.write(to: indexFile, options: .atomic)
    }
}
