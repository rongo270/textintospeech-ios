import SwiftUI
import UIKit

/// Full-screen, immersive reader for a photo - like a translate-app image view, but with our
/// player: tap any line on the picture to read from there, watch each line light up as it's
/// spoken, change voice/speed, and flip to a read-along **Text** view. Editing OCR mistakes
/// happens back on the Read tab (which holds the same text); this screen is for reading.
struct PhotoReaderScreen: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var vm: ReaderViewModel
    @ObservedObject var speech: SpeechController

    @State private var photoMode = true
    @State private var showVoiceSheet = false

    private var playback: SpeechController.Playback { speech.playback }
    private var speaking: Bool { playback.state == .speaking }
    private var active: Bool { speaking || playback.state == .paused }
    private var playable: Bool { playback.state != .initializing && playback.state != .failed }
    private var ours: Bool { playback.sourceId == ReaderViewModel.sourceRead }

    var body: some View {
        let text = vm.editorText
        let highlightStart = ours ? playback.highlightStart : -1
        let highlightEnd = ours ? playback.highlightEnd : -1

        VStack(spacing: 0) {
            topBar(text: text)

            viewToggle
                .padding(.horizontal, 12)
                .padding(.vertical, 4)

            if photoMode && !speaking {
                Text("Tap a line to read from there")
                    .font(.caption)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 2)
            }

            Group {
                if let photo = vm.photo {
                    if photoMode {
                        PhotoCanvas(
                            photo: photo,
                            highlightStart: highlightStart,
                            onTapLine: { offset in vm.readFrom(offset: offset, text: text) }
                        )
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    } else {
                        ReadOnlyHighlightText(
                            text: text,
                            highlight: highlightStart >= 0 && highlightEnd > highlightStart
                                ? NSRange(location: highlightStart, length: highlightEnd - highlightStart)
                                : nil,
                            fontSize: 17 * settings.textScale,
                            rtl: isRtlText(text),
                            textColor: UIColor(theme.onSurface),
                            scrollEnabled: true,
                            autoScrollToHighlight: true
                        )
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 24).fill(theme.surfaceContainerLow))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)

            PlayerBar(
                status: statusText(doc: vm.doc, playback: playback),
                busy: vm.doc.busy,
                speaking: speaking, active: active, playable: playable,
                onStop: { vm.stopClicked() },
                onPrev: { speech.skipPrevious() },
                onNext: { speech.skipNext() },
                onPlayPause: { vm.playPauseClicked(currentText: text) },
                onOpenVoiceSound: { showVoiceSheet = true }
            )
        }
        .background(theme.surface.ignoresSafeArea())
        // The photo is dropped when the text is hand-edited on the Read tab; leave if that happens.
        .onChange(of: vm.photo == nil) { _, isGone in
            if isGone { dismiss() }
        }
        .sheet(isPresented: $showVoiceSheet) {
            VoiceSoundSheet(speech: speech, isReading: speaking) { speech.restartCurrentChunk() }
                .presentationDetents([.medium, .large])
        }
    }

    private func topBar(text: String) -> some View {
        HStack(spacing: 0) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.backward")
                    .foregroundStyle(theme.onSurface)
                    .frame(width: 44, height: 44)
            }
            Text("Photo")
                .font(.headline)
                .foregroundStyle(theme.onSurface)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !text.isEmpty {
                ShareLink(item: text) {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(theme.onSurfaceVariant)
                        .frame(width: 44, height: 44)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private var viewToggle: some View {
        HStack(spacing: 8) {
            toggleChip("Photo", systemImage: "photo", selected: photoMode) { photoMode = true }
            toggleChip("Text", systemImage: "text.alignleft", selected: !photoMode) { photoMode = false }
        }
    }

    private func toggleChip(_ label: String, systemImage: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.footnote)
                Text(label).font(.footnote.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(Capsule().fill(selected ? theme.primary : theme.surfaceContainerHigh))
            .foregroundStyle(selected ? theme.onPrimary : theme.onSurfaceVariant)
        }
        .buttonStyle(.plain)
    }
}

/// The picture, filling the area, with the line currently being read lit up (mapped from the
/// reader's character position onto the saved line boxes). Tapping a line reads from there.
private struct PhotoCanvas: View {
    @Environment(\.theme) private var theme
    let photo: ReaderViewModel.PhotoDoc
    let highlightStart: Int
    let onTapLine: (Int) -> Void

    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 24).fill(theme.surfaceContainerLow)
                if let image {
                    let rect = fitRect(
                        container: CGSize(width: geo.size.width - 16, height: geo.size.height - 16),
                        width: image.size.width, height: image.size.height
                    ).offsetBy(dx: 8, dy: 8)

                    Image(uiImage: image)
                        .resizable()
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)

                    if highlightStart >= 0,
                       let line = photo.lines.first(where: { highlightStart >= $0.start && highlightStart < $0.end }) {
                        let box = lineRect(line, in: rect).insetBy(dx: -3, dy: -3)
                        RoundedRectangle(cornerRadius: 6)
                            .fill(theme.primary.opacity(0.28))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.primary, lineWidth: 2))
                            .frame(width: box.width, height: box.height)
                            .position(x: box.midX, y: box.midY)
                    }

                    // Invisible tap layer that maps a touch to the OCR line under it.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .local) { point in
                            if let line = photo.lines.first(where: { lineRect($0, in: rect).contains(point) }) {
                                onTapLine(line.start)
                            }
                        }
                } else {
                    ProgressView()
                }
            }
        }
        .task(id: photo.url) {
            image = await Task.detached(priority: .userInitiated) {
                UIImage(contentsOfFile: photo.url.path)?.normalizedOrientation()
            }.value
        }
    }
}

/// Maps a normalised OCR line box into on-screen coordinates within `imageRect`.
func lineRect(_ line: OcrLine, in imageRect: CGRect) -> CGRect {
    CGRect(
        x: imageRect.minX + line.left * imageRect.width,
        y: imageRect.minY + line.top * imageRect.height,
        width: (line.right - line.left) * imageRect.width,
        height: (line.bottom - line.top) * imageRect.height
    )
}
