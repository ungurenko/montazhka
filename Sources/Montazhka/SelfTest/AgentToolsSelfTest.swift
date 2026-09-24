import Foundation

/// «Глаза, уши и ножницы» агента на настоящем видео: кадры, громкость, правки и отмена.
/// Работает во временной папке — проекты пользователя не трогает.
enum AgentToolsSelfTest {
    static func run() async -> Int {
        print("Инструменты агента (кадры, звук, правки):")
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
            .appendingPathComponent("montazhka-agent-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("source.mov")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            // Звук 0–3 с, тишина 3–5 с, звук 5–8 с.
            try await TestVideoFactory.make(
                segments: [(3.0, true), (2.0, false), (3.0, true)], videoLuma: 128, to: video)
        } catch {
            check(false, "тестовое видео (\(error.localizedDescription))")
            return failures
        }

        let service = AgentService(baseDirectory: root)
        let project = Project(name: "Самопроверка агента", clips: [Clip(sourcePath: video.path, start: 0, end: 8)])
        do {
            try await service.store.save(project)
        } catch {
            check(false, "сохранение проекта (\(error.localizedDescription))")
            return failures
        }

        let audio = await service.audio(
            target: AgentMediaTarget(projectID: project.id), from: nil, to: nil, buckets: 8)
        if case .array(let silences)? = audio.data?["silences"], silences.count == 1,
            case .object(let silence) = silences[0],
            case .number(let from)? = silence["from"], case .number(let to)? = silence["to"]
        {
            check(abs(from - 3) < 0.1 && abs(to - 5) < 0.1, "звук: тишина найдена на 3–5 с")
        } else {
            check(false, "звук: тишина найдена на 3–5 с (\(audio.error?.message ?? "нет данных"))")
        }

        let edited = await service.applyEdits(
            projectID: project.id,
            operations: (try? AgentEditOperation.decodeList(
                Data(#"[{"op":"delete","ranges":[{"from":3,"to":5}]}]"#.utf8))) ?? [])
        check(edited.data?["duration"] == .number(6), "правка: пауза вырезана, осталось 6 с")

        let frames = await service.frames(
            AgentFramesRequest(target: AgentMediaTarget(projectID: project.id), aroundCuts: true))
        if case .string(let path)? = frames.data?["imagePath"] {
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            check(frames.data?["extracted"] == .number(2) && size > 0, "кадры: картинка «до/после» склейки")
        } else {
            check(false, "кадры: картинка «до/после» склейки (\(frames.error?.message ?? "нет данных"))")
        }

        let undone = await service.applyEdits(
            projectID: project.id, operations: [AgentEditOperation(op: "undo")])
        check(undone.data?["duration"] == .number(8), "отмена: вернулась исходная длина 8 с")
        return failures
    }
}
