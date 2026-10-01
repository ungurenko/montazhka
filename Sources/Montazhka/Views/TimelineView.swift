import SwiftUI
import UniformTypeIdentifiers

struct TimelineLayoutItem: Identifiable, Equatable {
    let clip: Clip
    let start: Double

    var id: UUID { clip.id }
}

/// Готовые координаты клипов: один линейный проход без повторных поисков.
struct TimelineLayout: Equatable {
    let items: [TimelineLayoutItem]
    let duration: Double

    init(clips: [Clip]) {
        var cursor = 0.0
        items = clips.map { clip in
            defer { cursor += clip.duration }
            return TimelineLayoutItem(clip: clip, start: cursor)
        }
        duration = cursor
    }
}

enum TimelineDragPreviewMath {
    static func width(forClipWidth width: CGFloat) -> CGFloat {
        min(240, max(80, width))
    }
}

private struct TimelineTrimPreview: Equatable, Sendable {
    let originalClip: Clip
    let edge: TimelineTrimEdge
    var sourceTime: Double

    var clip: Clip {
        var result = originalClip
        if edge == .start {
            result.start = sourceTime
        } else {
            result.end = sourceTime
        }
        return result
    }
}

/// Лента клипов: волны звука, линейка времени, курсор, зум, перетаскивание.
struct TimelineView: View {
    var controller: EditorController
    @State private var reorderSession: TimelineReorderSession?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @State private var viewportWidth: CGFloat = 800
    @State private var viewportProxy = TimelineViewportProxy()
    @State private var handToolLatched = false
    @State private var handKeyHeld = false
    @State private var followPlayback = false
    @State private var pointerX: CGFloat?
    @State private var trimPreview: TimelineTrimPreview?
    @State private var trimWasCancelled = false

    private let clipHeight: CGFloat = 92
    private let rulerHeight: CGFloat = 20
    /// Зазор между линейкой, полосой анимаций и клипами.
    private let laneSpacing: CGFloat = 4
    private let timelineInset: CGFloat = 12

    private var pps: CGFloat { controller.pixelsPerSecond }
    private var handToolActive: Bool { handToolLatched || handKeyHeld }
    private func totalWidth(for duration: Double) -> CGFloat {
        max(CGFloat(duration) * pps + 40, viewportWidth - 24)
    }

    var body: some View {
        let layout = TimelineLayout(clips: reorderSession?.previewClips ?? controller.project.clips)

        VStack(spacing: 6) {
            header(duration: layout.duration)
            GeometryReader { geo in
                ScrollView(.horizontal, showsIndicators: true) {
                    timelineContent(layout: layout)
                        .padding(.horizontal, timelineInset)
                        .background(TimelineScrollResolver(proxy: viewportProxy))
                }
                .overlay {
                    TimelineInputMonitor(
                        onHandKeyChanged: { handKeyHeld = $0 },
                        onZoom: { factor, anchor in
                            zoom(by: factor, anchorX: anchor >= 0 ? anchor : nil)
                        },
                        onFit: { fitTimeline(duration: layout.duration) },
                        onEscape: cancelTransientInteraction,
                        onManualScroll: manualViewportInteraction,
                        onPointerChanged: { pointerX = $0 }
                    )
                }
                .overlay {
                    if handToolActive {
                        TimelineHandPanOverlay(proxy: viewportProxy) {
                            manualViewportInteraction()
                        }
                    }
                }
                .onAppear {
                    viewportWidth = geo.size.width
                    viewportProxy.onManualScroll = manualViewportInteraction
                }
                .onChange(of: geo.size.width) { _, w in viewportWidth = w }
            }
        }
        .padding(12)
        .cardStyle()
        .background {
            TimelinePlaybackFollower(
                controller: controller,
                pixelsPerSecond: pps,
                leadingInset: timelineInset,
                followsPlayback: followPlayback,
                viewportProxy: viewportProxy
            )
        }
        .accessibilityIdentifier("editor.timeline")
        .onDrop(of: [.timelineClip], isTargeted: nil) { _ in finishReorder() }
        .onChange(of: controller.project.clips) {
            if let session = reorderSession, session.originalClips != controller.project.clips {
                reorderSession = nil
            }
        }
        .onDisappear {
            handKeyHeld = false
            reorderSession = nil
            viewportProxy.onManualScroll = nil
        }
    }

