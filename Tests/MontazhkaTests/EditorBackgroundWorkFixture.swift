@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import MontazhkaKit

@MainActor
final class EditorBackgroundWorkFixture {
    let root: URL
    private var controllers: [EditorController] = []
    private var gates: [EditorWorkGate] = []
    private var preferenceSuites: [String] = []

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-editor-work-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    static func run(_ body: (EditorBackgroundWorkFixture) async throws -> Void) async throws {
        let fixture = try EditorBackgroundWorkFixture()
        do {
            try await body(fixture)
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    func editor(
        project: Project = Project(name: "Проверка фоновой работы"),
        read: @escaping EditorClipLoader.Read = EditorClipLoader.read,
        render: @escaping VoiceEnhanceStore.Render = VoiceEnhancer.render
    ) -> EditorController {
        let suite = UUID().uuidString
        preferenceSuites.append(suite)
        let controller = EditorController(
            project: project,
            store: ProjectStore(baseDirectory: root.appendingPathComponent("store-\(controllers.count)")),
            openRouterKeyStore: EmptyOpenRouterKeyStore(),
            preferences: UserDefaultsPreferenceStore(defaults: UserDefaults(suiteName: suite)!),
            activity: ActivityCenter(), readClip: read, voiceRender: render)
        controllers.append(controller)
        return controller
    }

    func gate() -> EditorWorkGate {
        let gate = EditorWorkGate()
        gates.append(gate)
        return gate
    }

    func video(_ name: String = "source.mov", duration: Double = 2) async throws -> URL {
        let url = root.appendingPathComponent(name)
        try await TestVideoFactory.make(segments: [(duration: duration, loud: true)], to: url)
        return url
    }

    func voiceProject(_ url: URL, level: Double = 20) -> Project {
        let source = MediaReference(path: url.path)
        var project = Project(
            name: "Голос",
            clips: [
                Clip(source: source, start: 0, end: 1),
                Clip(source: source, start: 1, end: 2),
            ])
        project.voiceEnhance = VoiceEnhanceSettings(enabled: true, leveling: level)
        return project
    }

    nonisolated static func writeAudio(to url: URL, duration: Double = 2) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let frames = AVAudioFrameCount(duration * format.sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(frames) {
            samples[index] = Float(sin(2 * .pi * 440 * Double(index) / format.sampleRate) * 0.1)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    static func audioSources(in composition: AVComposition) async throws -> [URL] {
        let tracks = try await composition.loadTracks(withMediaType: .audio)
        return tracks.flatMap { $0.segments.compactMap(\.sourceURL) }
    }

    static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw EditorWorkTimeout.conditionNotMet
    }

    private func close() async {
        for controller in controllers { await controller.shutdown() }
        for gate in gates { await gate.openAll() }
        try? await Task.sleep(for: .milliseconds(30))
        for suite in preferenceSuites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        try? FileManager.default.removeItem(at: root)
    }
}

private enum EditorWorkTimeout: Error {
    case conditionNotMet
}

actor EditorWorkGate {
    private var opened = Set<String>()
    private var allOpen = false
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private(set) var started: [String] = []
    private(set) var finished: [String] = []
    private(set) var voiceSources: [String] = []

    func recordVoiceSource(_ path: String) { voiceSources.append(path) }

    func wait(_ label: String) async {
        started.append(label)
        if !allOpen, !opened.contains(label) {
            await withCheckedContinuation { waiters[label, default: []].append($0) }
        }
    }

    func didFinish(_ label: String) { finished.append(label) }

    func open(_ label: String) {
        opened.insert(label)
        let pending = waiters.removeValue(forKey: label) ?? []
        pending.forEach { $0.resume() }
    }

    func openAll() {
        allOpen = true
        let pending = waiters.values.flatMap { $0 }
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func waitForStart(_ label: String) async throws {
        for _ in 0..<300 {
            if started.contains(label) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw EditorWorkTimeout.conditionNotMet
    }

    func waitForFinish(_ label: String) async throws {
        for _ in 0..<300 {
            if finished.contains(label) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw EditorWorkTimeout.conditionNotMet
    }

    nonisolated func voiceRender(failing levels: [Double: VoiceEnhanceError] = [:]) -> VoiceEnhanceStore.Render {
        { path, settings, to, _ in
            await self.recordVoiceSource(path)
            let label = "voice-\(settings.leveling)"
            await self.wait(label)
            if let error = levels[settings.leveling] {
                await self.didFinish(label)
                throw error
            }
            try EditorBackgroundWorkFixture.writeAudio(to: to)
            await self.didFinish(label)
        }
    }
}

/// All accesses share one lock because Observation's callback is Sendable.
final class EditorObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var changed: Bool { lock.withLock { value } }
    func markChanged() { lock.withLock { value = true } }
}
