import AVFoundation
import Combine
import Foundation
import NaturalLanguage

/// Wraps the on-device speech synthesizer (AVSpeechSynthesizer) - the iOS port of the Android
/// SpeechController.
///
/// Only installed (offline) voices are exposed, so speech always works with no internet. Text is
/// split into sentence chunks, which gives pause/resume, progress reporting and live highlighting
/// (word-precise via `willSpeakRangeOfSpeechString`). All character offsets are UTF-16, matching
/// what NSAttributedString/UITextView use, so highlights line up exactly.
@MainActor
final class SpeechController: NSObject, ObservableObject {

    enum State { case initializing, ready, speaking, paused, failed }

    struct Playback: Equatable {
        var state: State = .initializing
        var chunkIndex = 0
        var chunkCount = 0
        var highlightStart = -1
        var highlightEnd = -1
        var message: String? = nil
        /// Identifies who started the current reading, so each screen only shows its own highlight.
        var sourceId: String? = nil
    }

    nonisolated struct Chunk: Sendable { let start: Int; let end: Int }   // UTF-16 offsets

    @Published private(set) var playback = Playback()
    @Published private(set) var voices: [AVSpeechSynthesisVoice] = []
    @Published private(set) var selectedVoice: AVSpeechSynthesisVoice?

    /// Emits the source id of a reading that finished on its own (used to auto-advance chapters/pages).
    let completed = PassthroughSubject<String?, Never>()

    /// Speed multiplier the user sees (x0.5...x2.5); mapped onto AVSpeechUtterance.rate.
    private(set) var rate: Float = 1
    private(set) var pitch: Float = 1
    private(set) var volume: Float = 0.9

    private let synth = AVSpeechSynthesizer()
    private let previewSynth = AVSpeechSynthesizer()
    private var fullText: NSString = ""
    private var chunks: [Chunk] = []
    private var currentChunk = 0
    private var sourceId: String?
    private var currentUtterance: AVSpeechUtterance?
    /// Set when a seek/skip happens while paused: resume must restart instead of continuing.
    private var pausedNeedsRestart = false

    private let defaults = UserDefaults.standard

    override init() {
        super.init()
        rate = defaults.object(forKey: "rate") as? Float ?? 1
        pitch = defaults.object(forKey: "pitch") as? Float ?? 1
        volume = defaults.object(forKey: "volume") as? Float ?? 0.9

        synth.delegate = self
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)

        refreshVoices()
        if let saved = defaults.string(forKey: "voice"),
           let match = voices.first(where: { $0.identifier == saved }) {
            selectedVoice = match
        }
        playback.state = .ready

