import AppKit
import Foundation

/// Сообщает о работе за пределами окна: прогресс и значок на иконке в Доке,
/// короткий звук по завершении.
///
/// Всё общение с AppKit собрано здесь и защищено проверкой `NSApp`: при запуске
/// самопроверки из терминала приложение не поднимается, и любой прямой вызов
/// AppKit там уронил бы процесс.
@MainActor
final class ActivityAnnouncer {
    /// Короче этого работа не заслуживает звука — пользователь всё ещё смотрит на экран.
    private let quietThreshold: TimeInterval = 8
    /// Иконку в Доке перерисовываем не чаще, чем меняется целый процент.
    private var lastBadge: String?

    private let isAppActive: () -> Bool
    private let showBadge: (String?) -> Void
    private let playSound: (String) -> Void
    private let bounceIcon: () -> Void

    init(
        isAppActive: (() -> Bool)? = nil,
        showBadge: ((String?) -> Void)? = nil,
        playSound: ((String) -> Void)? = nil,
        bounceIcon: (() -> Void)? = nil
    ) {
        self.isAppActive = isAppActive ?? { NSApp?.isActive ?? true }
        self.showBadge = showBadge ?? { label in NSApp?.dockTile.badgeLabel = label }
        self.playSound = playSound ?? { name in NSSound(named: name)?.play() }
        self.bounceIcon = bounceIcon ?? { _ = NSApp?.requestUserAttention(.informationalRequest) }
    }

    /// Показывает ход работы на иконке в Доке.
    func render(primary: Activity?) {
        guard let primary, primary.kind.deservesAttention else {
            setBadge(nil)
            return
        }
        if let fraction = primary.progress.value {
            setBadge("\(Int(fraction * 100)) %")
        } else {
            setBadge("…")
        }
    }

    /// Сообщает, чем всё кончилось.
    func announce(_ completion: ActivityCompletion) {
        guard completion.kind.deservesAttention else {
            setBadge(nil)
            return
        }

        switch completion.outcome {
        case .cancelled:
            // Отмену пользователь сделал сам — сообщать ему об этом незачем.
            setBadge(nil)
        case .success:
            setBadge("✓")
            notify(sound: "Glass", duration: completion.duration)
        case .failure:
            setBadge("!")
            notify(sound: "Basso", duration: completion.duration)
        }
    }

    /// Пользователь вернулся в окно и всё увидел сам.
    func acknowledge() {
        setBadge(nil)
    }

    private func notify(sound: String, duration: TimeInterval) {
        // Если окно открыто и активно, пользователь и так всё видит:
        // лишний звук в этот момент только раздражает.
        guard !isAppActive(), duration >= quietThreshold else { return }
        playSound(sound)
        bounceIcon()
    }

    private func setBadge(_ label: String?) {
        guard label != lastBadge else { return }
        lastBadge = label
        showBadge(label)
    }
}
