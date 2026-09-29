@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Проверка файла анимации (прозрачный ProRes 4444, например из HyperFrames)
/// до того, как он попадёт в проект. Каждый отказ говорит, что сделать дальше.
enum OverlayMediaProbe {
    static let durationRange = 0.2...60.0
    /// Кодеки ProRes с каналом прозрачности.
    private static let alphaCodecs: Set<FourCharCode> = [
        kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes4444XQ,
    ]
    /// Пиксель с альфой ниже этого хотя бы частично прозрачен.
    private static let opaqueAlpha: UInt8 = 250
    /// Расхождение пропорций с кадром проекта, после которого стоит предупредить.
    private static let aspectTolerance = 0.02
    private static let renderHint = "рендерьте HyperFrames с --format mov"

    /// Видеодорожка файла и её свойства.
    private struct VideoTrack {
        let track: AVAssetTrack
        let duration: Double
        let size: CGSize
        let codec: FourCharCode
        let containsAlpha: Bool
    }

    static func validate(_ url: URL, projectFrame: CGSize, mode: OverlayMode = .transparent) async throws -> (
        duration: Double, warnings: [String]
    ) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AgentServiceError.invalidInput(
                "Файл анимации не найден: \(url.path). Проверьте путь или отрендерьте анимацию заново.")
        }
        guard url.pathExtension.lowercased() != "webm" else {
            throw AgentServiceError.invalidInput("Монтажка не читает webm — \(renderHint).")
        }
        let asset = AVURLAsset(url: url)
        let video = try await loadVideoTrack(of: asset, name: url.lastPathComponent)
        guard durationRange.contains(video.duration) else {
            throw AgentServiceError.invalidInput(
                "Анимация длится \(seconds(video.duration)) с, а нужно от 0,2 до 60 с: "
                    + "поменяйте длину композиции HyperFrames и отрендерьте заново.")
        }
        guard mode == .cover || alphaCodecs.contains(video.codec) || video.containsAlpha else {
            throw AgentServiceError.invalidInput(
                "У файла \(url.lastPathComponent) (кодек \(fourCC(video.codec))) нет прозрачности: "
                    + "фон непрозрачный — анимация закроет видео. Чтобы получить ProRes 4444 "
                    + "с прозрачным фоном, \(renderHint).")
        }
        guard
            try mode == .cover || middleFrameHasTransparency(asset: asset, track: video.track, duration: video.duration)
        else {
            throw AgentServiceError.invalidInput(
                "Фон непрозрачный — анимация закроет видео, рендерьте с прозрачным фоном.")
        }
        return (video.duration, aspectWarning(size: video.size, projectFrame: projectFrame).map { [$0] } ?? [])
    }

    private static func loadVideoTrack(of asset: AVURLAsset, name: String) async throws -> VideoTrack {
        let unreadable = AgentServiceError.invalidInput(
            "В файле \(name) нет видео, которое можно прочитать: \(renderHint).")
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw unreadable }
            let (naturalSize, transform, formats, traits) = try await track.load(
                .naturalSize, .preferredTransform, .formatDescriptions, .mediaCharacteristics)
            guard let format = formats.first else { throw unreadable }
            let shown = naturalSize.applying(transform)
            return VideoTrack(
                track: track, duration: try await asset.load(.duration).seconds,
                size: CGSize(width: abs(shown.width), height: abs(shown.height)),
                codec: CMFormatDescriptionGetMediaSubType(format),
                containsAlpha: traits.contains(.containsAlphaChannel))
        } catch {
            throw unreadable
        }
    }

    /// Кадр из середины ролика в BGRA: есть ли в нём хоть один прозрачный пиксель.
    private static func middleFrameHasTransparency(
        asset: AVAsset, track: AVAssetTrack, duration: Double
    ) throws -> Bool {
        let unreadable = AgentServiceError.invalidInput(
            "Не удалось прочитать кадр анимации: отрендерьте файл заново, \(renderHint).")
        guard let reader = try? AVAssetReader(asset: asset) else { throw unreadable }
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        guard reader.canAdd(output) else { throw unreadable }
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: duration / 2, preferredTimescale: 600), duration: .positiveInfinity)
        guard reader.startReading() else { throw unreadable }
        defer { reader.cancelReading() }
        guard let sample = output.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) else {
            throw unreadable
        }
        return hasTransparentPixel(buffer)
    }

    private static func hasTransparentPixel(_ buffer: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else {
            return false
        }
        let width = CVPixelBufferGetWidth(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<CVPixelBufferGetHeight(buffer) {
            let row = base + y * rowBytes
            for x in 0..<width where row[x * 4 + 3] < opaqueAlpha {
                return true
            }
        }
        return false
    }

    private static func aspectWarning(size: CGSize, projectFrame: CGSize) -> String? {
        guard size.width > 0, size.height > 0, projectFrame.width > 0, projectFrame.height > 0 else { return nil }
        let overlayAspect = size.width / size.height
        let projectAspect = projectFrame.width / projectFrame.height
        guard abs(overlayAspect - projectAspect) / projectAspect > aspectTolerance else { return nil }
        let project = "\(Int(projectFrame.width.rounded()))×\(Int(projectFrame.height.rounded()))"
        return "Пропорции анимации \(Int(size.width.rounded()))×\(Int(size.height.rounded())) "
            + "отличаются от кадра проекта \(project). Если анимация должна закрывать весь кадр, "
            + "рендерьте HyperFrames в размере \(project)."
    }

    private static func seconds(_ value: Double) -> String {
        String(format: "%.2f", value).replacingOccurrences(of: ".", with: ",")
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "\(code)"
    }
}
