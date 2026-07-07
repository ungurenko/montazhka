import Foundation
import AVFoundation
import AppKit

enum ExportQuality: String, CaseIterable, Identifiable {
    case maximum, high, medium, compact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .maximum: "Максимальное"
        case .high: "Высокое"
        case .medium: "Среднее"
        case .compact: "Компактное"
        }
    }

    var subtitle: String {
        switch self {
        case .maximum: "Исходное разрешение, файл заметно больше"
        case .high: "Full HD — отличная картинка"
        case .medium: "Full HD — баланс качества и размера"
        case .compact: "HD 720 — маленький файл для мессенджера"
        }
    }

    /// Потолок меньшей стороны кадра (720 у компактного = «720p» и для вертикальных видео).
    private var sideCap: Double? {
        switch self {
        case .maximum: nil
        case .high, .medium: 1080
        case .compact: 720
        }
    }

    /// Базовый битрейт видео при полном опорном кадре.
    private var baseVideoBitrate: Double {
        switch self {
        case .maximum: 16_000_000
        case .high: 8_000_000
        case .medium: 4_500_000
        case .compact: 2_000_000
        }
    }

    /// Опорная площадь кадра для базового битрейта.
    private var referencePixels: Double {
        switch self {
        case .compact: 1280 * 720
        default: 1920 * 1080
        }
    }

    var audioBitrate: Int {
        switch self {
        case .maximum: 192_000
        case .high: 160_000
        case .medium: 128_000
        case .compact: 96_000
        }
    }

    /// Размер кадра на выходе: потолок по меньшей стороне, без увеличения,
    /// аспект сохраняется, стороны чётные (требование H.264).
    func targetDimensions(forDisplaySize size: CGSize) -> CGSize {
        let width = abs(size.width), height = abs(size.height)
        guard width > 1, height > 1 else { return CGSize(width: 1920, height: 1080) }
        var scale = 1.0
        if let cap = sideCap {
            scale = min(1.0, cap / min(width, height))
        }
        func even(_ value: Double) -> Double { max(2, (value * scale / 2).rounded() * 2) }
        return CGSize(width: even(width), height: even(height))
    }

    /// Битрейт видео масштабируется по площади кадра; меньше 1 Мбит/с не опускаемся.
    func videoBitrate(forDimensions dims: CGSize) -> Int {
        let area = Double(dims.width * dims.height) / referencePixels
        let scaled = baseVideoBitrate * (self == .maximum ? area : min(1, area))
        return max(1_000_000, Int(scaled))
    }

    /// Примерный размер файла: (битрейт видео + звука) × длительность, +4% на контейнер.
    func estimatedBytes(duration: Double, displaySize: CGSize) -> Int64 {
        let dims = targetDimensions(forDisplaySize: displaySize)
        let bitsPerSecond = Double(videoBitrate(forDimensions: dims) + audioBitrate)
        return Int64((bitsPerSecond / 8 * duration * 1.04).rounded())
    }

    /// Текст для окна экспорта: «≈ 180 МБ» или «≈ 1.2 ГБ».
    func estimateText(duration: Double, displaySize: CGSize) -> String {
        let bytes = Double(estimatedBytes(duration: duration, displaySize: displaySize))
        let megabytes = bytes / 1_000_000
        if megabytes >= 1000 {
            return String(format: "≈ %.1f ГБ", bytes / 1_000_000_000)
        }
        return "≈ \(Int(megabytes.rounded())) МБ"
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

    private var exportTask: Task<Void, Never>?

    func chooseDestination(projectName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Сохранить видео"
        panel.nameFieldStringValue = "\(projectName).mp4"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        return panel.runModal() == .OK ? panel.url : nil
    }

    func export(composition: AVAsset, audioMix: AVAudioMix? = nil, quality: ExportQuality, to url: URL) {
        state = .exporting
        progress = 0
        let onProgress: @Sendable (Double) -> Void = { [weak self] value in
            Task { @MainActor in
                guard let self, self.state == .exporting else { return }
                self.progress = value
            }
        }
        exportTask = Task { [weak self] in
            do {
                let settings = try await Transcoder.settings(for: quality, composition: composition)
                try await Transcoder.export(composition: composition,
                                            audioMix: audioMix,
                                            settings: settings,
                                            to: url,
                                            progress: onProgress)
                guard let self, !Task.isCancelled else { return }
                self.progress = 1
                self.state = .done(url)
            } catch is CancellationError {
                self?.state = .idle
            } catch {
                self?.state = .failed("Не получилось сохранить видео: \(error.localizedDescription)")
            }
            self?.exportTask = nil
        }
    }

    func cancel() {
        exportTask?.cancel()
        exportTask = nil
        state = .idle
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