    // MARK: - Шапка ленты

    private func header(duration: Double) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            Text("Лента")
                .typeStyle(.bodyEmphasis)
                .foregroundStyle(Theme.textSecondary)
            if !controller.candidates.isEmpty {
                Label("\(controller.candidates.filter(\.enabled).count) пауз к вырезке", systemImage: "scissors")
                    .typeStyle(.helper)
                    .foregroundStyle(Theme.pauseHighlight)
            }
            if !controller.smartEditCandidates.isEmpty {
                Label(
                    "\(controller.smartEditCandidates.filter(\.enabled).count) умных правок",
                    systemImage: "wand.and.sparkles"
                )
                .typeStyle(.helper)
                .foregroundStyle(.orange)
            }
            if let selection = controller.timelineSelection {
                Label("\(TimeFormat.short(selection.duration)) выделено", systemImage: "selection.pin.in.out")
                    .typeStyle(.helper)
                    .foregroundStyle(Theme.accent)
            }
            Spacer()
            IconButton(icon: "arrow.right.to.line", help: "Показать курсор воспроизведения", size: .toolbar) {
                viewportProxy.center(on: playheadContentX, anchorFraction: 0.3)
            }
            Divider().frame(height: 14)
            IconButton(
                icon: handToolActive ? "hand.raised.fill" : "hand.raised",
                help: "Двигать ленту мышью (удерживай H)",
                size: .toolbar,
                prominence: handToolActive ? .active : .quiet,
                stateDescription: handToolActive ? "Включено" : "Выключено"
            ) {
                handToolLatched.toggle()
            }
            IconButton(
                icon: followPlayback ? "location.fill" : "location",
                help: "Следить за воспроизведением",
                size: .toolbar,
                prominence: followPlayback ? .active : .quiet,
                stateDescription: followPlayback ? "Включено" : "Выключено"
            ) {
                toggleFollowPlayback()
            }
            Divider().frame(height: 14)
            IconButton(icon: "minus.magnifyingglass", help: "Отдалить", size: .toolbar) {
                zoom(by: 1 / 1.4, anchorX: pointerX)
            }
            IconButton(icon: "arrow.left.and.right.square", help: "Вся лента целиком", size: .toolbar) {
                fitTimeline(duration: duration)
            }
            IconButton(icon: "plus.magnifyingglass", help: "Приблизить", size: .toolbar) {
                zoom(by: 1.4, anchorX: pointerX)
            }
        }
    }

    // MARK: - Содержимое

    private func timelineContent(layout: TimelineLayout) -> some View {
        let width = totalWidth(for: layout.duration)
        // Без анимаций полосы нет совсем — лента у обычного проекта не сдвигается.
        let showsOverlayLane = !controller.project.overlays.isEmpty
        let laneSpace = showsOverlayLane ? TimelineOverlayLane.height + laneSpacing : 0

        return VStack(alignment: .leading, spacing: laneSpacing) {
            RulerView(
                duration: layout.duration, pps: pps, viewport: viewportProxy.drawingState, contentX: timelineInset
            )
            .frame(width: width, height: rulerHeight)
            .contentShape(Rectangle())
            .gesture(scrubGesture)
            .accessibilityElement()
            .accessibilityLabel("Линейка времени")
            .accessibilityHint("Увеличивай или уменьшай значение, чтобы перемещаться по видео")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    controller.seek(to: min(controller.duration, controller.currentTime + 1))
                case .decrement:
                    controller.seek(to: max(0, controller.currentTime - 1))
                @unknown default:
                    break
                }
            }

            if showsOverlayLane {
                TimelineOverlayLane(
                    overlays: OverlayTimeline.resolve(controller.project.overlays, clips: controller.project.clips),
                    pps: pps,
                    width: width,
                    onSeek: { controller.seek(to: $0) },
                    onRemove: { controller.removeOverlay(id: $0) })
            }

            ZStack(alignment: .topLeading) {
                if layout.items.isEmpty {
                    Text("Здесь появятся клипы")
                        .typeStyle(.body)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: width, height: clipHeight)
                } else {
                    ForEach(layout.items) { item in
                        timelineClip(item)
                    }
                }

                if trimPreview == nil, let selection = controller.timelineSelection {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Theme.accent.opacity(0.18))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(Theme.accent.opacity(0.8), lineWidth: 1.5)
                        )
                        .frame(width: max(2, CGFloat(selection.duration) * pps), height: clipHeight)
                        .offset(x: CGFloat(selection.start) * pps)
                        .allowsHitTesting(false)
                }

                // Подсветка предложений умного монтажа
                ForEach(trimPreview == nil ? controller.smartEditCandidates : []) { candidate in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.orange.opacity(candidate.enabled ? 0.28 : 0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(Color.orange.opacity(candidate.enabled ? 0.8 : 0.2), lineWidth: 1)
                        )
                        .frame(
                            width: max(2, CGFloat(candidate.timelineEnd - candidate.timelineStart) * pps),
                            height: clipHeight
                        )
                        .offset(x: CGFloat(candidate.timelineStart) * pps)
                        .allowsHitTesting(false)
                }

                // Подсветка найденных пауз
                ForEach(trimPreview == nil ? controller.candidates : []) { candidate in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Theme.pauseHighlight.opacity(candidate.enabled ? 0.32 : 0.10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(Theme.pauseHighlight.opacity(candidate.enabled ? 0.8 : 0.25), lineWidth: 1)
                        )
                        .frame(
                            width: max(2, CGFloat(candidate.fullEnd - candidate.fullStart) * pps),
                            height: clipHeight
                        )
                        .offset(x: CGFloat(candidate.fullStart) * pps)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: width, alignment: .topLeading)
        }
        .overlay(alignment: .topLeading) {
            TimelinePlayhead(
                controller: controller,
                pps: pps,
                height: rulerHeight + laneSpacing + laneSpace + clipHeight)
        }
    }

    // MARK: - Жесты

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                controller.player.pause()
                if abs(value.translation.width) < 3 {
                    controller.seek(to: Double(value.location.x / pps))
                } else {
                    controller.setSelection(
                        start: Double(value.startLocation.x / pps),
                        end: Double(value.location.x / pps))
                }
            }
    }

    private func finishReorder() -> Bool {
        guard let session = reorderSession, session.originalClips == controller.project.clips else {
            reorderSession = nil
            return false
        }
        reorderSession = nil
        controller.commitReorder(session.previewClips, expectedClips: session.originalClips)
        return true
    }

    private func beginReorder(_ clipID: UUID) -> UUID? {
        trimPreview = nil
        let session = TimelineReorderSession(clipID: clipID, clips: controller.project.clips)
        reorderSession = session
        return session?.id
    }

    private func moveReorder(over targetID: UUID) {
        guard var session = reorderSession, session.originalClips == controller.project.clips else {
            reorderSession = nil
            return
        }
        session.move(over: targetID)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
            reorderSession = session
        }
    }

    private func endReorder(_ sessionID: UUID) {
        if reorderSession?.id == sessionID { reorderSession = nil }
    }

    private var playheadContentX: CGFloat {
        timelineInset + CGFloat(controller.currentTime) * pps
    }

    private func timelineClip(_ item: TimelineLayoutItem) -> some View {
        let geometry = clipGeometry(for: item)
        return ClipCell(
            clip: geometry.clip,
            originalClip: item.clip,
            width: geometry.width,
            height: clipHeight,
            contentX: timelineInset + geometry.x,
            viewport: viewportProxy.drawingState,
            selected: controller.selectedClipID == item.clip.id,
            waveforms: controller.waveforms,
            waveformVersion: controller.waveformVersion,
            isDragged: reorderSession?.draggedClipID == item.clip.id,
            timelineStart: item.start,
            pps: pps,
            trimPreview: trimPreview?.originalClip.id == item.clip.id ? trimPreview : nil,
            controller: controller,
            displayScale: displayScale,
            onReorderBegan: { beginReorder(item.clip.id) },
            onReorderEnded: endReorder,
            onReorderEntered: { moveReorder(over: item.clip.id) },
            onReorderDropped: finishReorder,
            onTrimChanged: updateTrimPreview,
            onTrimEnded: commitTrimPreview
        )
        .equatable()
        .offset(x: geometry.x)
        .zIndex(trimPreview?.originalClip.id == item.clip.id ? 3 : 0)
    }

    private func clipGeometry(for item: TimelineLayoutItem) -> (clip: Clip, x: CGFloat, width: CGFloat) {
        guard let preview = trimPreview, preview.originalClip.id == item.clip.id else {
            return (item.clip, CGFloat(item.start) * pps, max(3, CGFloat(item.clip.duration) * pps))
        }
        let clip = preview.clip
        let leadingTrim =
            preview.edge == .start
            ? CGFloat(clip.start - preview.originalClip.start) * pps
            : 0
        return (
            clip,
            CGFloat(item.start) * pps + leadingTrim,
            max(3, CGFloat(clip.duration) * pps)
        )
    }

    private func updateTrimPreview(
        clip: Clip,
        edge: TimelineTrimEdge,
        sourceTime: Double
    ) {
        guard !trimWasCancelled else { return }
        controller.player.pause()
        trimPreview = TimelineTrimPreview(
            originalClip: clip,
            edge: edge,
            sourceTime: sourceTime
        )
    }

    private func commitTrimPreview() {
        if trimWasCancelled {
            trimWasCancelled = false
            trimPreview = nil
            return
        }
        guard let preview = trimPreview else { return }
        trimPreview = nil
        guard
            preview.sourceTime
                != (preview.edge == .start
                    ? preview.originalClip.start
                    : preview.originalClip.end)
        else { return }
        controller.commitTrim(
            clipID: preview.originalClip.id,
            edge: preview.edge,
            sourceTime: preview.sourceTime
        )
    }

    private func cancelTransientInteraction() -> Bool {
        if reorderSession != nil {
            reorderSession = nil
            // Esc должен также завершить нативную NSDraggingSession.
            return false
        }
        if trimPreview != nil {
            trimPreview = nil
            trimWasCancelled = true
            return true
        }
        if handToolLatched {
            handToolLatched = false
            return true
        }
        return false
    }

    private func manualViewportInteraction() {
        if followPlayback { followPlayback = false }
    }

    private func zoom(by factor: CGFloat, anchorX: CGFloat?) {
        let oldScale = pps
        let newScale = TimelineViewportMath.clampedPixelsPerSecond(oldScale * factor)
        guard abs(newScale - oldScale) > 0.001 else { return }
        manualViewportInteraction()

        let targetOffset: CGFloat
        if let anchorX, anchorX >= 0, anchorX <= viewportWidth {
            targetOffset = TimelineViewportMath.offsetKeepingAnchor(
                currentOffset: viewportProxy.horizontalOffset,
                anchorX: anchorX,
                oldPixelsPerSecond: oldScale,
                newPixelsPerSecond: newScale,
                leadingInset: timelineInset
            )
        } else {
            targetOffset =
                timelineInset + CGFloat(controller.currentTime) * newScale
                - viewportWidth / 2
        }

        controller.pixelsPerSecond = newScale
        Task { @MainActor in
            await Task.yield()
            viewportProxy.setHorizontalOffset(targetOffset)
        }
    }

    private func fitTimeline(duration: Double) {
        guard duration > 0 else { return }
        manualViewportInteraction()
        controller.pixelsPerSecond = TimelineViewportMath.clampedPixelsPerSecond(
            (viewportWidth - 64) / CGFloat(duration)
        )
        Task { @MainActor in
            await Task.yield()
            viewportProxy.setHorizontalOffset(0)
        }
    }

    private func toggleFollowPlayback() {
        followPlayback.toggle()
        guard followPlayback else { return }
        if !viewportProxy.isVisible(contentX: playheadContentX) {
            viewportProxy.center(on: playheadContentX)
        }
    }

}

