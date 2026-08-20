import Foundation

actor SmartEditService {
    private let transcriptStore: TranscriptStore
    private let openRouter: OpenRouterClient
    private let waveforms: WaveformStore

    init(
        transcriptStore: TranscriptStore, openRouter: OpenRouterClient,
        waveforms: WaveformStore
    ) {
        self.transcriptStore = transcriptStore
        self.openRouter = openRouter
        self.waveforms = waveforms
    }

    func analyze(
        clips: [Clip], projectThresholdDB: Double,
        model: SmartEditModel, effort: String?, apiKey: String,
        status: @escaping @Sendable (SmartEditStatus) async -> Void
    ) async throws -> SmartEditAnalysisResult {
        let snapshot = SmartEditSnapshot(clips: clips)
        try await openRouter.ensureModelAvailable(model, apiKey: apiKey)
        let cached = await transcriptStore.modelIsCached()
        if !cached { await status(.preparingModel(progress: nil)) }

        var seen = Set<UUID>()
        let sources = clips.compactMap { seen.insert($0.source.id).inserted ? $0.source : nil }
        var transcripts: [TranscriptWord] = []
        for (index, source) in sources.enumerated() {
            try Task.checkCancellation()
            let preparesModel = index == 0 && !cached
            if !preparesModel {
                await status(.transcribing(done: index, total: sources.count, progress: nil))
            }
            let words = try await transcriptStore.ensure(source: source) { progress in
                Task {
                    if preparesModel, (progress ?? 0) < 1 {
                        await status(.preparingModel(progress: progress))
                    } else {
                        await status(.transcribing(done: index, total: sources.count, progress: nil))
                    }
                }
            }
            transcripts.append(contentsOf: words)
            await status(.transcribing(done: index + 1, total: sources.count, progress: 1))
        }

        let timelineMap = TranscriptTimelineMapper.make(clips: clips, transcripts: transcripts)
        guard !timelineMap.words.isEmpty else { throw SmartEditError.emptyTranscript }

        await status(.proposing)
        let proposals = try await openRouter.propose(
            words: timelineMap.words.map(\.publicPayload), model: model,
            effort: effort, apiKey: apiKey)
        try Task.checkCancellation()
        await status(.reviewing)
        let reviews = try await openRouter.review(
            words: timelineMap.words.map(\.publicPayload), proposals: proposals,
            model: model, effort: effort, apiKey: apiKey)
        try Task.checkCancellation()
        await status(.preparingCuts)

        let proposalByID = Dictionary(uniqueKeysWithValues: proposals.edits.map { ($0.id, $0) })
        let clipStarts = timelineStarts(clips: clips)
        var candidates: [SmartEditCandidate] = []
        for review in reviews.decisions where review.decision == .accept {
            guard let proposal = proposalByID[review.editID],
                let words = timelineMap.range(
                    firstWordID: review.firstWordID,
                    lastWordID: review.lastWordID),
                let first = words.first,
                let clip = clips.first(where: { $0.id == first.clipID }),
                let clipTimelineStart = clipStarts[clip.id]
            else { continue }
            let confidence = min(proposal.confidence, review.confidence)
            guard confidence >= 0.75 else { continue }
            guard let peaks = await waveforms.ensure(path: clip.sourcePath),
                let boundary = SmartCutBoundaryResolver.resolve(
                    words: words, clip: clip, clipTimelineStart: clipTimelineStart,
                    peaks: peaks, projectThresholdDB: projectThresholdDB)
            else { continue }
            let text = words.map(\.text).joined(separator: " ")
            candidates.append(
                SmartEditCandidate(
                    id: UUID(), kind: proposal.kind, reason: review.reason,
                    originalText: text,
                    timelineStart: boundary.timelineStart, timelineEnd: boundary.timelineEnd,
                    confidence: confidence,
                    enabled: SmartEditSelection.shouldEnable(
                        kind: proposal.kind, confidence: confidence, hasSafeBoundary: true)
                ))
        }

        await status(.ready)
        return SmartEditAnalysisResult(
            snapshot: snapshot,
            candidates: candidates.sorted { $0.timelineStart < $1.timelineStart })
    }

    private func timelineStarts(clips: [Clip]) -> [UUID: Double] {
        var cursor = 0.0
        var result: [UUID: Double] = [:]
        for clip in clips {
            result[clip.id] = cursor
            cursor += clip.duration
        }
        return result
    }
}
