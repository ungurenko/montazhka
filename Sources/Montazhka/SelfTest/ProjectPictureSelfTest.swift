@preconcurrency import AVFoundation
import AppKit
import CoreGraphics
import Foundation

/// Картинка обычного горизонтального ролика в готовом MP4: вшитые субтитры видны только
/// во время фразы, анимация — только в своём окне. Текст рисуется только здесь: в
/// `swift test` CoreText не выводит глифы.
enum ProjectPictureSelfTest {
    static func run() async -> Int {
        print("Картинка обычного ролика (вшитые субтитры и анимация):")
        var failures = 0

        func check(_ condition: Bool, _ label: String) {
            if condition {
                print("  ✓ \(label)")
            } else {
                failures += 1
                print("  ✗ ПРОВАЛ: \(label)")
            }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-picture-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let output = try await exportPicture(in: root)
            let asset = AVURLAsset(url: output)
            // Фраза звучит 0,4–1,6 с, анимация видна 2,5–3,5 с.
            let plain = try image(at: 2.2, in: asset)
            let during = inkPixels(in: try image(at: 1.0, in: asset), rows: 0.5...1)
            let between = inkPixels(in: plain, rows: 0.5...1)
            check(
                during > 20 && between == 0,
                "субтитры впечатаны в нижнюю часть кадра только во время фразы (\(during) / \(between) px)")
            // Основу сравниваем с кадром этого же файла: генератор кадров управляет цветом.
            let base = centre(of: plain)
            let shown = centre(of: try image(at: 3.0, in: asset))
            let after = centre(of: try image(at: 3.8, in: asset))
            let restored = [(after.red, base.red), (after.green, base.green), (after.blue, base.blue)]
                .allSatisfy { abs($0 - $1) < 0.05 }
            check(
                shown.red > 0.85 && shown.green < 0.25 && shown.blue < 0.25 && restored,
                "анимация видна в MP4 в своё время и не залипает после конца "
                    + "(\(format(shown)) → \(format(after)), основа \(format(base)))")
        } catch {
            check(false, "экспорт ролика с вшитыми субтитрами и анимацией (\(error.localizedDescription))")
        }
        return failures
    }

    /// Серый ролик 4 с со словами 0,4–1,6 с и анимацией 1 с на 2,5 с, выгруженный агентом
    /// с `burnSubtitles`.
    private static func exportPicture(in root: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let video = root.appendingPathComponent("source.mov")
        try await TestVideoFactory.make(segments: [(duration: 4.0, loud: true)], videoLuma: 128, to: video)
        let overlayURL = root.appendingPathComponent("overlay.mov")
        try await TestOverlayFactory.make(width: 320, height: 180, duration: 1, to: overlayURL)

        let service = AgentService(baseDirectory: root)
        let media = MediaReference(url: video)
        var project = Project(name: "Самопроверка картинки", clips: [Clip(source: media, start: 0, end: 4)])
        project.overlays = [
            ProjectOverlay(
                id: UUID(), media: MediaReference(url: overlayURL),
                anchor: OverlayAnchor(sourceID: media.id, sourceTime: 2.5, wordText: nil),
                align: .start, payoffAt: 0, duration: 1, position: .full, scale: 1)
        ]
        try await service.store.save(project)
        let words = [
            TranscriptWord(sourceID: media.id, text: "Проверяем", start: 0.4, end: 0.9, confidence: 1),
            TranscriptWord(sourceID: media.id, text: "вшитые", start: 0.95, end: 1.2, confidence: 1),
            TranscriptWord(sourceID: media.id, text: "субтитры", start: 1.25, end: 1.6, confidence: 1),
        ]
        let cacheURL = await service.makeTranscriptStore().cacheURL(for: media)
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(TranscriptDocument(words: words)).write(to: cacheURL)

        let output = root.appendingPathComponent("picture.mp4")
        let response = await service.export(
            projectID: project.id, outputPath: output.path, quality: "compact",
            final: false, confirmFinal: false, overwrite: false, burnSubtitles: true)
        guard response.ok else {
            throw TestOverlayFactory.Failure(reason: response.error?.message ?? "экспорт не удался")
        }
        return output
    }

    /// Сколько пикселей в полосе `rows` (доли высоты сверху вниз) заметно отличаются от
    /// серой основы (≈ 0,5–0,6 после управления цветом): надпись любого цвета, тень, плашка.
    private static func inkPixels(in image: CGImage, rows: ClosedRange<Double>) -> Int {
        let bitmap = NSBitmapImageRep(cgImage: image)
        var count = 0
        for y in Int(Double(image.height) * rows.lowerBound)..<Int(Double(image.height) * rows.upperBound) {
            for x in stride(from: 0, to: image.width, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let offset = max(
                    abs(color.redComponent - 0.55), abs(color.greenComponent - 0.55),
                    abs(color.blueComponent - 0.55))
                if offset > 0.25 { count += 1 }
            }
        }
        return count
    }

    private static func centre(of image: CGImage) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        let color = NSBitmapImageRep(cgImage: image).colorAt(x: image.width / 2, y: image.height / 2)?
            .usingColorSpace(.deviceRGB)
        return (color?.redComponent ?? -1, color?.greenComponent ?? -1, color?.blueComponent ?? -1)
    }

    private static func format(_ color: (red: CGFloat, green: CGFloat, blue: CGFloat)) -> String {
        String(format: "%.2f, %.2f, %.2f", color.red, color.green, color.blue)
    }

    /// Кадр готового файла без видеокомпозиции — так генератор кадров надёжен.
    private static func image(at seconds: Double, in asset: AVAsset) throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
    }
}
