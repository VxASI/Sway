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

## Usage

```sh
swift build -c release

.build/release/sway record --output ~/Movies/demo.sway   # Return to stop
.build/release/sway inspect ~/Movies/demo.sway
.build/release/sway export  ~/Movies/demo.sway ~/Movies/demo.mp4
.build/release/sway recamera ~/Movies/demo.sway          # retune, no re-record
```

`record` options: `--display <id>`, `--fps <n>`, `--no-audio`,
`--duration <seconds>`. `export` options: `--no-cursor`, `--width <px>`.

### Permissions

- **Screen Recording** - required by ScreenCaptureKit.
- **Input Monitoring** (and Accessibility if prompted) - required for the event
  tap; without it `sway record` fails with a `CGEventTap` error.

Both are granted to whatever process runs the binary, so when running from a
terminal, grant them to that terminal.

## Bundle format

```
demo.sway/
  project.json   duration, capture geometry, timebase, track inventory
  screen.mov     H.264 + system audio, no cursor
  cursor.json    every cursor event, normalized, video-relative seconds
  camera.json    generated camera keyframes (center + zoom over time)
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
| `sway` | CLI | `record`, `export`, `inspect`, `recamera` |

`SwayCore` is platform-independent and holds all the timing and camera math, so
it is unit tested with `swift test` on any platform.

## Not implemented yet

- Microphone and camera tracks (system audio only).
- Auto-hiding the cursor while typing (needs keyboard events in the tap).
- Region capture is passed to `SCStreamConfiguration.sourceRect`, which requires
  macOS 14; on macOS 13 the full display is captured.
- Editing UI - the bundle is designed for one, but `sway` is a CLI.
