import AVFoundation
import AppKit
import CoreGraphics
import Foundation

/// Интеграционная проверка субтитров: от композиции до видимых пикселей MP4.
enum ShortsSubtitleSelfTest {
    static func run() async -> Int {
        print("Автоматические субтитры:")
        var failures = 0

        func check(_ condition: Bool, _ label: String) {
            if condition {
                print("  ✓ \(label)")
            } else {
                failures += 1
                print("  ✗ ПРОВАЛ: \(label)")
            }
        }

        let runID = UUID().uuidString
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-selftest-subtitles-\(runID).mov")
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-selftest-subtitles-\(runID).mp4")
        let croppedOutput = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-selftest-subtitles-cropped-\(runID).mp4")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(at: croppedOutput)
        }

        do {
            try await TestVideoFactory.make(
                segments: [(duration: 4.0, loud: true)], to: source)
            let words = [
                TranscriptWord(
                    sourceID: UUID(), text: "Проверяем автоматические субтитры",
                    start: 1.2, end: 1.8, confidence: 1),
                TranscriptWord(
                    sourceID: UUID(), text: "в готовом коротком ролике",
                    start: 2.0, end: 2.8, confidence: 1),
            ]
            let mode = ShortsSubtitleMode.on(
                words: words, style: .boxed, size: .large)
            let cues = ShortsSubtitleCueBuilder.make(
                words: words, sourceStart: 1, sourceEnd: 3, relativeTo: 1)
            check(
                cues.count == 2 && abs((cues.first?.start ?? 0) - 0.2) < 0.001,
                "субтитры собираются с относительными таймкодами")

            let sourceAsset = AVURLAsset(url: source)
            let disabledPlan = await ShortsVideoCompositionBuilder.make(
                asset: sourceAsset,
                displaySize: CGSize(width: 320, height: 180),
                cropVertical: false,
                subtitleMode: .off,
                subtitleTimeline: .empty)
            check(
                disabledPlan.videoComposition == nil,
                "выключенные субтитры не добавляют видеокомпозицию")

            let previewPlan = await ShortsExporter.previewComposition(
                for: sourceAsset,
                displaySize: CGSize(width: 320, height: 180),
                cropVertical: false)
            check(
                previewPlan == nil,
                "горизонтальный preview оставляет текстовый слой интерфейсу")
            let previewOverlay = ShortsSubtitleOverlayBuilder.make(
                at: 1.4, sourceStart: 1, sourceEnd: 3, mode: mode)
            check(
                previewOverlay?.text == "Проверяем автоматические субтитры"
                    && previewOverlay?.style == .boxed
                    && previewOverlay?.size == .large,
                "preview получает активную фразу и выбранный стиль")
            let croppedPreview = await ShortsExporter.previewComposition(
                for: sourceAsset,
                displaySize: CGSize(width: 320, height: 180),
                cropVertical: true)
            check(
                croppedPreview?.renderSize.height == 180
                    && croppedPreview?.animationTool == nil,
                "вертикальный preview сохраняет кроп без offline-слоя")

            var everyVariantHasLayer = true
            for style in ShortsSubtitleStyle.allCases {
                for size in ShortsSubtitleSize.allCases {
                    let variant = await ShortsVideoCompositionBuilder.make(
                        asset: sourceAsset,
                        displaySize: CGSize(width: 320, height: 180),
                        cropVertical: false,
                        subtitleMode: .on(words: words, style: style, size: size),
                        subtitleTimeline: ShortsSubtitleTimeline(
                            sourceStart: 1,
                            sourceEnd: 3,
                            relativeTo: 0,
                            duration: 4))
                    everyVariantHasLayer =
                        everyVariantHasLayer
                        && variant.videoComposition?.animationTool != nil
                }
            }
            check(everyVariantHasLayer, "все стили и размеры создают слой субтитров")

            let candidate = ShortCandidate(
                id: UUID(), rank: 1, title: "Проверка субтитров", reason: "", hook: "",
                pattern: "", excerpt: "", start: 1, end: 3, confidence: 1,
                hookScore: 10, standaloneScore: 10, payoffScore: 10, pacingScore: 10,
                enabled: true)
            try await ShortsExporter.export(
                candidate: candidate,
                sourceURL: source,
                displaySize: CGSize(width: 320, height: 180),
                quality: .compact,
                cropVertical: false,
                subtitleMode: mode,
                to: output
            ) { _ in }
            try await checkExportedVideo(
                output,
                at: 0.4,
                expectedDuration: 2,
                label: "горизонтальный MP4 содержит видимые субтитры",
                check: check)

            try await ShortsExporter.export(
                candidate: candidate,
                sourceURL: source,
                displaySize: CGSize(width: 320, height: 180),
                quality: .compact,
                cropVertical: true,
                subtitleMode: mode,
                to: croppedOutput
            ) { _ in }
            try await checkExportedVideo(
                croppedOutput,
                at: 0.4,
                expectedDuration: 2,
                label: "вертикальный MP4 сохраняет субтитры после кропа",
                check: check)
        } catch {
            check(false, "экспорт MP4 с автоматическими субтитрами (\(error.localizedDescription))")
        }

        return failures
    }

    private static func checkExportedVideo(
        _ url: URL,
        at seconds: Double,
        expectedDuration: Double,
        label: String,
        check: (Bool, String) -> Void
    ) async throws {
        let exported = AVURLAsset(url: url)
        let duration = (try await exported.load(.duration)).seconds
        let tracks = try await exported.loadTracks(withMediaType: .video)
        let image = try image(at: seconds, in: exported)
        check(
            !tracks.isEmpty
                && abs(duration - expectedDuration) <= 0.3
                && hasBrightPixels(image),
            "\(label) (\(String(format: "%.2f", duration)) сек)")
    }

    private static func image(
        at seconds: Double,
        in asset: AVAsset,
        videoComposition: AVVideoComposition? = nil
    ) throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.videoComposition = videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try generator.copyCGImage(
            at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
    }

    private static func hasBrightPixels(_ image: CGImage) -> Bool {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let stepX = max(1, image.width / 160)
        let stepY = max(1, image.height / 90)
        var brightPixels = 0
        for y in stride(from: 0, to: image.height, by: stepY) {
            for x in stride(from: 0, to: image.width, by: stepX) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                if color.redComponent + color.greenComponent + color.blueComponent > 1.35 {
                    brightPixels += 1
                    if brightPixels >= 8 { return true }
                }
            }
        }
        return false
    }
}
