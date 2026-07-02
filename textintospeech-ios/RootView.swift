import SwiftUI
import UIKit

/// The app frame: the Read and Books tabs, the settings sheet, and the full-screen photo and
/// PDF readers - the port of the Android ReadAloudApp navigation.
struct RootView: View {
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var speech: SpeechController
    @ObservedObject var readerVm: ReaderViewModel
    @ObservedObject var libraryVm: LibraryViewModel
    @ObservedObject var repo: BookRepository

    private enum Tab { case read, books }
    @State private var tab: Tab = .read
    @State private var showSettings = false
    @State private var showPhotoReader = false
    @State private var showPdfViewer = false
    @State private var booksPath = NavigationPath()

    var body: some View {
        let theme = AppTheme.resolve(settings.theme, systemDark: systemScheme == .dark)

        TabView(selection: $tab) {
            ReadScreen(
                vm: readerVm,
                speech: speech,
                onOpenSettings: { showSettings = true },
                onOpenPdf: { showPdfViewer = true }
            )
            .tabItem { Label("Read", systemImage: "speaker.wave.2.fill") }
            .tag(Tab.read)

            NavigationStack(path: $booksPath) {
                LibraryScreen(
                    vm: libraryVm,
                    repo: repo,
                    onOpenBook: { id in booksPath.append(id) },
                    onOpenSettings: { showSettings = true }
                )
                .navigationDestination(for: String.self) { bookId in
                    BookReaderScreen(vm: libraryVm, speech: speech, bookId: bookId)
                }
            }
            .tabItem { Label("Books", systemImage: "books.vertical.fill") }
            .tag(Tab.books)
        }
        .tint(theme.primary)
        .environment(\.theme, theme)
        .preferredColorScheme(preferredScheme)
        .sheet(isPresented: $showSettings) {
            SettingsScreen()
                .environment(\.theme, theme)
        }
        .fullScreenCover(isPresented: $showPhotoReader) {
            PhotoReaderScreen(vm: readerVm, speech: speech)
                .environment(\.theme, theme)
        }
        .fullScreenCover(isPresented: $showPdfViewer) {
            PdfViewerScreen(vm: readerVm, speech: speech)
                .environment(\.theme, theme)
        }
        // Text/documents opened into the app land on the Read tab.
        .onReceive(readerVm.openRead) { tab = .read }
        // A finished photo OCR (or the Read-tab button) opens the full-screen photo reader.
        .onReceive(readerVm.openPhotoReader) { showPhotoReader = true }
        // Keep the screen awake while reading aloud.
        .onChange(of: speech.playback.state == .speaking) { _, speaking in
            UIApplication.shared.isIdleTimerDisabled = speaking
        }
        // Pick up voices the user just downloaded in the system settings.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { speech.refreshVoices() }
        }
    }

    private var preferredScheme: ColorScheme? {
        switch settings.theme {
        case .system: return nil
        case .dark: return .dark
        case .light, .sepia, .mono: return .light
        }
    }
}
