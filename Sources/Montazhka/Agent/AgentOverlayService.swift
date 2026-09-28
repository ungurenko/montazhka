@preconcurrency import AVFoundation
import Foundation

/// Анимации поверх обычного проекта для агента: операции `addOverlay`, `removeOverlay`,
/// `clearOverlays` в `montazhka_apply_edits` и их вид в `inspect`. Анимация держится
/// за момент исходника (слово), поэтому правки ленты не сдвигают её с этого слова.
extension AgentService {
    /// Что сделала операция: `copy` — подготовленная копия файла анимации (её удаляют,
    /// если пачка правок не сохранится), `warnings` — замечания проверки файла.
    struct OverlayOpResult: Sendable {
        var copy: URL?
        var warnings: [String] = []
    }

    func applyOverlayOp(
        _ operation: AgentEditOperation, to project: inout Project, clips: [Clip], words: [TranscriptWord]?
    ) async throws -> OverlayOpResult {
        guard project.shorts == nil else {
            throw AgentServiceError.invalidInput("Анимации пока только в обычном проекте")
        }
        switch operation.op {
        case "addOverlay":
            return try await addOverlay(operation, to: &project, clips: clips, words: words)
        case "removeOverlay":
            guard let id = operation.overlay.flatMap(UUID.init(uuidString:)),
                project.overlays.contains(where: { $0.id == id })
            else {
                throw AgentServiceError.invalidInput(
                    "removeOverlay: нет анимации «\(operation.overlay ?? "")». Список — overlays в montazhka_inspect.")
            }
            project.overlays.removeAll { $0.id == id }
        case "clearOverlays":
            project.overlays = []
        default:
            throw AgentServiceError.invalidInput("Неизвестная операция: \(operation.op).")
        }
        return OverlayOpResult()
    }

    /// Проверяет файл и якорь до тяжёлой работы, затем кладёт подготовленную копию
    /// (premultiplied BT.709 ProRes) в папку Overlays и добавляет анимацию в проект.
    private func addOverlay(
        _ operation: AgentEditOperation, to project: inout Project, clips: [Clip], words: [TranscriptWord]?
    ) async throws -> OverlayOpResult {
        guard let path = operation.file, !path.isEmpty else {
            throw AgentServiceError.invalidInput("addOverlay: нужно поле file — .mov с прозрачным фоном.")
        }
        let placement = try Self.overlayPlacement(operation)
        let anchor = try Self.overlayAnchor(operation, clips: clips, words: words)
        let source = URL(fileURLWithPath: path).standardized
        let frame = await Self.frameSize(of: clips) ?? .zero
        let (duration, warnings) = try await OverlayMediaProbe.validate(source, projectFrame: frame)
        let payoffAt = placement.align == .payoff ? operation.payoffAt ?? 0 : 0
        guard payoffAt <= duration else {
            throw AgentServiceError.invalidInput(
                "addOverlay: payoffAt=\(payoffAt) дальше конца анимации (\(Self.rounded(duration)) с).")
        }
        let id = UUID()
        let directory = store.directories.overlays
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = directory.appendingPathComponent("\(id.uuidString).mov")
        try await OverlayMediaNormalizer.normalize(source, to: copy)
        project.overlays.append(
            ProjectOverlay(
                id: id, media: MediaReference(url: copy), anchor: anchor, align: placement.align, payoffAt: payoffAt,
                duration: duration, position: placement.position, scale: placement.scale))
        return OverlayOpResult(copy: copy, warnings: warnings)
    }

    /// Выравнивание и место в кадре. Без `align`: `payoff`, если передан `payoffAt`, иначе `start`.
    private static func overlayPlacement(
        _ operation: AgentEditOperation
    ) throws -> (align: OverlayAlign, position: OverlayPosition, scale: Double) {
        let alignName = operation.align ?? (operation.payoffAt == nil ? "start" : "payoff")
        guard let align = OverlayAlign(rawValue: alignName) else {
            throw AgentServiceError.invalidInput("addOverlay: align — payoff или start.")
        }
        if align == .payoff {
            guard let payoffAt = operation.payoffAt, payoffAt >= 0 else {
                throw AgentServiceError.invalidInput(
                    "addOverlay: align=payoff требует payoffAt — секунду анимации, которая совпадёт со словом.")
            }
        }
        guard let position = OverlayPosition(rawValue: operation.position ?? "full") else {
            throw AgentServiceError.invalidInput(
                "addOverlay: position — full, center, topLeft, topRight, bottomLeft или bottomRight.")
        }
        let scale = operation.scale ?? 1
        guard position == .full || (0.2...1).contains(scale) else {
            throw AgentServiceError.invalidInput("addOverlay: scale — от 0.2 до 1.")
        }
        return (align, position, position == .full ? 1 : scale)
    }

