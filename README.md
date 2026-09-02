# Sway

Cinematic screen recording for macOS: record the screen without a cursor, record
the cursor as data, and generate the camera moves afterwards.

## How it works

```
CGEventTap ─┐
            ├─ cursor track (normalized, shared timebase) ─ smoothing ─ focus detection ─ camera path
20 Hz sampler ┘
ScreenCaptureKit (showsCursor = false) ─ screen.mov
```

**Hybrid cursor tracking.** A listen-only `CGEventTap` receives `.mouseMoved`,
mouse down/up, drags and `.scrollWheel`. Its callback only timestamps, converts
and enqueues, then returns, so it never delays event delivery or gets disabled
for being slow. A 20 Hz sampler runs alongside it purely as a safety net;
samples that merely repeat what the tap already reported are dropped when the
two streams are merged. Polling alone would miss fast movement, drift against
the video and record redundant points while the mouse sits still.

**One clock.** Recording start is a `mach_continuous_time` reading. Cursor
events store seconds since that instant. ScreenCaptureKit stamps frames with the
host time clock (`mach_absolute_time`), so `HostClockBridge` measures the offset
between the two clocks once and applies it to every presentation timestamp.
Nothing in the pipeline uses `Date()`, which can jump.

**Capture-relative coordinates.** Global mouse locations are converted into the
capture rect and normalized to 0...1 the moment they arrive, so displays placed
left of or above the main one, mixed Retina scales and differing resolutions all
collapse into one space. The display ID, capture rect in points and the pixel
dimensions are preserved in `project.json`.

**Camera is generated, not followed.** The tracker never moves the camera. After
recording, the path is smoothed, interactions are grouped into focus segments
(three clicks on nearby controls within a couple of seconds produce one shot,
not three zooms), and the camera is integrated with a dead zone, velocity
look-ahead, critically damped springs, a minimum shot length and a delayed zoom
out. Near a frame edge the camera clamps and lets the cursor drift off-center
rather than pushing past the edge.

**Cursor is drawn at export.** `showsCursor` is false during capture, so the
exporter can draw a larger, smoothed cursor with a shadow and click rings from
the recorded events.

**Effects are edits, not detections.** The editor's camera is driven by
non-overlapping effect segments on the timeline. Outside them the camera sits
at 1x, dead center, showing the complete recording. A **Zoom** segment holds a
fixed focal point the user aims by dragging a ring on the preview; a **Follow
Cursor** segment zooms in and tracks the recorded cursor with the dead zone,
springs and edge clamping above, with a per-segment smoothing amount. Both ease
in and out through the springs. Click detection only supplies the initial
suggested segment.

## The app

```sh
./Scripts/package-app.sh          # -> .build/Sway.app, double-clickable
open .build/Sway.app
```

```
Record -> pick a display or window, fps, system audio -> 3-2-1 -> record
  -> stop (Shift-Cmd-S) -> editor -> add Zoom / Follow Cursor segments
  -> Export (preset, quality, fps, progress, Reveal in Finder)
```

The welcome screen is also the library: every recording in `~/Movies/Sway`
with a thumbnail, reopened with one click. The picker lists every display and
window with a live thumbnail and its macOS name ("Built-in Display", "LG
Monitor"), plus 30/60 fps and a system-audio toggle. Start runs a floating,
cancellable countdown before capture begins. While recording, the main window
hides and a floating capsule shows the elapsed time and Stop; Sway itself is
excluded from display captures.

The editor shows the preview with the camera applied live (the same renderer
the exporter uses, so preview is export), a playhead, trim handles, a zoomable
timeline, and any number of effect segments drawn as colored bars that select,
move and resize by dragging. A selected segment's intensity, smoothing and (for
Zoom) focal point are edited inline; the project name is editable in the
toolbar. Export offers Original / 1920x1080 / 1080x1920 / 1080x1080 (aspect-
filled, never stretched), Standard / High quality, an optional 30 fps cap, a
progress bar and Reveal in Finder. Trimmed exports keep their audio.

## CLI

```sh
swift build -c release

.build/release/sway record --output ~/Movies/demo.sway   # Return to stop
.build/release/sway inspect ~/Movies/demo.sway
.build/release/sway export  ~/Movies/demo.sway ~/Movies/demo.mp4
.build/release/sway recamera ~/Movies/demo.sway          # retune, no re-record
```

`record` options: `--display <id>`, `--window <id>`, `--fps <n>`, `--no-audio`,
`--duration <seconds>`. `export` options: `--no-cursor`, `--width <px>`.

