import AppKit
import SwiftUI

enum TimelineViewportMath {
    static func clampedPixelsPerSecond(_ proposed: CGFloat) -> CGFloat {
        min(240, max(3, proposed))
    }

    static func clampedOffset(
        _ proposed: CGFloat,
        contentWidth: CGFloat,
        viewportWidth: CGFloat
    ) -> CGFloat {
        min(max(0, proposed), max(0, contentWidth - viewportWidth))
    }

    static func offsetKeepingAnchor(
        currentOffset: CGFloat,
        anchorX: CGFloat,
        oldPixelsPerSecond: CGFloat,
        newPixelsPerSecond: CGFloat,
        leadingInset: CGFloat
    ) -> CGFloat {
        guard oldPixelsPerSecond > 0 else { return currentOffset }
        let timeAtAnchor = (currentOffset + anchorX - leadingInset) / oldPixelsPerSecond
        return timeAtAnchor * newPixelsPerSecond + leadingInset - anchorX
    }

    static func followOffset(
        playheadX: CGFloat,
        currentOffset: CGFloat,
        viewportWidth: CGFloat
    ) -> CGFloat {
        guard viewportWidth > 0 else { return currentOffset }
        let visibleX = playheadX - currentOffset
        let midpoint = viewportWidth / 2
        if visibleX < 0 || visibleX > viewportWidth || visibleX >= midpoint {
            return playheadX - midpoint
        }
        return currentOffset
    }
}

@MainActor
final class TimelineViewportProxy {
    private weak var scrollView: NSScrollView?
    private var boundsObserver: NSObjectProtocol?
    private var programmaticScrollDepth = 0
    private var lastKnownOffset: CGFloat = 0
    var onManualScroll: (() -> Void)?

    var horizontalOffset: CGFloat {
        scrollView?.contentView.bounds.minX ?? 0
    }

    var viewportWidth: CGFloat {
        scrollView?.contentView.bounds.width ?? 0
    }

    func attach(to scrollView: NSScrollView) {
        guard self.scrollView !== scrollView else { return }
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        self.scrollView = scrollView
        lastKnownOffset = scrollView.contentView.bounds.minX
        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let scrollView = self.scrollView else { return }
                let offset = scrollView.contentView.bounds.minX
                guard abs(offset - self.lastKnownOffset) > 0.25 else { return }
                self.lastKnownOffset = offset
                if self.programmaticScrollDepth == 0 { self.onManualScroll?() }
            }
        }
    }

    func setHorizontalOffset(_ proposed: CGFloat) {
        guard let scrollView else { return }
        let contentWidth = max(
            scrollView.documentView?.bounds.width ?? 0,
            scrollView.documentView?.frame.width ?? 0
        )
        let x = TimelineViewportMath.clampedOffset(
            proposed,
            contentWidth: contentWidth,
            viewportWidth: scrollView.contentView.bounds.width
        )
        var origin = scrollView.contentView.bounds.origin
        origin.x = x
        programmaticScrollDepth += 1
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        lastKnownOffset = x
        programmaticScrollDepth -= 1
    }

    func center(on contentX: CGFloat, anchorFraction: CGFloat = 0.5) {
        setHorizontalOffset(contentX - viewportWidth * anchorFraction)
    }

    func isVisible(contentX: CGFloat) -> Bool {
        let visible = horizontalOffset...(horizontalOffset + viewportWidth)
        return visible.contains(contentX)
    }

    deinit {
        MainActor.assumeIsolated {
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        }
    }
}

struct TimelineScrollResolver: NSViewRepresentable {
    let proxy: TimelineViewportProxy

    func makeNSView(context: Context) -> ResolverView {
        let view = ResolverView()
        view.proxy = proxy
        return view
    }

    func updateNSView(_ nsView: ResolverView, context: Context) {
        nsView.proxy = proxy
        nsView.resolveScrollView()
    }

    final class ResolverView: NSView {
        weak var proxy: TimelineViewportProxy?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resolveScrollView()
        }

