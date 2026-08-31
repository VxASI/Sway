import SwayCore
import SwiftUI

/// The timeline: trim handles at both ends, the playhead, and any number of
/// effect segments drawn as colored bars whose edges drag independently.
///
/// ```
///          Zoom (fixed point)      Follow cursor
/// ─────[=================]────[=================]───────
///       Start           End
/// ```
///
/// `scale` magnifies the timeline horizontally inside a scroll view, so long
/// recordings can still be edited precisely.
struct SegmentTimelineView: View {
    @ObservedObject var editor: EditorModel
    var scale: CGFloat = 1

    private let handleWidth: CGFloat = 10
    private let barHeight: CGFloat = 56

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width * max(1, scale)
            ScrollView(.horizontal, showsIndicators: scale > 1) {
                content(width: width)
                    .frame(width: width, height: geometry.size.height, alignment: .topLeading)
            }
        }
    }

    private func content(width: CGFloat) -> some View {
        let duration = max(editor.duration, 0.001)
        let x = { (time: TimeInterval) in CGFloat(time / duration) * width }
        let time = { (point: CGFloat) in
            min(max(0, TimeInterval(point / max(width, 1)) * duration), duration)
        }

        return ZStack(alignment: .topLeading) {
            track(width: width, x: x)

            ForEach(editor.segments) { segment in
                segmentBar(segment: segment, x: x, time: time)
            }

            // Trim handles.
            handle(color: .white.opacity(0.7), at: x(editor.trimStart)) { point in
                editor.setTrimStart(time(point))
            }
            handle(color: .white.opacity(0.7), at: x(editor.trimEnd)) { point in
                editor.setTrimEnd(time(point))
            }

            playhead(at: x(editor.playhead))
        }
        .coordinateSpace(name: "timeline")
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                .onChanged { value in editor.seek(to: time(value.location.x)) }
        )
    }

    private func track(width: CGFloat, x: @escaping (TimeInterval) -> CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.08))
                .frame(height: barHeight)
            // Trimmed-away regions are dimmed.
            Rectangle()
                .fill(Color.black.opacity(0.45))
                .frame(width: max(0, x(editor.trimStart)), height: barHeight)
            Rectangle()
                .fill(Color.black.opacity(0.45))
                .frame(width: max(0, width - x(editor.trimEnd)), height: barHeight)
                .offset(x: x(editor.trimEnd))
        }
    }

    private func segmentBar(
        segment: EffectSegment,
        x: @escaping (TimeInterval) -> CGFloat,
        time: @escaping (CGFloat) -> TimeInterval
    ) -> some View {
        let start = x(segment.start)
        let end = x(segment.end)
        let isSelected = editor.selectedSegmentID == segment.id
        let color: Color = segment.kind == .zoom ? .purple : .blue

        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(isSelected ? 0.55 : 0.35))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            isSelected ? color : color.opacity(0.5),
                            lineWidth: isSelected ? 2 : 1
                        )
                }
                .frame(width: max(2, end - start), height: barHeight)
                .offset(x: start)
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 4) {
                        Image(systemName: segment.kind == .zoom
                            ? "plus.magnifyingglass"
                            : "cursorarrow.motionlines")
                            .font(.system(size: 9, weight: .bold))
                        Text(String(format: "%.1f×", segment.zoom))
                            .font(.caption2.weight(.semibold))
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 5)
                    .offset(x: start)
                    .allowsHitTesting(false)
                }
                // The bar itself selects the segment and moves the whole range.
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            editor.selectedSegmentID = segment.id
                            let delta = time(value.translation.width) - time(0)
                            guard delta != 0 else { return }
                            var moved = segment
                            moved.start = segment.start + delta
                            moved.end = segment.end + delta
                            guard moved.start >= 0, moved.end <= editor.duration else { return }
                            editor.updateSegment(moved)
                        }
                        .onEnded { _ in editor.save() }
                )

            if isSelected {
                edgeHandle(color: color, at: start) { point in
                    var updated = segment
                    updated.start = min(time(point), segment.end - 0.25)
                    editor.updateSegment(updated, movingEnd: false)
                }
                edgeHandle(color: color, at: end) { point in
                    var updated = segment
                    updated.end = max(time(point), segment.start + 0.25)
                    editor.updateSegment(updated)
                }
            }
        }
    }

    private func edgeHandle(
        color: Color,
        at position: CGFloat,
        onDrag: @escaping (CGFloat) -> Void
    ) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(color)
            .frame(width: handleWidth, height: barHeight)
            .overlay {
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 2, height: 22)
            }
            .offset(x: position - handleWidth / 2)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                    .onChanged { value in onDrag(value.location.x) }
                    .onEnded { _ in editor.save() }
            )
    }

    private func handle(
        color: Color,
        at position: CGFloat,
        onDrag: @escaping (CGFloat) -> Void
    ) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(width: 6, height: barHeight)
            .offset(x: position - 3)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                    .onChanged { value in onDrag(value.location.x) }
                    .onEnded { _ in editor.save() }
            )
    }

    private func playhead(at position: CGFloat) -> some View {
        Rectangle()
            .fill(Color.red)
            .frame(width: 2, height: barHeight + 12)
            .overlay(alignment: .top) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 9, height: 9)
                    .offset(y: -4)
            }
            .offset(x: position - 1, y: -6)
            .allowsHitTesting(false)
    }
}
