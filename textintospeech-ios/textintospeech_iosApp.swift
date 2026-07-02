import SwiftUI

/// Read Aloud - the iOS port of the Android TextInToSpeech app: an offline text-to-speech
/// reader for files, pictures and books. One shared speech engine drives every screen, so only
/// one thing speaks at a time and all screens observe the same playback state.
@main
struct ReadAloudApp: App {
    @StateObject private var settings: SettingsStore
    @StateObject private var speech: SpeechController
    @StateObject private var repo: BookRepository
    @StateObject private var readerVm: ReaderViewModel
    @StateObject private var libraryVm: LibraryViewModel

    init() {
        let settings = SettingsStore()
        let speech = SpeechController()
        let repo = BookRepository()
        _settings = StateObject(wrappedValue: settings)
        _speech = StateObject(wrappedValue: speech)
        _repo = StateObject(wrappedValue: repo)
        _readerVm = StateObject(wrappedValue: ReaderViewModel(speech: speech))
        _libraryVm = StateObject(wrappedValue: LibraryViewModel(speech: speech, repo: repo))
    }

    var body: some Scene {
        WindowGroup {
            RootView(speech: speech, readerVm: readerVm, libraryVm: libraryVm, repo: repo)
                .environmentObject(settings)
        }
    }
}
