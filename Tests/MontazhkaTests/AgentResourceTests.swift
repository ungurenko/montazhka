import Foundation
import Testing

@testable import MontazhkaKit

/// Ресурсы задач агента: текст читается страницами ровно в пределах страницы,
/// видео и прочие медиа отдаются путём и размером, а не байтами как текстом.
@Suite("Agent resources")
struct AgentResourceTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-resource-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Задача с одним артефактом `name` из файла `file`.
    private func run(_ file: URL, name: String, root: URL) async throws -> (AgentService, UUID) {
        let service = AgentService(baseDirectory: root)
        let run = try await service.runs.create(kind: .export, sourcePaths: [])
        try await service.runs.update(id: run.id) { $0.artifacts[name] = file.path }
        return (service, run.id)
    }

    private func page(_ json: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    @Test("a page reads at most the limit plus a few bytes, however big the file is")
    func pageReadsOnlyItsBytes() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("huge.log")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 256 * 1024 * 1024)  // разреженный файл: места на диске не занимает
        try handle.close()
        var bytesRead = 0

        let page = try AgentResourceReader.textPage(at: file, offset: 1_000_000, limit: 1000) { handle, count in
            let data = try handle.read(upToCount: count) ?? Data()
            bytesRead += data.count
            return data
        }

        #expect(bytesRead <= 1000 + 8, "прочитано \(bytesRead) байт")
        #expect(page.total == 256 * 1024 * 1024)
        #expect(page.start == 1_000_000 && page.end == 1_001_000)
    }

    @Test("pages cut across Cyrillic letters join back into the same text")
    func pagesJoinAcrossLetters() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("transcript.json")
        let text = "Привет, мир! Это проверка страниц."
        try Data(text.utf8).write(to: file)
        var joined = ""
        var offset = 0
        for _ in 0..<100 {
            let page = try AgentResourceReader.textPage(at: file, offset: offset, limit: 3)
            joined += page.content
            #expect(!page.content.contains("\u{FFFD}"))
            if page.end >= page.total { break }
            offset = page.end
        }
        #expect(joined == text)
        #expect(
            try AgentResourceReader.textPage(at: file, offset: 1, limit: 4).content == "ри",
            "середина буквы — со следующей")
    }

    @Test("an empty file and out-of-range requests give an empty last page")
    func edgesOfTheFile() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = root.appendingPathComponent("empty.txt")
        try Data().write(to: empty)
        let text = root.appendingPathComponent("short.txt")
        try Data("абв".utf8).write(to: text)

        let emptyPage = try AgentResourceReader.textPage(at: empty, offset: 0, limit: 100)
        #expect(emptyPage.content.isEmpty && emptyPage.total == 0)
        let beyond = try AgentResourceReader.textPage(at: text, offset: 1000, limit: 100)
        #expect(beyond.content.isEmpty && beyond.start == 6 && beyond.end == 6)
        let negative = try AgentResourceReader.textPage(at: text, offset: -5, limit: 0)
        #expect(negative.start == 0 && negative.content == "а", "отрицательный сдвиг — с начала, лимит не меньше буквы")
    }

    @Test("a finished MP4 is described by path and size, not decoded as text")
    func videoIsNotText() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("final.mp4")
        try Data(repeating: 0xFF, count: 5000).write(to: video)
        let (service, id) = try await run(video, name: "final", root: root)

        let object = try page(try await service.resource(uri: "montazhka://runs/\(id.uuidString)/final"))

        #expect(object["content"] == nil, "байты видео не идут текстом")
        #expect(object["kind"] as? String == "media")
        #expect(object["mimeType"] as? String == "video/mp4")
        #expect(object["path"] as? String == video.path)
        #expect(object["totalBytes"] as? Int == 5000)
    }
}
