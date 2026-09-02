import AppKit
import SwiftUI

/// Стартовый экран: новый монтаж + недавние проекты.
struct StartView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                brand
                actions
                agentIntegration

                VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                    Text("Недавние проекты")
                        .typeStyle(.sectionTitle)
                        .foregroundStyle(Theme.textPrimary)

                    if app.recents.isEmpty {
                        Label("Здесь появятся проекты, с которыми ты работал", systemImage: "clock")
                            .typeStyle(.body)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(Theme.Spacing.medium)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .rowSurfaceStyle()
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 240), spacing: Theme.Spacing.medium)],
                            spacing: Theme.Spacing.medium
                        ) {
                            ForEach(app.recents) { meta in
                                RecentCard(meta: meta)
                            }
                        }
                    }
                }

                if app.isProjectOperationInProgress {
                    HStack(spacing: Theme.Spacing.small) {
                        ProgressView().controlSize(.small)
                        Text("Открываю проект…")
                            .typeStyle(.helper)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 56)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var brand: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: Theme.Spacing.compact) {
                Text("Монтажка")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("Простой монтаж: добавь клипы, вырежи паузы, сохрани")
                    .typeStyle(.body)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: Theme.Spacing.medium) {
            StartActionCard(
                title: "Новый монтаж",
                subtitle: "Собери ролик, убери паузы и улучши звук",
                systemImage: "plus.rectangle.on.rectangle",
                primary: true
            ) {
                let urls = AppModel.pickVideos()
                if !urls.isEmpty { app.newProject(with: urls) }
            }
            .disabled(app.isProjectOperationInProgress)
            .accessibilityIdentifier("start.newProject")

            StartActionCard(
                title: "Нарезать на shorts",
                subtitle: "Найди сильные моменты в длинном видео",
                systemImage: "sparkles.rectangle.stack",
                primary: false
            ) {
                if let url = AppModel.pickVideo() { app.startShorts(url: url) }
            }
            .disabled(app.isProjectOperationInProgress)
            .accessibilityIdentifier("start.shorts")
        }
        .frame(maxWidth: .infinity)
    }

    private var agentIntegration: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: app.agentIntegration.installed ? "checkmark.circle.fill" : "terminal")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(app.agentIntegration.installed ? Color.green : Theme.accent)
                .frame(width: 44, height: 44)
                .background(Theme.selected)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
            VStack(alignment: .leading, spacing: Theme.Spacing.compact) {
                Text("AI-агенты")
                    .typeStyle(.bodyEmphasis)
                    .foregroundStyle(Theme.textPrimary)
                Text(app.agentIntegration.message)
                    .typeStyle(.helper)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button(app.agentIntegration.installed ? "Обновить подключение" : "Подключить AI-агентов") {
                app.connectAgents()
            }
            .disabled(app.isAgentIntegrationInProgress)
            if app.isAgentIntegrationInProgress { ProgressView().controlSize(.small) }
        }
        .padding(Theme.Spacing.medium)
        .rowSurfaceStyle()
        .accessibilityIdentifier("start.agentIntegration")
    }
}

private struct StartActionCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let primary: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.medium) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(primary ? Color.white : Theme.accent)
                    .frame(width: 44, height: 44)
                    .background(primary ? Theme.accent : Theme.selected)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))

                VStack(alignment: .leading, spacing: Theme.Spacing.compact) {
                    Text(title)
                        .typeStyle(.sectionTitle)
                        .foregroundStyle(Theme.textPrimary)
                    Text(subtitle)
                        .typeStyle(.helper)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Spacing.small)
                Image(systemName: "chevron.right")
                    .typeStyle(.helperEmphasis)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(Theme.Spacing.medium)
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
            .background(primary ? Theme.selected : (hovering ? Theme.hover : Theme.card))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .stroke(
                        primary || hovering ? Theme.accent.opacity(primary ? 0.42 : 0.28) : Theme.border,
                        lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct RecentCard: View {
    @Environment(AppModel.self) private var app
    let meta: ProjectMeta
    @State private var hovering = false

    var body: some View {
        Button {
            app.openProject(id: meta.id)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "film")
                        .foregroundStyle(Theme.accent)
                    Text(meta.name)
                        .typeStyle(.bodyEmphasis)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                }
                Text("\(TimeFormat.spoken(meta.duration)) · \(clipsLabel(meta.clipCount))")
                    .typeStyle(.helper)
                    .foregroundStyle(Theme.textSecondary)
                Text(TimeFormat.date(meta.updatedAt))
                    .typeStyle(.helper)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Theme.hover : Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .stroke(hovering ? Theme.accent.opacity(0.35) : Theme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(app.isProjectOperationInProgress)
        .onHover { hovering = $0 }
        .accessibilityLabel("Проект \(meta.name)")
        .accessibilityValue("\(TimeFormat.spoken(meta.duration)), \(clipsLabel(meta.clipCount))")
        .accessibilityHint("Открыть проект")
        .accessibilityIdentifier("start.recent.\(meta.id.uuidString)")
        .contextMenu {
            Button("Удалить проект", role: .destructive) {
                app.deleteProject(id: meta.id)
            }
        }
    }

    private func clipsLabel(_ count: Int) -> String {
        let mod10 = count % 10, mod100 = count % 100
        let word: String
        if mod10 == 1 && mod100 != 11 {
            word = "клип"
        } else if (2...4).contains(mod10) && !(12...14).contains(mod100) {
            word = "клипа"
        } else {
            word = "клипов"
        }
        return "\(count) \(word)"
    }
}
