import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let timelineClip = UTType(exportedAs: "ru.ungurenko.montazhka.timeline-clip")
}

/// AppKit сообщает об окончании и успешного, и отменённого drag на macOS 14.
struct TimelineClipDragSource: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let clipID: UUID
    let image: () -> NSImage?
    let onBegin: () -> UUID?
    let onEnd: (UUID) -> Void
    let onClick: (CGFloat) -> Void

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.source = self
        return view
    }

    func updateNSView(_ view: DragView, context: Context) { view.source = self }

    final class DragView: NSView, NSDraggingSource {
        var source: TimelineClipDragSource?
        private var downEvent: NSEvent?
        private var sessionID: UUID?
        // Замыкание сохраняется до конца сессии даже при замене SwiftUI-ячейки.
        private var finish: ((UUID) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent,
                event.type == .leftMouseDown,
                bounds.insetBy(dx: min(12, bounds.width / 4), dy: 0).contains(convert(point, from: superview))
            else { return nil }
            return self
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) { downEvent = event }

        override func mouseUp(with event: NSEvent) {
            guard downEvent != nil else { return }
            downEvent = nil
            source?.onClick(convert(event.locationInWindow, from: nil).x)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let downEvent, let source,
                hypot(
                    event.locationInWindow.x - downEvent.locationInWindow.x,
                    event.locationInWindow.y - downEvent.locationInWindow.y) >= 4,
                let image = source.image(), let token = source.onBegin()
            else { return }
            self.downEvent = nil
            sessionID = token
            finish = source.onEnd
            let writer = NSPasteboardItem()
            writer.setString(
                source.clipID.uuidString, forType: NSPasteboard.PasteboardType(UTType.timelineClip.identifier))
            let item = NSDraggingItem(pasteboardWriter: writer)
            let point = convert(event.locationInWindow, from: nil)
            item.setDraggingFrame(
                NSRect(
                    x: point.x - image.size.width / 2, y: point.y - image.size.height / 2,
                    width: image.size.width, height: image.size.height), contents: image)
            let session = beginDraggingSession(with: [item], event: event, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = !source.reduceMotion
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext)
            -> NSDragOperation
        {
            context == .withinApplication ? .move : []
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            if let sessionID { finish?(sessionID) }
            sessionID = nil
            finish = nil
            downEvent = nil
        }
    }
}

/// Снимок нужен только интерфейсу; контроллер получает окончательный порядок.
struct TimelineReorderSession: Equatable {
    let id = UUID()
    let draggedClipID: UUID
    let originalClips: [Clip]
    private(set) var previewClips: [Clip]

    init?(clipID: UUID, clips: [Clip]) {
        guard clips.contains(where: { $0.id == clipID }) else { return nil }
        draggedClipID = clipID
        originalClips = clips
        previewClips = clips
    }

    mutating func move(over targetID: UUID) {
        guard draggedClipID != targetID,
            let from = previewClips.firstIndex(where: { $0.id == draggedClipID }),
            let to = previewClips.firstIndex(where: { $0.id == targetID })
        else { return }
        previewClips.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }
}