## Permissions

- **Screen Recording** - ScreenCaptureKit, for both the picker's window list and
  the capture itself.
- **Input Monitoring** - the listen-only `CGEventTap` that records the cursor;
  without it recording fails with a `CGEventTap` error.

Three properties of these APIs shape the whole permission flow, and all three
present as a hang if they are ignored:

1. **A new Screen Recording grant does not apply to the running process.**
   `SCShareableContent` keeps failing - or never returns at all - until the app
   is relaunched. The permissions screen therefore distinguishes *granted* from
   *granted, pending relaunch* (by remembering whether the permission was ever
   observed missing during this launch) and offers a **Reopen Sway** button.
   Polling for longer does not help; only a relaunch does.
2. **The TCC calls themselves can block.** `CGPreflightScreenCaptureAccess` and
   `CGPreflightListenEventAccess` talk to `tccd`, so they run off the main
   thread behind a deadline. An unanswered check is reported as unknown, with a
   remedy, rather than being guessed at.
3. **The `async` `SCShareableContent` API has no timeout and can hang forever.**
   The completion-handler form (`getExcludingDesktopWindows`) is used instead,
   with the deadline outside the continuation, so the UI always gets content, an
   error, or a timeout.

If ScreenCaptureKit stops answering entirely, `replayd` is usually wedged (often
after force-quitting an app mid-capture): `killall -9 replayd` fixes it.

Permission is granted to the process that runs the code: run `Sway.app`, not
`swift run`, or the grant lands on your terminal instead.

**Signing matters more than it looks.** TCC keys grants to the code-signing
identity, and an ad-hoc signature (`codesign --sign -`) changes with every
rebuild - macOS then silently ignores the previous grant while the toggle still
looks on. `package-app.sh` uses an *Apple Development* or *Developer ID*
certificate if you have one (override with `SWAY_SIGN_IDENTITY`), which keeps
the grant across rebuilds. Without one it falls back to ad-hoc and clears
Sway's own TCC entries (`tccutil reset ScreenCapture ai.sway.Sway`) so the next
launch asks again cleanly instead of failing silently.

## Bundle format

```
demo.sway/
  project.json   duration, capture geometry, timebase, track inventory
  screen.mov     H.264 + system audio, no cursor
  cursor.json    every cursor event, normalized, video-relative seconds
  camera.json    generated camera keyframes (center + zoom over time)
  edit.json      trim points and the effect segments the camera was generated from
```

`edit.json` segments look like (`kind` is `zoom` or `followCursor`; older files
with a single `focus` range load as one follow-cursor segment):

```json
{ "id": "…", "kind": "zoom", "start": 3.2, "end": 6.8, "zoom": 2.0,
  "centerX": 0.62, "centerY": 0.41, "smoothing": 0.5 }
```

`cursor.json` events look like:

```json
{ "time": 4.826, "x": 0.734, "y": 0.412, "type": "leftMouseDown" }
```

Camera keyframes are `{ time, centerX, centerY, zoom }` in the same normalized
space; the visible viewport is `1 / zoom` of the capture on each axis.

## Layout

| Target | Platform | Contents |
| --- | --- | --- |
| `SwayCore` | any | timebase, geometry, cursor track, focus detection, camera path, bundle I/O |
| `SwayCapture` | macOS 13+ | event tap, sampler, ScreenCaptureKit recorder, session, exporter |
| `SwayApp` | macOS 13+ | SwiftUI app: capture picker, recording control, timeline editor |
| `sway` | CLI | `record`, `export`, `inspect`, `recamera` |

`SwayCore` is platform-independent and holds all the timing and camera math, so
it is unit tested with `swift test` on any platform. `SwayCaptureTests` (macOS)
synthesizes a real movie + cursor track and runs the exporter end to end:
segments baked in, progress, trimmed audio, aspect presets, frame-rate cap.

## Not implemented yet

- Microphone and camera tracks (system audio only).
- Pause/resume during recording (ScreenCaptureKit has no pause; it needs
  timestamp re-basing across both the movie and the cursor track).
- Auto-hiding the cursor while typing (needs keyboard events in the tap).
- Region capture is passed to `SCStreamConfiguration.sourceRect`, which requires
  macOS 14; on macOS 13 the full display is captured.
- Cursor highlights, click effects, backgrounds, captions, scene transitions.
  The segment model (`EffectSegment.kind`) is where these slot in.
