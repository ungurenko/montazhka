@preconcurrency import AVFoundation
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
        let trimmedOutput = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-selftest-subtitles-trimmed-\(runID).mp4")
        let blackFitOutput = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-selftest-fit-black-\(runID).mp4")
        let whiteFitOutput = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-selftest-fit-white-\(runID).mp4")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(at: croppedOutput)
            try? FileManager.default.removeItem(at: trimmedOutput)
            try? FileManager.default.removeItem(at: blackFitOutput)
            try? FileManager.default.removeItem(at: whiteFitOutput)
        }

        do {
            try await TestVideoFactory.make(
                segments: [(duration: 4.0, loud: true)], videoLuma: 96, to: source)
            let words = [
                TranscriptWord(
                    sourceID: UUID(), text: "Проверяем автоматические субтитры",
                    start: 1.2, end: 1.8, confidence: 1),
                TranscriptWord(
                    sourceID: UUID(), text: "в готовом коротком ролике",
                    start: 2.0, end: 2.8, confidence: 1),
            ]
            let mode = ShortsSubtitleMode.on(
                words: words, style: .boxed, size: .large, highlight: true)
            let timeMap = ShortsTimeMap.single(start: 1, end: 3)
            let cues = ShortsSubtitleCueBuilder.make(words: words, timeMap: timeMap)
            check(
                cues.count == 2 && abs((cues.first?.start ?? 0) - 0.2) < 0.001,
                "субтитры собираются с относительными таймкодами")

            // Вырезанная пауза сдвигает всё, что после неё: слова второй фразы
            // приезжают к концу первой.
            let trimmed = ShortsTimeMap(segments: [
                ShortsSegment(start: 1, end: 1.9), ShortsSegment(start: 1.95, end: 3),
            ])
            let trimmedCues = ShortsSubtitleCueBuilder.make(words: words, timeMap: trimmed)
            check(
                trimmedCues.count == 2
                    && abs((trimmedCues.last?.start ?? 0) - 0.95) < 0.01,
                "вырезанная пауза сдвигает субтитры на своей длине")

            let sourceAsset = AVURLAsset(url: source)
            let disabledPlan = try await ShortsVideoCompositionBuilder.make(
                asset: sourceAsset,
                frameRequest: .original,
                subtitleMode: .off,
                subtitleTimeMap: .single(start: 0, end: 0))
            check(
                disabledPlan.videoComposition == nil,
                "выключенные субтитры не добавляют видеокомпозицию")

            let previewPlan = try await ShortsExporter.previewComposition(
                for: sourceAsset,
                frameSettings: ShortsFrameSettings())
            check(
                previewPlan == nil,
                "горизонтальный preview оставляет текстовый слой интерфейсу")
            let previewOverlay = ShortsSubtitleOverlayBuilder.make(
                at: 0.4, timeMap: timeMap, mode: mode)
            check(
                previewOverlay?.text == "Проверяем автоматические субтитры"
                    && previewOverlay?.style == .boxed
                    && previewOverlay?.size == .large
                    && previewOverlay?.activeWordIndex == 0,
                "preview получает активную фразу, стиль и подсвеченное слово")
            let croppedPreview = try await ShortsExporter.previewComposition(
                for: sourceAsset,
                frameSettings: ShortsFrameSettings(mode: .verticalCrop))
            check(
                croppedPreview?.renderSize.height == 180
                    && croppedPreview?.animationTool == nil,
                "вертикальный preview сохраняет кроп без offline-слоя")

            var everyVariantHasLayer = true
            for style in ShortsSubtitleStyle.allCases {
                for size in ShortsSubtitleSize.allCases {
                    let variant = try await ShortsVideoCompositionBuilder.make(
                        asset: sourceAsset,
                        frameRequest: .original,
                        subtitleMode: .on(
                            words: words, style: style, size: size, highlight: true),
                        subtitleTimeMap: .single(start: 1, end: 3))
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
                segments: [], enabled: true)
            try await ShortsExporter.export(
                candidate: candidate,
                timeMap: timeMap,
                sourceURL: source,
                displaySize: CGSize(width: 320, height: 180),
                quality: .compact,
                frameSettings: ShortsFrameSettings(),
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
                timeMap: timeMap,
                sourceURL: source,
                displaySize: CGSize(width: 320, height: 180),
                quality: .compact,
                frameSettings: ShortsFrameSettings(mode: .verticalCrop),
                subtitleMode: mode,
                to: croppedOutput
            ) { _ in }
            try await checkExportedVideo(
                croppedOutput,
                at: 0.4,
                expectedDuration: 2,
                label: "вертикальный MP4 сохраняет субтитры после кропа",
                check: check)

            try await checkTrimmedExport(
                candidate: candidate, source: source, mode: mode,
                output: trimmedOutput, check: check)

            for (color, destination) in [
                (ShortsCanvasColor.black, blackFitOutput),
                (ShortsCanvasColor.white, whiteFitOutput),
            ] {
                try await ShortsExporter.export(
                    candidate: candidate,
                    timeMap: timeMap,
                    sourceURL: source,
                    displaySize: CGSize(width: 320, height: 180),
                    quality: .compact,
                    frameSettings: ShortsFrameSettings(
                        mode: .verticalFit, canvasColor: color),
                    subtitleMode: mode,
                    to: destination
                ) { _ in }
                try await checkVerticalFitExport(
                    destination,
                    expectedBackground: color,
                    expectedDuration: 2,
                    check: check)
            }
        } catch {
            check(false, "экспорт MP4 с автоматическими субтитрами (\(error.localizedDescription))")
        }

        return failures
    }

    private static func checkVerticalFitExport(
        _ url: URL,
        expectedBackground: ShortsCanvasColor,
        expectedDuration: Double,
        check: (Bool, String) -> Void
    ) async throws {
        let exported = AVURLAsset(url: url)
        let duration = (try await exported.load(.duration)).seconds
        let baseline = try image(at: 0.05, in: exported)
        let image = try image(at: 0.4, in: exported)
        let bitmap = NSBitmapImageRep(cgImage: image)
        // NSBitmapImageRep считает y от верха; фон берём выше видео и субтитров.
        let top = bitmap.colorAt(x: image.width / 2, y: image.height / 8)?
            .usingColorSpace(.deviceRGB)
        let center = bitmap.colorAt(x: image.width / 2, y: image.height / 2)?
            .usingColorSpace(.deviceRGB)
        let leftCenter = bitmap.colorAt(x: max(1, image.width / 40), y: image.height / 2)?
            .usingColorSpace(.deviceRGB)
        let backgroundMatches: Bool
        if expectedBackground == .black {
            backgroundMatches = (top?.redComponent ?? 1) < 0.08
        } else {
            backgroundMatches = (top?.redComponent ?? 0) > 0.92
        }
        let sourceIsVisible =
            (0.20...0.60).contains(center?.redComponent ?? 0)
            && (0.20...0.60).contains(leftCenter?.redComponent ?? 0)
        check(
            image.height * 9 == image.width * 16
                && abs(duration - expectedDuration) <= 0.3
                && backgroundMatches
                && sourceIsVisible
                && hasMeaningfulDifference(between: baseline, and: image),
            "видео целиком на \(expectedBackground == .black ? "чёрном" : "белом") фоне и с субтитрами (\(image.width)×\(image.height), фон \(String(format: "%.2f", top?.redComponent ?? -1)), центр \(String(format: "%.2f", center?.redComponent ?? -1)))"
        )
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
        let baseline = try image(at: 0.05, in: exported)
        let image = try image(at: seconds, in: exported)
        check(
            !tracks.isEmpty
                && abs(duration - expectedDuration) <= 0.3
                && hasMeaningfulDifference(between: baseline, and: image),
            "\(label) (\(String(format: "%.2f", duration)) сек)")
    }

    /// Вырезание пауз: длительность файла равна сумме кусков, а на кадре во
    /// время слова видна подсветка.
    private static func checkTrimmedExport(
        candidate: ShortCandidate,
        source: URL,
        mode: ShortsSubtitleMode,
        output: URL,
        check: (Bool, String) -> Void
    ) async throws {
        let trimmedMap = ShortsTimeMap(segments: [
            ShortsSegment(start: 1, end: 1.9), ShortsSegment(start: 2.2, end: 3),
        ])
        try await ShortsExporter.export(
            candidate: candidate,
            timeMap: trimmedMap,
            sourceURL: source,
            displaySize: CGSize(width: 320, height: 180),
            quality: .compact,
            frameSettings: ShortsFrameSettings(),
            subtitleMode: mode,
            to: output
        ) { _ in }
        try await checkExportedVideo(
            output,
            at: 0.4,
            expectedDuration: trimmedMap.outputDuration,
            label: "MP4 без пауз короче исходного диапазона",
            check: check)
        check(
            try hasHighlightColor(in: output, at: 0.4),
            "подсвеченное слово видно в готовом файле")
    }

    /// Жёлтая подсветка активного слова в нижней части кадра.
    private static func hasHighlightColor(in url: URL, at seconds: Double) throws -> Bool {
        let frame = try image(at: seconds, in: AVURLAsset(url: url))
        let bitmap = NSBitmapImageRep(cgImage: frame)
        // NSBitmapImageRep считает y от верха: субтитры живут в нижней трети.
        for y in stride(from: frame.height * 2 / 3, to: frame.height, by: 1) {
            for x in stride(from: 0, to: frame.width, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                else { continue }
                if color.redComponent > 0.6, color.greenComponent > 0.45,
                    color.blueComponent < 0.35
                {
                    return true
                }
            }
        }
        return false
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

    private static func hasMeaningfulDifference(
        between baseline: CGImage,
        and active: CGImage
    ) -> Bool {
        guard baseline.width == active.width, baseline.height == active.height else { return false }
        let before = NSBitmapImageRep(cgImage: baseline)
        let after = NSBitmapImageRep(cgImage: active)
        let stepX = max(1, active.width / 180)
        let stepY = max(1, active.height / 110)
        var changedPixels = 0
        for y in stride(from: 0, to: active.height, by: stepY) {
            for x in stride(from: 0, to: active.width, by: stepX) {
                guard let old = before.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                    let new = after.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                else {
                    continue
                }
                let difference =
                    abs(old.redComponent - new.redComponent)
                    + abs(old.greenComponent - new.greenComponent)
                    + abs(old.blueComponent - new.blueComponent)
                if difference > 0.35 {
                    changedPixels += 1
                    if changedPixels >= 10 { return true }
                }
            }
        }
        return false
    }
}
