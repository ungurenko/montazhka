import AVFoundation
import Foundation
import Testing

@testable import MontazhkaKit

@Suite
@MainActor
struct ExportModelTests {
    @Test
    func exportQualityKeepsExpectedDimensionsAndEstimates() {
        let fullHD = CGSize(width: 1920, height: 1080)

        #expect(ExportQuality.compact.targetDimensions(forDisplaySize: fullHD) == CGSize(width: 1280, height: 720))
        #expect(
            ExportQuality.compact.targetDimensions(forDisplaySize: CGSize(width: 1080, height: 1920))
                == CGSize(width: 720, height: 1280))
        #expect(
            ExportQuality.medium.targetDimensions(forDisplaySize: CGSize(width: 3840, height: 2160))
                == CGSize(width: 1920, height: 1080))
        #expect(
            ExportQuality.maximum.targetDimensions(forDisplaySize: CGSize(width: 3840, height: 2160))
                == CGSize(width: 3840, height: 2160))
        #expect(
            ExportQuality.compact.targetDimensions(forDisplaySize: CGSize(width: 320, height: 180))
                == CGSize(width: 320, height: 180))

        let odd = ExportQuality.medium.targetDimensions(forDisplaySize: CGSize(width: 1279, height: 717))
        #expect(Int(odd.width) % 2 == 0 && Int(odd.height) % 2 == 0)
        #expect(ExportQuality.compact.estimatedBytes(duration: 300, displaySize: fullHD) == 81_744_000)
        #expect(ExportQuality.medium.estimatedBytes(duration: 300, displaySize: fullHD) == 180_492_000)
        #expect(ExportQuality.compact.estimateText(duration: 300, displaySize: fullHD) == "≈ 82 МБ")
        #expect(ExportQuality.maximum.estimateText(duration: 1200, displaySize: fullHD) == "≈ 2.5 ГБ")
    }

    @Test
    func preparationAndExportHaveObservableStates() async throws {
        let exporter = ControlledVideoExporter()
        let model = ExportModel(videoExporter: exporter)
        let destination = URL(fileURLWithPath: "/tmp/montazhka-export-state.mp4")

        #expect(
            model.start(
                preparer: ImmediateExportPreparer(warning: "Тестовое предупреждение"),
                quality: .high,
                to: destination
            ))
        #expect(model.state == .preparing)
        try await waitUntil { model.state == .exporting }
        #expect(model.audioWarning == "Тестовое предупреждение")

        exporter.complete()
        try await waitUntil { model.state == .done(destination, ControlledVideoExporter.report) }
        #expect(model.progress == 1)
    }

    @Test
    func completedWarningsKeepDistinctIdentityUntilNextExport() async throws {
        let report = FinalExportReport(
            loudness: nil, normalized: false, gainDB: 0, targetMet: nil, subtitlesURL: nil,
            subtitlesSkippedReason: nil, warnings: ["Проверочное замечание", "Проверочное замечание"])
        let exporter = ControlledVideoExporter(completedReport: report)
        let model = ExportModel(videoExporter: exporter)
        let destination = URL(fileURLWithPath: "/tmp/montazhka-export-notices.mp4")
        model.start(preparer: ImmediateExportPreparer(), quality: .high, to: destination)
        try await waitUntil { model.state == .exporting }

        exporter.complete()
        try await waitUntil { model.state == .done(destination, report) }
        let ids = try #require(model.resultText).notices.map(\.id)
        #expect(ids.count == 2)
        #expect(Set(ids).count == 2)
        #expect(model.resultText?.notices.map(\.id) == ids)

        model.start(preparer: SlowExportPreparer(), quality: .high, to: destination)
        #expect(model.state == .preparing)
        #expect(model.resultText == nil)
        model.cancel()
    }

    @Test
    func cancellationDuringPreparationReturnsToIdle() async throws {
        let model = ExportModel(videoExporter: ControlledVideoExporter())

        #expect(
            model.start(
                preparer: SlowExportPreparer(),
                quality: .compact,
                to: URL(fileURLWithPath: "/tmp/montazhka-cancel.mp4")
            ))
        model.cancel()
        try await Task.sleep(for: .milliseconds(20))

        #expect(model.state == .idle)
        #expect(model.progress == 0)
        #expect(model.stageCaption == nil)
    }

    @Test
    func secondStartIsRejectedWhileOperationIsRunning() {
        let model = ExportModel(videoExporter: ControlledVideoExporter())
        let preparer = SlowExportPreparer()

        #expect(
            model.start(
                preparer: preparer,
                quality: .high,
                to: URL(fileURLWithPath: "/tmp/montazhka-first.mp4")
            ))
        #expect(
            !model.start(
                preparer: preparer,
                quality: .high,
                to: URL(fileURLWithPath: "/tmp/montazhka-second.mp4")
            ))
        model.cancel()
    }

    @Test
    func exporterFailureBecomesUserVisibleFailure() async throws {
        let model = ExportModel(videoExporter: FailingVideoExporter())

        #expect(
            model.start(
                preparer: ImmediateExportPreparer(),
                quality: .medium,
                to: URL(fileURLWithPath: "/tmp/montazhka-failure.mp4")
            ))
        try await waitUntil {
            if case .failed = model.state { return true }
            return false
        }

        guard case .failed(let message) = model.state else {
            Issue.record("Ожидалось состояние failed")
            return
        }
        #expect(message.message.contains("Проверочная ошибка"))
        #expect(model.stageCaption == nil)
    }

    @Test
    func stageCaptionFollowsPreparationAndExportPasses() async throws {
        let preparer = SteppingExportPreparer()
        let exporter = StagedVideoExporter()
        let model = ExportModel(videoExporter: exporter)
        #expect(model.stageCaption == nil)

        #expect(
            model.start(
                preparer: preparer,
                quality: .high,
                to: URL(fileURLWithPath: "/tmp/montazhka-caption.mp4")
            ))
        #expect(model.stageCaption == "Собираю дорожки и обрабатываю звук")
        try await waitUntil { model.stageCaption == "Распознаю речь" }

        preparer.finish()
        try await waitUntil { model.stageCaption == "Замеряю громкость" }
        exporter.announce(.writing)
        try await waitUntil { model.stageCaption == "Записываю файл" }

        exporter.complete()
        try await waitUntil {
            if case .done = model.state { return true }
            return false
        }
        #expect(model.stageCaption == nil)
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Состояние не изменилось вовремя")
    }
}

