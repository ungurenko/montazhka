import SwiftUI

/// Дорожка этапов: сколько шагов всего, какой идёт сейчас.
///
/// Заменяет единственную шкалу, которая на длинных шагах замирала и создавала
/// впечатление зависшей программы. «Шаг 4 из 6» — правда в любой момент.
struct StageTrack: View {
    let stages: [ActivityStage]
    let currentIndex: Int
    let progress: ActivityProgress

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(stages.enumerated()), id: \.element.id) { index, _ in
                Capsule()
                    .fill(Theme.border)
                    .frame(height: 4)
                    .overlay(alignment: .leading) {
                        GeometryReader { geo in
                            Capsule()
                                .fill(Theme.accent)
                                .frame(width: geo.size.width * fill(at: index))
                                .opacity(opacity(at: index))
                        }
                    }
            }
        }
        .onAppear { pulsing = true }
        .animation(pulseAnimation, value: pulsing)
        .accessibilityElement()
        .accessibilityLabel("Шаг \(currentIndex + 1) из \(stages.count)")
    }

    private func fill(at index: Int) -> CGFloat {
        if index < currentIndex { return 1 }
        if index > currentIndex { return 0 }
        // Пока доля неизвестна, сегмент залит наполовину и дышит —
        // это видно как «работает», но не обещает конкретного процента.
        return progress.value.map { CGFloat($0) } ?? 0.5
    }

    private func opacity(at index: Int) -> Double {
        guard index == currentIndex, progress.value == nil, !reduceMotion else { return 1 }
        return pulsing ? 0.35 : 1
    }

    private var pulseAnimation: Animation? {
        guard progress.value == nil, !reduceMotion else { return nil }
        return .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
    }
}

/// Строка о времени: сколько идёт, сколько осталось, не затянулось ли.
///
/// Показывает только то, что известно наверняка. Когда программа ждёт ответа
/// модели, оценку остатка взять неоткуда — тогда говорим, сколько уже идёт,
/// и сравниваем с прошлыми запусками.
struct ActivityCaption: View {
    let activity: Activity

    var body: some View {
        SwiftUI.TimelineView(.periodic(from: activity.stageStartedAt, by: 1)) { context in
            Text(text(now: context.date))
                .typeStyle(.helper)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .monospacedDigit()
        }
    }

    private func text(now: Date) -> String {
        if let remaining = activity.estimatedRemaining {
            return "Осталось \(TimeFormat.approximate(remaining))"
        }

        let elapsed = TimeFormat.spoken(now.timeIntervalSince(activity.stageStartedAt))
        if activity.isSlowerThanUsual(now: now) {
            return "Идёт \(elapsed) — дольше обычного"
        }
        if let typical = activity.typicalStageDuration {
            return "Идёт \(elapsed) · обычно \(TimeFormat.approximate(typical))"
        }
        return "Идёт \(elapsed)"
    }
}

/// Блок хода работы внутри панели: что делаем, на каком шаге, сколько осталось.
struct ActivityBlock: View {
    let activity: Activity
    var cancel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            if activity.stages.count > 1 {
                StageTrack(
                    stages: activity.stages,
                    currentIndex: activity.stageIndex,
                    progress: activity.progress)
                Text("Шаг \(activity.stageIndex + 1) из \(activity.stages.count) · \(stageTitle)")
                    .typeStyle(.helperEmphasis)
                    .foregroundStyle(Theme.textPrimary)
            } else {
                InlineProgress(progress: activity.progress)
            }

            Text(activity.caption)
                .typeStyle(.helper)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ActivityCaption(activity: activity)

            if activity.isCancellable, let cancel {
                Button("Отменить", action: cancel)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(Theme.Spacing.snug)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
        .accessibilityIdentifier("activity.block")
    }

    private var stageTitle: String {
        activity.currentStage?.title ?? activity.title
    }
}

/// Компактный индикатор в верхней панели: работа видна, даже если панель,
/// которая её начала, закрыта.
struct ActivityChip: View {
    let activity: Activity
    var cancel: (() -> Void)?

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            ProgressView(value: activity.progress.value)
                .progressViewStyle(.circular)
                .controlSize(.small)

            VStack(alignment: .leading, spacing: 0) {
                Text(activity.title)
                    .typeStyle(.helperEmphasis)
                    .foregroundStyle(Theme.textPrimary)
                ActivityCaption(activity: activity)
            }
            .lineLimit(1)

            if activity.isCancellable, let cancel {
                IconButton(icon: "xmark", help: "Отменить", size: .toolbar) { cancel() }
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, Theme.Spacing.compact)
        .background(Theme.accent.opacity(0.07))
        .clipShape(Capsule())
        .accessibilityIdentifier("activity.chip")
    }
}

/// Одиночная шкала для работы без этапов.
struct InlineProgress: View {
    let progress: ActivityProgress

    var body: some View {
        ProgressView(value: progress.value)
            .progressViewStyle(.linear)
            .tint(Theme.accent)
    }
}
