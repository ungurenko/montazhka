@preconcurrency import AVFoundation
import Foundation

/// Одна операция `montazhka_apply_edits` в том виде, в каком её присылает агент.
struct AgentEditOperation: Codable, Sendable {
    struct Range: Codable, Sendable {
        let from: Double
        let to: Double
    }

    let op: String
    var ranges: [Range]?
    var at: Double?
    var clip: Int?
    var to: Int?
    var edge: String?
    var seconds: Double?
    var sourcePath: String?
    var start: Double?
    var end: Double?
    var steps: Int?

    var isUndo: Bool { op == "undo" }

    init(op: String, steps: Int? = nil) {
        self.op = op
        self.steps = steps
    }

    /// Принимает и голый список операций, и объект `{"operations": [...]}`.
    static func decodeList(_ data: Data) throws -> [AgentEditOperation] {
        struct Wrapper: Decodable { let operations: [AgentEditOperation] }
        if let list = try? JSONDecoder().decode([AgentEditOperation].self, from: data) { return list }
        do {
            return try JSONDecoder().decode(Wrapper.self, from: data).operations
        } catch {
            throw AgentServiceError.invalidInput("operations не разобраны: \(error.localizedDescription)")
        }
    }

    func timelineOp() throws -> TimelineEditOp {
        func need<T>(_ value: T?, _ name: String) throws -> T {
            guard let value else { throw AgentServiceError.invalidInput("Операции \(op) нужно поле \(name).") }
            return value
        }
        switch op {
        case "delete":
            return .delete(ranges: try need(ranges, "ranges").map { TimelineRange(from: $0.from, to: $0.to) })
        case "split": return .split(at: try need(at, "at"))
        case "move": return .move(clip: try need(clip, "clip"), to: try need(to, "to"))
        case "trim":
            let edgeName = try need(edge, "edge")
            guard let trimEdge: TimelineTrimEdge = edgeName == "start" ? .start : (edgeName == "end" ? .end : nil)
            else {
                throw AgentServiceError.invalidInput("edge должен быть start или end.")
            }
            return .trim(clip: try need(clip, "clip"), edge: trimEdge, seconds: try need(seconds, "seconds"))
        case "insert":
            return .insert(
                sourcePath: URL(fileURLWithPath: try need(sourcePath, "sourcePath")).standardized.path,
                start: try need(start, "start"), end: try need(end, "end"), at: try need(at, "at"))
        default:
            throw AgentServiceError.invalidInput("Неизвестная операция: \(op).")
        }
    }
}

extension AgentService {
    func applyEdits(projectID: UUID, operations: [AgentEditOperation]) async -> AgentResponse {
        do {
            guard !operations.isEmpty else { throw AgentServiceError.invalidInput("Список operations пуст.") }
            let lock = try AgentProjectLock(projectID: projectID, directory: store.projectsDir)
            defer { withExtendedLifetime(lock) {} }
            var project = try await store.load(id: projectID)

            if operations.contains(where: \.isUndo) {
                guard operations.count == 1 else {
                    throw AgentServiceError.invalidInput("undo передаётся отдельным вызовом, без других операций.")
                }
                let steps = operations[0].steps ?? 1
                let restored = try await revisions.snapshot(projectID: projectID, steps: steps)
                project.clips = restored.clips
                project.updatedAt = Date()
                try await store.save(project)
                await revisions.drop(projectID: projectID, steps: steps)
                return try await editResponse(project, warnings: [])
            }

            let ops = try operations.map { try $0.timelineOp() }
            var durations: [String: Double] = [:]
            let paths = Set(project.clips.map(\.sourcePath)).union(
                ops.compactMap {
                    if case .insert(let path, _, _, _) = $0 { path } else { nil }
                })
            for path in paths {
                guard FileManager.default.fileExists(atPath: path) else { throw AgentServiceError.missingFile(path) }
                durations[path] = try await AVURLAsset(url: URL(fileURLWithPath: path)).load(.duration).seconds
            }

            let transcript = try? await cachedTimelineTranscript(for: project)
            let sourceWords = transcript.map { map in
                Dictionary(grouping: map.words, by: \.sourceID)
            }
            var warnings: [String] = []
            var clips = project.clips
            for (index, op) in ops.enumerated() {
                if let sourceWords {
                    warnings += Self.wordSplitWarnings(op, index: index, clips: clips, sourceWords: sourceWords)
                }
                clips = try TimelineEditOps.apply([op], to: clips, sourceDurations: durations)
            }
            try await revisions.push(project)
            project.clips = clips
            project.updatedAt = Date()
            do {
                try await store.save(project)
            } catch {
                await revisions.drop(projectID: projectID, steps: 1)
                throw error
            }
            if transcript == nil {
                warnings.append("Расшифровки нет в кэше — резы посреди слов не проверялись.")
            }
            return try await editResponse(project, warnings: warnings)
        } catch { return failure("apply_edits", error) }
    }

    /// Лента проекта для агента: номера клипов, их место на ленте и в исходнике.
    func clipsData(_ project: Project, limit: Int = 200) -> AgentJSONValue {
        let starts = TimelineEditOps.starts(of: project.clips)
        return .array(
            zip(project.clips, starts).prefix(limit).enumerated().map { index, pair in
                let (clip, start) = pair
                return .object([
                    "clip": .number(Double(index)),
                    "timelineStart": .number(Self.rounded(start)),
                    "timelineEnd": .number(Self.rounded(start + clip.duration)),
                    "sourcePath": .string(clip.sourcePath),
                    "sourceStart": .number(Self.rounded(clip.start)),
                    "sourceEnd": .number(Self.rounded(clip.end)),
                ])
            })
    }

    private func editResponse(_ project: Project, warnings: [String]) async throws -> AgentResponse {
        .success(
            command: "apply_edits",
            data: [
                "projectId": .string(project.id.uuidString),
                "revision": .number(Double(await revisions.revision(of: project.id))),
                "duration": .number(Self.rounded(project.totalDuration)),
                "clipCount": .number(Double(project.clips.count)),
                "clips": clipsData(project, limit: 50),
                "warnings": .array(warnings.map { .string($0) }),
            ])
    }

    /// Предупреждает, если точка реза на ленте попадает внутрь слова.
    private static func wordSplitWarnings(
        _ op: TimelineEditOp, index: Int, clips: [Clip], sourceWords: [UUID: [MappedTranscriptWord]]
    ) -> [String] {
        let points: [Double]
        switch op {
        case .delete(let ranges): points = ranges.flatMap { [$0.from, $0.to] }
        case .split(let at), .insert(_, _, _, let at): points = [at]
        default: return []
        }
        let starts = TimelineEditOps.starts(of: clips)
        return points.compactMap { point in
            guard
                let clipIndex = clips.indices.first(where: {
                    point > starts[$0] && point < starts[$0] + clips[$0].duration
                })
            else { return nil }
            let clip = clips[clipIndex]
            let sourceTime = clip.start + point - starts[clipIndex]
            guard
                let word = sourceWords[clip.source.id]?.first(where: {
                    sourceTime > $0.sourceStart + 0.03 && sourceTime < $0.sourceEnd - 0.03
                })
            else { return nil }
            return "Операция \(index + 1): точка \(String(format: "%.2f", point)) режет слово «\(word.text)»."
        }
    }
}
