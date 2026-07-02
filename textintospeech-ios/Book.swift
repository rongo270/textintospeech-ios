import Foundation

/// A book in the library. The full text lives on disk (content.txt); this index entry holds
/// metadata, the chapter boundaries (UTF-16 char offsets into the full text) and the saved
/// reading position so a book can be resumed.
nonisolated struct Book: Identifiable, Codable, Equatable {
    let id: String
    let title: String
    let author: String?
    let format: String                  // "epub" | "pdf" | "text"
    let coverFile: String?              // file name inside the book's folder, or nil
    let chapterTitles: [String]
    let chapterOffsets: [Int]           // start char offset of each chapter
    let totalChars: Int
    var direction: String = "ltr"       // "ltr" | "rtl" - text & page-flip direction
    var lastOffset: Int = 0             // where reading stopped (char offset)
    var progress: Double = 0            // 0...1
    var addedAt: Date = Date()

    var chapterCount: Int { chapterTitles.count }

    /// Index of the chapter that contains `offset`.
    func chapterIndex(forOffset offset: Int) -> Int {
        guard !chapterOffsets.isEmpty else { return 0 }
        let i = chapterOffsets.lastIndex { $0 <= offset } ?? 0
        return min(max(i, 0), max(chapterTitles.count - 1, 0))
    }

    var currentChapter: Int { chapterIndex(forOffset: lastOffset) }

    /// Character range [start, end) of chapter `index` within the full text.
    func chapterRange(_ index: Int) -> Range<Int> {
        let start = index < chapterOffsets.count ? chapterOffsets[index] : 0
        let end = index + 1 < chapterOffsets.count ? chapterOffsets[index + 1] : totalChars
        return start..<max(end, start)
    }

    func chapterTitle(_ index: Int) -> String {
        chapterTitles.indices.contains(index) ? chapterTitles[index] : ""
    }
}
