@preconcurrency import AVFoundation
import Foundation

private struct AgentShortCandidateArtifact: Encodable {
    let title: String
    let reason: String
    let start: Double
    let end: Double
    let confidence: Double
}

extension AgentService {
    func makeShorts(
        sourcePath: String, confirmModelDownload: Bool,
        runMode: AgentRunMode = .standalone
    ) async -> AgentResponse {
        var activeRunID: UUID?
        do {
            let sourceURL = URL(fileURLWithPath: sourcePath).standardized
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                throw AgentServiceError.missingFile(sourceURL.path)
            }
            let transcriptStore = TranscriptStore(
                cacheDir: store.transcriptsDir, modelsDir: transcriptionModelsDirectory)
            if await !transcriptStore.modelIsCached(), !confirmModelDownload {
                return .failure(
                    command: "make_shorts", code: "MODEL_DOWNLOAD_REQUIRED",
                    message: "Нужна совместимая модель Parakeet Core ML (около 500 МБ).",
                    recovery: "Повторите вызов с confirmModelDownload=true.")
            }
            let asset = AVURLAsset(url: sourceURL)
            guard let duration = try? await asset.load(.duration).seconds,
                duration.isFinite, duration >= ShortsLimits.minSourceDuration
            else {
                throw AgentServiceError.invalidInput("Для shorts нужно видео длительностью от 20 секунд.")
            }
            let displaySize = await Self.displaySize(asset: asset)
            let run = try await beginRun(
                mode: runMode, kind: .makeShorts, sourcePaths: [sourceURL.path],
                stage: "Расшифровка и поиск моментов")
            activeRunID = run.id
            let configuration = try await AgentAIConfigurationResolver.resolve(
                reasoningKey: ShortsController.reasoningKey)
            let service = ShortsCutService(
                transcriptStore: transcriptStore,
                ai: UnifiedAIClient(openRouter: OpenRouterClient()),
                waveforms: waveforms,
                cache: ShortsAnalysisCache(cacheDir: store.shortsAnalysisDir))
            let source = MediaReference(path: sourceURL.path)
            let analysis = try await service.analyze(
                source: source, sourceDuration: duration, count: .five,
                configuration: configuration, thresholdDB: DetectionSettings().thresholdDB,
                status: { status in
                    try? await self.runs.update(id: run.id) { $0.stage = Self.stage(status) }
                })
            let selected = Array(analysis.candidates.filter(\.enabled).prefix(5))
            guard !selected.isEmpty else {
                throw AgentServiceError.invalidInput("ИИ не нашёл самостоятельных фрагментов для shorts.")
            }
            let outputDirectory = sourceURL.deletingLastPathComponent()
                .appendingPathComponent(
                    "\(sourceURL.deletingPathExtension().lastPathComponent)-shorts", isDirectory: true)
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let frame = ShortsFrameSettings(mode: .verticalCrop, canvasColor: .black)
            let subtitles = ShortsSubtitleMode.on(words: analysis.transcript, style: .classic, size: .medium)
            var outputs: [String] = []
            for (index, candidate) in selected.enumerated() {
                let output = ShortsExporter.fileURL(
                    in: outputDirectory, sourceName: sourceURL.deletingPathExtension().lastPathComponent,
                    index: index, title: candidate.title)
                try await ShortsExporter.export(
                    candidate: candidate, sourceURL: sourceURL, displaySize: displaySize,
                    quality: .compact, frameSettings: frame, subtitleMode: subtitles,
                    to: output, progress: { _ in })
                outputs.append(output.path)
                try await runs.update(id: run.id) {
                    $0.progress = Double(index + 1) / Double(selected.count)
                    $0.stage = "Экспорт shorts \(index + 1) из \(selected.count)"
                }
            }
            let artifacts = try await writeShortsArtifacts(
                runID: run.id, transcript: analysis.transcript, candidates: selected)
            try await runs.update(id: run.id) {
                $0.status = .completed; $0.progress = 1; $0.stage = "Shorts готовы"
                $0.summary = "Создано \(outputs.count) вертикальных роликов."
                $0.artifacts["transcript"] = artifacts.transcript.path
                $0.artifacts["candidates"] = artifacts.candidates.path
            }
            return .success(
                command: "make_shorts",
                data: [
                    "jobId": .string(run.id.uuidString), "status": .string("completed"),
                    "outputs": .array(outputs.map { .string($0) }),
                    "transcript": .string("montazhka://runs/\(run.id.uuidString)/transcript"),
                    "candidates": .string("montazhka://runs/\(run.id.uuidString)/candidates"),
                ])
        } catch {
            if let activeRunID { await failRun(id: activeRunID, error: error) }
            return failure("make_shorts", error)
        }
    }

    private func writeShortsArtifacts(
        runID: UUID, transcript: [TranscriptWord], candidates: [ShortCandidate]
    ) async throws -> (transcript: URL, candidates: URL) {
        let directory = try await runs.artifactDirectory(id: runID)
        let transcriptURL = directory.appendingPathComponent("transcript.json")
        try JSONEncoder().encode(TranscriptDocument(words: transcript)).write(
            to: transcriptURL, options: .atomic)
        let candidatesURL = directory.appendingPathComponent("candidates.json")
        let artifacts = candidates.map {
            AgentShortCandidateArtifact(
                title: $0.title, reason: $0.reason, start: $0.start,
                end: $0.end, confidence: $0.confidence)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(artifacts).write(to: candidatesURL, options: .atomic)
        return (transcriptURL, candidatesURL)
    }

    private static func displaySize(asset: AVURLAsset) async -> CGSize {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
            let natural = try? await track.load(.naturalSize),
            let transform = try? await track.load(.preferredTransform)
        else {
            return CGSize(width: 1920, height: 1080)
        }
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    private static func stage(_ status: ShortsStatus) -> String {
        switch status {
        case .idle: "Ожидание"
        case .preparingModel: "Подготовка модели"
        case .transcribing: "Расшифровка"
        case .mapping: "Карта видео"
        case .searching: "Поиск моментов"
        case .ranking: "Отбор моментов"
        case .verifying: "Проверка моментов"
        case .ready: "Анализ готов"
        case .failed(let message): message
        }
    }
}