        // A phone call or another app taking over the audio pauses the reading (audio-focus parity).
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init) == .began
            Task { @MainActor in
                if began { self?.pause() }
            }
        }
    }

    // MARK: - Voices

    /// Re-scans the installed voices. Called at init and every time the app comes back to the
    /// foreground, so voices the user just downloaded in the system settings appear immediately.
    func refreshVoices() {
        let installed = AVSpeechSynthesisVoice.speechVoices()
            .filter { voice in
                let traits = voice.voiceTraits
                return !traits.contains(.isNoveltyVoice) && !traits.contains(.isPersonalVoice)
            }
            .sorted { a, b in
                let langA = Self.displayLanguage(a.language)
                let langB = Self.displayLanguage(b.language)
                if langA != langB { return langA < langB }
                if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
                return a.name < b.name
            }
        let changed = installed.map(\.identifier) != voices.map(\.identifier)
        if changed {
            voices = installed
            let selected = selectedVoice
            if selected == nil || !installed.contains(where: { $0.identifier == selected?.identifier }) {
                let preferred = Locale.preferredLanguages.first ?? "en"
                let pick = installed.first { Self.sameLanguage($0.language, preferred) } ?? installed.first
                if let pick { selectVoice(pick) } else { selectedVoice = nil }
            }
        }
        let noVoicesMsg = "No voices are installed. Add one in Settings → Accessibility → Spoken Content → Voices."
        if installed.isEmpty {
            playback.message = noVoicesMsg
        } else if playback.message == noVoicesMsg {
            playback.message = nil
        }
    }

    /// True when a voice for `lang` (BCP-47) is installed.
    func hasVoiceFor(_ lang: String) -> Bool {
        voices.contains { Self.sameLanguage($0.language, lang) }
    }

    func selectVoice(_ voice: AVSpeechSynthesisVoice) {
        selectedVoice = voice
        defaults.set(voice.identifier, forKey: "voice")
        if playback.state == .speaking { restartCurrentChunk() }
    }

    /// Switches to a voice matching `lang` (BCP-47); returns it, or nil when none is installed.
    @discardableResult
    func selectVoiceForLanguage(_ lang: String) -> AVSpeechSynthesisVoice? {
        if let current = selectedVoice, Self.sameLanguage(current.language, lang) { return current }
        guard let match = voices.first(where: { Self.sameLanguage($0.language, lang) }) else { return nil }
        selectVoice(match)
        return match
    }

    func setRate(_ v: Float) { rate = v; defaults.set(v, forKey: "rate") }
    func setPitch(_ v: Float) { pitch = v; defaults.set(v, forKey: "pitch") }
    func setVolume(_ v: Float) { volume = v; defaults.set(v, forKey: "volume") }

    /// Speaks a short sample so the user can hear the currently selected voice. Runs on its own
    /// synthesizer, so it never touches the playback state or highlight; does nothing while a
    /// real reading is in progress.
    func previewSelected() {
        guard let voice = selectedVoice, playback.state != .speaking else { return }
        previewSynth.stopSpeaking(at: .immediate)
        let sample = Self.sameLanguage(voice.language, "he")
            ? "שלום, כך אני נשמע כשאני מקריא לך."
            : "Hi! This is how I sound when I read to you."
        let utterance = AVSpeechUtterance(string: sample)
        apply(to: utterance, voice: voice)
        previewSynth.speak(utterance)
    }

    // MARK: - Playback

    /// Starts reading `text`. `startOffset` is a UTF-16 character index to begin from (used to
    /// resume a book); `source` tags who owns this reading so each screen only renders its own
    /// highlight.
    func speak(_ text: String, startOffset: Int = 0, source: String? = nil) {
        guard playback.state != .initializing, playback.state != .failed else { return }
        cancelCurrent()
        sourceId = source
        fullText = text as NSString
        chunks = Self.split(text)
        if chunks.isEmpty {
            playback = Playback(state: .ready, message: "Nothing to read yet - open a file or type some text first.")
            return
        }
        enqueue(from: chunkForOffset(startOffset))
    }

    /// Index of the sentence chunk containing `offset` (for resume / seeking).
    private func chunkForOffset(_ offset: Int) -> Int {
        guard !chunks.isEmpty else { return 0 }
        if let i = chunks.firstIndex(where: { offset < $0.end }) { return i }
        return chunks.count - 1
    }

    /// Jumps reading to the chunk containing character `offset` (progress-bar seek / tap-a-line).
    func seekTo(_ offset: Int) {
        guard !chunks.isEmpty else { return }
        let target = chunkForOffset(offset)
        switch playback.state {
        case .speaking:
            cancelCurrent()
            enqueue(from: target)
        case .paused:
            currentChunk = target
            pausedNeedsRestart = true
            let c = chunks[target]
            playback.chunkIndex = target
            playback.highlightStart = c.start
            playback.highlightEnd = c.end
        default:
            break
        }
    }

    func pause() {
        guard playback.state == .speaking else { return }
        synth.pauseSpeaking(at: .immediate)
        playback.state = .paused
        playback.highlightStart = -1
        playback.highlightEnd = -1
    }

    func resume() {
        guard playback.state == .paused, !chunks.isEmpty else { return }
        if pausedNeedsRestart || !synth.isPaused {
            pausedNeedsRestart = false
            cancelCurrent()
            enqueue(from: currentChunk)
        } else {
            activateSession()
            synth.continueSpeaking()
            playback.state = .speaking
            let c = chunks[currentChunk]
            playback.highlightStart = c.start
            playback.highlightEnd = c.end
        }
    }

    func stop() {
        cancelCurrent()
        currentChunk = 0
        chunks = []
        fullText = ""
        sourceId = nil
        playback = Playback(state: .ready)
        deactivateSession()
    }

    /// Re-applies rate/pitch/volume/voice from the current sentence onward.
    func restartCurrentChunk() {
        guard playback.state == .speaking else { return }
        cancelCurrent()
        enqueue(from: currentChunk)
    }

    func skipNext() { skip(to: currentChunk + 1) }
    func skipPrevious() { skip(to: currentChunk - 1) }

    private func skip(to index: Int) {
        guard !chunks.isEmpty else { return }
        let target = min(max(index, 0), chunks.count - 1)
        switch playback.state {
        case .speaking:
            cancelCurrent()
            enqueue(from: target)
        case .paused:
            currentChunk = target
            pausedNeedsRestart = true
            let c = chunks[target]
            playback.chunkIndex = target
            playback.highlightStart = c.start
            playback.highlightEnd = c.end
        default:
            break
        }
    }

    // MARK: - Internals

    /// Stops the synthesizer without letting the didCancel callback touch our state.
    private func cancelCurrent() {
        currentUtterance = nil
        synth.stopSpeaking(at: .immediate)
        pausedNeedsRestart = false
    }

    private func enqueue(from index: Int) {
        currentChunk = min(max(index, 0), chunks.count - 1)
        activateSession()
        speakChunk(currentChunk)
        let c = chunks[currentChunk]
        playback = Playback(
            state: .speaking,
            chunkIndex: currentChunk, chunkCount: chunks.count,
            highlightStart: c.start, highlightEnd: c.end,
            message: nil, sourceId: sourceId
        )
    }

    /// Chunks are spoken one at a time: each didFinish starts the next, which keeps skip/seek
    /// instant (only one utterance is ever in flight).
    private func speakChunk(_ index: Int) {
        let c = chunks[index]
        let utterance = AVSpeechUtterance(string: fullText.substring(with: NSRange(location: c.start, length: c.end - c.start)))
        apply(to: utterance, voice: selectedVoice)
        currentUtterance = utterance
        synth.speak(utterance)
    }

    private func apply(to utterance: AVSpeechUtterance, voice: AVSpeechSynthesisVoice?) {
        if let voice { utterance.voice = voice }
        // The user's x-multiplier maps around the platform default rate (0.5 on iOS).
        let mapped = AVSpeechUtteranceDefaultSpeechRate * rate
        utterance.rate = min(max(mapped, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
        utterance.pitchMultiplier = min(max(pitch, 0.5), 2.0)
        utterance.volume = min(max(volume, 0), 1)
    }

    private func activateSession() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // Delegate events, already hopped onto the main actor.

    private func utteranceStarted(_ utterance: AVSpeechUtterance) {
        guard utterance === currentUtterance, playback.state == .speaking,
              chunks.indices.contains(currentChunk) else { return }
        let c = chunks[currentChunk]
        playback.chunkIndex = currentChunk
        playback.highlightStart = c.start
        playback.highlightEnd = c.end
    }

    private func utteranceRange(_ utterance: AVSpeechUtterance, _ range: NSRange) {
        guard utterance === currentUtterance, playback.state == .speaking,
              chunks.indices.contains(currentChunk), range.location != NSNotFound else { return }
        let c = chunks[currentChunk]
        playback.chunkIndex = currentChunk
        playback.highlightStart = c.start + range.location
        playback.highlightEnd = c.start + range.location + range.length
    }

    private func utteranceFinished(_ utterance: AVSpeechUtterance) {
        guard utterance === currentUtterance, playback.state == .speaking else { return }
        if currentChunk < chunks.count - 1 {
            currentChunk += 1
            speakChunk(currentChunk)
            let c = chunks[currentChunk]
            playback.chunkIndex = currentChunk
            playback.highlightStart = c.start
            playback.highlightEnd = c.end
        } else {
            currentUtterance = nil
            currentChunk = 0
            let finishedSource = sourceId
            playback.state = .ready
            playback.highlightStart = -1
            playback.highlightEnd = -1
            playback.message = "Finished reading."
            deactivateSession()
            // Lets the Books reader auto-advance to the next chapter.
            completed.send(finishedSource)
        }
    }

    // MARK: - Language helpers

    /// Compares only the primary subtag, routing legacy codes (iw→he) through Locale.
    nonisolated static func sameLanguage(_ a: String, _ b: String) -> Bool {
        func primary(_ tag: String) -> String {
            let code = tag.split(separator: "-").first.map(String.init) ?? tag
            return Locale(identifier: code).language.languageCode?.identifier ?? code.lowercased()
        }
        return primary(a) == primary(b)
    }

    nonisolated static func displayLanguage(_ tag: String) -> String {
        let code = tag.split(separator: "-").first.map(String.init) ?? tag
        return Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? tag
    }

    // MARK: - Sentence chunking

    /// Splits into sentence chunks (UTF-16 offsets), never crossing line breaks and never
    /// exceeding a safe utterance length.
    nonisolated static func split(_ text: String, maxLength: Int = 3000) -> [Chunk] {
        let ns = text as NSString
        var out: [Chunk] = []
        var lineStart = 0
        while lineStart <= ns.length {
            let searchRange = NSRange(location: lineStart, length: ns.length - lineStart)
            let newline = ns.range(of: "\n", options: [], range: searchRange)
            let lineEnd = newline.location == NSNotFound ? ns.length : newline.location
            if lineEnd > lineStart {
                let line = ns.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
                let tokenizer = NLTokenizer(unit: .sentence)
                tokenizer.string = line
                let lineNS = line as NSString
                tokenizer.enumerateTokens(in: line.startIndex..<line.endIndex) { range, _ in
                    let nsRange = NSRange(range, in: line)
                    addChunk(lineNS, lineOffset: lineStart, start: nsRange.location,
                             end: nsRange.location + nsRange.length, max: maxLength, into: &out)
                    return true
                }
            }
            if lineEnd == ns.length { break }
            lineStart = lineEnd + 1
        }
        return out
    }

    private nonisolated static func addChunk(
        _ line: NSString, lineOffset: Int, start: Int, end: Int, max: Int, into out: inout [Chunk]
    ) {
        var s = start
        while end - s > max {
            let window = NSRange(location: s, length: max)
            let space = line.range(of: " ", options: .backwards, range: window)
            var cut = space.location == NSNotFound ? s + max : space.location
            if cut <= s { cut = s + max }
            appendIfNotBlank(line, lineOffset: lineOffset, start: s, end: cut, into: &out)
            s = cut
        }
        if s < end { appendIfNotBlank(line, lineOffset: lineOffset, start: s, end: end, into: &out) }
    }

    private nonisolated static func appendIfNotBlank(
        _ line: NSString, lineOffset: Int, start: Int, end: Int, into out: inout [Chunk]
    ) {
        let piece = line.substring(with: NSRange(location: start, length: end - start))
        if !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append(Chunk(start: lineOffset + start, end: lineOffset + end))
        }
    }
}

// Only the main synthesizer has its delegate set; the preview synthesizer never reports here.
extension SpeechController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in self.utteranceStarted(utterance) }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.utteranceRange(utterance, characterRange) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.utteranceFinished(utterance) }
    }
}
