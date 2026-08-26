import CoreGraphics
import Foundation

/// Сохранённые пользовательские настройки кадра.
struct ShortsFrameSettings: Equatable, Sendable {
    var mode: ShortsFrameMode = .original
    var canvasColor: ShortsCanvasColor = .black

    static func loadAndMigrate(
        in store: any PreferenceStoring = UserDefaultsPreferenceStore.standard
    ) -> ShortsFrameSettings {
        let mode: ShortsFrameMode
        if let raw = store.string(forKey: ShortsFrameMode.key),
            let saved = ShortsFrameMode(rawValue: raw)
        {
            mode = saved
        } else {
            mode = store.bool(forKey: ShortsFrameMode.legacyCropKey) ? .verticalCrop : .original
        }
        let color =
            store.string(forKey: ShortsCanvasColor.key)
            .flatMap(ShortsCanvasColor.init(rawValue:)) ?? .black
        let settings = ShortsFrameSettings(mode: mode, canvasColor: color)
        settings.save(in: store)
        return settings
    }

    func save(in store: any PreferenceStoring = UserDefaultsPreferenceStore.standard) {
        store.set(mode.rawValue, forKey: ShortsFrameMode.key)
        store.set(canvasColor.rawValue, forKey: ShortsCanvasColor.key)
    }

    var previewRequest: ShortsFrameRequest {
        request(resolution: .source)
    }

    func exportRequest(quality: ExportQuality) -> ShortsFrameRequest {
        request(resolution: .quality(quality))
    }

    private func request(resolution: ShortsVerticalResolution) -> ShortsFrameRequest {
        switch mode {
        case .original: .original
        case .verticalCrop: .verticalCrop
        case .verticalFit: .verticalFit(color: canvasColor, resolution: resolution)
        }
    }
}

/// Валидный запрос раскладки: фон и разрешение существуют только у aspect-fit.
enum ShortsFrameRequest: Equatable, Sendable {
    case original
    case verticalCrop
    case verticalFit(color: ShortsCanvasColor, resolution: ShortsVerticalResolution)
}

enum ShortsVerticalResolution: Equatable, Sendable {
    case source
    case quality(ExportQuality)
}

/// Чистая геометрия кадра: отделена от AVFoundation и проверяется тестами.
struct ShortsFrameLayout: Equatable {
    let renderSize: CGSize
    let contentRect: CGRect

    static func verticalFit(displaySize: CGSize, renderSize: CGSize) -> ShortsFrameLayout {
        let canvas = CGSize(width: even(renderSize.width), height: even(renderSize.height))
        let width = abs(displaySize.width)
        let height = abs(displaySize.height)
        guard width > 0, height > 0 else {
            return ShortsFrameLayout(renderSize: canvas, contentRect: .zero)
        }
        let scale = min(canvas.width / width, canvas.height / height)
        let content = CGSize(width: width * scale, height: height * scale)
        return ShortsFrameLayout(
            renderSize: canvas,
            contentRect: CGRect(
                x: (canvas.width - content.width) / 2,
                y: (canvas.height - content.height) / 2,
                width: content.width,
                height: content.height))
    }

    static func verticalCanvasSize(for displaySize: CGSize, quality: ExportQuality?) -> CGSize {
        // Ширина, кратная 18, даёт точный 9:16 с чётными сторонами H.264.
        let available = min(abs(displaySize.width), abs(displaySize.height))
        let shortSide = max(18, floor(available / 18) * 18)
        let native = CGSize(width: shortSide, height: shortSide * 16 / 9)
        return quality?.targetDimensions(forDisplaySize: native) ?? native
    }

    private static func even(_ value: CGFloat) -> CGFloat {
        max(2, (value / 2).rounded() * 2)
    }
}
