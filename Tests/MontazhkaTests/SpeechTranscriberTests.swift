import XCTest
@testable import Montazhka

final class SpeechTranscriberTests: XCTestCase {
    func testLongAudioIsSplitIntoBoundedOverlappingChunks() {
        let chunks = SpeechChunkPlanner.make(duration: 121, maximumDuration: 50, overlap: 1)

        XCTAssertEqual(chunks.map(\.start), [0, 49, 98])
        XCTAssertEqual(chunks.map(\.duration), [50, 50, 23])
        XCTAssertTrue(chunks.allSatisfy { $0.duration <= 50 })
    }
}
