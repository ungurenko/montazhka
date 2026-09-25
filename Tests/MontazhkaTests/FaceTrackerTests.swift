import CoreGraphics
import Foundation
import Testing

@testable import MontazhkaKit

@Suite("Face following")
struct FaceTrackerTests {
    private func face(_ time: Double, x: Double, y: Double = 0.4, size: Double = 0.2) -> FaceSample {
        FaceSample(time: time, box: CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size))
    }

    private func times(_ from: Double, _ to: Double) -> [Double] {
        stride(from: from, to: to, by: FaceTrackStore.step).map { $0 }
    }

    @Test("small head wobble does not shake the frame")
    func jitterIsIgnored() {
        let samples = times(0, 10).enumerated().map { face($1, x: $0 % 2 == 0 ? 0.50 : 0.53) }
        let path = FaceFollowSmoother.path(samples, cropWidth: 0.3)
        let xs = path.map(\.x)
        #expect((xs.max() ?? 0) - (xs.min() ?? 0) < 0.01)
    }

    @Test("the frame follows a move smoothly and arrives")
    func followsWithLimitedSpeed() {
        let samples = times(0, 15).map { face($0, x: $0 < 5 ? 0.3 : 0.7) }
        let path = FaceFollowSmoother.path(samples, cropWidth: 0.3)
        for (a, b) in zip(path, path.dropFirst()) {
            #expect(abs(b.x - a.x) <= FaceFollowSmoother.maxSpeed * (b.time - a.time) + 1e-9)
        }
        #expect(abs((path.last?.x ?? 0) - 0.7) < 0.02)
    }

    @Test("the crop never leaves the picture")
    func clampsToFrame() {
        let samples = times(0, 3).map { face($0, x: 0.02) }
        let path = FaceFollowSmoother.path(samples, cropWidth: 0.3)
        #expect(path.allSatisfy { abs($0.x - 0.15) < 1e-9 })
    }

    @Test("when the face is lost the frame stays where it was")
    func holdsLastPosition() {
        let samples = times(0, 10).map { $0 < 3 ? face($0, x: 0.6) : FaceSample(time: $0, box: nil) }
        let path = FaceFollowSmoother.path(samples, cropWidth: 0.3)
        #expect(abs((path.last?.x ?? 0) - 0.6) < 0.01)
    }

    @Test("no faces at all keeps the centre")
    func noFacesCentre() {
        let path = FaceFollowSmoother.path(times(0, 2).map { FaceSample(time: $0, box: nil) }, cropWidth: 0.3)
        #expect(path.allSatisfy { $0.x == 0.5 })
    }

    @Test("a small face in the corner means a screen recording")
    func suggestsSplit() {
        let samples = times(0, 10).map { face($0, x: 0.88, y: 0.85, size: 0.1) }
        #expect(FaceLayoutAdvisor.suggest(samples) == .split)
    }

    @Test("a big face means a talking head")
    func suggestsFace() {
        let samples = times(0, 10).map { face($0, x: 0.5, y: 0.4, size: 0.3) }
        #expect(FaceLayoutAdvisor.suggest(samples) == .face)
    }

    @Test("no faces means the whole frame")
    func suggestsFit() {
        #expect(FaceLayoutAdvisor.suggest(times(0, 10).map { FaceSample(time: $0, box: nil) }) == .fit)
    }

    @Test("a video without a face gives an empty track and is cached")
    func storeFindsNoFaceInBlackVideo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("black.mov")
        try await TestVideoFactory.make(segments: [(duration: 4, loud: true)], to: video)
        let store = FaceTrackStore(cacheDir: root.appendingPathComponent("FaceTracks"))

        let samples = try await store.samples(for: video, ranges: [0...2])
        #expect(samples.count == 9)
        #expect(samples.allSatisfy { $0.box == nil })
        let cached = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("FaceTracks").path)
        #expect(cached.count == 1)
    }
}