/// Наблюдение за 30 Гц позицией плеера не инвалидирует всю ленту клипов.
private struct TimelinePlaybackFollower: View {
    var controller: EditorController
    let pixelsPerSecond: CGFloat
    let leadingInset: CGFloat
    let followsPlayback: Bool
    let viewportProxy: TimelineViewportProxy

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: controller.currentTime) { _, time in
                guard followsPlayback, controller.isPlaying else { return }
                let playheadX = leadingInset + CGFloat(time) * pixelsPerSecond
                let offset = TimelineViewportMath.followOffset(
                    playheadX: playheadX,
                    currentOffset: viewportProxy.horizontalOffset,
                    viewportWidth: viewportProxy.viewportWidth
                )
                viewportProxy.setHorizontalOffset(offset)
            }
            .accessibilityHidden(true)
    }
}

/// Частые обновления позиции плеера ограничены этим маленьким представлением.
private struct TimelinePlayhead: View {
    var controller: EditorController
    let pps: CGFloat
    let height: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 9))
                .foregroundStyle(Theme.accent)
                .offset(y: 1)
            Rectangle()
                .fill(Theme.accent)
                .frame(width: 2)
        }
        .frame(height: height)
        .offset(x: CGFloat(controller.currentTime) * pps - 4.5)
        .allowsHitTesting(false)
    }
}