@MainActor
private struct ImmediateExportPreparer: ExportPreparing {
    var exportInputFiles: [URL] { [] }
    var warning: String?

    init(warning: String? = nil) {
        self.warning = warning
    }

    func prepareExport(
        quality: ExportQuality, step: @escaping @Sendable (ExportPreparationStep) -> Void
    ) async throws -> PreparedExport {
        PreparedExport(composition: AVMutableComposition(), audioMix: nil, warning: warning)
    }
}

@MainActor
private struct SlowExportPreparer: ExportPreparing {
    var exportInputFiles: [URL] { [] }
    func prepareExport(
        quality: ExportQuality, step: @escaping @Sendable (ExportPreparationStep) -> Void
    ) async throws -> PreparedExport {
        try await Task.sleep(for: .seconds(30))
        return PreparedExport(composition: AVMutableComposition(), audioMix: nil, warning: nil)
    }
}

@MainActor
private final class ControlledVideoExporter: VideoExporting {
    static let report = FinalExportReport(
        loudness: nil, normalized: false, gainDB: 0, targetMet: nil, subtitlesURL: nil,
        subtitlesSkippedReason: "нет расшифровки", warnings: [])
    private var continuation: CheckedContinuation<Void, Error>?
    private let completedReport: FinalExportReport

    init(completedReport: FinalExportReport = ControlledVideoExporter.report) {
        self.completedReport = completedReport
    }

    func export(
        _ prepared: PreparedExport,
        quality: ExportQuality,
        to url: URL,
        progress: @escaping @Sendable (Double) -> Void,
        stage: @escaping @Sendable (FinalExportStage) -> Void
    ) async throws -> FinalExportReport {
        progress(0.5)
        try await withCheckedThrowingContinuation { continuation = $0 }
        return completedReport
    }

    func complete() {
        continuation?.resume()
        continuation = nil
    }
}

/// Сообщает о распознавании речи и ждёт, пока тест его отпустит.
@MainActor
private final class SteppingExportPreparer: ExportPreparing {
    var exportInputFiles: [URL] { [] }
    private var continuation: CheckedContinuation<Void, Never>?

    func prepareExport(
        quality: ExportQuality, step: @escaping @Sendable (ExportPreparationStep) -> Void
    ) async throws -> PreparedExport {
        step(.transcribing(0.4))
        await withCheckedContinuation { continuation = $0 }
        return PreparedExport(composition: AVMutableComposition(), audioMix: nil, warning: nil)
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

/// Проходы записи объявляет тест.
@MainActor
private final class StagedVideoExporter: VideoExporting {
    private var continuation: CheckedContinuation<Void, Error>?
    private var stage: (@Sendable (FinalExportStage) -> Void)?

    func export(
        _ prepared: PreparedExport,
        quality: ExportQuality,
        to url: URL,
        progress: @escaping @Sendable (Double) -> Void,
        stage: @escaping @Sendable (FinalExportStage) -> Void
    ) async throws -> FinalExportReport {
        self.stage = stage
        try await withCheckedThrowingContinuation { continuation = $0 }
        return ControlledVideoExporter.report
    }

    func announce(_ value: FinalExportStage) {
        stage?(value)
    }

    func complete() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private struct FailingVideoExporter: VideoExporting {
    struct Failure: LocalizedError {
        var errorDescription: String? { "Проверочная ошибка" }
    }

    func export(
        _ prepared: PreparedExport,
        quality: ExportQuality,
        to url: URL,
        progress: @escaping @Sendable (Double) -> Void,
        stage: @escaping @Sendable (FinalExportStage) -> Void
    ) async throws -> FinalExportReport {
        throw Failure()
    }
}
