import SwiftUI

/// App settings: reading color scheme, reading text size and base reading direction - the port
/// of the Android Settings screen. (The UI language follows the iPhone's own language settings.)
struct SettingsScreen: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.primary)
                Spacer()
                Button("Done") { dismiss() }
                    .font(.body.weight(.medium))
                    .foregroundStyle(theme.primary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    settingsCard("Appearance") {
                        sectionTitle("Theme")
                        ColorThemeChips(theme: settings.theme) { settings.theme = $0 }
                            .padding(.top, 8)

                        sectionTitle("Reading text size").padding(.top, 18)
                        textSizePicker.padding(.top, 8)

                        sectionTitle("Reading direction").padding(.top, 18)
                        directionPicker.padding(.top, 8)
                    }

                    Text("Read Aloud · works fully offline")
                        .font(.caption)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
        }
        .background(theme.surface.ignoresSafeArea())
    }

    private var textSizePicker: some View {
        VStack(spacing: 4) {
            Text("The quick brown fox jumps over the lazy dog.")
                .font(.system(size: 17 * settings.textScale))
                .foregroundStyle(theme.onSurface)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14).fill(theme.surfaceContainerHigh))
            HStack(spacing: 10) {
                Image(systemName: "textformat.size.smaller")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.onSurfaceVariant)
                Slider(value: $settings.textScale, in: 0.8...1.8, step: 0.2)
                    .tint(theme.primary)
                Image(systemName: "textformat.size.larger")
                    .font(.system(size: 22))
                    .foregroundStyle(theme.onSurfaceVariant)
            }
        }
    }

    private var directionPicker: some View {
        Picker("Reading direction", selection: $settings.readingDirection) {
            Text("Auto").tag(ReadingDirection.auto)
            Text("LTR").tag(ReadingDirection.ltr)
            Text("RTL").tag(ReadingDirection.rtl)
        }
        .pickerStyle(.segmented)
    }

    private func settingsCard(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(theme.primary)
                .padding(.leading, 4)
                .padding(.top, 18)
                .padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 0, content: content)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 20).fill(theme.surfaceContainerLow))
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .foregroundStyle(theme.onSurfaceVariant)
    }
}
