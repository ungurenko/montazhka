import AppKit
import Testing

@testable import MontazhkaKit

@MainActor
@Suite("Timeline held keys finish in every focus context", .serialized)
struct TimelineKeyboardTests {
    @Test
    func handKeyReleaseSurvivesTextFocusAndModifiers() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: .titled,
            backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let view = TimelineInputMonitor.MonitorView()
        window.contentView = view
        window.makeKey()
        var held = false
        let monitor = TimelineInputMonitor(
            onHandKeyChanged: { held = $0 }, onZoom: { _, _ in }, onFit: {}, onEscape: { false },
            onManualScroll: {}, onPointerChanged: { _ in })
        let coordinator = TimelineInputMonitor.Coordinator(parent: monitor)
        coordinator.view = view
        let down = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil,
                characters: "h", charactersIgnoringModifiers: "h", isARepeat: false, keyCode: 4))
        #expect(coordinator.handleKey(down, keyWindow: window, modalWindow: nil) == nil)
        #expect(held)
        let text = NSTextView(frame: .zero)
        view.addSubview(text)
        window.makeFirstResponder(text)
        let up = try #require(
            NSEvent.keyEvent(
                with: .keyUp, location: .zero, modifierFlags: .command, timestamp: 1,
                windowNumber: window.windowNumber, context: nil,
                characters: "h", charactersIgnoringModifiers: "h", isARepeat: false, keyCode: 4))
        #expect(coordinator.handleKey(up, keyWindow: window, modalWindow: nil) == nil)
        #expect(!held)
        #expect(coordinator.handleKey(down, keyWindow: window, modalWindow: nil) != nil)
        #expect(!held)
    }

    @Test
    func windowAndApplicationDeactivationReleaseHeldKey() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: .titled,
            backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let view = TimelineInputMonitor.MonitorView()
        window.contentView = view
        window.makeKey()
        var held = false
        let monitor = TimelineInputMonitor(
            onHandKeyChanged: { held = $0 }, onZoom: { _, _ in }, onFit: {}, onEscape: { false },
            onManualScroll: {}, onPointerChanged: { _ in })
        let coordinator = TimelineInputMonitor.Coordinator(parent: monitor)
        coordinator.view = view
        coordinator.installMonitor()
        defer { coordinator.removeMonitor() }
        let down = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil,
                characters: "h", charactersIgnoringModifiers: "h", isARepeat: false, keyCode: 4))
        _ = coordinator.handleKey(down, keyWindow: window, modalWindow: nil)
        #expect(held)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(!held)
        _ = coordinator.handleKey(down, keyWindow: window, modalWindow: nil)
        #expect(held)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        #expect(!held)
    }
}
