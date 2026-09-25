import CoreGraphics
import Foundation

/// Чистая «операторская» геометрия черновика шортса: какой прямоугольник
/// исходника в какой момент ленты попадает в кадр. AVFoundation здесь нет —
/// всё проверяется тестами.
enum ShortsCameraPlanner {
    /// Центр кадра (доли исходника) для исходника `sourceID` в секунду исходника.
    typealias Centre = (_ sourceID: UUID, _ sourceTime: Double) -> CGPoint

    /// Ключевой кадр: момент ленты, прямоугольник исходника и номер клипа.
    /// Плавный переход строится только между ключами одного клипа.
    struct Key: Equatable {
        let time: Double
        let rect: CGRect
        let clip: Int
    }

    /// Раскладка «экран + лицо»: где на холсте экран, где лицо и какой кусок
    /// исходника идёт в нижнюю половину.
    struct Split: Equatable {
        let screen: CGRect
        let faceRegion: CGRect
        let faceCrop: CGRect
    }

    static let maxZoom = 1.12
    static let keyStep = 0.2
    static let zoomRelease = 0.6
    /// Сверху оставляем полосу под хук и интерфейс Reels.
    static let splitTopInset = 0.1
    /// Рамка лица в нижней половине в столько раз больше самого лица.
    static let faceMargin = 2.2

    static func keys(
        clips: [Clip], display: CGSize, layout: ShortsDraftLayout, centre: Centre,
        zooms: [ShortsZoom], aspect: CGFloat = 9.0 / 16.0, base: CGSize? = nil
    ) -> [Key] {
        let baseSize = base ?? baseCrop(display: display, layout: layout, aspect: aspect)
        let clamps = layout != .fit
        var keys: [Key] = []
        var timelineStart = 0.0
        for (index, clip) in clips.enumerated() {
            var offsets = Array(stride(from: 0.0, to: clip.duration, by: keyStep))
            offsets.append(clip.duration)
            for offset in offsets {
                let sourceTime = clip.start + offset
                let scale = zoomScale(zooms, sourceID: clip.source.id, sourceTime: sourceTime)
                let size = CGSize(width: baseSize.width / scale, height: baseSize.height / scale)
                let point = centre(clip.source.id, sourceTime)
                var rect = CGRect(
                    x: point.x * display.width - size.width / 2,
                    y: centreY(point.y, layout: layout, scale: scale, display: display) - size.height / 2,
                    width: size.width, height: size.height)
                if layout == .fit { rect.origin.x = (display.width - size.width) / 2 }
                if clamps { rect = clamp(rect, inside: display) }
                keys.append(Key(time: timelineStart + offset, rect: rect, clip: index))
            }
            timelineStart += clip.duration
        }
        return keys
    }

    /// Во сколько раз наехала камера: плавный наезд на всём отрезке зума и
    /// отпускание за `zoomRelease` после него.
    static func zoomScale(_ zooms: [ShortsZoom], sourceID: UUID, sourceTime: Double) -> Double {
        zooms.filter { $0.sourceID == sourceID }.map { zoom -> Double in
            let target = min(maxZoom, max(1, zoom.scale))
            let length = max(0.001, zoom.sourceEnd - zoom.sourceStart)
            if sourceTime >= zoom.sourceStart, sourceTime <= zoom.sourceEnd {
                return 1 + (target - 1) * ease((sourceTime - zoom.sourceStart) / length)
            }
            if sourceTime > zoom.sourceEnd, sourceTime < zoom.sourceEnd + zoomRelease {
                return target - (target - 1) * ease((sourceTime - zoom.sourceEnd) / zoomRelease)
            }
            return 1
        }.max() ?? 1
    }

    static func split(display: CGSize, canvas: CGSize, faceBox: CGRect?) -> Split? {
        guard display.width > 0, display.height > 0, let faceBox else { return nil }
        let top = (canvas.height * splitTopInset).rounded()
        let screen = CGRect(
            x: 0, y: top, width: canvas.width, height: (canvas.width * display.height / display.width).rounded())
        let faceRegion = CGRect(x: 0, y: screen.maxY, width: canvas.width, height: canvas.height - screen.maxY)
        guard faceRegion.height > 0 else { return nil }
        let aspect = faceRegion.width / faceRegion.height
        var height = min(display.height, faceBox.height * display.height * faceMargin)
        var width = height * aspect
        if width > display.width {
            width = display.width
            height = width / aspect
        }
        let crop = clamp(
            CGRect(
                x: faceBox.midX * display.width - width / 2, y: faceBox.midY * display.height - height / 2,
                width: width, height: height),
            inside: display)
        return Split(screen: screen, faceRegion: faceRegion, faceCrop: crop)
    }

    /// Преобразование, которое кладёт `crop` исходника ровно в `region` холста.
    /// `normalized` — поворот дорожки, приведённый к началу координат.
    static func transform(crop: CGRect, into region: CGRect, normalized: CGAffineTransform) -> CGAffineTransform {
        let scale = region.width / max(1, crop.width)
        return normalized
            .concatenating(CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: region.minX, y: region.minY))
    }

    /// Прямоугольник кадра без зума: самый большой 9:16 внутри исходника
    /// (face) или исходник целиком посреди высокого холста (fit).
    static func baseCrop(display: CGSize, layout: ShortsDraftLayout, aspect: CGFloat = 9.0 / 16.0) -> CGSize {
        if layout == .fit {
            return display.width / display.height > aspect
                ? CGSize(width: display.width, height: display.width / aspect)
                : CGSize(width: display.height * aspect, height: display.height)
        }
        return display.width / display.height > aspect
            ? CGSize(width: display.height * aspect, height: display.height)
            : CGSize(width: display.width, height: display.width / aspect)
    }

    /// По вертикали кадр стоит посередине, а при наезде смещается к лицу.
    private static func centreY(_ faceY: Double, layout: ShortsDraftLayout, scale: Double, display: CGSize) -> Double {
        let middle = display.height / 2
        guard layout != .fit, maxZoom > 1 else { return middle }
        let pull = min(1, (scale - 1) / (maxZoom - 1))
        return middle + (faceY * display.height - middle) * pull
    }

    private static func clamp(_ rect: CGRect, inside size: CGSize) -> CGRect {
        var result = rect
        if result.width <= size.width {
            result.origin.x = max(0, min(size.width - result.width, result.origin.x))
        }
        if result.height <= size.height {
            result.origin.y = max(0, min(size.height - result.height, result.origin.y))
        }
        return result
    }

    private static func ease(_ progress: Double) -> Double {
        let p = max(0, min(1, progress))
        return p * p * (3 - 2 * p)
    }
}
