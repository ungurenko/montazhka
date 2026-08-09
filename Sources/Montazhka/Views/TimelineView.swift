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

/// Лента клипов: волны звука, линейка времени, курсор, зум, перетаскивание.
struct TimelineView: View {
    var controller: EditorController
    @State private var draggedClipID: UUID?
    @State private var orderAtDragStart: [Clip]?
    @State private var zoomAtPinchStart: CGFloat?
    @State private var viewportWidth: CGFloat = 800
    @State private var jumpToPlayheadRequest = 0

    private let clipHeight: CGFloat = 92
    private let rulerHeight: CGFloat = 20

    private var pps: CGFloat { controller.pixelsPerSecond }
    private func totalWidth(for duration: Double) -> CGFloat {
        max(CGFloat(duration) * pps + 40, viewportWidth - 24)
    }

    var body: some View {
        let layout = TimelineLayout(clips: controller.project.clips)

        VStack(spacing: 6) {
            header(duration: layout.duration)
            GeometryReader { geo in
                ScrollViewReader { proxy in
                    // Лента НИКОГДА не прокручивается сама: на Mac нельзя надёжно понять,
                    // листает ли пользователь прямо сейчас, и любая автоподкрутка дерётся с ним.
                    // Вернуться к курсору можно кнопкой в шапке ленты.
                    ScrollView(.horizontal, showsIndicators: true) {
                        timelineContent(layout: layout)
                            .padding(.horizontal, 12)
                    }
                    .onAppear { viewportWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in viewportWidth = w }
                    .onChange(of: jumpToPlayheadRequest) { _, _ in
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo("playhead-marker", anchor: UnitPoint(x: 0.3, y: 0.5))
                        }
                    }
                }
            }
        }
        .padding(12)
        .cardStyle()
        .simultaneousGesture(pinchGesture)
        .onDrop(of: [.text], isTargeted: nil) { _ in
            finishReorder()
            return true
        }
    }

    // MARK: - Шапка ленты

    private func header(duration: Double) -> some View {
        HStack(spacing: 10) {
            Text("Лента")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
            if !controller.candidates.isEmpty {
                Label("\(controller.candidates.filter(\.enabled).count) пауз к вырезке", systemImage: "scissors")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.pauseHighlight)
            }
            if !controller.smartEditCandidates.isEmpty {
                Label("\(controller.smartEditCandidates.filter(\.enabled).count) умных правок", systemImage: "wand.and.sparkles")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }
            if let selection = controller.timelineSelection {
                Label("\(TimeFormat.short(selection.duration)) выделено", systemImage: "selection.pin.in.out")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accent)
            }
            Spacer()
            ZoomButton(icon: "arrow.right.to.line", help: "Показать курсор воспроизведения") {
                jumpToPlayheadRequest += 1
            }
            Divider().frame(height: 14)
            ZoomButton(icon: "minus.magnifyingglass", help: "Отдалить") {
                controller.pixelsPerSecond = max(3, pps / 1.4)
            }
            ZoomButton(icon: "arrow.left.and.right.square", help: "Вся лента целиком") {
                guard duration > 0 else { return }
                controller.pixelsPerSecond = max(3, (viewportWidth - 64) / CGFloat(duration))
            }
            ZoomButton(icon: "plus.magnifyingglass", help: "Приблизить") {
                controller.pixelsPerSecond = min(240, pps * 1.4)
            }
        }
    }

    // MARK: - Содержимое

    private func timelineContent(layout: TimelineLayout) -> some View {
        let width = totalWidth(for: layout.duration)

        return VStack(alignment: .leading, spacing: 4) {
            RulerView(duration: layout.duration, pps: pps)
                .frame(width: width, height: rulerHeight)
                .contentShape(Rectangle())
                .gesture(scrubGesture)

            ZStack(alignment: .topLeading) {
                if layout.items.isEmpty {
                    Text("Здесь появятся клипы")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: width, height: clipHeight)
                } else {
                    HStack(spacing: 0) {
                        ForEach(layout.items) { item in
                            ClipCell(
                                clip: item.clip,
                                width: max(3, CGFloat(item.clip.duration) * pps),
                                height: clipHeight,
                                selected: controller.selectedClipID == item.clip.id,
                                waveforms: controller.waveforms,
                                waveformVersion: controller.waveformVersion,
                                isDragged: draggedClipID == item.clip.id,
                                timelineStart: item.start,
                                controller: controller,
                                draggedClipID: $draggedClipID,
                                orderAtDragStart: $orderAtDragStart
                            )
                            .equatable()
                        }
                    }
                }

                // Подсветка найденных пауз
                if let selection = controller.timelineSelection {
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
                ForEach(controller.smartEditCandidates) { candidate in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.orange.opacity(candidate.enabled ? 0.28 : 0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(Color.orange.opacity(candidate.enabled ? 0.8 : 0.2), lineWidth: 1)
                        )
                        .frame(width: max(2, CGFloat(candidate.timelineEnd - candidate.timelineStart) * pps),
                               height: clipHeight)
                        .offset(x: CGFloat(candidate.timelineStart) * pps)
                        .allowsHitTesting(false)
                }

                // Подсветка найденных пауз
                ForEach(controller.candidates) { candidate in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Theme.pauseHighlight.opacity(candidate.enabled ? 0.32 : 0.10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(Theme.pauseHighlight.opacity(candidate.enabled ? 0.8 : 0.25), lineWidth: 1)
                        )
                        .frame(width: max(2, CGFloat(candidate.fullEnd - candidate.fullStart) * pps),
                               height: clipHeight)
                        .offset(x: CGFloat(candidate.fullStart) * pps)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: width, alignment: .topLeading)
        }
        .overlay(alignment: .topLeading) {
            TimelinePlayhead(controller: controller,
                             pps: pps,
                             height: rulerHeight + 4 + clipHeight)
                .id("playhead-marker")
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
                    controller.setSelection(start: Double(value.startLocation.x / pps),
                                            end: Double(value.location.x / pps))
                }
            }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if zoomAtPinchStart == nil { zoomAtPinchStart = controller.pixelsPerSecond }
                if let base = zoomAtPinchStart {
                    controller.pixelsPerSecond = min(240, max(3, base * value.magnification))
                }
            }
            .onEnded { _ in zoomAtPinchStart = nil }
    }

    private func finishReorder() {
        if let original = orderAtDragStart {
            controller.commitReorder(originalOrder: original)
        }
        draggedClipID = nil
        orderAtDragStart = nil
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

    var body: some View {
        Canvas { context, size in
            guard duration > 0 else { return }
            // Шаг подписей: чтобы между ними было не меньше ~64 пикселей.
            let steps: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
            let step = steps.first { CGFloat($0) * pps >= 64 } ?? 600
            var t: Double = 0
            while t <= duration {
                let x = CGFloat(t) * pps
                context.fill(
                    Path(CGRect(x: x, y: size.height - 6, width: 1, height: 6)),
                    with: .color(Theme.textSecondary.opacity(0.5))
                )
                context.draw(
                    Text(TimeFormat.compact(t))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.textSecondary),
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
    let width: CGFloat
    let height: CGFloat
    let selected: Bool
    let waveforms: WaveformStore
    let waveformVersion: Int
    let isDragged: Bool
    let timelineStart: Double
    let controller: EditorController
    @Binding var draggedClipID: UUID?
    @Binding var orderAtDragStart: [Clip]?

    static func == (lhs: ClipCell, rhs: ClipCell) -> Bool {
        lhs.clip == rhs.clip
            && lhs.width == rhs.width
            && lhs.selected == rhs.selected
            && lhs.waveformVersion == rhs.waveformVersion
            && lhs.isDragged == rhs.isDragged
            && lhs.timelineStart == rhs.timelineStart
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                .fill(Theme.clipBackground)

            WaveformCanvas(clip: clip, waveforms: waveforms, version: waveformVersion)
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
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                .stroke(selected ? Theme.accent : Color.black.opacity(0.08),
                        lineWidth: selected ? 2 : 1)
        )
        .opacity(isDragged ? 0.5 : 1)
        .padding(.trailing, 2)
        .contentShape(Rectangle())
        .gesture(tapToSelectAndSeek)
        .contextMenu {
            Button("Переместить влево") { controller.moveClip(id: clip.id, direction: -1) }
            Button("Переместить вправо") { controller.moveClip(id: clip.id, direction: 1) }
            Divider()
            Button("Удалить клип", role: .destructive) { controller.deleteClip(id: clip.id) }
        }
        .onDrag {
            orderAtDragStart = controller.project.clips
            draggedClipID = clip.id
            return NSItemProvider(object: clip.id.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: ReorderDropDelegate(
            targetID: clip.id,
            controller: controller,
            draggedClipID: $draggedClipID,
            orderAtDragStart: $orderAtDragStart
        ))
    }

    private var tapToSelectAndSeek: some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                controller.selectedClipID = clip.id
                controller.seek(to: timelineStart + Double(value.location.x) / Double(max(1, width / CGFloat(clip.duration))))
            }
    }
}

private struct ReorderDropDelegate: DropDelegate {
    let targetID: UUID
    let controller: EditorController
    @Binding var draggedClipID: UUID?
    @Binding var orderAtDragStart: [Clip]?

    func dropEntered(info: DropInfo) {
        guard let dragged = draggedClipID else { return }
        controller.liveReorder(draggedID: dragged, over: targetID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        if let original = orderAtDragStart {
            controller.commitReorder(originalOrder: original)
        }
        draggedClipID = nil
        orderAtDragStart = nil
        return true
    }
}

// MARK: - Волна звука

private struct WaveformCanvas: View {
    let clip: Clip
    let waveforms: WaveformStore
    let version: Int

    var body: some View {
        Canvas { context, size in
            guard let peaks = waveforms.peaks(for: clip.sourcePath), !peaks.isEmpty else {
                // Волна ещё считается — рисуем тонкую линию-заглушку.
                let mid = size.height / 2
                context.fill(
                    Path(CGRect(x: 0, y: mid - 0.5, width: size.width, height: 1)),
                    with: .color(Theme.waveform.opacity(0.3))
                )
                return
            }
            let wps = WaveformStore.windowsPerSecond
            let mid = size.height / 2
            let step: CGFloat = 2
            let secondsPerPixel = clip.duration / Double(size.width)
            var x: CGFloat = 0
            var path = Path()
            while x < size.width {
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
                    cornerSize: CGSize(width: 0.75, height: 0.75)
                )
                x += step
            }
            context.fill(path, with: .color(Theme.waveform))
        }
    }
}

private struct ZoomButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 26, height: 22)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