        func resolveScrollView() {
            MainActor.assumeIsolated { [weak self] in
                guard let self, let scrollView = enclosingScrollView else { return }
                proxy?.attach(to: scrollView)
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct TimelineInputMonitor: NSViewRepresentable {
    var onHandKeyChanged: (Bool) -> Void
    var onZoom: (CGFloat, CGFloat) -> Void
    var onFit: () -> Void
    var onEscape: () -> Bool
    var onManualScroll: () -> Void
    var onPointerChanged: (CGFloat?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.coordinator = context.coordinator
        context.coordinator.view = view
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class MonitorView: NSView {
        weak var coordinator: Coordinator?
        private var pointerTrackingArea: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
            let trackingArea = NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(trackingArea)
            pointerTrackingArea = trackingArea
        }

        override func mouseMoved(with event: NSEvent) {
            coordinator?.parent.onPointerChanged(convert(event.locationInWindow, from: nil).x)
        }

        override func mouseExited(with event: NSEvent) {
            coordinator?.parent.onPointerChanged(nil)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: TimelineInputMonitor
        weak var view: MonitorView?
        private let monitor = LocalEventMonitor()

        init(parent: TimelineInputMonitor) {
            self.parent = parent
        }

        func installMonitor() {
            monitor.install(
                matching: [.keyDown, .keyUp, .magnify, .scrollWheel]
            ) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func removeMonitor() {
            monitor.remove()
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let view, event.window === view.window else { return event }
            let location = view.convert(event.locationInWindow, from: nil)
            let isInside = view.bounds.contains(location)

            switch event.type {
            case .scrollWheel where isInside:
                parent.onManualScroll()
                return event
            case .magnify where isInside:
                parent.onManualScroll()
                parent.onZoom(max(0.1, 1 + event.magnification), location.x)
                return nil
            case .keyDown, .keyUp:
                return handleKey(event)
            default:
                return event
            }
        }

        private func handleKey(_ event: NSEvent) -> NSEvent? {
            if NSApp.keyWindow?.firstResponder is NSTextView { return event }
            let isDown = event.type == .keyDown
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if event.keyCode == 4,
                !modifiers.contains(.command),
                !modifiers.contains(.control),
                !modifiers.contains(.option)
            {  // H / Р
                parent.onHandKeyChanged(isDown)
                return nil
            }
            guard isDown else { return event }

            if modifiers.contains(.command), (event.keyCode == 24 || event.keyCode == 69) {
                parent.onZoom(1.4, fallbackAnchorX())
                return nil
            }
            if modifiers.contains(.command), (event.keyCode == 27 || event.keyCode == 78) {
                parent.onZoom(1 / 1.4, fallbackAnchorX())
                return nil
            }
            if modifiers.contains(.shift), !modifiers.contains(.command), event.keyCode == 6 {
                parent.onFit()
                return nil
            }
            if event.keyCode == 53, parent.onEscape() {
                return nil
            }
            return event
        }

        private func fallbackAnchorX() -> CGFloat {
            guard let view, let window = view.window else { return 0 }
            let location = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            return view.bounds.contains(location) ? location.x : -1
        }
    }
}

struct TimelineHandPanOverlay: NSViewRepresentable {
    let proxy: TimelineViewportProxy
    var onBegan: () -> Void

    func makeNSView(context: Context) -> HandPanView {
        let view = HandPanView()
        view.proxy = proxy
        view.onBegan = onBegan
        return view
    }

    func updateNSView(_ nsView: HandPanView, context: Context) {
        nsView.proxy = proxy
        nsView.onBegan = onBegan
        nsView.window?.invalidateCursorRects(for: nsView)
    }

    final class HandPanView: NSView {
        weak var proxy: TimelineViewportProxy?
        var onBegan: (() -> Void)?
        private var dragStartX: CGFloat = 0
        private var offsetAtDragStart: CGFloat = 0
        private var isDragging = false

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: isDragging ? .closedHand : .openHand)
        }

        override func mouseDown(with event: NSEvent) {
            dragStartX = event.locationInWindow.x
            offsetAtDragStart = proxy?.horizontalOffset ?? 0
            isDragging = true
            onBegan?()
            window?.invalidateCursorRects(for: self)
            NSCursor.closedHand.set()
        }

        override func mouseDragged(with event: NSEvent) {
            let translation = event.locationInWindow.x - dragStartX
            proxy?.setHorizontalOffset(offsetAtDragStart - translation)
        }

        override func mouseUp(with event: NSEvent) {
            isDragging = false
            window?.invalidateCursorRects(for: self)
            NSCursor.openHand.set()
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}
