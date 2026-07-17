import AVFoundation
import SwiftUI

/// The status line under the player, mirroring the Android `statusText`.
func statusText(doc: ReaderViewModel.DocState, playback: SpeechController.Playback) -> String {
    if doc.busy { return doc.status ?? "Extracting text…" }
    switch playback.state {
    case .speaking: return "Reading sentence \(playback.chunkIndex + 1) of \(playback.chunkCount)"
    case .paused: return "Paused - sentence \(playback.chunkIndex + 1) of \(playback.chunkCount)"
    default: break
    }
    if let message = playback.message { return message }
    if let status = doc.status { return status }
    if playback.state == .initializing { return "Starting the speech engine…" }
    return "Ready. Everything runs on your phone - no internet."
}

/// The big round play/pause button used by all readers.
struct PlayPauseButton: View {
    @Environment(\.theme) private var theme
    let isSpeaking: Bool
    let enabled: Bool
    let onClick: () -> Void
    var size: CGFloat = 64

    var body: some View {
        Button(action: onClick) {
            ZStack {
                Circle().fill(enabled ? theme.primary : theme.surfaceVariant)
                Image(systemName: isSpeaking ? "pause.fill" : "play.fill")
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(enabled ? theme.onPrimary : theme.onSurfaceVariant.opacity(0.5))
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(isSpeaking ? "Pause" : "Play")
        .accessibilityIdentifier("playPause")
    }
}

/// Compact bottom player: a status line, the transport buttons, and the slide-up
/// "Voice & sound" opener - shared by the Read tab, the photo reader and the PDF reader.
struct PlayerBar: View {
    @Environment(\.theme) private var theme
    let status: String
    let busy: Bool
    let speaking: Bool
    let active: Bool
    let playable: Bool
    let onStop: () -> Void
    let onPrev: () -> Void
    let onNext: () -> Void
    let onPlayPause: () -> Void
    let onOpenVoiceSound: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 8) {
                if busy {
                    ProgressView().scaleEffect(0.7)
                }
                Text(status)
                    .font(.caption)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("statusText")
                Button(action: onOpenVoiceSound) {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3").font(.footnote)
                        Text("Voice & sound").font(.footnote.weight(.medium))
                        Image(systemName: "chevron.up").font(.caption2)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(theme.secondaryContainer))
                    .foregroundStyle(theme.onSecondaryContainer)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 6)

            HStack {
                Spacer()
                TransportButton(systemName: "stop.fill", enabled: active, action: onStop)
                    .accessibilityLabel("Stop")
                Spacer()
                TransportButton(systemName: "backward.end.fill", enabled: active, action: onPrev)
                    .accessibilityLabel("Previous sentence")
                Spacer()
                PlayPauseButton(isSpeaking: speaking, enabled: playable, onClick: onPlayPause)
                Spacer()
                TransportButton(systemName: "forward.end.fill", enabled: active, action: onNext)
                    .accessibilityLabel("Next sentence")
                Spacer()
            }
            .padding(.vertical, 4)
        }
        .frame(maxWidth: 700)          // keeps the controls together on iPad
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28)
                .fill(theme.surfaceContainerHigh)
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

struct TransportButton: View {
    @Environment(\.theme) private var theme
    let systemName: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 20))
                .foregroundStyle(enabled ? theme.onSurfaceVariant : theme.onSurfaceVariant.opacity(0.35))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// The "Voice & sound" panel shown inside a slide-up sheet on all readers: a two-step voice
