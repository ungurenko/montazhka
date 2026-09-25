@preconcurrency import AVFoundation
import CoreGraphics
import CryptoKit
import Foundation
import Vision

/// Самое крупное лицо в кадре в момент `time` (секунды исходника).
/// `box` — доли кадра, начало координат в левом верхнем углу; nil — лица нет.
struct FaceSample: Codable, Equatable, Sendable {
    let time: Double
    let box: CGRect?
}

/// Центр вертикальной рамки в долях кадра исходника.
struct FacePoint: Equatable, Sendable {
    let time: Double
    let x: Double
    let y: Double
}

/// Превращает дёрганые находки Vision в спокойное движение «операторской» рамки.
enum FaceFollowSmoother {
    /// Сдвиги лица меньше этой доли ширины кадра рамку не трогают.
    static let deadZone = 0.08
    /// Больше этой доли ширины кадра в секунду рамка не движется.
    static let maxSpeed = 0.12
    /// Доля оставшегося пути, которую рамка проходит за шаг выборки.
    static let followRate = 0.35

    /// `cropWidth` — ширина рамки в долях ширины кадра: центр держится так,
    /// чтобы рамка не выходила за края.
    static func path(_ samples: [FaceSample], cropWidth: Double) -> [FacePoint] {
        let sorted = samples.sorted { $0.time < $1.time }
        guard !sorted.isEmpty else { return [] }
        let raw = heldCentres(sorted)
        let targets = zip(medianFiltered(raw.map(\.x)), medianFiltered(raw.map(\.y))).map { ($0, $1) }
        let half = min(0.5, cropWidth / 2)

        var x = targets[0].0
        var y = targets[0].1
        var moving = false
        var result: [FacePoint] = []
        for (index, sample) in sorted.enumerated() {
            if index > 0 {
                let dt = sample.time - sorted[index - 1].time
                let (tx, ty) = targets[index]
                if max(abs(tx - x), abs(ty - y)) > deadZone { moving = true }
                if moving {
                    let limit = maxSpeed * dt
                    x += max(-limit, min(limit, (tx - x) * followRate))
                    y += max(-limit, min(limit, (ty - y) * followRate))
                    if max(abs(tx - x), abs(ty - y)) < 0.005 { moving = false }
                }
            }
            result.append(
                FacePoint(time: sample.time, x: max(half, min(1 - half, x)), y: max(0, min(1, y))))
        }
        return result
    }

    /// Средняя рамка лица — для нижней половины раскладки «экран + лицо».
    static func medianBox(_ samples: [FaceSample]) -> CGRect? {
        let boxes = samples.compactMap(\.box)
        guard !boxes.isEmpty else { return nil }
        func median(_ values: [CGFloat]) -> CGFloat { values.sorted()[values.count / 2] }
        return CGRect(
            x: median(boxes.map(\.minX)), y: median(boxes.map(\.minY)),
            width: median(boxes.map(\.width)), height: median(boxes.map(\.height)))
    }

    /// Центры лиц; где лица нет — последний известный центр
    /// (до первой находки — первый, без находок вообще — середина кадра).
    private static func heldCentres(_ samples: [FaceSample]) -> [(x: Double, y: Double)] {
        let first = samples.lazy.compactMap(\.box).first.map { (x: Double($0.midX), y: Double($0.midY)) }
        var last = first ?? (x: 0.5, y: 0.5)
        return samples.map { sample in
            if let box = sample.box { last = (x: Double(box.midX), y: Double(box.midY)) }
            return last
        }
    }

    private static func medianFiltered(_ values: [Double], radius: Int = 2) -> [Double] {
        values.indices.map { index in
            let window = values[max(0, index - radius)...min(values.count - 1, index + radius)].sorted()
            return window[window.count / 2]
        }
    }
}

/// Какая раскладка подходит куску видео, судя по лицам.
enum FaceLayoutAdvisor {
    static func suggest(_ samples: [FaceSample]) -> ShortsDraftLayout {
        let boxes = samples.compactMap(\.box)
        guard !samples.isEmpty, Double(boxes.count) >= Double(samples.count) * 0.3 else { return .fit }
        let cornerCams = boxes.filter { box in
            let small = box.width * box.height < 0.03
            let sideways = box.midX < 0.33 || box.midX > 0.67
            let offCentreVertically = box.midY < 0.4 || box.midY > 0.6
            return small && sideways && offCentreVertically
        }
        return Double(cornerCams.count) >= Double(boxes.count) * 0.7 ? .split : .face
    }
}

/// Находит лица в нужных кусках исходника четыре раза в секунду и помнит
/// найденное: повторный запрос тех же моментов не гоняет Vision заново.
actor FaceTrackStore {
    static let step = 0.25
    private let cacheDir: URL

    init(cacheDir: URL) {
        self.cacheDir = cacheDir
    }

    private struct Cache: Codable {
        var samples: [Int: CGRect?]
    }

    /// Выборки по сетке `step` внутри `ranges` (секунды исходника, края включены).
    func samples(for source: URL, ranges: [ClosedRange<Double>]) async throws -> [FaceSample] {
        let slots = Set(ranges.flatMap { range in
            Int((max(0, range.lowerBound) / Self.step).rounded(.down))...Int((range.upperBound / Self.step).rounded(.up))
        })
        let cacheURL = cacheURL(for: source)
        var cache = (try? JSONDecoder().decode(Cache.self, from: Data(contentsOf: cacheURL))) ?? Cache(samples: [:])
        let missing = slots.filter { cache.samples[$0] == nil }.sorted()
        if !missing.isEmpty {
            let found = try await detect(in: source, slots: missing)
            for slot in missing { cache.samples[slot] = .some(found[slot] ?? nil) }
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            try JSONEncoder().encode(cache).write(to: cacheURL, options: .atomic)
        }
        return slots.sorted().map { FaceSample(time: Double($0) * Self.step, box: cache.samples[$0] ?? nil) }
    }

    private func detect(in source: URL, slots: [Int]) async throws -> [Int: CGRect?] {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let tolerance = CMTime(seconds: Self.step / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var result: [Int: CGRect?] = [:]
        let times = slots.map { CMTime(seconds: min(Double($0) * Self.step, max(0, duration - 0.05)), preferredTimescale: 600) }
        for await item in generator.images(for: times) {
            try Task.checkCancellation()
            let slot = slots[times.firstIndex(of: item.requestedTime) ?? 0]
            guard let image = try? item.image else {
                result[slot] = .some(nil)
                continue
            }
            result[slot] = .some(largestFace(in: image))
        }
        return result
    }

    private func largestFace(in image: CGImage) -> CGRect? {
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        guard let face = (request.results ?? []).max(by: { $0.boundingBox.area < $1.boundingBox.area }) else {
            return nil
        }
        let box = face.boundingBox
        // У Vision начало координат снизу; у нас — сверху, как у кадра.
        return CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }

    private func cacheURL(for source: URL) -> URL {
        let attrs = try? FileManager.default.attributesOfItem(atPath: source.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "faces-v1|\(source.path)|\(size)|\(Int(mtime))"
        let hash = SHA256.hash(data: Data(key.utf8)).hex
        return cacheDir.appendingPathComponent("\(hash).json")
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}
