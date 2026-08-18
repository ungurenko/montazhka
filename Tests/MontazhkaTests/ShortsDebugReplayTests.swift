import Foundation
import XCTest
@testable import Montazhka

/// Регрессия реального сбоя: DeepSeek V4 Flash на втором окне вернул JSON
/// в markdown-ограждении и с эхо-обёрткой запроса {"name":…, "schema": {…}}.
/// Декодер должен развернуть обёртку без ремонтного вызова.
final class ShortsDebugReplayTests: XCTestCase {
    func testRealDeepSeekWrapperResponseUnwrapsWithoutRepair() throws {
        let raw = """
        ```json
        {
          "name": "shorts_clips",
          "schema": {
            "schema_version": 1,
            "clips": [
              {
                "id": "confirm-plan-and-build",
                "first_word_id": "w002593",
                "last_word_id": "w002641",
                "title": "Он спросит согласия, прежде чем менять код",
                "reason": "Цельный практический отрывок: ассистент сперва предлагает план, а перед выполнением запрашивает подтверждение.",
                "confidence": 0.92
              },
              {
                "id": "agent-vs-chatbot",
                "first_word_id": "w002746",
                "last_word_id": "w002795",
                "title": "Чем ИИ-агент отличается от чат-бота",
                "reason": "Сильный и понятный отрывок без контекста: объясняет, что агент может выполнить команду на компьютере.",
                "confidence": 0.94
              }
            ]
          }
        }
        ```
        """

        // Слова окна 2: ID должны существовать в переданном массиве.
        var words: [OpenRouterTranscriptWord] = []
        for index in 2593...2800 {
            let time = Double(index - 2593) * 0.4
            words.append(OpenRouterTranscriptWord(
                id: String(format: "w%06d", index),
                text: "слово", start: time, end: time + 0.3))
        }

        let envelope = try OpenRouterClient.decodeShortsProposals(raw, words: words)
        XCTAssertEqual(envelope.clips.map(\.id), ["confirm-plan-and-build", "agent-vs-chatbot"])
        XCTAssertEqual(envelope.clips.first?.firstWordID, "w002593")
    }

    /// Тот же ответ, но уже без ограждений (модель вернула чистый JSON с обёрткой).
    func testRealDeepSeekWrapperWithoutFenceUnwraps() throws {
        let raw = """
        {
          "name": "shorts_clips",
          "schema": {
            "schema_version": 1,
            "clips": [{"id":"agent-vs-chatbot","first_word_id":"w002746","last_word_id":"w002795","title":"т","reason":"р","confidence":0.94}]
          }
        }
        """
        let words = [OpenRouterTranscriptWord(id: "w002746", text: "а", start: 0, end: 1),
                     OpenRouterTranscriptWord(id: "w002795", text: "б", start: 1, end: 2)]
        let envelope = try OpenRouterClient.decodeShortsProposals(raw, words: words)
        XCTAssertEqual(envelope.clips.map(\.id), ["agent-vs-chatbot"])
    }
}
