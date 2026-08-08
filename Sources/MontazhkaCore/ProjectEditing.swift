import Foundation

public enum ProjectEdit: Equatable, Sendable {
    case replaceClips([Clip])
    case rename(String)
    case updateDetection(DetectionSettings)
    case updateVoice(VoiceEnhanceSettings)
    case updateMusic(MusicSettings)
    case relink(sourceID: UUID, to: MediaReference)

    fileprivate func apply(to project: inout Project) {
        switch self {
        case .replaceClips(let clips):
            project.clips = clips
        case .rename(let name):
            project.name = name
        case .updateDetection(let settings):
            project.detection = settings
        case .updateVoice(let settings):
            project.voiceEnhance = settings
        case .updateMusic(let settings):
            project.music = settings
        case .relink(let sourceID, let replacement):
            for index in project.clips.indices where project.clips[index].source.id == sourceID {
                project.clips[index].source = replacement
            }
        }
    }
}

/// Чистое редактирование документа и история. Плеер, диск и UI сюда не входят.
public struct ProjectEditor {
    public private(set) var project: Project
    private var history: EditHistory<Project>

    public init(project: Project, historyLimit: Int = 200) {
        self.project = project
        history = EditHistory(limit: historyLimit)
    }

    public var canUndo: Bool { history.canUndo }
    public var canRedo: Bool { history.canRedo }

    public mutating func apply(_ edit: ProjectEdit, recordHistory: Bool = true) {
        if recordHistory { history.record(project) }
        edit.apply(to: &project)
    }

    public mutating func recordCurrent() {
        history.record(project)
    }

    @discardableResult
    public mutating func undo() -> Project? {
        guard let previous = history.undo(current: project) else { return nil }
        project = previous
        return project
    }

    @discardableResult
    public mutating func redo() -> Project? {
        guard let next = history.redo(current: project) else { return nil }
        project = next
        return project
    }
}
