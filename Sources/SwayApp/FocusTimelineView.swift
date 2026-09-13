import SwayCore
import SwiftUI

/// The timeline: trim handles at both ends, the playhead, and independent zoom
/// and follow-cursor lanes whose segments can be stacked in time.
///
/// `scale` magnifies the timeline horizontally inside a scroll view, so long
/// recordings can still be edited precisely.
struct SegmentTimelineView: View {
    @ObservedObject var editor: EditorModel
    var scale: CGFloat = 1

    private let handleWidth: CGFloat = 10
    private let laneHeight: CGFloat = 38
    private let laneSpacing: CGFloat = 6
    @State private var dragOrigin: EffectSegment?

    private var trackHeight: CGFloat { laneHeight * 2 + laneSpacing }

    var body: some View {
        HStack(spacing: 10) {
            VStack(spacing: laneSpacing) {
                laneLabel("Zoom", icon: "plus.magnifyingglass", color: .purple)
                laneLabel("Follow Cursor", icon: "cursorarrow.motionlines", color: .blue)
            }
            .frame(width: 92)

            GeometryReader { geometry in
                let width = geometry.size.width * max(1, scale)
                ScrollView(.horizontal, showsIndicators: scale > 1) {
                    content(width: width)
                        .frame(width: width, height: geometry.size.height, alignment: .topLeading)
                }
            }
        }
    }

    private func laneLabel(_ title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).foregroundStyle(color)
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .font(.caption.weight(.semibold))
        .frame(height: laneHeight)
    }

    private func content(width: CGFloat) -> some View {
        let duration = max(editor.duration, 0.001)
        let x = { (time: TimeInterval) in CGFloat(time / duration) * width }
        let time = { (point: CGFloat) in
            min(max(0, TimeInterval(point / max(width, 1)) * duration), duration)
        }
        let secondsPerPoint = duration / Double(max(width, 1))

        return ZStack(alignment: .topLeading) {
            track(width: width, x: x)
            ForEach(editor.segments) { segment in
                segmentBar(segment: segment, x: x, time: time, secondsPerPoint: secondsPerPoint)
            }
            handle(color: .white.opacity(0.7), at: x(editor.trimStart)) { editor.setTrimStart(time($0)) }
            handle(color: .white.opacity(0.7), at: x(editor.trimEnd)) { editor.setTrimEnd(time($0)) }
            playhead(at: x(editor.playhead))
        }
        .coordinateSpace(name: "timeline")
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                .onChanged { editor.seek(to: time($0.location.x)) }
        )
    }

    private func track(width: CGFloat, x: @escaping (TimeInterval) -> CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(EffectKind.allCases.enumerated()), id: \.element) { index, _ in
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(index == 0 ? 0.08 : 0.06))
                    .frame(height: laneHeight)
                    .offset(y: CGFloat(index) * (laneHeight + laneSpacing))
            }
            Rectangle()
                .fill(Color.black.opacity(0.45))
                .frame(width: max(0, x(editor.trimStart)), height: trackHeight)
            Rectangle()
                .fill(Color.black.opacity(0.45))
                .frame(width: max(0, width - x(editor.trimEnd)), height: trackHeight)
                .offset(x: x(editor.trimEnd))
        }
    }

    private func segmentBar(
        segment: EffectSegment,
        x: @escaping (TimeInterval) -> CGFloat,
        time: @escaping (CGFloat) -> TimeInterval,
        secondsPerPoint: Double
    ) -> some View {
        let start = x(segment.start)
        let end = x(segment.end)
        let isSelected = editor.selectedSegmentID == segment.id
        let color: Color = segment.kind == .zoom ? .purple : .blue
        let y = segment.kind == .zoom ? 0 : laneHeight + laneSpacing

        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(isSelected ? 0.55 : 0.35))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isSelected ? color : color.opacity(0.5), lineWidth: isSelected ? 2 : 1)
                }
                .overlay(alignment: .leading) {
                    HStack(spacing: 4) {
                        Image(systemName: segment.kind == .zoom ? "plus.magnifyingglass" : "cursorarrow.motionlines")
                        Text(segment.kind == .zoom
                            ? String(format: "%.1f×", segment.zoom)
                            : String(format: "%.0f%%", segment.smoothing * 100))
                    }
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .allowsHitTesting(false)
                }
                .frame(width: max(2, end - start), height: laneHeight)
                .offset(x: start, y: y)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            editor.selectedSegmentID = segment.id
                            let origin = dragOrigin ?? segment
                            if dragOrigin == nil { dragOrigin = segment }
                            let delta = Double(value.translation.width) * secondsPerPoint
                            editor.moveSegment(id: origin.id, toStart: origin.start + delta, duration: origin.duration)
                        }
                        .onEnded { _ in
                            dragOrigin = nil
                            editor.save()
                        }
                )

            if isSelected {
                edgeHandle(color: color, at: start, y: y) { point in
                    var updated = segment
                    updated.start = min(time(point), segment.end - 0.25)
                    editor.updateSegment(updated, movingEnd: false)
                }
                edgeHandle(color: color, at: end, y: y) { point in
                    var updated = segment
                    updated.end = max(time(point), segment.start + 0.25)
                    editor.updateSegment(updated)
                }
            }
        }
    }

    private func edgeHandle(color: Color, at position: CGFloat, y: CGFloat, onDrag: @escaping (CGFloat) -> Void) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(color)
            .frame(width: handleWidth, height: laneHeight)
            .overlay { Capsule().fill(Color.white.opacity(0.9)).frame(width: 2, height: 18) }
            .offset(x: position - handleWidth / 2, y: y)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                    .onChanged { onDrag($0.location.x) }
                    .onEnded { _ in editor.save() }
            )
    }

    private func handle(color: Color, at position: CGFloat, onDrag: @escaping (CGFloat) -> Void) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(width: 6, height: trackHeight)
            .offset(x: position - 3)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                    .onChanged { onDrag($0.location.x) }
                    .onEnded { _ in editor.save() }
            )
    }

    private func playhead(at position: CGFloat) -> some View {
        Rectangle()
            .fill(Color.red)
            .frame(width: 2, height: trackHeight + 12)
            .overlay(alignment: .top) {
                Circle().fill(Color.red).frame(width: 9, height: 9).offset(y: -4)
            }
            .offset(x: position - 1, y: -6)
            .allowsHitTesting(false)
    }
}
