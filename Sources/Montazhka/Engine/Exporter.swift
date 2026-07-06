import Foundation
import AVFoundation
import AppKit

enum ExportQuality: String, CaseIterable, Identifiable {
    case high, medium, light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .high: "Высокое"
        case .medium: "Среднее"
        case .light: "Лёгкий файл"
        }
    }

    var subtitle: String {
        switch self {
        case .high: "Максимальное качество, файл больше"
        case .medium: "Full HD — баланс качества и размера"
        case .light: "HD 720 — быстро отправить в мессенджер"
        }
    }

    var preset: String {
        switch self {
        case .high: AVAssetExportPresetHighestQuality
        case .medium: AVAssetExportPreset1920x1080
        case .light: AVAssetExportPreset1280x720
        }
    }
}

/// Сохранение готового видео в MP4 с прогрессом.
@MainActor
final class ExportModel: ObservableObject {
    enum State: Equatable {
        case idle
        case exporting
        case done(URL)
        case failed(String)
    }

    @Published var state: State = .idle
    @Published var progress: Double = 0

    private var session: AVAssetExportSession?
    private var progressTimer: Timer?

    func chooseDestination(projectName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Сохранить видео"
        panel.nameFieldStringValue = "\(projectName).mp4"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        return panel.runModal() == .OK ? panel.url : nil
    }

    func export(composition: AVAsset, audioMix: AVAudioMix? = nil, quality: ExportQuality, to url: URL) {
        guard let session = AVAssetExportSession(asset: composition, presetName: quality.preset) else {
            state = .failed("Не удалось подготовить экспорт для этого видео.")
            return
        }
        try? FileManager.default.removeItem(at: url)
        session.outputURL = url
        session.outputFileType = .mp4
        session.audioMix = audioMix
        self.session = session
        state = .exporting
        progress = 0

        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let session = self.session else { return }
                self.progress = Double(session.progress)
            }
        }

        session.exportAsynchronously { [weak self] in
            Task { @MainActor in
                guard let self, let session = self.session else { return }
                self.progressTimer?.invalidate()
                self.progressTimer = nil
                switch session.status {
                case .completed:
                    self.progress = 1
                    self.state = .done(url)
                case .cancelled:
                    self.state = .idle
                default:
                    let message = session.error?.localizedDescription ?? "Неизвестная ошибка"
                    self.state = .failed("Не получилось сохранить видео: \(message)")
                }
                self.session = nil
            }
        }
    }

    func cancel() {
        session?.cancelExport()
        progressTimer?.invalidate()
        progressTimer = nil
        state = .idle
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
