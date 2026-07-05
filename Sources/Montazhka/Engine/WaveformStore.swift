import Foundation
import AVFoundation
import CryptoKit

/// Громкость звука (RMS) окнами по 10 мс — основа и для отрисовки волны, и для поиска пауз.
/// Извлекается один раз на исходный файл и кэшируется на диск.
final class WaveformStore: @unchecked Sendable {
    static let windowsPerSecond = 100.0

    private let cacheDir: URL
    private let lock = NSLock()
    private var memory: [String: [Float]] = [:]
    private var inFlight: [String: Task<[Float]?, Never>] = [:]

    init(cacheDir: URL) {
        self.cacheDir = cacheDir
    }

    /// Мгновенный доступ для отрисовки (nil — ещё не готово).
    func peaks(for path: String) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        return memory[path]
    }

    /// Гарантирует, что волна для файла посчитана (из кэша или заново).
    @discardableResult
    func ensure(path: String) async -> [Float]? {
        if let ready = peaks(for: path) { return ready }
        let task = extractionTask(for: path)
        let result = await task.value
        finish(path: path, with: result)
        return result
    }

    private func extractionTask(for path: String) -> Task<[Float]?, Never> {
        lock.lock(); defer { lock.unlock() }
        if let existing = inFlight[path] { return existing }
        let cacheURL = cacheFileURL(for: path)
        let task = Task.detached(priority: .userInitiated) {
            Self.loadOrExtract(path: path, cacheURL: cacheURL)
        }
        inFlight[path] = task
        return task
    }

    private func finish(path: String, with result: [Float]?) {
        lock.lock(); defer { lock.unlock() }
        if let result { memory[path] = result }
        inFlight[path] = nil
    }

    // MARK: - Кэш

    private func cacheFileURL(for path: String) -> URL {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? Int) ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(path)|\(size)|\(Int(mtime))"
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent("\(hash).f32")
    }

    private static func loadOrExtract(path: String, cacheURL: URL) -> [Float]? {
        if let data = try? Data(contentsOf: cacheURL), !data.isEmpty {
            return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        guard let peaks = extract(path: path) else { return nil }
        peaks.withUnsafeBytes { try? Data($0).write(to: cacheURL, options: .atomic) }
        return peaks
    }

    // MARK: - Извлечение

    /// Декодирует звук в 16 кГц моно и считает RMS окнами по 10 мс (160 сэмплов).
    private static func extract(path: String) -> [Float]? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let semaphore = DispatchSemaphore(value: 0)
        var audioTrack: AVAssetTrack?
        asset.loadTracks(withMediaType: .audio) { tracks, _ in
            audioTrack = tracks?.first
            semaphore.signal()
        }
        semaphore.wait()
        guard let track = audioTrack, let reader = try? AVAssetReader(asset: asset) else { return nil }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        let windowSize = 160 // 10 мс при 16 кГц
        var peaks: [Float] = []
        var sumSquares: Double = 0
        var count = 0

        while reader.status == .reading {
            guard let sample = output.copyNextSampleBuffer() else { break }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let floatCount = length / MemoryLayout<Float>.size
            guard floatCount > 0 else { continue }
            var buffer = [Float](repeating: 0, count: floatCount)
            let status = buffer.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { continue }

            for value in buffer {
                sumSquares += Double(value * value)
                count += 1
                if count == windowSize {
                    peaks.append(Float((sumSquares / Double(windowSize)).squareRoot()))
                    sumSquares = 0
                    count = 0
                }
            }
        }
        if count > 0 {
            peaks.append(Float((sumSquares / Double(count)).squareRoot()))
        }
        return reader.status == .completed || !peaks.isEmpty ? peaks : nil
    }
}