/// picker (language → voice) plus the speed/tone/volume sliders, and quick access to the
/// reading direction and color scheme.
struct VoiceSoundSheet: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var speech: SpeechController
    let isReading: Bool
    let onRelease: () -> Void

    @State private var rate: Float = 1
    @State private var pitch: Float = 1
    @State private var volume: Float = 0.9
    @State private var selectedLang: String = ""
    @State private var showVoiceHelp = false
    @State private var showAllVoices = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Voice & sound")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.onSurface)
                Text("Pick a voice and adjust the speed, tone and volume")
                    .font(.caption)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .padding(.top, 2)
                    .padding(.bottom, 18)

                sectionLabel("Voice")
                voicePicker
                    .padding(.top, 8)

                sectionLabel("Reading").padding(.top, 22)
                Text("Direction")
                    .font(.caption)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                ReadingDirectionChips(direction: settings.readingDirection) { settings.readingDirection = $0 }

                Text("Color")
                    .font(.caption)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .padding(.top, 16)
                    .padding(.bottom, 6)
                ColorThemeChips(theme: settings.theme) { settings.theme = $0 }

                sectionLabel("Sound").padding(.top, 22).padding(.bottom, 4)
                SpeechSliders(
                    rate: $rate, pitch: $pitch, volume: $volume,
                    onRate: { speech.setRate($0) },
                    onPitch: { speech.setPitch($0) },
                    onVolume: { speech.setVolume($0) },
                    onRelease: onRelease
                )
                .padding(.top, 10)

                Divider().padding(.top, 16)
                Button {
                    showVoiceHelp = true
                } label: {
                    Label("Download new voices", systemImage: "arrow.down.circle")
                        .font(.footnote)
                }
                .padding(.top, 10)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 28)
        }
        .background(theme.surfaceContainerLow)
        .onAppear {
            rate = speech.rate
            pitch = speech.pitch
            volume = speech.volume
            selectedLang = primaryLanguage(of: speech.selectedVoice) ?? languages.first ?? ""
        }
        .alert("Download new voices", isPresented: $showVoiceHelp) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Higher-quality voices can be downloaded in the Settings app:\n\nSettings → Accessibility → Spoken Content → Voices.\n\nAfter downloading, come back here - the new voice appears automatically.")
        }
    }

    private var languages: [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for voice in speech.voices {
            let lang = primaryLanguage(of: voice) ?? voice.language
            if seen.insert(lang).inserted { out.append(lang) }
        }
        return out
    }

    private func primaryLanguage(of voice: AVSpeechSynthesisVoice?) -> String? {
        guard let voice else { return nil }
        return voice.language.split(separator: "-").first.map(String.init)?.lowercased()
    }

    @ViewBuilder
    private var voicePicker: some View {
        if speech.voices.isEmpty {
            Text("No voices yet - add one in Settings → Accessibility → Spoken Content.")
                .font(.subheadline)
                .foregroundStyle(theme.onSurfaceVariant)
        } else {
            let allForLang = VoiceCatalog.friendlyList(
                for: speech.voices.filter { primaryLanguage(of: $0) == selectedLang }
            )
            let main = VoiceCatalog.mainList(allForLang)
            let shown = showAllVoices ? allForLang : main
            VStack(spacing: 10) {
                if languages.count > 1 {
                    dropdownRow(label: "Language", selection: SpeechController.displayLanguage(selectedLang)) {
                        ForEach(languages, id: \.self) { lang in
                            Button(SpeechController.displayLanguage(lang)) {
                                selectedLang = lang
                                showAllVoices = false
                            }
                        }
                    }
                }

                VStack(spacing: 0) {
                    ForEach(shown) { item in
                        voiceRow(item)
                        if item.id != shown.last?.id {
                            Divider().padding(.leading, 48)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(theme.surfaceContainerHigh))

                if allForLang.count > main.count {
                    Button {
                        withAnimation(theme.eInk ? nil : .easeInOut(duration: 0.2)) {
                            showAllVoices.toggle()
                        }
                    } label: {
                        Label(
                            showAllVoices ? "Show main voices" : "More voices (\(allForLang.count))",
                            systemImage: showAllVoices ? "chevron.up" : "plus.circle"
                        )
                        .font(.footnote.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background(Capsule().fill(theme.secondaryContainer))
                        .foregroundStyle(theme.onSecondaryContainer)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("moreVoices")
                }

                Text("Tap a voice to hear it.")
                    .font(.caption2)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// One selectable voice row: radio mark, friendly label, HD tag; tapping selects the voice
    /// and speaks a short sample (or switches the live reading to it).
    private func voiceRow(_ item: FriendlyVoice) -> some View {
        let selected = speech.selectedVoiceId.map { $0 == item.id }
            ?? (speech.selectedVoice?.identifier == item.voice.identifier && item.presetSlug == nil)
        return Button {
            speech.selectVoice(item)
            speech.previewSelected()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(selected ? theme.primary : theme.outline)
                Text(item.label)
                    .font(.body)
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if item.voice.quality != .default {
                    Text("HD")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(theme.tertiary.opacity(0.15)))
                        .foregroundStyle(theme.tertiary)
                }
                Image(systemName: "speaker.wave.2")
                    .font(.caption)
                    .foregroundStyle(theme.onSurfaceVariant)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("voiceRow")
        .accessibilityLabel(item.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func dropdownRow<Content: View>(
        label: String, selection: String, @ViewBuilder content: () -> Content
    ) -> some View {
        Menu {
            content()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(theme.onSurfaceVariant)
                HStack {
                    Text(selection.isEmpty ? "—" : selection)
                        .font(.body)
                        .foregroundStyle(theme.onSurface)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(theme.onSurfaceVariant)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(theme.outline, lineWidth: 1)
            )
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(theme.onSurfaceVariant)
    }
}

/// Auto / LTR / RTL reading-direction chips, shared by the sheet and Settings.
struct ReadingDirectionChips: View {
    let direction: ReadingDirection
    let onPick: (ReadingDirection) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ReadingDirection.allCases, id: \.self) { choice in
                FilterChip(
                    label: label(choice),
                    selected: direction == choice,
                    onTap: { onPick(choice) }
                )
            }
        }
    }

    private func label(_ choice: ReadingDirection) -> String {
        switch choice {
        case .auto: return "Auto"
        case .ltr: return "LTR"
        case .rtl: return "RTL"
        }
    }
}

/// Reading color-scheme chips, each with a little swatch - shared by the sheet and Settings.
struct ColorThemeChips: View {
    let theme: ThemeChoice
    let onPick: (ThemeChoice) -> Void

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(ThemeChoice.allCases, id: \.self) { choice in
                FilterChip(
                    label: label(choice),
                    selected: theme == choice,
                    swatch: swatch(choice),
                    onTap: { onPick(choice) }
                )
            }
        }
    }

    private func label(_ choice: ThemeChoice) -> String {
        switch choice {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        case .sepia: return "Sepia"
        case .mono: return "Black & white"
        }
    }

    private func swatch(_ choice: ThemeChoice) -> AnyView {
        let border = Color.gray.opacity(0.6)
        switch choice {
        case .system: return AnyView(TwoToneSwatch(left: Color(argb: 0xFFFBF8FF), right: Color(argb: 0xFF121318), border: border))
        case .light: return AnyView(SolidSwatch(color: Color(argb: 0xFFFBF8FF), border: border))
        case .dark: return AnyView(SolidSwatch(color: Color(argb: 0xFF121318), border: border))
        case .sepia: return AnyView(SolidSwatch(color: Color(argb: 0xFFF4ECD8), border: border))
        case .mono: return AnyView(TwoToneSwatch(left: .white, right: .black, border: border))
        }
    }
}

struct SolidSwatch: View {
    let color: Color
    let border: Color
    var body: some View {
        Circle().fill(color)
            .overlay(Circle().stroke(border, lineWidth: 1))
            .frame(width: 14, height: 14)
    }
}

struct TwoToneSwatch: View {
    let left: Color
    let right: Color
    let border: Color
    var body: some View {
        HStack(spacing: 0) {
            left
            right
        }
        .frame(width: 14, height: 14)
        .clipShape(Circle())
        .overlay(Circle().stroke(border, lineWidth: 1))
    }
}

struct FilterChip: View {
    @Environment(\.theme) private var theme
    let label: String
    let selected: Bool
    var swatch: AnyView? = nil
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                if let swatch { swatch }
                if selected {
                    Image(systemName: "checkmark").font(.caption2.weight(.bold))
                }
                Text(label).font(.footnote.weight(.medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(selected ? theme.secondaryContainer : Color.clear)
            )
            .overlay(
                Capsule().stroke(selected ? Color.clear : theme.outlineVariant, lineWidth: 1)
            )
            .foregroundStyle(selected ? theme.onSecondaryContainer : theme.onSurfaceVariant)
        }
        .buttonStyle(.plain)
    }
}

/// Speed / Tone / Volume sliders. `onRelease` is called when the user lifts a thumb.
struct SpeechSliders: View {
    @Binding var rate: Float
    @Binding var pitch: Float
    @Binding var volume: Float
    let onRate: (Float) -> Void
    let onPitch: (Float) -> Void
    let onVolume: (Float) -> Void
    let onRelease: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            LabeledSlider(
                icon: "speedometer", label: "Speed",
                value: $rate, range: 0.5...2.5,
                valueText: String(format: "×%.2f", rate),
                onChange: onRate, onRelease: onRelease
            )
            LabeledSlider(
                icon: "waveform", label: "Tone",
                value: $pitch, range: 0.5...2.0,
                valueText: String(format: "×%.2f", pitch),
                onChange: onPitch, onRelease: onRelease
            )
            LabeledSlider(
                icon: "speaker.wave.2.fill", label: "Volume",
                value: $volume, range: 0...1,
                valueText: "\(Int(volume * 100))%",
                onChange: onVolume, onRelease: onRelease
            )
        }
    }
}

struct LabeledSlider: View {
    @Environment(\.theme) private var theme
    let icon: String
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let valueText: String
    let onChange: (Float) -> Void
    let onRelease: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(theme.primary)
                .frame(width: 24)
            VStack(spacing: 0) {
                HStack {
                    Text(label)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(theme.onSurface)
                    Spacer()
                    Text(valueText)
                        .font(.caption)
                        .foregroundStyle(theme.onSurfaceVariant)
                }
                Slider(
                    value: Binding(
                        get: { value },
                        set: { value = $0; onChange($0) }
                    ),
                    in: range,
                    onEditingChanged: { editing in
                        if !editing { onRelease() }
                    }
                )
                .tint(theme.primary)
            }
        }
    }
}

/// A simple wrapping layout for the chips row.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
