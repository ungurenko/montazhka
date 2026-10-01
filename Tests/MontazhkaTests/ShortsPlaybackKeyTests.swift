import AppKit
import Testing

@testable import MontazhkaKit

@Suite
@MainActor
struct ShortsPlaybackKeyTests {
    @Test
    func spaceIsRestrictedToItsWindowAndSkipsTextModifiersAndDialogs() throws {
        _ = NSApplication.shared
        let host = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        other.isReleasedWhenClosed = false
        defer {
            host.close()
            other.close()
        }
        let space = try #require(event(window: host))
        #expect(ShortsPlaybackKeyScope.handles(space, hostWindow: host, keyWindow: host, modalWindow: nil))
        #expect(!ShortsPlaybackKeyScope.handles(space, hostWindow: other, keyWindow: host, modalWindow: nil))
        #expect(!ShortsPlaybackKeyScope.handles(space, hostWindow: host, keyWindow: other, modalWindow: nil))
        #expect(!ShortsPlaybackKeyScope.handles(space, hostWindow: nil, keyWindow: host, modalWindow: nil))
        #expect(!ShortsPlaybackKeyScope.handles(space, hostWindow: host, keyWindow: host, modalWindow: other))
        let commandSpace = try #require(event(window: host, flags: .command))
        #expect(!ShortsPlaybackKeyScope.handles(commandSpace, hostWindow: host, keyWindow: host, modalWindow: nil))

        let text = NSTextView(frame: CGRect(x: 0, y: 0, width: 100, height: 50))
        host.contentView?.addSubview(text)
        host.makeFirstResponder(text)
        #expect(!ShortsPlaybackKeyScope.handles(space, hostWindow: host, keyWindow: host, modalWindow: nil))
        host.makeFirstResponder(nil)

        host.beginSheet(other)
        #expect(!ShortsPlaybackKeyScope.handles(space, hostWindow: host, keyWindow: host, modalWindow: nil))
        host.endSheet(other)
    }

    private func event(window: NSWindow, flags: NSEvent.ModifierFlags = []) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)
    }
}