// MARK: - Линейка времени

private struct RulerView: View {
    let duration: Double
    let pps: CGFloat
    let viewport: TimelineViewportState
    let contentX: CGFloat

    var body: some View {
        let bounds = viewport.bounds
        Canvas { context, size in
            guard duration > 0 else { return }
            let range = TimelineDrawingRange.local(contentX: contentX, width: size.width, viewport: bounds)
            guard !range.isEmpty else { return }
            // Шаг подписей: чтобы между ними было не меньше ~64 пикселей.
            let steps: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
            let step = steps.first { CGFloat($0) * pps >= 64 } ?? 600
            var t = floor(Double(range.lowerBound / pps) / step) * step
            let end = min(duration, Double(range.upperBound / pps))
            while t <= end {
                let x = CGFloat(t) * pps
                context.fill(
                    Path(CGRect(x: x, y: size.height - 6, width: 1, height: 6)),
                    with: .color(Theme.textSecondary.opacity(0.5))
                )
                context.draw(
                    Text(TimeFormat.compact(t))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary),
                    at: CGPoint(x: x + 3, y: 4),
                    anchor: .topLeading
                )
                // Мелкие насечки между подписями
                let minor = step / 5
                var m = t + minor
                while m < min(t + step, duration) {
                    let mx = CGFloat(m) * pps
                    context.fill(
                        Path(CGRect(x: mx, y: size.height - 3, width: 1, height: 3)),
                        with: .color(Theme.textSecondary.opacity(0.25))
                    )
                    m += minor
                }
                t += step
            }
        }
    }
}

