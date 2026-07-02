import Combine
import PDFKit
import SwiftUI
import UIKit

/// One text line on a PDF page: its UTF-16 range in the page text and its box in PDF page space.
nonisolated struct PdfLine {
    let start: Int
    let end: Int
    let bounds: CGRect
}

/// The text of one page plus the box of every line, so the reader can light up the spoken line
/// right on the rendered page.
nonisolated struct PdfPageLayout {
    let text: String
    let lines: [PdfLine]
}

/// Owns one open PDF for the whole reader session: per-page text + line boxes for the
/// read-along highlight. Digital pages get exact boxes from the PDF text layer; pages with
/// little or no text layer (scanned/photographed PDFs) are rendered and OCR'd with Vision.
/// Results are cached per page.
@MainActor
final class PdfReadSession: ObservableObject {

    let document: PDFDocument
    @Published private(set) var layouts: [Int: PdfPageLayout] = [:]

    var pageCount: Int { document.pageCount }

    init?(url: URL) {
        guard let doc = PDFDocument(url: url), !doc.isLocked, doc.pageCount > 0 else { return nil }
        document = doc
    }

    func layout(for pageIndex: Int) async -> PdfPageLayout {
        if let cached = layouts[pageIndex] { return cached }
        guard let page = document.page(at: pageIndex) else { return PdfPageLayout(text: "", lines: []) }
        let result = await Task.detached(priority: .userInitiated) {
            Self.computeLayout(page: page)
        }.value
        layouts[pageIndex] = result
        return result
    }

    private nonisolated static func computeLayout(page: PDFPage) -> PdfPageLayout {
        let textLayer = textLayerLayout(page: page)
        let letters = textLayer.text.unicodeScalars.filter { $0.properties.isAlphabetic }.count
        if letters >= 12 { return textLayer }
        // Little/no text layer: a scanned page - render it and OCR for boxes.
        if let ocr = ocrLayout(page: page), !ocr.text.isEmpty { return ocr }
        return textLayer
    }

    /// Walks the page's text layer line by line; offsets line up exactly with the boxes because
    /// the page text is built from the very same line strings.
    private nonisolated static func textLayerLayout(page: PDFPage) -> PdfPageLayout {
        guard page.numberOfCharacters > 0,
              let full = page.selection(for: NSRange(location: 0, length: page.numberOfCharacters)) else {
            return PdfPageLayout(text: "", lines: [])
        }
        var text = ""
        var lines: [PdfLine] = []
        for selection in full.selectionsByLine() {
            let raw = selection.string ?? ""
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let bounds = selection.bounds(for: page)
            if bounds.isEmpty || bounds.isNull { continue }
            let start = text.utf16Count
            text += line
            lines.append(PdfLine(start: start, end: text.utf16Count, bounds: bounds))
            text += "\n"
        }
        if text.hasSuffix("\n") { text.removeLast() }
        return PdfPageLayout(text: text, lines: lines)
    }

    /// Vision OCR fallback for scanned pages. Boxes come back normalised to the rendered image
    /// (top-left origin) and are mapped into PDF page space via the crop box. Rotated pages may
    /// be slightly off; the text is still read correctly.
    private nonisolated static func ocrLayout(page: PDFPage) -> PdfPageLayout? {
        guard let cg = TextExtractor.renderPage(page, targetWidth: 2048),
              let layout = try? TextExtractor.recognizeLayout(cgImage: cg) else { return nil }
        let crop = page.bounds(for: .cropBox)
        let lines = layout.lines.map { line in
            PdfLine(
                start: line.start, end: line.end,
                bounds: CGRect(
                    x: crop.minX + line.left * crop.width,
                    y: crop.minY + (1 - line.bottom) * crop.height,
                    width: (line.right - line.left) * crop.width,
                    height: (line.bottom - line.top) * crop.height
                )
            )
        }
        return PdfPageLayout(text: layout.text, lines: lines)
    }
}

