import AVFoundation
import CryptoKit
import Foundation

/// Громкость звука (RMS) окнами по 10 мс — основа и для отрисовки волны, и для поиска пауз.
/// Извлекается один раз на исходный файл и кэшируется на диск.
///
/// @unchecked Sendable: NSCache потокобезопасен, а дедупликацией и лимитом работ
/// владеет приватный actor. Массивы пиков после публикации не мутируются.
/// `peaks(for:)` остаётся синхронным: его читает Canvas при отрисовке каждого кадра.
final class WaveformStore: @unchecked Sendable {
    static let windowsPerSecond = 100.0
    typealias Loader = @Sendable (_ path: String, _ cacheURL: URL) async -> [Float]?

    private let cacheDir: URL
    private let memory = NSCache<NSString, WaveformPeaksBox>()
    private let work: WaveformWorkCoordinator

    init(
        cacheDir: URL,
        memoryCostLimit: Int = 64 * 1024 * 1024,
        memoryCountLimit: Int = 0,
        maxConcurrentDecodes: Int = 2,
        loader: Loader? = nil
    ) {
        self.cacheDir = cacheDir
        memory.totalCostLimit = memoryCostLimit
        memory.countLimit = memoryCountLimit
        work = WaveformWorkCoordinator(
            maxConcurrent: maxConcurrentDecodes,
            loader: loader ?? Self.loadOrExtract
        )
    }

    /// Мгновенный доступ для отрисовки (nil — ещё не готово).
    func peaks(for path: String) -> [Float]? {
        memory.object(forKey: path as NSString)?.peaks
    }

    /// Гарантирует, что волна для файла посчитана (из кэша или заново).
    @discardableResult
    func ensure(path: String) async -> [Float]? {
        if let ready = peaks(for: path) { return ready }
        let cacheURL = cacheFileURL(for: path)
        let result = await work.value(key: cacheURL.path, path: path, cacheURL: cacheURL)
        if let result {
            memory.setObject(
                WaveformPeaksBox(result),
                forKey: path as NSString,
                cost: result.count * MemoryLayout<Float>.stride
            )
        }
        return result
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

    private static func loadOrExtract(path: String, cacheURL: URL) async -> [Float]? {
        if let data = try? Data(contentsOf: cacheURL), !data.isEmpty {
            return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        guard let peaks = await extract(path: path) else { return nil }
        peaks.withUnsafeBytes { try? Data($0).write(to: cacheURL, options: .atomic) }
        return peaks
    }

    // MARK: - Извлечение

    /// Декодирует звук в 16 кГц моно и считает RMS окнами по 10 мс (160 сэмплов).
    private static func extract(path: String) async -> [Float]? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard let track = audioTracks.first, let reader = try? AVAssetReader(asset: asset) else { return nil }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        let windowSize = 160  // 10 мс при 16 кГц
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

private final class WaveformPeaksBox: NSObject {
    let peaks: [Float]
    init(_ peaks: [Float]) { self.peaks = peaks }
}

private actor WaveformWorkCoordinator {
    private struct Entry {
        let id: UUID
        let task: Task<[Float]?, Never>
    }

    private let maxConcurrent: Int
    private let loader: WaveformStore.Loader
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var inFlight: [String: Entry] = [:]

    init(maxConcurrent: Int, loader: @escaping WaveformStore.Loader) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.loader = loader
    }

    func value(key: String, path: String, cacheURL: URL) async -> [Float]? {
        if let existing = inFlight[key] { return await existing.task.value }
        let id = UUID()
        let task = Task<[Float]?, Never> { [weak self, loader] in
            guard let self else { return nil }
            await self.acquire()
            let result = await loader(path, cacheURL)
            await self.release()
            return result
        }
        inFlight[key] = Entry(id: id, task: task)
        let result = await task.value
        if inFlight[key]?.id == id { inFlight[key] = nil }
        return result
    }

    private func acquire() async {
        if active < maxConcurrent {
            active += 1
            return
        }
        await withCheckedContinuation { continuation in waiters.append(continuation) }
    }

    private func release() {
        if waiters.isEmpty {
            active -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
