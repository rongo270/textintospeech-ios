import Foundation
import Combine

/// User-facing app preferences (theme, reading text size, reading direction), persisted in
/// UserDefaults and published so the SwiftUI views react instantly - the port of the Android
/// SettingsStore.
@MainActor
final class SettingsStore: ObservableObject {

    @Published var theme: ThemeChoice {
        didSet { defaults.set(theme.rawValue, forKey: Keys.theme) }
    }
    @Published var textScale: Double {
        didSet { defaults.set(textScale, forKey: Keys.textScale) }
    }
    @Published var readingDirection: ReadingDirection {
        didSet { defaults.set(readingDirection.rawValue, forKey: Keys.readingDirection) }
    }
    /// False until the one-time welcome dialog has been dismissed.
    @Published var welcomeShown: Bool {
        didSet { defaults.set(welcomeShown, forKey: Keys.welcomeShown) }
    }

    private let defaults = UserDefaults.standard

    init() {
        theme = ThemeChoice(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .system
        let scale = defaults.double(forKey: Keys.textScale)
        textScale = scale > 0 ? scale : 1.0
        readingDirection = ReadingDirection(rawValue: defaults.string(forKey: Keys.readingDirection) ?? "") ?? .auto
        welcomeShown = defaults.bool(forKey: Keys.welcomeShown)
    }

    private enum Keys {
        static let theme = "theme"
        static let textScale = "text_scale"
        static let readingDirection = "reading_direction"
        static let welcomeShown = "welcome_shown"
    }
}
