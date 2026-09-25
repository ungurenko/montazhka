import CoreGraphics
import Foundation
import Testing

@testable import MontazhkaKit

@Suite("Shorts camera")
struct ShortsCameraTests {
    private let landscape = CGSize(width: 1920, height: 1080)
    private let canvas = CGSize(width: 1080, height: 1920)
    private let source = MediaReference(path: "/tmp/a.mov")

    private func centre(_ x: Double, _ y: Double = 0.4) -> ShortsCameraPlanner.Centre {
        { _, _ in CGPoint(x: x, y: y) }
    }

    @Test("a face on the right pulls a 9:16 crop to the right")
    func faceCropFollowsFace() {
        let clips = [Clip(source: source, start: 0, end: 2)]
        let keys = ShortsCameraPlanner.keys(
            clips: clips, display: landscape, layout: .face, centre: centre(0.8), zooms: [])
        let rect = keys[0].rect
        #expect(abs(rect.height - 1080) < 0.01)
        #expect(abs(rect.width - 1080 * 9 / 16) < 0.01)
        #expect(abs(rect.midX - 1536) < 0.01)
    }

    @Test("the crop stays inside the picture")
    func faceCropClamped() {
        let clips = [Clip(source: source, start: 0, end: 2)]
        let keys = ShortsCameraPlanner.keys(
            clips: clips, display: landscape, layout: .face, centre: centre(0.99), zooms: [])
        #expect(keys.allSatisfy { $0.rect.maxX <= 1920 + 0.01 && $0.rect.minX >= -0.01 })
    }

    @Test("a zoom pushes in slowly, never past the limit, and lets go")
    func zoomPushesIn() {
        let clips = [Clip(source: source, start: 0, end: 10)]
        let zoom = ShortsZoom(sourceID: source.id, sourceStart: 2, sourceEnd: 6, scale: 1.3)
        let keys = ShortsCameraPlanner.keys(
            clips: clips, display: landscape, layout: .face, centre: centre(0.5), zooms: [zoom])
        func height(at time: Double) -> CGFloat { keys.min { abs($0.time - time) < abs($1.time - time) }!.rect.height }
        #expect(height(at: 1) == 1080)
        #expect(height(at: 4) < 1080)
        #expect(height(at: 5.99) >= 1080 / ShortsCameraPlanner.maxZoom - 0.5)
        #expect(height(at: 8) == 1080)
        #expect(keys.allSatisfy { $0.rect.height >= 1080 / ShortsCameraPlanner.maxZoom - 0.01 })
    }

    @Test("every clip gets its own keys so ramps never cross a cut")
    func keysPerClip() {
        let clips = [Clip(source: source, start: 0, end: 1), Clip(source: source, start: 5, end: 6.5)]
        let keys = ShortsCameraPlanner.keys(
            clips: clips, display: landscape, layout: .face, centre: centre(0.5), zooms: [])
        #expect(keys.contains { $0.clip == 1 && abs($0.time - 1) < 1e-9 })
        #expect(keys.contains { $0.clip == 0 && abs($0.time - 1) < 1e-9 })
        #expect(keys.last.map { abs($0.time - 2.5) < 1e-9 } == true)
        for (a, b) in zip(keys, keys.dropFirst()) { #expect(a.time <= b.time) }
    }

    @Test("fit shows the whole picture on a tall canvas")
    func fitShowsEverything() {
        let keys = ShortsCameraPlanner.keys(
            clips: [Clip(source: source, start: 0, end: 1)], display: landscape, layout: .fit,
            centre: centre(0.1), zooms: [])
        let rect = keys[0].rect
        #expect(abs(rect.width - 1920) < 0.01)
        #expect(abs(rect.height - 1920 * 16 / 9) < 0.01)
        #expect(abs(rect.midY - 540) < 0.01)
    }

    @Test("split puts the whole screen on top and the face below")
    func splitLayout() throws {
        let face = CGRect(x: 0.85, y: 0.8, width: 0.08, height: 0.14)
        let plan = try #require(ShortsCameraPlanner.split(display: landscape, canvas: canvas, faceBox: face))
        #expect(abs(plan.screen.width - 1080) < 0.01)
        #expect(abs(plan.screen.height - 1080 * 1080 / 1920) < 1)
        #expect(plan.faceRegion.minY >= plan.screen.maxY - 0.01)
        #expect(abs(plan.faceRegion.maxY - 1920) < 0.01)
        let aspect = plan.faceRegion.width / plan.faceRegion.height
        #expect(abs(plan.faceCrop.width / plan.faceCrop.height - aspect) < 0.001)
        #expect(CGRect(origin: .zero, size: landscape).insetBy(dx: -0.5, dy: -0.5).contains(plan.faceCrop))
    }

    @Test("a small crop around a corner webcam sits on the face, not on the frame middle")
    func smallCropFollowsFaceVertically() {
        let keys = ShortsCameraPlanner.keys(
            clips: [Clip(source: source, start: 0, end: 1)], display: landscape, layout: .face,
            centre: centre(0.85, 0.8), zooms: [], aspect: 1, base: CGSize(width: 200, height: 200))
        #expect(abs(keys[0].rect.midY - 0.8 * 1080) < 1)
        #expect(abs(keys[0].rect.midX - 0.85 * 1920) < 1)
    }

    @Test("the transform maps the crop exactly onto the canvas region")
    func transformMapsCrop() {
        let crop = CGRect(x: 600, y: 0, width: 607.5, height: 1080)
        let region = CGRect(origin: .zero, size: canvas)
        let transform = ShortsCameraPlanner.transform(crop: crop, into: region, normalized: .identity)
        let topLeft = CGPoint(x: crop.minX, y: crop.minY).applying(transform)
        let bottomRight = CGPoint(x: crop.maxX, y: crop.maxY).applying(transform)
        #expect(abs(topLeft.x) < 0.01 && abs(topLeft.y) < 0.01)
        #expect(abs(bottomRight.x - 1080) < 0.5 && abs(bottomRight.y - 1920) < 0.5)
    }
}
