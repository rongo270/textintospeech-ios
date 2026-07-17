import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The **Read** tab: type/paste text, open a file, or scan a picture - then listen, with the
/// spoken sentence highlighted live in the editor.
struct ReadScreen: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var vm: ReaderViewModel
    @ObservedObject var speech: SpeechController
    let onOpenSettings: () -> Void
    let onOpenPdf: () -> Void

    /// Edit: normal typing. Read: typing off, tap a line to read from it.
    private enum EditorMode { case edit, read }

    @State private var localText = ""
    @State private var mode: EditorMode = .edit
    @State private var showVoiceSheet = false
    @State private var showFileImporter = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var cropImage: UIImage?
    @State private var keyboardVisible = false

    private var playback: SpeechController.Playback { speech.playback }
    private var speaking: Bool { playback.state == .speaking }
    private var active: Bool { speaking || playback.state == .paused }
    private var playable: Bool { playback.state != .initializing && playback.state != .failed }
    private var ours: Bool { playback.sourceId == ReaderViewModel.sourceRead }

    private var editorRtl: Bool {
        switch vm.readingDir {
        case .rtl: return true
        case .ltr: return false
        case .auto:
            switch settings.readingDirection {
            case .rtl: return true
            case .ltr: return false
            case .auto: return isRtlText(localText)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                header
                sourceButtons
                    .padding(.top, 6)

                if vm.photo != nil {
                    fullWidthButton("Open photo view", systemImage: "photo") { vm.requestPhotoReader() }
                        .padding(.top, 10)
                }
                if vm.pdf != nil {
                    fullWidthButton("Read on the page", systemImage: "doc.richtext") { onOpenPdf() }
                        .padding(.top, 10)
                }

                editorCard
                    .padding(.top, 12)
            }
            .frame(maxWidth: 700)   // keeps reading comfortable on iPad

            if !keyboardVisible {
                PlayerBar(
                    status: statusText(doc: vm.doc, playback: playback),
                    busy: vm.doc.busy,
                    speaking: speaking, active: active, playable: playable,
                    onStop: { vm.stopClicked() },
                    onPrev: { speech.skipPrevious() },
                    onNext: { speech.skipNext() },
                    onPlayPause: {
                        dismissKeyboard()
                        vm.playPauseClicked(currentText: localText)
                    },
                    onOpenVoiceSound: { showVoiceSheet = true }
                )
                .padding(.horizontal, -12)
            }
        }
        .padding(.horizontal, 12)
        .background(theme.surface.ignoresSafeArea())
        .onAppear { localText = vm.editorText }
        .onChange(of: vm.doc.version) { _, _ in
            localText = vm.editorText
            if localText.isEmpty { mode = .edit }
        }
        // Pressing play flips the editor into Read mode, so a tap jumps the reading around
        // instead of opening the keyboard.
        .onChange(of: playback.state) { _, state in
            if state == .speaking && ours { mode = .read }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(theme.eInk ? nil : .easeOut(duration: 0.2)) { keyboardVisible = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(theme.eInk ? nil : .easeOut(duration: 0.2)) { keyboardVisible = false }
        }
        .sheet(isPresented: $showVoiceSheet) {
            VoiceSoundSheet(speech: speech, isReading: speaking) { speech.restartCurrentChunk() }
                .presentationDetents([.medium, .large])
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: Self.openableTypes) { result in
            if case .success(let url) = result { vm.openDocument(pickedURL: url) }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    cropImage = image
                }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                showCamera = false
                if let image { cropImage = image }
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: Binding(get: { cropImage != nil }, set: { if !$0 { cropImage = nil } })) {
            if let image = cropImage {
                CropScreen(
                    image: image,
                    onCancel: { cropImage = nil },
                    onCropped: { cropped in
                        cropImage = nil
                        if let url = try? cropped.savedToCaches() {
                            vm.openPhoto(localURL: url)
                        }
                    }
                )
            }
        }
        .alert(
            "Welcome to Read Aloud",
            isPresented: Binding(get: { !settings.welcomeShown }, set: { if !$0 { settings.welcomeShown = true } })
        ) {
            Button("Got it") { settings.welcomeShown = true }
        } message: {
            Text("Three ways to begin:\n\n📄  File - open a PDF, Word, text or EPUB\n🖼️  Image or Camera - scan a picture\n⌨️  Or just type or paste your text\n\nThen press play. Everything runs on your phone - no internet needed.")
        }
        .alert(
            "One-time voice download",
            isPresented: Binding(get: { settings.welcomeShown && vm.voiceSetup != nil }, set: { if !$0 { vm.voiceSetupShown() } })
        ) {
            Button("OK") { vm.voiceSetupShown() }
        } message: {
            let langs = (vm.voiceSetup ?? []).map { SpeechController.displayLanguage($0) }.joined(separator: " · ")
            Text("To read aloud, your phone needs voices for: \(langs).\n\nDownload them once in Settings → Accessibility → Spoken Content → Voices. This app itself never connects to the internet.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(theme.primaryContainer)
                Image(systemName: "person.wave.2.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(theme.onPrimaryContainer)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 1) {
                Text("Read Aloud")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.primary)
                HStack(spacing: 4) {
                    Image(systemName: "icloud.slash")
                        .font(.caption2)
                        .foregroundStyle(theme.tertiary)
                    Text("Works fully offline - nothing leaves your phone")
                        .font(.caption)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !localText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ShareLink(item: localText) {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(theme.primary)
                        .frame(width: 40, height: 40)
                }
            }
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .foregroundStyle(theme.onSurfaceVariant)
                    .frame(width: 40, height: 40)
            }
        }
        .padding(.top, 8)
    }

    private var sourceButtons: some View {
        HStack(spacing: 8) {
            sourceButton("File", systemImage: "folder") { showFileImporter = true }
            sourceButton("Image", systemImage: "photo") { showPhotoPicker = true }
            sourceButton("Camera", systemImage: "camera") { showCamera = true }
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
        }
    }

    @State private var showPhotoPicker = false

    private func sourceButton(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.subheadline)
                Text(label).font(.subheadline.weight(.medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(RoundedRectangle(cornerRadius: 14).fill(theme.secondaryContainer))
            .foregroundStyle(theme.onSecondaryContainer)
        }
        .buttonStyle(.plain)
    }

    private func fullWidthButton(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.subheadline)
                Text(label).font(.subheadline.weight(.medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 14).fill(theme.secondaryContainer))
            .foregroundStyle(theme.onSecondaryContainer)
        }
        .buttonStyle(.plain)
    }

    private var editorCard: some View {
        VStack(spacing: 0) {
            if !localText.isEmpty {
                HStack(spacing: 6) {
                    modeToggle
                    Spacer()
                    editorToolButton(systemImage: editorRtl ? "text.alignright" : "text.alignleft") {
                        vm.setReadingDirection(editorRtl ? .ltr : .rtl)
                    }
                    editorToolButton(systemImage: "xmark") {
                        localText = ""
                        mode = .edit
                        vm.clear()
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)

                if mode == .read {
                    Text("Tap any line to read from there")
                        .font(.caption2)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 17)
                        .padding(.top, 6)
                }
            }
            ZStack(alignment: .topLeading) {
                HighlightTextEditor(
                    initialText: vm.editorText,
                    version: vm.doc.version,
                    highlight: ours && playback.highlightStart >= 0
                        ? NSRange(location: playback.highlightStart, length: max(playback.highlightEnd - playback.highlightStart, 0))
                        : nil,
                    fontSize: 17 * settings.textScale,
                    rtl: editorRtl,
                    textColor: UIColor(theme.onSurface),
                    followHighlight: speaking && ours,
                    editable: mode == .edit,
                    onTapLine: { offset in
                        vm.readFrom(offset: offset, text: localText)
                    },
                    onTextChanged: { text in
                        localText = text
                        vm.onEditorChanged(text)
                    }
                )
                if localText.isEmpty {
                    Text("Type or paste text here…")
                        .font(.system(size: 17 * settings.textScale))
                        .foregroundStyle(theme.outline)
                        .padding(.horizontal, 17)
                        .padding(.top, 14)
                        .allowsHitTesting(false)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 24).fill(theme.surfaceContainerLow))
        .frame(maxHeight: .infinity)
    }

    /// The Edit / Read switch on the text card.
    private var modeToggle: some View {
        HStack(spacing: 2) {
            modeChip("Edit", systemImage: "pencil", value: .edit)
            modeChip("Read", systemImage: "headphones", value: .read)
        }
        .padding(2)
        .background(Capsule().fill(theme.surfaceContainerHigh))
    }

    private func modeChip(_ label: String, systemImage: String, value: EditorMode) -> some View {
        let selected = mode == value
        return Button {
            if value == .read { dismissKeyboard() }
            mode = value
        } label: {
            HStack(spacing: 4) {
                Image(systemName: systemImage).font(.caption2)
                Text(label).font(.footnote.weight(.medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(selected ? theme.secondaryContainer : Color.clear))
            .foregroundStyle(selected ? theme.onSecondaryContainer : theme.onSurfaceVariant)
        }
        .buttonStyle(.plain)
    }

    private func editorToolButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.onSecondaryContainer)
                .frame(width: 34, height: 34)
                .background(Circle().fill(theme.secondaryContainer))
        }
        .buttonStyle(.plain)
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    static let openableTypes: [UTType] = {
        var types: [UTType] = [.pdf, .epub, .rtf, .plainText, .utf8PlainText, .html, .text, .image]
        if let docx = UTType(filenameExtension: "docx") { types.append(docx) }
        if let md = UTType(filenameExtension: "md") { types.append(md) }
        return types
    }()
}
