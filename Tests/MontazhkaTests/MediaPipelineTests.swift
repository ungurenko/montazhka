import XCTest
@testable import Montazhka

final class MediaPipelineTests: XCTestCase {
    func testCompositionReportsMissingVideoInsteadOfSilentlySkippingIt() async {
        let clip = Clip(sourcePath: "/tmp/montazhka-definitely-missing.mov", start: 0, end: 5)

        let result = await CompositionBuilder.buildResult(clips: [clip])

        XCTAssertTrue(result.warnings.contains(.missingVideo(clip.fileName)))
        XCTAssertEqual(result.composition.duration.seconds, 0, accuracy: 0.001)
    }
}
