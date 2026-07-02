import SwiftUI
import UIKit

private enum ReaderSheet: String, Identifiable {
    case toc, sleep, settings
    var id: String { rawValue }
}

/// The single-book reader: the chapter laid out as turnable pages (like a real book), the spoken
/// line highlighted on its page, chapter navigation, a progress slider over the whole book, and
/// the sleep timer.
struct BookReaderScreen: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var vm: LibraryViewModel
    @ObservedObject var speech: SpeechController
    let bookId: String

    @State private var sheet: ReaderSheet?
    @State private var seeking: Double?

    private var playback: SpeechController.Playback { speech.playback }
    private var speaking: Bool { playback.state == .speaking }
    private var active: Bool { speaking || playback.state == .paused }
    private var playable: Bool { playback.state != .initializing && playback.state != .failed }

    var body: some View {
        let book = vm.reader.book
        let ours = book.map { playback.sourceId == LibraryViewModel.source(of: $0) } ?? false

        VStack(spacing: 0) {
            topBar(book: book)

            if let book {
                chapterHeader(book: book)

                let rtl: Bool = {
                    switch settings.readingDirection {
                    case .ltr: return false
                    case .rtl: return true
                    case .auto: return book.direction == "rtl"
                    }
                }()
                let lastChapter = vm.reader.chapterIndex >= book.chapterCount - 1

                PagedReadingSurface(
                    text: vm.reader.chapterText,
                    highlightStart: ours ? playback.highlightStart : -1,
                    highlightEnd: ours ? playback.highlightEnd : -1,
                    fontSize: 17 * 1.12 * settings.textScale,
                    rtl: rtl,
                    resumeOffset: max(book.lastOffset - vm.reader.chapterStart, 0),
                    endLabel: lastChapter ? "End of book" : "End of chapter",
                    nextChapterTitle: lastChapter ? nil : nonBlankTitle(book, vm.reader.chapterIndex + 1),
                    onNextChapter: { vm.nextChapter() },
                    onTapToRead: { vm.readFrom(withinChapterOffset: $0) }
                )
                .frame(maxHeight: .infinity)

                controls(book: book)
            } else {
                Spacer()
                ProgressView()
                Spacer()
            }
        }
        .background(theme.surface.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { vm.openBook(bookId) }
        .onDisappear { vm.closeBook() }
        .sheet(item: $sheet) { which in
            switch which {
            case .toc:
                if let book = vm.reader.book {
                    TocSheet(titles: book.chapterTitles, current: vm.reader.chapterIndex) { index in
                        vm.jumpToChapter(index)
                        sheet = nil
                    }
                    .presentationDetents([.medium, .large])
                }
            case .sleep:
                SleepSheet(
                    active: vm.sleepRemaining != nil,
                    onPick: { minutes in
                        vm.startSleepTimer(minutes: minutes)
                        sheet = nil
                    },
                    onCancel: {
                        vm.cancelSleepTimer()
                        sheet = nil
                    }
                )
                .presentationDetents([.height(220)])
            case .settings:
                VoiceSoundSheet(speech: speech, isReading: speaking) { speech.restartCurrentChunk() }
                    .presentationDetents([.medium, .large])
            }
        }
    }

    private func nonBlankTitle(_ book: Book, _ index: Int) -> String {
        let t = book.chapterTitle(index)
        return t.isEmpty ? "Chapter \(index + 1)" : t
    }

    private func topBar(book: Book?) -> some View {
        HStack(spacing: 0) {
            Button {
                vm.closeBook()
                dismiss()
            } label: {
                Image(systemName: "chevron.backward")
                    .foregroundStyle(theme.onSurface)
                    .frame(width: 44, height: 44)
            }
            Text(book?.title ?? "")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.onSurface)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !vm.reader.chapterText.isEmpty {
                ShareLink(item: vm.reader.chapterText) {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(theme.onSurfaceVariant)
                        .frame(width: 40, height: 44)
                }
            }
            barButton("list.bullet") { sheet = .toc }
            barButton("slider.horizontal.3") { sheet = .settings }
            Button { sheet = .sleep } label: {
                Image(systemName: "moon.zzz")
                    .foregroundStyle(vm.sleepRemaining != nil ? theme.primary : theme.onSurfaceVariant)
                    .frame(width: 40, height: 44)
            }
        }
        .padding(.horizontal, 4)
    }

    private func barButton(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .foregroundStyle(theme.onSurfaceVariant)
                .frame(width: 40, height: 44)
        }
    }

    private func chapterHeader(book: Book) -> some View {
        VStack(spacing: 8) {
            Text(nonBlankTitle(book, vm.reader.chapterIndex))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
            Divider().padding(.horizontal, 20)
        }
        .padding(.top, 4)
    }

    private func controls(book: Book) -> some View {
        VStack(spacing: 0) {
            if let remaining = vm.sleepRemaining {
                let total = Int(remaining)
                Text("\(total / 60):\(String(format: "%02d", total % 60)) left")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(theme.primary)
            }
            HStack {
                Text("Chapter \(vm.reader.chapterIndex + 1) of \(book.chapterCount)")
                    .font(.caption)
                    .foregroundStyle(theme.onSurfaceVariant)
                Spacer()
                Text("\(Int((seeking ?? vm.progress) * 100))%")
                    .font(.caption)
                    .foregroundStyle(theme.onSurfaceVariant)
            }
            Slider(
                value: Binding(
                    get: { seeking ?? min(max(vm.progress, 0), 1) },
                    set: { seeking = $0 }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    if !editing, let value = seeking {
                        vm.seekToFraction(value)
                        seeking = nil
                    }
                }
            )
            .tint(theme.primary)

            HStack {
                Spacer()
                TransportButton(systemName: "backward.end.alt.fill", enabled: active) { vm.prevChapter() }
                Spacer()
                TransportButton(systemName: "backward.fill", enabled: active) { vm.skipPreviousSentence() }
                Spacer()
                PlayPauseButton(isSpeaking: speaking, enabled: playable) { vm.playPause() }
                Spacer()
                TransportButton(systemName: "forward.fill", enabled: active) { vm.skipNextSentence() }
                Spacer()
                TransportButton(systemName: "forward.end.alt.fill", enabled: active) { vm.nextChapter() }
                Spacer()
            }
            .padding(.top, 2)
            .padding(.bottom, 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

/// The chapter laid out as turnable **pages** instead of one long scroll. The text is measured
/// once and sliced into screen-sized pages; the spoken line is highlighted on its page and the
/// pager auto-turns to follow it. A final page shows the end-of-chapter marker. `rtl` flips both
/// the text and the page-turn direction. Tapping a line reads from there.
struct PagedReadingSurface: View {
    @Environment(\.theme) private var theme
    let text: String
    let highlightStart: Int
    let highlightEnd: Int
    let fontSize: CGFloat
    let rtl: Bool
    let resumeOffset: Int
    let endLabel: String
    let nextChapterTitle: String?
    let onNextChapter: () -> Void
    let onTapToRead: (Int) -> Void

    private struct PageKey: Equatable {
        let textLength: Int
        let textHash: Int
        let width: Int
        let height: Int
        let fontSize: CGFloat
        let rtl: Bool
    }

    @State private var starts: [Int] = [0]
    @State private var page = 0
    @State private var appliedKey: PageKey?

    var body: some View {
        GeometryReader { geo in
            let hPad: CGFloat = 16
            let vPad: CGFloat = 8
            let pageSize = CGSize(width: geo.size.width - hPad * 2, height: geo.size.height - vPad * 2 - 24)
            let key = PageKey(
                textLength: text.utf16Count, textHash: text.hashValue,
                width: Int(pageSize.width), height: Int(pageSize.height),
                fontSize: fontSize, rtl: rtl
            )
            let textPages = starts.count
            let ns = text as NSString

            VStack(spacing: 0) {
                TabView(selection: $page) {
                    ForEach(0..<textPages, id: \.self) { index in
                        let start = starts[index]
                        let end = index + 1 < textPages ? starts[index + 1] : ns.length
                        let pageText = start < end && end <= ns.length
                            ? ns.substring(with: NSRange(location: start, length: end - start)) : ""
                        ReadOnlyHighlightText(
                            text: pageText,
                            highlight: pageHighlight(start: start, end: end),
                            fontSize: fontSize,
                            rtl: rtl,
                            textColor: UIColor(theme.onSurface),
                            scrollEnabled: false,
                            onTapLineStart: { lineStart in onTapToRead(start + lineStart) }
                        )
                        .padding(.horizontal, hPad)
                        .padding(.vertical, vPad)
                        .tag(index)
                    }
                    chapterEndMarker
                        .tag(textPages)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)

                if page < textPages {
                    Text("\(page + 1) / \(textPages)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(theme.onSurface)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(theme.surfaceContainerHigh.opacity(0.92)))
                } else {
                    Color.clear.frame(height: 24)
                }
            }
            .onAppear { repaginate(key, pageSize: pageSize) }
            .onChange(of: key) { _, newKey in repaginate(newKey, pageSize: pageSize) }
            .onChange(of: highlightStart) { _, newValue in
                // Follow the spoken line, turning the page as reading advances.
                if newValue >= 0 {
                    let target = pageForOffset(starts, newValue)
                    if target != page {
                        if theme.eInk { page = target } else { withAnimation { page = target } }
                    }
                }
            }
        }
    }

    private func pageHighlight(start: Int, end: Int) -> NSRange? {
        guard highlightStart >= 0, highlightEnd > highlightStart,
              highlightStart < end, highlightEnd > start else { return nil }
        let s = max(highlightStart - start, 0)
        let e = min(highlightEnd - start, end - start)
        guard e > s else { return nil }
        return NSRange(location: s, length: e - s)
    }

    private func repaginate(_ key: PageKey, pageSize: CGSize) {
        guard appliedKey != key else { return }
        appliedKey = key
        starts = paginate(text: text, fontSize: fontSize, rtl: rtl, pageSize: pageSize)
        // Land on the page of the resume/reading position whenever the text is (re)paginated.
        let anchor = highlightStart >= 0 ? highlightStart : resumeOffset
        page = min(pageForOffset(starts, anchor), starts.count)
    }

    private var chapterEndMarker: some View {
        VStack(spacing: 0) {
            Text("•  •  •")
                .font(.subheadline)
                .foregroundStyle(theme.onSurfaceVariant.opacity(0.6))
            Text(endLabel)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(theme.onSurfaceVariant)
                .padding(.top, 12)
            if let nextChapterTitle {
                Text(nextChapterTitle)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(theme.onSurface)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.top, 6)
                    .padding(.horizontal, 24)
                Button(action: onNextChapter) {
                    Label("Next chapter", systemImage: "forward.end.fill")
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(theme.secondaryContainer))
                        .foregroundStyle(theme.onSecondaryContainer)
                }
                .buttonStyle(.plain)
                .padding(.top, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TocSheet: View {
    @Environment(\.theme) private var theme
    let titles: [String]
    let current: Int
    let onPick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Chapters")
                .font(.headline)
                .foregroundStyle(theme.onSurface)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            Divider()
            ScrollViewReader { proxy in
                List {
                    ForEach(titles.indices, id: \.self) { index in
                        Button {
                            onPick(index)
                        } label: {
                            Text(titles[index].isEmpty ? "Chapter \(index + 1)" : titles[index])
                                .font(.body.weight(index == current ? .bold : .regular))
                                .foregroundStyle(index == current ? theme.primary : theme.onSurface)
                                .lineLimit(2)
                        }
                        .listRowBackground(Color.clear)
                        .id(index)
                    }
                }
                .listStyle(.plain)
                .onAppear { proxy.scrollTo(current, anchor: .center) }
            }
        }
        .background(theme.surfaceContainerLow)
    }
}

private struct SleepSheet: View {
    @Environment(\.theme) private var theme
    let active: Bool
    let onPick: (Int) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sleep timer")
                .font(.headline)
                .foregroundStyle(theme.onSurface)
            HStack(spacing: 8) {
                ForEach([15, 30, 45, 60], id: \.self) { minutes in
                    Button {
                        onPick(minutes)
                    } label: {
                        Text("\(minutes) min")
                            .font(.footnote.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(RoundedRectangle(cornerRadius: 12).fill(theme.secondaryContainer))
                            .foregroundStyle(theme.onSecondaryContainer)
                    }
                    .buttonStyle(.plain)
                }
            }
            if active {
                Button("Turn off timer", action: onCancel)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(theme.primary)
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceContainerLow)
    }
}
