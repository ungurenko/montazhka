import AppKit
import SwiftUI

/// Пробел принадлежит просмотру только в окне, которое содержит экран Shorts.
@MainActor
enum ShortsPlaybackKeyScope {
    static func handles(
        _ event: NSEvent,
        hostWindow: NSWindow?,
        keyWindow: NSWindow?,
        modalWindow: NSWindow?
    ) -> Bool {
        guard event.type == .keyDown, event.keyCode == 49,
            event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
            let hostWindow, event.window === hostWindow, keyWindow === hostWindow,
            modalWindow == nil, hostWindow.attachedSheet == nil
        else { return false }
        return !(hostWindow.firstResponder is any NSTextInputClient)
    }
}

struct ShortsPlaybackKeyMonitor: NSViewRepresentable {
    var controller: ShortsController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeNSView(context: Context) -> NSView {
        let view = MonitorView()
        context.coordinator.view = view
        if !controller.isPreview { context.coordinator.install() }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.controller = controller
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.monitor.remove()
    }

    @MainActor
    final class Coordinator {
        var controller: ShortsController
        weak var view: NSView?
        let monitor = LocalEventMonitor()

        init(controller: ShortsController) { self.controller = controller }

        func install() {
            monitor.install(matching: .keyDown) { [weak self] event in
                guard let self,
                    ShortsPlaybackKeyScope.handles(
                        event, hostWindow: self.view?.window,
                        keyWindow: NSApp.keyWindow, modalWindow: NSApp.modalWindow)
                else { return event }
                self.controller.togglePlay()
                return nil
            }
        }
    }

    private final class MonitorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