// MARK: - Клип на ленте

private struct ClipCell: View, Equatable {
    let clip: Clip
    let originalClip: Clip
    let width: CGFloat
    let height: CGFloat
    let contentX: CGFloat
    let viewport: TimelineViewportState
    let selected: Bool
    let waveforms: WaveformStore
    let waveformVersion: Int
    let isDragged: Bool
    let timelineStart: Double
    let pps: CGFloat
    let trimPreview: TimelineTrimPreview?
    let controller: EditorController
    let displayScale: CGFloat
    let onReorderBegan: () -> UUID?
    let onReorderEnded: (UUID) -> Void
    let onReorderEntered: () -> Void
    let onReorderDropped: () -> Bool
    let onTrimChanged: (Clip, TimelineTrimEdge, Double) -> Void
    let onTrimEnded: () -> Void
    @State private var isHovering = false

    nonisolated static func == (lhs: ClipCell, rhs: ClipCell) -> Bool {
        lhs.clip == rhs.clip
            && lhs.originalClip == rhs.originalClip
            && lhs.width == rhs.width
            && lhs.height == rhs.height
            && lhs.pps == rhs.pps
            && lhs.displayScale == rhs.displayScale
            && lhs.viewport === rhs.viewport
            && lhs.waveforms === rhs.waveforms
            && lhs.controller === rhs.controller
            && lhs.contentX == rhs.contentX
            && lhs.selected == rhs.selected
            && lhs.waveformVersion == rhs.waveformVersion
            && lhs.isDragged == rhs.isDragged
            && lhs.timelineStart == rhs.timelineStart
            && lhs.trimPreview == rhs.trimPreview
    }

