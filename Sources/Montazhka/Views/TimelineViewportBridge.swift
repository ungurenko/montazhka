import AppKit
import Observation
import SwiftUI

/// Наблюдается только рисовальщиками, а не раскладкой всех клипов.
@MainActor
@Observable
final class TimelineViewportState {
    var bounds = CGRect(x: 0, y: 0, width: 800, height: 0)
}

enum TimelineDrawingRange {
    static let overscan: CGFloat = 128

    static func local(contentX: CGFloat, width: CGFloat, viewport: CGRect) -> Range<CGFloat> {
        let lower = max(0, viewport.minX - contentX - overscan)
        let upper = min(width, viewport.maxX - contentX + overscan)
        return lower < upper ? lower..<upper : 0..<0
    }
}

enum TimelineWaveformDrawing {
    /// Шаг и начало сетки — прежние, даже когда рисуется только часть клипа.
    static func path(clip: Clip, peaks: [Float], size: CGSize, range: Range<CGFloat>) -> Path {
        guard size.width > 0, !peaks.isEmpty, !range.isEmpty else { return Path() }
        let wps = WaveformStore.windowsPerSecond
        let mid = size.height / 2
        let step: CGFloat = 2
        let secondsPerPixel = clip.duration / Double(size.width)
        var x = floor(range.lowerBound / step) * step
        var path = Path()
        while x < min(size.width, range.upperBound) {
            let from = clip.start + Double(x) * secondsPerPixel
            let to = from + Double(step) * secondsPerPixel
            let i0 = max(0, min(peaks.count - 1, Int(from * wps)))
            let i1 = max(i0 + 1, min(peaks.count, Int(to * wps)))
            var peak: Float = 0
            for i in i0..<i1 where peaks[i] > peak { peak = peaks[i] }
            let value = min(1.0, pow(Double(peak) * 4.0, 0.8))
            let h = max(1, mid * CGFloat(value))
            path.addRoundedRect(
                in: CGRect(x: x, y: mid - h, width: 1.5, height: h * 2),
                cornerSize: CGSize(width: 0.75, height: 0.75))
            x += step
        }
        return path
    }
}

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
    let drawingState = TimelineViewportState()
    private weak var scrollView: NSScrollView?
    private var boundsObserver: NSObjectProtocol?
    private var frameObserver: NSObjectProtocol?
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
        drawingState.bounds = scrollView.contentView.bounds
        guard self.scrollView !== scrollView else { return }
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        self.scrollView = scrollView
        lastKnownOffset = scrollView.contentView.bounds.minX
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let scrollView = self.scrollView else { return }
                self.drawingState.bounds = scrollView.contentView.bounds
                self.lastKnownOffset = scrollView.contentView.bounds.minX
            }
        }
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let scrollView = self.scrollView else { return }
                let oldSize = self.drawingState.bounds.size
                let newSize = scrollView.contentView.bounds.size
                let resized = abs(oldSize.width - newSize.width) > 0.25 || abs(oldSize.height - newSize.height) > 0.25
                self.drawingState.bounds = scrollView.contentView.bounds
                let offset = scrollView.contentView.bounds.minX
                guard abs(offset - self.lastKnownOffset) > 0.25 else { return }
                self.lastKnownOffset = offset
                if self.programmaticScrollDepth == 0, !resized { self.onManualScroll?() }
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
        drawingState.bounds = scrollView.contentView.bounds
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
            if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
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

        override func layout() {
            super.layout()
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

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { coordinator?.resetHandKey() }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: TimelineInputMonitor
        weak var view: MonitorView?
        private let monitor = LocalEventMonitor()
        private var handKeyHeld = false

        init(parent: TimelineInputMonitor) {
            self.parent = parent
        }

        func installMonitor() {
            NotificationCenter.default.addObserver(
                self, selector: #selector(resetHandKey), name: NSApplication.didResignActiveNotification, object: nil)
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowResignedKey(_:)), name: NSWindow.didResignKeyNotification, object: nil)
            monitor.install(
                matching: [.keyDown, .keyUp, .magnify, .scrollWheel]
            ) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func removeMonitor() {
            monitor.remove()
            NotificationCenter.default.removeObserver(self)
            resetHandKey()
        }

        @objc func resetHandKey() {
            handKeyHeld = false
            parent.onHandKeyChanged(false)
        }

        @objc private func windowResignedKey(_ notification: Notification) {
            if notification.object as? NSWindow === view?.window { resetHandKey() }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            if event.type == .keyUp, event.keyCode == 4, handKeyHeld {
                resetHandKey()
                return nil
            }
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

        func handleKey(
            _ event: NSEvent,
            keyWindow: NSWindow? = NSApp.keyWindow,
            modalWindow: NSWindow? = NSApp.modalWindow
        ) -> NSEvent? {
            if event.type == .keyUp, event.keyCode == 4, handKeyHeld {
                resetHandKey()
                return nil
            }
            guard let window = view?.window, window === keyWindow,
                window.attachedSheet == nil, modalWindow == nil,
                !(window.firstResponder is any NSTextInputClient)
            else { return event }
            let isDown = event.type == .keyDown
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if event.keyCode == 4,
                !modifiers.contains(.command),
                !modifiers.contains(.control),
                !modifiers.contains(.option)
            {  // H / Р
                handKeyHeld = isDown
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
