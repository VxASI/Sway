import SwayCore
import SwiftUI

/// The timeline: trim handles at both ends, the playhead, and one focus range
/// drawn as a colored bar whose start and end edges are dragged independently.
///
/// ```
/// Full screen       Focused cursor mode          Full screen
/// ────────────[==========================]────────────────
///              Start                      End
/// ```
struct FocusTimelineView: View {
    @ObservedObject var editor: EditorModel

    private let handleWidth: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let duration = max(editor.duration, 0.001)
            let x = { (time: TimeInterval) in CGFloat(time / duration) * width }
            let time = { (point: CGFloat) in
                min(max(0, TimeInterval(point / max(width, 1)) * duration), duration)
            }

            ZStack(alignment: .topLeading) {
                track(width: width, x: x)

                if let focus = editor.focus {
                    focusBar(focus: focus, x: x, time: time)
                }

                // Trim handles.
                handle(color: .primary.opacity(0.7), at: x(editor.trimStart)) { point in
                    editor.setTrimStart(time(point))
                }
                handle(color: .primary.opacity(0.7), at: x(editor.trimEnd)) { point in
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
    }

    private func track(width: CGFloat, x: @escaping (TimeInterval) -> CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.18))
                .frame(height: 56)
            // Trimmed-away regions are dimmed.
            Rectangle()
                .fill(Color.black.opacity(0.35))
                .frame(width: max(0, x(editor.trimStart)), height: 56)
            Rectangle()
                .fill(Color.black.opacity(0.35))
                .frame(width: max(0, width - x(editor.trimEnd)), height: 56)
                .offset(x: x(editor.trimEnd))
            HStack {
                Text("Full screen").font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
            .offset(y: 62)
        }
    }

    private func focusBar(
        focus: FocusRange,
        x: @escaping (TimeInterval) -> CGFloat,
        time: @escaping (CGFloat) -> TimeInterval
    ) -> some View {
        let start = x(focus.start)
        let end = x(focus.end)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.45))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                }
                .frame(width: max(2, end - start), height: 56)
                .offset(x: start)
                .overlay(alignment: .topLeading) {
                    Text("Focus \(String(format: "%.1f×", focus.zoom))")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.top, 4)
                        .offset(x: start + 6)
                }
                // The bar itself moves the whole range.
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let delta = time(value.translation.width) - time(0)
                            var moved = focus
                            moved.start = focus.start + delta
                            moved.end = focus.end + delta
                            guard moved.start >= 0, moved.end <= editor.duration else { return }
                            editor.setFocus(moved)
                        }
                        .onEnded { _ in editor.save() }
                )

            edgeHandle(at: start) { point in
                var range = focus
                range.start = min(time(point), focus.end - 0.25)
                editor.setFocus(range.clamped(to: editor.duration, movingEnd: false))
            }
            edgeHandle(at: end) { point in
                var range = focus
                range.end = max(time(point), focus.start + 0.25)
                editor.setFocus(range.clamped(to: editor.duration))
            }
        }
    }

    private func edgeHandle(at position: CGFloat, onDrag: @escaping (CGFloat) -> Void) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.accentColor)
            .frame(width: handleWidth, height: 56)
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
            .frame(width: 6, height: 56)
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
            .frame(width: 2, height: 68)
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