/// Full-screen, in-app PDF **reader**: shows the real pages (swipe between them, pinch to zoom)
/// and reads them aloud, marking the spoken line right on the page. Each page is read as a unit;
/// when one finishes, the reader turns to the next page and keeps going. Tap a line to read
/// from there.
struct PdfViewerScreen: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vm: ReaderViewModel
    @ObservedObject var speech: SpeechController

    @State private var session: PdfReadSession?
    @State private var sessionFailed = false
    @State private var pageIndex = 0
    /// The page whose text is loaded in the speech engine (-1 when idle); only it shows the highlight.
    @State private var readingPage = -1
    /// True while a page's text/boxes are being prepared (text layer is instant; OCR takes a moment).
    @State private var preparing = false
    @State private var showVoiceSheet = false

    private var playback: SpeechController.Playback { speech.playback }
    private var speaking: Bool { playback.state == .speaking }
    private var active: Bool { speaking || playback.state == .paused }
    private var playable: Bool { playback.state != .initializing && playback.state != .failed }
    private var ours: Bool { playback.sourceId == ReaderViewModel.sourcePdf }

    var body: some View {
        VStack(spacing: 0) {
            topBar

            if let session {
                ZStack(alignment: .bottom) {
                    PdfKitView(
                        document: session.document,
                        pageIndex: $pageIndex,
                        highlight: currentHighlight(session: session),
                        backgroundColor: UIColor(theme.surfaceVariant),
                        onTapLine: { index, point in handleTap(session: session, page: index, point: point) }
                    )
                    Text("\(pageIndex + 1) / \(session.pageCount)")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(theme.onSurface)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(theme.surfaceContainerHigh.opacity(0.9)))
                        .padding(.bottom, 14)
                }
            } else if sessionFailed {
                Text("Couldn't open this PDF.")
                    .font(.subheadline)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            PlayerBar(
                status: preparing ? "Preparing page…" : statusText(doc: vm.doc, playback: playback),
                busy: vm.doc.busy || preparing,
                speaking: speaking, active: active, playable: playable,
                onStop: { vm.stopClicked() },
                onPrev: { speech.skipPrevious() },
                onNext: { speech.skipNext() },
                onPlayPause: {
                    switch playback.state {
                    case .speaking: speech.pause()
                    case .paused: speech.resume()
                    default: Task { await startReading(from: pageIndex) }
                    }
                },
                onOpenVoiceSound: { showVoiceSheet = true }
            )
        }
        .background(theme.surface.ignoresSafeArea())
        .task(id: vm.pdf?.url) {
            guard let pdf = vm.pdf else { return }
            session = PdfReadSession(url: pdf.url)
            sessionFailed = session == nil
        }
        // Leave if the document was cleared/replaced on the Read tab.
        .onChange(of: vm.pdf == nil) { _, isGone in
            if isGone { dismiss() }
        }
        // When a page finishes on its own, roll on to the next one.
        .onReceive(speech.completed) { source in
            guard let session, source == ReaderViewModel.sourcePdf,
                  (0..<session.pageCount).contains(readingPage) else { return }
            Task { await startReading(from: readingPage + 1) }
        }
        .sheet(isPresented: $showVoiceSheet) {
            VoiceSoundSheet(speech: speech, isReading: speaking) { speech.restartCurrentChunk() }
                .presentationDetents([.medium, .large])
        }
    }

    private var topBar: some View {
        HStack(spacing: 0) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.backward")
                    .foregroundStyle(theme.onSurface)
                    .frame(width: 44, height: 44)
            }
            Text(vm.pdf?.name ?? "Document")
                .font(.headline)
                .foregroundStyle(theme.onSurface)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !vm.editorText.isEmpty {
                ShareLink(item: vm.editorText) {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(theme.onSurfaceVariant)
                        .frame(width: 44, height: 44)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    /// The spoken line's box, only on the page being read (annotation-based highlight).
    private func currentHighlight(session: PdfReadSession) -> PdfHighlight? {
        guard ours, playback.highlightStart >= 0, readingPage >= 0,
              let layout = session.layouts[readingPage],
              let line = layout.lines.first(where: {
                  playback.highlightStart >= $0.start && playback.highlightStart < $0.end
              }) else { return nil }
        return PdfHighlight(pageIndex: readingPage, bounds: line.bounds)
    }

    /// Reads from page `start` onward, skipping blank pages, scrolling the pager to follow.
    private func startReading(from start: Int) async {
        guard let session else { return }
        preparing = true
        defer { preparing = false }
        var p = max(start, 0)
        while p < session.pageCount {
            let layout = await session.layout(for: p)
            if !layout.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                readingPage = p
                pageIndex = p
                vm.pdfReadPage(layout.text)
                return
            }
            p += 1
        }
    }

    private func handleTap(session: PdfReadSession, page: Int, point: CGPoint) {
        Task {
            let layout = await session.layout(for: page)
            if let line = layout.lines.first(where: { $0.bounds.contains(point) }) {
                readingPage = page
                vm.pdfReadPage(layout.text, startOffset: line.start)
            }
        }
    }
}