    /// Якорь: начало слова `words[0].from` (нужен свежий `timeline`) или момент ленты `at`.
    private static func overlayAnchor(
        _ operation: AgentEditOperation, clips: [Clip], words: [TranscriptWord]?
    ) throws -> OverlayAnchor {
        let map = words.map { TranscriptTimelineMapper.make(clips: clips, transcripts: $0).words }
        if let span = operation.words?.first {
            guard operation.timeline == AgentWordCuts.fingerprint(clips) else {
                throw AgentServiceError.invalidInput(
                    "addOverlay: нужны words [{from, to}] и свежий timeline из montazhka_transcript.")
            }
            guard let map else { throw AgentServiceError.invalidInput("Для addOverlay по словам нужна расшифровка.") }
            guard span.from >= 1, span.from <= map.count else {
                throw AgentServiceError.invalidInput("addOverlay: слова #\(span.from) нет, в расшифровке \(map.count).")
            }
            let word = map[span.from - 1]
            return OverlayAnchor(sourceID: word.sourceID, sourceTime: word.sourceStart, wordText: word.text)
        }
        guard let at = operation.at else {
            throw AgentServiceError.invalidInput(
                "addOverlay: нужен якорь — words [{from, to}] с timeline или at (секунды ленты).")
        }
        guard let anchor = OverlayTimeline.anchor(atTimeline: at, clips: clips, words: map) else {
            throw AgentServiceError.invalidInput("addOverlay: at=\(at) вне ленты.")
        }
        return anchor
    }

    /// Размер кадра обычного проекта — видео первого клипа с учётом поворота; nil — не прочитать.
    static func frameSize(of clips: [Clip]) async -> CGSize? {
        guard let clip = clips.first,
            let track = try? await AVURLAsset(url: clip.url).loadTracks(withMediaType: .video).first,
            case let (natural, transform)? = try? await track.load(.naturalSize, .preferredTransform)
        else { return nil }
        let shown = CGRect(origin: .zero, size: natural).applying(transform)
        return CGSize(width: abs(shown.width), height: abs(shown.height))
    }

    /// `frameSize` и `overlays` обычного проекта для inspect и ответа apply_edits;
    /// у черновика шортса анимаций нет — пусто.
    func overlaysData(_ project: Project) async -> [String: AgentJSONValue] {
        guard project.shorts == nil else { return [:] }
        let size = await Self.frameSize(of: project.clips)
        let resolved = OverlayTimeline.resolve(project.overlays, clips: project.clips)
        return [
            "frameSize": size.map {
                .object(["width": .number(Double(Int($0.width))), "height": .number(Double(Int($0.height)))])
            } ?? .null,
            "overlays": .array(
                resolved.map { item in
                    let visible = item.status == .visible
                    return .object([
                        "id": .string(item.overlay.id.uuidString),
                        "file": .string(item.overlay.media.lastKnownPath),
                        "word": item.overlay.anchor.wordText.map { .string($0) } ?? .null,
                        "timelineStart": visible ? .number(Self.rounded(item.window.from)) : .null,
                        "timelineEnd": visible ? .number(Self.rounded(item.window.to)) : .null,
                        "payoffTimeline": item.overlay.align == .payoff
                            ? item.anchorTimeline.map { .number(Self.rounded($0)) } ?? .null : .null,
                        "position": .string(item.overlay.position.rawValue),
                        "status": .string(item.status.rawValue),
                    ])
                }),
        ]
    }

    /// Анимации, которые после правки ленты стоит проверить: слово-якорь вырезано
    /// (анимация скрыта) или момент якоря встречается на ленте несколько раз.
    static func overlayWarnings(_ project: Project) -> [String] {
        guard project.shorts == nil else { return [] }
        return OverlayTimeline.resolve(project.overlays, clips: project.clips).compactMap { item in
            let name =
                "Анимация \(item.overlay.id.uuidString)"
                + (item.overlay.anchor.wordText.map { " («\($0)»)" } ?? "")
            if item.status == .anchorCut {
                return "\(name): слово вырезано — анимация скрыта; removeOverlay или addOverlay заново"
            }
            if item.occurrences > 1 {
                return "\(name): момент якоря повторяется на ленте (\(item.occurrences)×) — анимация у первого; "
                    + "лишний повтор вырежьте или addOverlay заново"
            }
            return nil
        }
    }
}