    var body: some View {
        interactiveSurface
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Клип \(clip.fileName)")
            .accessibilityIdentifier("timeline.clip.\(clip.id.uuidString)")
            .accessibilityValue("\(TimeFormat.spoken(clip.duration))\(selected ? ", выбран" : "")")
            .accessibilityHint("Активируй, чтобы выбрать клип")
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction {
                controller.selectedClipID = clip.id
                controller.seek(to: timelineStart)
            }
            .accessibilityAction(named: "Переместить влево") {
                controller.moveClip(id: clip.id, direction: -1)
            }
            .accessibilityAction(named: "Переместить вправо") {
                controller.moveClip(id: clip.id, direction: 1)
            }
            .accessibilityAction(named: "Укоротить начало на один кадр") {
                trimOneFrame(edge: .start)
            }
            .accessibilityAction(named: "Укоротить конец на один кадр") {
                trimOneFrame(edge: .end)
            }
            .accessibilityAction(named: "Удалить клип") {
                controller.deleteClip(id: clip.id)
            }
    }

    private var interactiveSurface: some View {
        surface
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                    .stroke(
                        selected ? Theme.accent : Color.black.opacity(0.08),
                        lineWidth: selected ? 2 : 1)
            )
            .opacity(isDragged ? 0.5 : 1)
            .contentShape(Rectangle())
            .gesture(tapToSelectAndSeek)
            .contextMenu {
                Button("Переместить влево") { controller.moveClip(id: clip.id, direction: -1) }
                Button("Переместить вправо") { controller.moveClip(id: clip.id, direction: 1) }
                Divider()
                Button("Удалить клип", role: .destructive) { controller.deleteClip(id: clip.id) }
            }
            .overlay { dragSource }
            .onDrop(
                of: [.timelineClip],
                delegate: ReorderDropDelegate(onEntered: onReorderEntered, onDropped: onReorderDropped)
            )
            .overlay(alignment: .leading) {
                if isHovering || selected || trimPreview != nil {
                    trimHandle(edge: .start)
                }
            }
            .overlay(alignment: .trailing) {
                if isHovering || selected || trimPreview != nil {
                    trimHandle(edge: .end)
                }
            }
            .overlay(alignment: trimPreview?.edge == .start ? .topLeading : .topTrailing) {
                trimIndicator
            }
            .onHover { isHovering = $0 }
    }

    private var surface: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                .fill(Theme.clipBackground)

            WaveformCanvas(
                clip: clip, waveforms: waveforms, version: waveformVersion, contentX: contentX, viewport: viewport
            )
            .padding(.vertical, 6)

            if width > 60 {
                Text(clip.fileName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
            }
        }
    }

    private var dragSource: some View {
        TimelineClipDragSource(
            clipID: clip.id,
            image: {
                let renderer = ImageRenderer(
                    content: TimelineClipDragPreview(
                        fileName: clip.fileName,
                        width: TimelineDragPreviewMath.width(forClipWidth: width)))
                renderer.scale = displayScale
                return renderer.nsImage
            },
            onBegin: onReorderBegan,
            onEnd: onReorderEnded,
            onClick: { x in selectAndSeek(x: x) }
        )
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var trimIndicator: some View {
        if let trimPreview {
            Text(TimeFormat.short(trimBoundaryTime(trimPreview)))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Theme.accent)
                .clipShape(Capsule())
                .offset(y: -25)
                .allowsHitTesting(false)
        }
    }

    private func trimOneFrame(edge: TimelineTrimEdge) {
        controller.trimOneFrame(clipID: clip.id, edge: edge)
    }

    private var tapToSelectAndSeek: some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                selectAndSeek(x: value.location.x)
            }
    }

    private func selectAndSeek(x: CGFloat) {
        controller.selectedClipID = clip.id
        controller.seek(to: timelineStart + Double(x) / Double(max(1, width / CGFloat(clip.duration))))
    }

    private func trimHandle(edge: TimelineTrimEdge) -> some View {
        ZStack {
            Color.clear
            Capsule()
                .fill(Theme.accent)
                .frame(width: 3, height: max(28, height * 0.62))
        }
        .frame(width: 10, height: height)
        .contentShape(Rectangle())
        .offset(x: edge == .start ? -2 : 2)
        .gesture(trimGesture(edge: edge))
        .help(edge == .start ? "Укоротить начало" : "Укоротить конец")
    }

    private func trimGesture(edge: TimelineTrimEdge) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let seconds = Double(value.translation.width / max(1, pps))
                var sourceTime: Double
                if edge == .start {
                    sourceTime = min(
                        originalClip.end - 0.1,
                        originalClip.start + max(0, seconds)
                    )
                } else {
                    sourceTime = max(
                        originalClip.start + 0.1,
                        originalClip.end + min(0, seconds)
                    )
                }

                if !NSEvent.modifierFlags.contains(.option) {
                    let boundary = timelineStart + (sourceTime - originalClip.start)
                    if abs(controller.currentTime - boundary) * Double(pps) <= 6 {
                        let snapped = originalClip.start + controller.currentTime - timelineStart
                        sourceTime =
                            edge == .start
                            ? min(originalClip.end - 0.1, max(originalClip.start, snapped))
                            : min(originalClip.end, max(originalClip.start + 0.1, snapped))
                    }
                }
                onTrimChanged(originalClip, edge, sourceTime)
            }
            .onEnded { _ in onTrimEnded() }
    }

    private func trimBoundaryTime(_ preview: TimelineTrimPreview) -> Double {
        timelineStart + (preview.sourceTime - preview.originalClip.start)
    }
}

