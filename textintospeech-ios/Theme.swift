import SwiftUI

/// The reading color scheme. `system` follows the device light/dark setting, `sepia` is a warm
/// low-blue-light paper tone, and `mono` is the high-contrast black-and-white scheme for e-ink
/// readers.
nonisolated enum ThemeChoice: String, CaseIterable, Codable {
    case system, light, dark, sepia, mono
}

/// Base direction for the reading/editor text. `auto` follows the text's own script.
nonisolated enum ReadingDirection: String, CaseIterable, Codable {
    case auto, ltr, rtl
}

/// The semantic color roles the UI uses - a direct port of the Android app's Material 3
/// indigo palette, plus the sepia and e-ink schemes, so both apps look the same.
nonisolated struct AppTheme: Equatable {
    var primary: Color
    var onPrimary: Color
    var primaryContainer: Color
    var onPrimaryContainer: Color
    var secondaryContainer: Color
    var onSecondaryContainer: Color
    var tertiary: Color
    var surface: Color
    var onSurface: Color
    var surfaceVariant: Color
    var onSurfaceVariant: Color
    var surfaceContainerLow: Color
    var surfaceContainerHigh: Color
    var surfaceContainerHighest: Color
    var outline: Color
    var outlineVariant: Color
    var isDark: Bool
    /// Black-and-white (e-ink) mode drops animations, which ghost on slow e-ink panels.
    var eInk: Bool = false

    static let light = AppTheme(
        primary: Color(argb: 0xFF4C5BB3),
        onPrimary: .white,
        primaryContainer: Color(argb: 0xFFDEE1FF),
        onPrimaryContainer: Color(argb: 0xFF001159),
        secondaryContainer: Color(argb: 0xFFE0E1F9),
        onSecondaryContainer: Color(argb: 0xFF181A2C),
        tertiary: Color(argb: 0xFF745470),
        surface: Color(argb: 0xFFFBF8FF),
        onSurface: Color(argb: 0xFF1A1B23),
        surfaceVariant: Color(argb: 0xFFE2E1EC),
        onSurfaceVariant: Color(argb: 0xFF45464F),
        surfaceContainerLow: Color(argb: 0xFFF4F2FC),
        surfaceContainerHigh: Color(argb: 0xFFE9E7F1),
        surfaceContainerHighest: Color(argb: 0xFFE3E1EB),
        outline: Color(argb: 0xFF767680),
        outlineVariant: Color(argb: 0xFFC6C5D0),
        isDark: false
    )

    static let dark = AppTheme(
        primary: Color(argb: 0xFFBAC3FF),
        onPrimary: Color(argb: 0xFF16277E),
        primaryContainer: Color(argb: 0xFF334296),
        onPrimaryContainer: Color(argb: 0xFFDEE1FF),
        secondaryContainer: Color(argb: 0xFF434659),
        onSecondaryContainer: Color(argb: 0xFFE0E1F9),
        tertiary: Color(argb: 0xFFE2BBDB),
        surface: Color(argb: 0xFF121318),
        onSurface: Color(argb: 0xFFE3E1E9),
        surfaceVariant: Color(argb: 0xFF45464F),
        onSurfaceVariant: Color(argb: 0xFFC6C5D0),
        surfaceContainerLow: Color(argb: 0xFF1A1B21),
        surfaceContainerHigh: Color(argb: 0xFF292A2F),
        surfaceContainerHighest: Color(argb: 0xFF34343A),
        outline: Color(argb: 0xFF90909A),
        outlineVariant: Color(argb: 0xFF45464F),
        isDark: true
    )

    /// Warm "sepia" paper scheme, low blue light for comfortable evening reading.
    static let sepia = AppTheme(
        primary: Color(argb: 0xFF8A5A2B),
        onPrimary: .white,
        primaryContainer: Color(argb: 0xFFF0DEC0),
        onPrimaryContainer: Color(argb: 0xFF3A2410),
        secondaryContainer: Color(argb: 0xFFEADBC2),
        onSecondaryContainer: Color(argb: 0xFF2A2113),
        tertiary: Color(argb: 0xFF6E5C3E),
        surface: Color(argb: 0xFFF4ECD8),
        onSurface: Color(argb: 0xFF3F362A),
        surfaceVariant: Color(argb: 0xFFE7DAC0),
        onSurfaceVariant: Color(argb: 0xFF5C5341),
        surfaceContainerLow: Color(argb: 0xFFF3E9D2),
        surfaceContainerHigh: Color(argb: 0xFFE9DCC2),
        surfaceContainerHighest: Color(argb: 0xFFE3D5B9),
        outline: Color(argb: 0xFF8C8070),
        outlineVariant: Color(argb: 0xFFD0C3A8),
        isDark: false
    )

    /// High-contrast black-on-white scheme for e-ink devices.
    static let eInkTheme = AppTheme(
        primary: .black,
        onPrimary: .white,
        primaryContainer: Color(argb: 0xFFE6E6E6),
        onPrimaryContainer: .black,
        secondaryContainer: Color(argb: 0xFFE6E6E6),
        onSecondaryContainer: .black,
        tertiary: .black,
        surface: .white,
        onSurface: .black,
        surfaceVariant: Color(argb: 0xFFECECEC),
        onSurfaceVariant: .black,
        surfaceContainerLow: Color(argb: 0xFFF7F7F7),
        surfaceContainerHigh: Color(argb: 0xFFEAEAEA),
        surfaceContainerHighest: Color(argb: 0xFFE2E2E2),
        outline: .black,
        outlineVariant: Color(argb: 0xFF8A8A8A),
        isDark: false,
        eInk: true
    )

    static func resolve(_ choice: ThemeChoice, systemDark: Bool) -> AppTheme {
        switch choice {
        case .system: return systemDark ? .dark : .light
        case .light: return .light
        case .dark: return .dark
        case .sepia: return .sepia
        case .mono: return .eInkTheme
        }
    }
}

/// The translucent amber used to highlight the sentence/word being read aloud.
nonisolated let highlightColor = Color(argb: 0x66FFC107)
nonisolated let highlightUIColor = UIColor(red: 1.0, green: 0.757, blue: 0.027, alpha: 0.40)

nonisolated extension Color {
    /// 0xAARRGGBB, matching the Android color literals.
    init(argb: UInt32) {
        self.init(
            .sRGB,
            red: Double((argb >> 16) & 0xFF) / 255,
            green: Double((argb >> 8) & 0xFF) / 255,
            blue: Double(argb & 0xFF) / 255,
            opacity: Double((argb >> 24) & 0xFF) / 255
        )
    }
}

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme.light
}

extension EnvironmentValues {
    var theme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}
