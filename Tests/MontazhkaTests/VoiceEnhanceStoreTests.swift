import Foundation
import Testing

@testable import MontazhkaKit

/// Кэш обработанного голоса делят окно и агент: у каждой обработки свои рабочие файлы,
/// отмена одной не портит другую, а вариант, который читает идущий экспорт, не удаляется.
@Suite("Voice enhance cache")
struct VoiceEnhanceStoreTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-voice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Любой существующий файл годится как исходник: рендер подменён.
    private func source(in root: URL) throws -> String {
        let url = root.appendingPathComponent("source.mov")
        try Data("видео".utf8).write(to: url)
        return url.path
    }

    @Test("two stores on one folder render into their own work files; cancelling one keeps the other")
    func parallelStoresDoNotShareWorkFiles() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let path = try source(in: root)
        let renders = RenderGate()
        let window = VoiceEnhanceStore(cacheDir: cache, render: renders.render)
        let agent = VoiceEnhanceStore(cacheDir: cache, render: renders.render)
        let settings = VoiceEnhanceSettings(enabled: true)

        let first = Task { try await window.ensure(source: path, settings: settings) }
        let second = Task { try await agent.ensure(source: path, settings: settings) }
        try await renders.waitForStarted(2)
        let targets = await renders.targets
        #expect(Set(targets).count == 2, "у каждой обработки свой рабочий файл: \(targets.map(\.lastPathComponent))")

        await window.cancelAll()
        await renders.open()
        _ = await first.result
        let url = try await second.value

        #expect(try String(contentsOf: url, encoding: .utf8) == "обработанный голос")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: cache.path)
            .filter { $0 != url.lastPathComponent }
        #expect(leftovers.isEmpty, "рабочие файлы убраны: \(leftovers)")
    }

    @Test("a variant held by a running export survives another variant; once released it is cleaned up")
    func heldVariantSurvivesEviction() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try source(in: root)
        let store = VoiceEnhanceStore(cacheDir: root.appendingPathComponent("cache"), render: RenderGate.immediate)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("cache"), withIntermediateDirectories: true)
        var soft = VoiceEnhanceSettings(enabled: true)
        soft.leveling = 20
        var strong = VoiceEnhanceSettings(enabled: true)
        strong.leveling = 90
        var third = VoiceEnhanceSettings(enabled: true)
        third.leveling = 60

        let variantA = try await store.ensure(source: path, settings: soft)
        var lease = CacheFileLease(url: variantA)
        #expect(lease != nil)
        _ = try await store.ensure(source: path, settings: strong)

        #expect(FileManager.default.fileExists(atPath: variantA.path), "идущий экспорт дочитает свой вариант")

        lease = nil
        _ = try await store.ensure(source: path, settings: third)
        #expect(!FileManager.default.fileExists(atPath: variantA.path), "отпущенный вариант убран")
        withExtendedLifetime(lease) {}
    }
}

extension VoiceEnhanceStoreTests {
    @Test("an export's composition holds its voice file until the composition is gone")
    func compositionHoldsItsVoiceFile() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("talk.mov")
        try await TestVideoFactory.make(segments: [(duration: 1, loud: true)], to: video)
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let store = VoiceEnhanceStore(cacheDir: cache, render: RenderGate.immediate)
        var project = Project(name: "Голос", clips: [Clip(sourceURL: video, start: 0, end: 1)])
        project.voiceEnhance = VoiceEnhanceSettings(enabled: true, leveling: 20)
        let pipeline = MediaPipeline(voiceStore: store, musicEQStore: MusicEQStore(cacheDir: cache))
        var result: MediaRenderResult? = await pipeline.render(
            MediaRenderRequest(project: project, mode: .export, readyEnhancedAudio: [:]))
        // Путь исходника — как его видит склейка (закладка раскрывает /var в /private/var).
        let path = project.clips[0].sourcePath
        let variantA = try #require(await store.readyURL(source: path, settings: project.voiceEnhance))

        _ = try await store.ensure(source: path, settings: VoiceEnhanceSettings(enabled: true, leveling: 90))
        #expect(FileManager.default.fileExists(atPath: variantA.path), "склейка экспорта ещё жива")

        withExtendedLifetime(result) {}
        result = nil
        _ = try await store.ensure(source: path, settings: VoiceEnhanceSettings(enabled: true, leveling: 60))
        #expect(!FileManager.default.fileExists(atPath: variantA.path))
    }
}

extension VoiceEnhanceStoreTests {
    @Test("a variant already published is not replaced by a second render of the same variant")
    func publishedVariantIsNotReplaced() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let path = try source(in: root)
        let settings = VoiceEnhanceSettings(enabled: true)
        let slow = RenderGate()
        let second = VoiceEnhanceStore(cacheDir: cache, render: slow.render)
        let late = Task { try await second.ensure(source: path, settings: settings) }
        try await slow.waitForStarted(1)
        let first = VoiceEnhanceStore(
            cacheDir: cache, render: { _, _, to, _ in try Data("первый".utf8).write(to: to) })
        let url = try await first.ensure(source: path, settings: settings)
        let lease = CacheFileLease(url: url)

        await slow.open()
        #expect(try await late.value == url)

        #expect(try String(contentsOf: url, encoding: .utf8) == "первый", "готовый вариант не подменён")
        withExtendedLifetime(lease) {}
    }

    @Test("work folders left by a crashed render are cleaned up after a day; fresh ones stay")
    func staleWorkFoldersAreRemoved() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        let stale = cache.appendingPathComponent(".work-\(UUID().uuidString)", isDirectory: true)
        let fresh = cache.appendingPathComponent(".work-\(UUID().uuidString)", isDirectory: true)
        for folder in [stale, fresh] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("начало".utf8).write(to: folder.appendingPathComponent("voice.caf"))
        }
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-2 * 24 * 3600)], ofItemAtPath: stale.path)
        let store = VoiceEnhanceStore(cacheDir: cache, render: RenderGate.immediate)

        _ = try await store.ensure(source: try source(in: root), settings: VoiceEnhanceSettings(enabled: true))

        #expect(!FileManager.default.fileExists(atPath: stale.path), "остаток упавшей обработки убран")
        #expect(FileManager.default.fileExists(atPath: fresh.path), "идущую обработку не трогаем")
    }
}

/// Подменённый рендер: пишет файл и ждёт, пока тест откроет ворота.
private actor RenderGate {
    private(set) var targets: [URL] = []
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    nonisolated var render: VoiceEnhanceStore.Render {
        { _, _, to, isCancelled in
            try Data("начало".utf8).write(to: to)
            await self.started(to)
            await self.pass()
            if isCancelled() { throw CancellationError() }
            try Data("обработанный голос".utf8).write(to: to)
        }
    }

    static let immediate: VoiceEnhanceStore.Render = { _, settings, to, _ in
        try Data("голос \(settings.leveling)".utf8).write(to: to)
    }

    private func started(_ url: URL) { targets.append(url) }

    private func pass() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }

    func waitForStarted(_ count: Int) async throws {
        for _ in 0..<200 where targets.count < count { try await Task.sleep(for: .milliseconds(10)) }
    }
}