nonisolated struct PdfHighlight: Equatable {
    let pageIndex: Int
    let bounds: CGRect
}

/// PDFKit's PDFView wrapped for SwiftUI: single-page swipe paging, pinch zoom, page-change
/// tracking, tap-to-page-point mapping, and the amber line highlight as a PDF annotation.
private struct PdfKitView: UIViewRepresentable {
    let document: PDFDocument
    @Binding var pageIndex: Int
    let highlight: PdfHighlight?
    let backgroundColor: UIColor
    let onTapLine: (Int, CGPoint) -> Void

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePage
        view.displayDirection = .horizontal
        view.usePageViewController(true, withViewOptions: [UIPageViewController.OptionsKey.interPageSpacing: 14])
        view.backgroundColor = backgroundColor
        context.coordinator.pdfView = view

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.onTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged),
            name: .PDFViewPageChanged,
            object: view
        )
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        if let page = view.currentPage, document.index(for: page) != pageIndex,
           let target = document.page(at: pageIndex) {
            view.go(to: target)
        }
        coordinator.applyHighlight(highlight, document: document)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PdfKitView
        weak var pdfView: PDFView?
        private var annotation: (PDFAnnotation, PDFPage)?
        private var appliedHighlight: PdfHighlight?

        init(_ parent: PdfKitView) { self.parent = parent }

        @objc func pageChanged() {
            guard let pdfView, let page = pdfView.currentPage,
                  let document = pdfView.document else { return }
            let index = document.index(for: page)
            if parent.pageIndex != index {
                Task { @MainActor in self.parent.pageIndex = index }
            }
        }

        @objc func onTap(_ gesture: UITapGestureRecognizer) {
            guard let pdfView, let document = pdfView.document else { return }
            let point = gesture.location(in: pdfView)
            guard let page = pdfView.page(for: point, nearest: false) else { return }
            let pagePoint = pdfView.convert(point, to: page)
            parent.onTapLine(document.index(for: page), pagePoint)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }

        func applyHighlight(_ highlight: PdfHighlight?, document: PDFDocument) {
            guard appliedHighlight != highlight else { return }
            appliedHighlight = highlight
            if let (old, page) = annotation {
                page.removeAnnotation(old)
                annotation = nil
            }
            if let highlight, let page = document.page(at: highlight.pageIndex) {
                let box = highlight.bounds.insetBy(dx: -2, dy: -2)
                let mark = PDFAnnotation(bounds: box, forType: .highlight, withProperties: nil)
                mark.color = highlightUIColor
                page.addAnnotation(mark)
                annotation = (mark, page)
            }
        }
    }
}
