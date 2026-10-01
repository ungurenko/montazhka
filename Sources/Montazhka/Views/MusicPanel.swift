import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Панель фоновой музыки: тумблер, список встроенных мелодий, свой файл, громкость.
struct MusicPanel: View {
    var controller: EditorController
    private var settings: MusicSettings { controller.project.music }

    func setting<Value>(_ keyPath: WritableKeyPath<MusicSettings, Value>) -> Binding<Value> {
        Binding(
            get: { controller.project.music[keyPath: keyPath] },
            set: { value in updateSettings { $0[keyPath: keyPath] = value } })
    }

    private func updateSettings(_ change: (inout MusicSettings) -> Void) {
        var latest = controller.project.music
        change(&latest)
        controller.updateMusicSettings(latest)
    }

    var body: some View {
        InspectorPanel(
            title: "Фоновая музыка",
            systemImage: "music.note",
            accessibilityIdentifier: "editor.inspector.music",
            close: { withAnimation { controller.activeInspector = nil } }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                    toggleBlock
                    if settings.enabled {
                        tracksBlock
                        volumeBlock
                        duckingBlock
                        eqBlock
                        warningBlock
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
    }

    private var toggleBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Toggle("Добавить музыку", isOn: setting(\.enabled))
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .typeStyle(.bodyEmphasis)
                .foregroundStyle(Theme.textPrimary)
            Text(
                "Музыка играет под голосом, повторяется по кругу и плавно затихает в конце."
            )
            .typeStyle(.helper)
            .foregroundStyle(Theme.textSecondary)
        }
    }

    private var tracksBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Мелодия")
                .typeStyle(.bodyEmphasis)
                .foregroundStyle(Theme.textPrimary)

            if MusicLibrary.tracks.isEmpty && settings.customPath == nil {
                Text("Встроенных мелодий нет — выбери свой аудиофайл.")
                    .typeStyle(.helper)
                    .foregroundStyle(Theme.textSecondary)
            }

            ForEach(MusicLibrary.tracks) { track in
                TrackRow(
                    title: track.title,
                    selected: settings.customPath == nil && settings.trackID == track.id
                ) {
                    updateSettings {
                        $0.customPath = nil
                        $0.trackID = track.id
                    }
                }
            }

            if let path = settings.customPath {
                HStack(spacing: 8) {
                    TrackRow(title: URL(fileURLWithPath: path).lastPathComponent, selected: true) {}
                    Button {
                        updateSettings { $0.customPath = nil }
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
                    updateSettings { $0.customMedia = MediaReference(url: url) }
                }
            } label: {
                Label("Выбрать свой файл…", systemImage: "folder")
                    .typeStyle(.helper)
            }
            .buttonStyle(.bordered)
        }
    }

    private var volumeBlock: some View {
        SettingSlider(
            title: "Громкость музыки",
            explain: "Голос всегда на полной громкости",
            value: setting(\.volume),
            range: 0...100, step: 1,
            display: { "\(Int($0)) %" }
        )
    }

    private var duckingBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Toggle("Приглушать музыку под голосом", isOn: setting(\.ducking))
                .toggleStyle(.checkbox)
                .typeStyle(.bodyEmphasis)
                .foregroundStyle(Theme.textPrimary)
                .accessibilityIdentifier("music.ducking")
            Text("Пока звучит голос, музыка тише. Где звучит голос, берётся из расшифровки речи.")
                .typeStyle(.helper)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var eqBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Toggle("Не мешать голосу", isOn: setting(\.eqEnabled))
                .toggleStyle(.checkbox)
                .typeStyle(.bodyEmphasis)
                .foregroundStyle(Theme.textPrimary)
            Text(
                "Освобождает место для речи, чтобы голос звучал разборчивее."
            )
            .typeStyle(.helper)
            .foregroundStyle(Theme.textSecondary)
            if controller.musicProcessing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Обрабатываю музыку…")
                        .typeStyle(.helper)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    @ViewBuilder
    private var warningBlock: some View {
        if settings.enabled {
            if let path = settings.customPath, !FileManager.default.fileExists(atPath: path) {
                Label("Файл музыки не найден — видео будет без музыки.", systemImage: "exclamationmark.triangle.fill")
                    .typeStyle(.helper)
                    .foregroundStyle(.orange)
            } else if settings.customPath == nil, settings.trackID == nil {
                Label("Выбери мелодию из списка или свой файл.", systemImage: "info.circle")
                    .typeStyle(.helper)
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
        SelectableRow(
            marker: .choice,
            title: title,
            titleStyle: .body,
            leadingSystemImage: "music.note",
            isSelected: selected,
            select: select
        )
        .rowSurfaceStyle(selected: selected)
    }
}
