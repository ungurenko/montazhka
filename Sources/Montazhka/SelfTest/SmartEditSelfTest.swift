import Foundation

enum SmartEditSelfTest {
    static func run() -> Int {
        print("Умный монтаж:")
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            if condition { print("  ✓ \(label)") } else { failures += 1; print("  ✗ ПРОВАЛ: \(label)") }
        }

        let source = MediaReference(path: "/tmp/smart-edit.mov")
        let clip = Clip(source: source, start: 1, end: 9)
        let words = [
            TranscriptWord(sourceID: source.id, text: "я", start: 2.1, end: 2.2, confidence: 0.95),
            TranscriptWord(sourceID: source.id, text: "точнее", start: 2.25, end: 2.55, confidence: 0.94),
            TranscriptWord(sourceID: source.id, text: "мы", start: 2.6, end: 2.72, confidence: 0.96),
        ]
        let map = TranscriptTimelineMapper.make(clips: [clip], transcripts: words)
        check(
            map.words.map(\.wordID) == ["w000001", "w000002", "w000003"]
                && abs((map.words.first?.timelineStart ?? 0) - 1.1) < 0.001,
            "слова получают обезличенные ID и точные координаты ленты")
        check(
            map.range(firstWordID: "w000003", lastWordID: "w000001") == nil
                && map.range(firstWordID: "unknown", lastWordID: "w000002") == nil,
            "неизвестные и перевёрнутые диапазоны отклоняются")

        let proposalJSON = """
            {"schema_version":1,"edits":[{"id":"e1","kind":"false_start","first_word_id":"w000001","last_word_id":"w000002","reason":"Фраза начата заново","confidence":0.96}]}
            """
        do {
            let payloadWords = map.words.map(\.publicPayload)
            let proposals = try OpenRouterClient.decodeProposals(proposalJSON, words: payloadWords)
            let reviewJSON = """
                {"schema_version":1,"decisions":[{"edit_id":"e1","decision":"accept","first_word_id":"w000001","last_word_id":"w000002","reason":"Смысл сохраняется","confidence":0.94}]}
                """
            let reviews = try OpenRouterClient.decodeReviews(
                reviewJSON, proposals: proposals, words: payloadWords)
            check(
                proposals.edits.count == 1 && reviews.decisions.first?.decision == .accept,
                "оба JSON-контракта проходят строгую локальную проверку")

            let expandedReviewJSON = """
                {"schema_version":1,"decisions":[{"edit_id":"e1","decision":"accept","first_word_id":"w000001","last_word_id":"w000003","reason":"слишком широко","confidence":0.94}]}
                """
            do {
                _ = try OpenRouterClient.decodeReviews(
                    expandedReviewJSON, proposals: proposals, words: payloadWords)
                check(false, "второй ИИ-проход не может расширить диапазон вырезки")
            } catch {
                check(true, "второй ИИ-проход не может расширить диапазон вырезки")
            }
        } catch {
            check(false, "оба JSON-контракта проходят строгую локальную проверку")
        }

        let mapped = ArraySlice(map.words[0...1])
        var quietPeaks = [Float](repeating: 0.08, count: 1_000)
        for index in 198..<212 { quietPeaks[index] = 0.001 }
        for index in 255..<270 { quietPeaks[index] = 0.001 }
        let boundary = SmartCutBoundaryResolver.resolve(
            words: mapped, clip: clip, clipTimelineStart: 0,
            peaks: quietPeaks, projectThresholdDB: -40)
        check(
            boundary != nil && (boundary!.timelineEnd - boundary!.timelineStart) >= 0.25,
            "тихие точки превращаются в безопасную склейку")
        let loudBoundary = SmartCutBoundaryResolver.resolve(
            words: mapped, clip: clip, clipTimelineStart: 0,
            peaks: [Float](repeating: 0.08, count: 1_000), projectThresholdDB: -40)
        check(loudBoundary == nil, "склейка вплотную к громкой речи отклоняется")

        check(
            SmartEditSelection.shouldEnable(kind: .falseStart, confidence: 0.94, hasSafeBoundary: true)
                && !SmartEditSelection.shouldEnable(kind: .semanticRepeat, confidence: 0.99, hasSafeBoundary: true)
                && !SmartEditSelection.shouldEnable(kind: .duplicateTake, confidence: 0.89, hasSafeBoundary: true),
            "бережный режим включает только уверенные явные исправления")
        check(
            SmartEditStatus.idle.allowsAnalysisStart && SmartEditStatus.failed("ошибка").allowsAnalysisStart
                && !SmartEditStatus.proposing.allowsAnalysisStart,
            "после ошибки анализ можно запустить повторно")

        let merged = SmartEditRanges.merged([(1, 2), (1.5, 3), (3, 4)])
        check(
            merged.count == 2 && merged[0].start == 1 && merged[0].end == 3,
            "объединяются только пересекающиеся диапазоны")

        var editor = ProjectEditor(project: Project(name: "Тест", clips: [clip]))
        editor.recordCurrent()
        editor.apply(
            .replaceClips(
                TimelineOps.removingRange(
                    clips: editor.project.clips, start: 1, end: 2)), recordHistory: false)
        let editedCount = editor.project.clips.count
        let restored = editor.undo()
        let repeated = editor.redo()
        check(
            editedCount == 2 && restored?.clips == [clip] && repeated?.clips.count == 2,
            "пакетная правка полностью возвращается одним undo и повторяется одним redo")

        return failures
    }
}
