import Foundation
import Testing
import UniformTypeIdentifiers

@testable import MontazhkaKit

@Suite
struct DroppedVideoLoaderTests {
    @MainActor
    @Test
    func testLoaderPreservesProviderOrderAndSkipsNonVideo() async {
        let first = URL(fileURLWithPath: "/tmp/first.mov")
        let ignored = URL(fileURLWithPath: "/tmp/notes.txt")
        let second = URL(fileURLWithPath: "/tmp/second.mp4")
        let providers = [first, ignored, second].map {
            NSItemProvider(item: $0 as NSURL, typeIdentifier: UTType.fileURL.identifier)
        }

        let urls = await DroppedVideoLoader.load(from: providers)

        #expect((urls) == ([first, second]))
    }
}
