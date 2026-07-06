import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Панель фоновой музыки: тумблер, список встроенных мелодий, свой файл, громкость.
struct MusicPanel: View {
    @ObservedObject var controller: EditorController
    @State private var settings = MusicSettings()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Фоновая музыка")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button {
                    withAnimation { controller.showMusicPanel = false }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.textSecondary.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    toggleBlock
                    tracksBlock
                    volumeBlock
                    warningBlock
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .cardStyle()
        .onAppear { settings = controller.project.music }
        .onChange(of: settings) { _, new in
            controller.updateMusicSettings(new)
        }
    }

    private var toggleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Добавить музыку", isOn: $settings.enabled)
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Text("Мелодия тихо играет под голосом всё видео: повторяется по кругу и плавно затихает в конце. Слышно сразу в предпросмотре.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var tracksBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Мелодия")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)

            if MusicLibrary.tracks.isEmpty && settings.customPath == nil {
                Text("Встроенных мелодий нет — выбери свой аудиофайл.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }

            ForEach(MusicLibrary.tracks) { track in
                TrackRow(title: track.title,
                         selected: settings.customPath == nil && settings.trackID == track.id) {
                    settings.customPath = nil
                    settings.trackID = track.id
                }
            }

            if let path = settings.customPath {
                HStack(spacing: 8) {
                    TrackRow(title: URL(fileURLWithPath: path).lastPathComponent, selected: true) {}
                    Button {
                        settings.customPath = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textSecondary.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help("Убрать свой файл")
                }
            }

            Button {
                if let url = pickAudioFile() {
                    settings.customPath = url.path
                }
            } label: {
                Label("Выбрать свой файл…", systemImage: "folder")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
        }
        .disabled(!settings.enabled)
        .opacity(settings.enabled ? 1 : 0.5)
    }

    private var volumeBlock: some View {
        SettingSlider(
            title: "Громкость музыки",
            explain: "Голос всегда на полной громкости",
            value: $settings.volume,
            range: 0...100, step: 1,
            display: { "\(Int($0)) %" }
        )
        .disabled(!settings.enabled)
        .opacity(settings.enabled ? 1 : 0.5)
    }

    @ViewBuilder
    private var warningBlock: some View {
        if settings.enabled {
            if let path = settings.customPath, !FileManager.default.fileExists(atPath: path) {
                Label("Файл музыки не найден — видео будет без музыки.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            } else if settings.customPath == nil, settings.trackID == nil {
                Label("Выбери мелодию из списка или свой файл.", systemImage: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func pickAudioFile() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Выбрать музыку"
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

private struct TrackRow: View {
    let title: String
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? Theme.accent : Theme.textSecondary.opacity(0.5))
                Image(systemName: "music.note")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                Text(title)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                    .stroke(selected ? Theme.accent : Color.black.opacity(0.06), lineWidth: selected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}
