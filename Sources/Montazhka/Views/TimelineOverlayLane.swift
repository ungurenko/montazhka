import SwiftUI

/// Полоса анимаций над клипами: где на ленте видна каждая анимация поверх
/// видео. Шкала та же, что у клипов. Анимации, которых в ролике не видно
/// (слово-якорь вырезано, окно слишком короткое), не рисуются.
struct TimelineOverlayLane: View {
    static let height: CGFloat = 8

    let overlays: [ResolvedOverlay]
    let pps: CGFloat
    let width: CGFloat
    let onSeek: (Double) -> Void
    let onRemove: (UUID) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(overlays.filter { $0.status == .visible }, id: \.overlay.id) { resolved in
                OverlayCapsule(resolved: resolved, pps: pps, onSeek: onSeek, onRemove: onRemove)
            }
        }
        .frame(width: width, height: Self.height, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Анимации")
    }
}

/// Одна анимация на полосе: нажатие ставит курсор на её начало, правый клик
/// удаляет (⌘Z возвращает).
private struct OverlayCapsule: View {
    let resolved: ResolvedOverlay
    let pps: CGFloat
    let onSeek: (Double) -> Void
    let onRemove: (UUID) -> Void

    private var start: Double { resolved.window.from }
    private var width: CGFloat {
        max(TimelineOverlayLane.height, CGFloat(resolved.window.to - resolved.window.from) * pps)
    }

    private var description: String {
        let file = resolved.overlay.media.displayName
        if let word = resolved.overlay.anchor.wordText?.trimmingCharacters(in: .whitespacesAndNewlines),
            !word.isEmpty
        {
            return "Анимация на слове «\(word)» · \(file)"
        }
        return "Анимация с \(TimeFormat.short(resolved.anchorTimeline ?? start)) · \(file)"
    }

    var body: some View {
        Button {
            onSeek(start)
        } label: {
            Color.clear
                .frame(width: width, height: TimelineOverlayLane.height)
        }
        .buttonStyle(OverlayCapsuleStyle())
        .offset(x: CGFloat(start) * pps)
        .help(description)
        .contextMenu {
            Button("Удалить анимацию", role: .destructive) { onRemove(resolved.overlay.id) }
        }
        .accessibilityLabel(description)
        .accessibilityHint("Активируй, чтобы перейти к началу анимации")
        .accessibilityAction(named: "Удалить анимацию") { onRemove(resolved.overlay.id) }
    }
}

/// Капсула акцентного цвета: ярче при наведении и нажатии.
private struct OverlayCapsuleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        OverlayCapsuleSurface(configuration: configuration)
    }
}

private struct OverlayCapsuleSurface: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false

    var body: some View {
        configuration.label
            .background(Capsule().fill(Theme.accent.opacity(opacity)))
            .contentShape(Capsule())
            .animation(Theme.Motion.hover, value: hovering)
            .onHover { hovering = $0 }
    }

    private var opacity: Double {
        if configuration.isPressed { return 1 }
        return hovering ? 0.85 : 0.6
    }
}
