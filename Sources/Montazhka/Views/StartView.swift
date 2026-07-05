import SwiftUI

/// Стартовый экран: новый монтаж + недавние проекты.
struct StartView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 48)

            VStack(spacing: 10) {
                Image(systemName: "film.stack")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Theme.accent)
                Text("Монтажка")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("Простой монтаж: добавь клипы, вырежи паузы, сохрани")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
            }

            Button {
                let urls = AppModel.pickVideos()
                if !urls.isEmpty { app.newProject(with: urls) }
            } label: {
                Label("Новый монтаж", systemImage: "plus")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .background(Theme.accent)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 28)

            if !app.recents.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Недавние")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 4)

                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 16)], spacing: 16) {
                            ForEach(app.recents) { meta in
                                RecentCard(meta: meta)
                            }
                        }
                        .padding(4)
                    }
                }
                .frame(maxWidth: 780)
                .padding(.top, 44)
            }

            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RecentCard: View {
    @EnvironmentObject private var app: AppModel
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
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                }
                Text("\(TimeFormat.spoken(meta.duration)) · \(clipsLabel(meta.clipCount))")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                Text(TimeFormat.date(meta.updatedAt))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .stroke(hovering ? Theme.accent.opacity(0.5) : .clear, lineWidth: 1.5)
            )
            .scaleEffect(hovering ? 1.02 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Удалить проект", role: .destructive) {
                app.deleteProject(id: meta.id)
            }
        }
    }

    private func clipsLabel(_ count: Int) -> String {
        let mod10 = count % 10, mod100 = count % 100
        let word: String
        if mod10 == 1 && mod100 != 11 { word = "клип" }
        else if (2...4).contains(mod10) && !(12...14).contains(mod100) { word = "клипа" }
        else { word = "клипов" }
        return "\(count) \(word)"
    }
}
