@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import ImageIO
import Testing

@testable import MontazhkaKit

/// Анимации поверх обычного проекта через `montazhka_apply_edits`, `inspect` и `frames`.
@Suite("Agent animation overlays")
struct AgentOverlayTests {
    private struct Fixture {
        let root: URL
        let service: AgentService
        let project: Project
    }

    /// Серый ролик 320×180 на 4 с с ровным тоном и шестью словами по 0,3 с через каждые 0,5 с.
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-overlays-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let video = root.appendingPathComponent("talk.mov")
        try await TestVideoFactory.make(segments: [(duration: 4, loud: true)], videoLuma: 128, to: video)
        let service = AgentService(baseDirectory: root)
        let media = MediaReference(url: video)
        let project = Project(name: "Анимации", clips: [Clip(source: media, start: 0, end: 4)])
        try await service.store.save(project)
        let words = ["один", "два", "три", "четыре", "пять", "шесть"].enumerated().map { index, text in
            let start = 0.2 + Double(index) * 0.5
            return TranscriptWord(sourceID: media.id, text: text, start: start, end: start + 0.3, confidence: 1)
        }
        let cacheURL = await service.makeTranscriptStore().cacheURL(for: media)
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(TranscriptDocument(words: words)).write(to: cacheURL)
        return Fixture(root: root, service: service, project: project)
    }

    /// Анимация, как её пишет HyperFrames: ProRes 4444 с прямой (straight) альфой — прозрачный
    /// белый фон и непрозрачный красный квадрат в центре, 1 с.
    private func straightAlphaOverlay(in root: URL) async throws -> URL {
        let (width, height) = (320, 180)
        let frame = try TestOverlayFactory.pixelBuffer(
            width: width, height: height, format: kCVPixelFormatType_4444AYpCbCr16)
        CVPixelBufferLockBaseAddress(frame, [])
        let base = try #require(CVPixelBufferGetBaseAddress(frame))
        let rowBytes = CVPixelBufferGetBytesPerRow(frame)
        let (kr, kb) = (0.2126, 0.0722)
        for y in 0..<height {
            let row = (base + y * rowBytes).assumingMemoryBound(to: UInt16.self)
            for x in 0..<width {
                let square = abs(x - width / 2) < 30 && abs(y - height / 2) < 30
                let (r, g, b): (Double, Double, Double) = square ? (1, 0, 0) : (1, 1, 1)
                let luma = kr * r + (1 - kr - kb) * g + kb * b
                row[x * 4] = square ? 0xFFFF : 0
                row[x * 4 + 1] = UInt16(((16 + 219 * luma) * 256).rounded())
                row[x * 4 + 2] = UInt16(((128 + 224 * (b - luma) / (2 * (1 - kb))) * 256).rounded())
                row[x * 4 + 3] = UInt16(((128 + 224 * (r - luma) / (2 * (1 - kr))) * 256).rounded())
            }
        }
        CVPixelBufferUnlockBaseAddress(frame, [])
        let url = root.appendingPathComponent("hyperframes.mov")
        try await TestOverlayFactory.writeStill(
            frame,
            settings: [
                AVVideoCodecKey: AVVideoCodecType.proRes4444, AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
            ],
            fileType: .mov, frameCount: 30, frameDuration: CMTime(value: 1, timescale: 30), to: url)
        return url
    }

    private func transcriptTimeline(_ fixture: Fixture) async -> String? {
        let response = await fixture.service.transcript(
            AgentTranscriptRequest(target: AgentMediaTarget(projectID: fixture.project.id)))
        guard case .string(let timeline)? = response.data?["timeline"] else { return nil }
        return timeline
    }

    private func addOverlay(file: URL, word: Int, timeline: String?) -> AgentEditOperation {
        var operation = AgentEditOperation(op: "addOverlay")
        operation.file = file.path
        operation.words = [AgentWordRange(from: word, to: word)]
        operation.timeline = timeline
        operation.position = "full"
        return operation
    }

    private func deleteWords(_ from: Int, _ to: Int, timeline: String?) -> AgentEditOperation {
        var operation = AgentEditOperation(op: "deleteWords")
        operation.words = [AgentWordRange(from: from, to: to)]
        operation.timeline = timeline
        return operation
    }

    private func overlays(_ response: AgentResponse) -> [[String: AgentJSONValue]] {
        guard case .array(let items)? = response.data?["overlays"] else { return [] }
        return items.compactMap { if case .object(let object) = $0 { object } else { nil } }
    }

    private func number(_ value: AgentJSONValue?) -> Double? {
        if case .number(let number)? = value { number } else { nil }
    }

    @Test("addOverlay normalizes a straight-alpha ProRes into Overlays, inspect lists it, undo removes it")
    func addOverlayNormalizesAndLists() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let file = try await straightAlphaOverlay(in: fixture.root)

        let added = await fixture.service.applyEdits(
            projectID: fixture.project.id,
            operations: [addOverlay(file: file, word: 4, timeline: await transcriptTimeline(fixture))])

        #expect(added.ok, "\(String(describing: added.error))")
        let project = try await fixture.service.store.load(id: fixture.project.id)
        let overlay = try #require(project.overlays.first)
        let copy = try #require(overlay.media.resolvedURL)
        let overlaysDir = await fixture.service.store.directories.overlays
        #expect(
            copy.deletingLastPathComponent().resolvingSymlinksInPath().path
                == overlaysDir.resolvingSymlinksInPath().path)
        #expect(FileManager.default.fileExists(atPath: copy.path))
        #expect(overlay.anchor.wordText == "четыре")
        #expect(abs(overlay.duration - 1) < 0.05)

        let inspected = await fixture.service.inspect(projectID: fixture.project.id)
        #expect(inspected.data?["frameSize"] == .object(["width": 320, "height": 180]))
        let listed = try #require(overlays(inspected).first)
        #expect(listed["id"] == .string(overlay.id.uuidString))
        #expect(listed["word"] == .string("четыре"))
        #expect(listed["status"] == .string("visible"))
        #expect(listed["position"] == .string("full"))
        #expect(abs((number(listed["timelineStart"]) ?? 0) - 1.7) < 0.001)
        #expect(overlays(added).count == 1, "ответ apply_edits тоже показывает анимации")

        let undone = await fixture.service.applyEdits(
            projectID: fixture.project.id, operations: [AgentEditOperation(op: "undo")])
        #expect(undone.ok)
        #expect(try await fixture.service.store.load(id: fixture.project.id).overlays.isEmpty)
    }

    @Test("an exact opening anchor stays at zero before the first recognized word")
    func exactOpeningAnchor() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let file = try await straightAlphaOverlay(in: fixture.root)
        let data = try JSONSerialization.data(withJSONObject: [
            [
                "op": "addOverlay", "file": file.path,
                "at": 0, "snapToWord": false,
            ]
        ])
        let added = await fixture.service.applyEdits(
            projectID: fixture.project.id, operations: try AgentEditOperation.decodeList(data))
        #expect(added.ok)
        let project = try await fixture.service.store.load(id: fixture.project.id)
        #expect(project.overlays.first?.anchor.sourceTime == 0)
    }

    @Test("deleting words before the anchor moves the animation; deleting the anchor word hides it with a warning")
    func anchorFollowsWordsAndWarnsWhenCut() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let file = try await straightAlphaOverlay(in: fixture.root)
        let added = await fixture.service.applyEdits(
            projectID: fixture.project.id,
            operations: [addOverlay(file: file, word: 4, timeline: await transcriptTimeline(fixture))])
        #expect(added.ok, "\(String(describing: added.error))")
        let before = try #require(number(overlays(added).first?["timelineStart"]))

        let shortened = await fixture.service.applyEdits(
            projectID: fixture.project.id, operations: [deleteWords(1, 2, timeline: await transcriptTimeline(fixture))])

        #expect(shortened.ok, "\(String(describing: shortened.error))")
        let removed = 4 - (number(shortened.data?["duration"]) ?? 4)
        #expect(removed > 0.5)
        let after = try #require(number(overlays(shortened).first?["timelineStart"]))
        #expect(abs(after - (before - removed)) < 0.01)

        // «четыре» теперь второе слово ленты.
        let cut = await fixture.service.applyEdits(
            projectID: fixture.project.id, operations: [deleteWords(2, 2, timeline: await transcriptTimeline(fixture))])

        #expect(cut.ok, "\(String(describing: cut.error))")
        let id = try #require(try await fixture.service.store.load(id: fixture.project.id).overlays.first?.id)
        guard case .array(let warnings)? = cut.data?["warnings"] else {
            Issue.record("нет warnings: \(String(describing: cut.data))")
            return
        }
        #expect(
            warnings.contains(
                .string(
                    "Анимация \(id.uuidString) («четыре»): слово вырезано — анимация скрыта; "
                        + "removeOverlay или addOverlay заново")))
        let listed = overlays(await fixture.service.inspect(projectID: fixture.project.id)).first
        #expect(listed?["status"] == .string("anchorCut"))
        #expect(listed?["timelineStart"] == .null)
    }

    @Test("copies a batch made but the saved project does not use are deleted: cleared in the batch or batch failed")
    func unusedOverlayCopiesAreDeleted() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let file = try await straightAlphaOverlay(in: fixture.root)
        let timeline = await transcriptTimeline(fixture)
        let overlaysDir = await fixture.service.store.directories.overlays
        func copies() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: overlaysDir.path)) ?? [] }

        let cleared = await fixture.service.applyEdits(
            projectID: fixture.project.id,
            operations: [addOverlay(file: file, word: 2, timeline: timeline), AgentEditOperation(op: "clearOverlays")])

        #expect(cleared.ok, "\(String(describing: cleared.error))")
        #expect(copies().isEmpty, "копия, убранная той же пачкой, удалена: \(copies())")

        var missing = AgentEditOperation(op: "removeOverlay")
        missing.overlay = UUID().uuidString
        let failed = await fixture.service.applyEdits(
            projectID: fixture.project.id, operations: [addOverlay(file: file, word: 2, timeline: timeline), missing])

        #expect(!failed.ok)
        #expect(copies().isEmpty, "копия несохранённой пачки удалена: \(copies())")

        let kept = await fixture.service.applyEdits(
            projectID: fixture.project.id, operations: [addOverlay(file: file, word: 2, timeline: timeline)])
        #expect(kept.ok, "\(String(describing: kept.error))")
        #expect(copies().count == 1, "копия, на которую ссылается проект, на месте")
    }

    @Test("addOverlay on a shorts draft is refused")
    func draftRefusesOverlays() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var draft = fixture.project
        draft.shorts = ShortsPresentation(
            title: "Шортс", reason: "", layout: .fit, resolvedLayout: .fit, hook: nil, subtitles: nil, zooms: [],
            exportPath: nil)
        try await fixture.service.store.save(draft)
        var operation = AgentEditOperation(op: "addOverlay")
        operation.file = fixture.root.appendingPathComponent("any.mov").path
        operation.at = 1

        let response = await fixture.service.applyEdits(projectID: draft.id, operations: [operation])

        #expect(!response.ok)
        #expect(response.error?.message == "Анимации пока только в обычном проекте")
    }

    @Test("frames of a normal project show the animation like the export does")
    func framesShowOverlay() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let overlayURL = fixture.root.appendingPathComponent("ready.mov")
        try await TestOverlayFactory.make(width: 320, height: 180, duration: 1, to: overlayURL)
        var project = fixture.project
        let sourceID = try #require(project.clips.first?.source.id)
        project.overlays = [
            ProjectOverlay(
                id: UUID(), media: MediaReference(url: overlayURL),
                anchor: OverlayAnchor(sourceID: sourceID, sourceTime: 2, wordText: nil),
                align: .start, payoffAt: 0, duration: 1, position: .full, scale: 1)
        ]
        try await fixture.service.store.save(project)

        let during = await fixture.service.frames(
            AgentFramesRequest(target: AgentMediaTarget(projectID: project.id), times: [2.5]))
        let outside = await fixture.service.frames(
            AgentFramesRequest(target: AgentMediaTarget(projectID: project.id), times: [1]))

        #expect(during.ok, "\(String(describing: during.error))")
        let shown = try centreColour(during)
        let plain = try centreColour(outside)
        #expect(shown.red > 180 && shown.green < 90 && shown.blue < 90, "кадр с анимацией: \(shown)")
        #expect(abs(plain.red - plain.green) < 20, "кадр без анимации серый: \(plain)")
    }

    @Test("setSubtitles on a normal project switches burned-in subtitles for export")
    func setSubtitlesOnNormalProject() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var operation = AgentEditOperation(op: "setSubtitles")
        operation.on = true

        let response = await fixture.service.applyEdits(projectID: fixture.project.id, operations: [operation])

        #expect(response.ok, "\(String(describing: response.error))")
        let project = try await fixture.service.store.load(id: fixture.project.id)
        #expect(project.export.burnSubtitles)
        #expect(project.shorts == nil)
    }

    /// Цвет центра единственного кадра сетки (0…255).
    private func centreColour(_ response: AgentResponse) throws -> (red: Int, green: Int, blue: Int) {
        guard case .string(let path)? = response.data?["imagePath"],
            let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
            let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil),
            case .number(let height)? = response.data?["height"]
        else { throw TestOverlayFactory.Failure(reason: "сетка кадров не читается") }
        // Одна клетка: кадр сверху, подпись 28 точек снизу.
        let imageHeight = height - 28
        let context = try #require(
            CGContext(
                data: nil, width: sheet.width, height: sheet.height, bitsPerComponent: 8, bytesPerRow: sheet.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(sheet, in: CGRect(x: 0, y: 0, width: sheet.width, height: sheet.height))
        let pixels = try #require(context.data).bindMemory(to: UInt8.self, capacity: sheet.width * sheet.height * 4)
        let offset = (Int(imageHeight / 2) * sheet.width + sheet.width / 2) * 4
        return (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
    }
}