private struct TimelineClipDragPreview: View {
    let fileName: String
    let width: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
            .fill(Theme.clipBackground)
            .overlay {
                Text(fileName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                    .stroke(Theme.accent, lineWidth: 2)
            }
            .frame(width: width, height: 56)
    }
}

private struct ReorderDropDelegate: DropDelegate {
    let onEntered: () -> Void
    let onDropped: () -> Bool

    func dropEntered(info: DropInfo) { onEntered() }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool { onDropped() }
}

// MARK: - Волна звука

private struct WaveformCanvas: View {
    let clip: Clip
    let waveforms: WaveformStore
    let version: Int
    let contentX: CGFloat
    let viewport: TimelineViewportState

    var body: some View {
        let bounds = viewport.bounds
        Canvas { context, size in
            let range = TimelineDrawingRange.local(contentX: contentX, width: size.width, viewport: bounds)
            guard !range.isEmpty else { return }
            guard let peaks = waveforms.peaks(for: clip.sourcePath), !peaks.isEmpty else {
                // Волна ещё считается — рисуем тонкую линию-заглушку.
                let mid = size.height / 2
                context.fill(
                    Path(CGRect(x: 0, y: mid - 0.5, width: size.width, height: 1)),
                    with: .color(Theme.waveform.opacity(0.3))
                )
                return
            }
            context.fill(
                TimelineWaveformDrawing.path(clip: clip, peaks: peaks, size: size, range: range),
                with: .color(Theme.waveform))
        }
    }
}
