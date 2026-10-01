import Foundation
import Testing

@testable import MontazhkaKit

@Suite
struct ExportResultTextTests {
    private static let onTarget = LoudnessMeasurement(
        integratedLUFS: -14.02, truePeakDBTP: -1.27, loudnessRangeLU: 5, seconds: 10)

    private func report(
        loudness: LoudnessMeasurement? = onTarget,
        normalized: Bool = true,
        targetMet: Bool? = true,
        subtitlesURL: URL? = nil,
        skippedReason: String? = nil,
        warnings: [String] = []
    ) -> FinalExportReport {
        FinalExportReport(
            loudness: loudness, normalized: normalized, gainDB: 3, targetMet: targetMet,
            subtitlesURL: subtitlesURL, subtitlesSkippedReason: skippedReason, warnings: warnings)
    }

    @Test
    func loudnessLineUsesDecimalCommaAndRealMinus() {
        let text = ExportResultText(report: report())

        #expect(text.loudness == "Громкость: −14,0 LUFS · пик −1,3 dBTP")
        #expect(text.loudnessHint == "Как требуют YouTube и соцсети")
        #expect(text.notices.isEmpty)
    }

    @Test
    func decibelsRoundToOneDecimalWithoutNegativeZero() {
        #expect(ExportResultText.decibels(-0.04) == "0,0")
        #expect(ExportResultText.decibels(-23.96) == "−24,0")
        #expect(ExportResultText.decibels(1.5) == "1,5")
        #expect(ExportResultText.decibels(-.infinity) == "—")
    }

    @Test
    func missingLoudnessHasNoLine() {
        let unmeasured = ExportResultText(report: report(loudness: nil, targetMet: nil))
        #expect(unmeasured.loudness == nil)
        #expect(unmeasured.loudnessHint == nil)

        let silence = LoudnessMeasurement(integratedLUFS: nil, truePeakDBTP: -70, loudnessRangeLU: nil, seconds: 4)
        #expect(ExportResultText(report: report(loudness: silence, normalized: false, targetMet: nil)).loudness == nil)
    }

    @Test
    func loudnessKeptAsIsIsSaidPlainly() {
        let text = ExportResultText(report: report(normalized: false, targetMet: nil))

        #expect(text.loudness == "Громкость: −14,0 LUFS · пик −1,3 dBTP")
        #expect(text.loudnessHint == "Громкость оставлена как есть")
    }

    @Test
    func missedTargetBecomesPlainNoticeInsteadOfNumbers() {
        let leftover = "Рядом с видео остались субтитры прошлого экспорта: Ролик.srt"
        let text = ExportResultText(
            report: report(
                targetMet: false,
                warnings: [leftover, "Громкость не вышла на стандарт: -12.1 LUFS, пик -0.4 dBTP"]))

        #expect(text.notices.map(\.title) == ["Громкость не совсем по стандарту площадок", leftover])
        #expect(text.notices.first?.hint == "Ролик может звучать чуть тише или громче других. Выкладывать можно")
        #expect(text.loudnessHint == nil)
    }

    @Test
    func otherWarningsAreShownAsTheyAre() {
        let text = ExportResultText(
            report: report(loudness: nil, targetMet: nil, warnings: ["Не получилось замерить громкость готового файла"])
        )

        #expect(text.notices.map(\.title) == ["Не получилось замерить громкость готового файла"])
        #expect(text.notices.first?.hint == nil)
    }

    @Test
    func subtitlesShowFileNameOrWhyTheyAreMissing() {
        let file = URL(fileURLWithPath: "/tmp/Мой ролик.srt")
        let saved = ExportResultText(report: report(subtitlesURL: file))
        #expect(saved.subtitles == "Субтитры: Мой ролик.srt")
        #expect(saved.subtitlesURL == file)
        #expect(saved.subtitlesSkipped == nil)

        let skipped = ExportResultText(report: report(skippedReason: "Нет расшифровки — субтитры не созданы"))
        #expect(skipped.subtitles == nil)
        #expect(skipped.subtitlesSkipped == "Нет расшифровки — субтитры не созданы")
    }
}
