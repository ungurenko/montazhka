import SwiftUI
import UniformTypeIdentifiers

/// Лента клипов: волны звука, линейка времени, курсор, зум, перетаскивание.
struct TimelineView: View {
    @ObservedObject var controller: EditorController
    @State private var draggedClipID: UUID?
    @State private var orderAtDragStart: [Clip]?
    @State private var zoomAtPinchStart: CGFloat?
    @State private var viewportWidth: CGFloat = 800
    @State private var jumpToPlayheadRequest = 0

    private let clipHeight: CGFloat = 92
    private let rulerHeight: CGFloat = 20

    private var pps: CGFloat { controller.pixelsPerSecond }
    private var totalWidth: CGFloat { max(CGFloat(controller.duration) * pps + 40, viewportWidth - 24) }

    var body: some View {
        VStack(spacing: 6) {
            header
            GeometryReader { geo in
                ScrollViewReader { proxy in
                    // Лента НИКОГДА не прокручивается сама: на Mac нельзя надёжно понять,
                    // листает ли пользователь прямо сейчас, и любая автоподкрутка дерётся с ним.
                    // Вернуться к курсору можно кнопкой в шапке ленты.
                    ScrollView(.horizontal, showsIndicators: true) {
                        timelineContent
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

    private var header: some View {
        HStack(spacing: 10) {
            Text("Лента")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
            if !controller.candidates.isEmpty {
                Label("\(controller.candidates.filter(\.enabled).count) пауз к вырезке", systemImage: "scissors")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.pauseHighlight)
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
                guard controller.duration > 0 else { return }
                controller.pixelsPerSecond = max(3, (viewportWidth - 64) / CGFloat(controller.duration))
            }
            ZoomButton(icon: "plus.magnifyingglass", help: "Приблизить") {
                controller.pixelsPerSecond = min(240, pps * 1.4)
            }
        }
    }

    // MARK: - Содержимое

    private var timelineContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            RulerView(duration: controller.duration, pps: pps)
                .frame(width: totalWidth, height: rulerHeight)
                .contentShape(Rectangle())
                .gesture(scrubGesture)

            ZStack(alignment: .topLeading) {
                if controller.project.clips.isEmpty {
                    Text("Здесь появятся клипы")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: totalWidth, height: clipHeight)
                } else {
                    HStack(spacing: 0) {
                        ForEach(controller.project.clips) { clip in
                            ClipCell(
                                clip: clip,
                                width: max(3, CGFloat(clip.duration) * pps),
                                height: clipHeight,
                                selected: controller.selectedClipID == clip.id,
                                waveforms: controller.waveforms,
                                waveformVersion: controller.waveformVersion,
                                isDragged: draggedClipID == clip.id,
                                timelineStart: controller.timelineStart(
                                    of: controller.project.clips.firstIndex(where: { $0.id == clip.id }) ?? 0),
                                controller: controller,
                                draggedClipID: $draggedClipID,
                                orderAtDragStart: $orderAtDragStart
                            )
                            .equatable()
                        }
                    }
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
            .frame(width: totalWidth, alignment: .topLeading)
        }
        .overlay(alignment: .topLeading) { playhead }
    }

    private var playhead: some View {
        VStack(spacing: 0) {
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 9))
                .foregroundStyle(Theme.accent)
                .offset(y: 1)
            Rectangle()
                .fill(Theme.accent)
                .frame(width: 2)
        }
        .frame(height: rulerHeight + 4 + clipHeight)
        .offset(x: CGFloat(controller.currentTime) * pps - 4.5)
        .allowsHitTesting(false)
        .id("playhead-marker")
    }

    // MARK: - Жесты

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                controller.player.pause()
                controller.seek(to: Double(value.location.x / pps))
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
