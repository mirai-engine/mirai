# Package `platform`

Operating system layer over SDL3 (`vendor:sdl3`) and `core:os`. It imports `mirai:std/base`
(handles) and `mirai:audio` (only for the audio device).

## Context

`create(Platform_Desc)` sets capacities and allocator; a zero capacity takes the default from its
comment. With a window it starts SDL video (the `"dummy"` driver opens nothing on the desktop).
Headless does not start SDL: the window is a size and a density of the desc, the input is the
injected one, and title, cursor, maximized or clipboard are stored in the `Platform` and read with
the same API.

## Frame

```odin
for running {
    platform.frame_begin(p)   // SDL events, injected events, dt, dialog response
    frame:=platform.input_frame(p)
    // ... fixed ticks with platform.input_tick_take(p), drawing ...
    platform.frame_end(p,presented)
}
```

- `frame_begin` clears what lasts one frame, drains SDL's queue and then applies the injected
  events. `dt` is the real time since the previous frame, capped at `FRAME_DT_MAX`.
- With `vsync`, a presented frame and a known refresh rate, `dt` is a whole number of refresh
  periods (`frame_dt_ns`): the frame reaches the screen at a vertical blank and the clock only says
  when the swapchain released the loop, with a jitter that would make movement uneven. The
  difference is carried over: the sum never strays more than one period from real time.

### Pacing

`Frame_Pacing{limit,vsync}`: `vsync` is data that the graphics backend applies. `frame_end` sleeps
with `sleep_precise` what is left of the budget (`1/limit`), and also:

- without a presented image, or with the window minimized or hidden, at least `IDLE_FRAME_NS`: the
  loop attends to events without spinning;
- without focus and with `set_background`, at least `1/background`: asked for by whoever does not
  need to run behind other windows (the editor outside Play), not a game;
- with `vsync`, a presented frame and `limit` 0 or not less than the display's refresh rate, one
  refresh period: the swapchain releases the loop unevenly (the Windows compositor, in pairs) and
  input and movement would follow it;
- each end is spaced from the one that the previous one aimed at (`pacing_target_ns`): the error of
  one wait does not accumulate, and a frame that overran neither waits nor leaves a debt.

`window_refresh_rate` on Windows comes from `EnumDisplaySettingsW`: with the desktop scaled by the
GPU, SDL can report a mode that the display does not use.

## Input

Every event goes through `input_apply`, which maintains two views:

- **`Input_Frame`** (`input_frame(p)`, stable pointer): state and edges of the frame for keys,
  mouse, text, gamepads, window and the last used device. `input_events` gives the frame's ordered
  events and `input_dropped` the dropped paths, valid until the next frame.
- **`Input_Tick`** (`input_tick_take(p)`): current state plus edges and deltas accumulated since
  the previous tick. Delivering them clears them: `pressed` and `released` hold in a single tick
  even if many frames are drawn in between, and a second tick in the same frame does not repeat
  them. A key pressed and released between two ticks arrives as `pressed` and `released` without
  `down`. A paused simulation takes them and discards them.

Rules:

- `Key` is the US keyboard; its values are bit indices of `Keys` and are only added at the end.
- Releasing what was not pressed is not a `released`. The first event that brings the pointer
  inside the window adds no delta. Outside the window and without buttons pressed, `mouse_inside`
  is false and the position is `MOUSE_OUTSIDE`; during a drag it keeps its place.
- Gamepad axes without a dead zone, with Y positive downward. When a gamepad disconnects its
  buttons are released. Its family comes from the SDL type (an unknown one is `Xbox`) and decides
  how its prompts are drawn.
- `device` changes with a key, a button, the wheel, a motion greater than `DEVICE_MOTION` or an
  axis beyond `DEVICE_AXIS`: the jitter of a stick or the mouse does not change it. Disconnecting
  the gamepad that had it returns it to the keyboard. It reaches the tick and `core.Input.device`.
- The tablet pen gives `pressure` and `eraser` (eraser tip) while the tip touches; with the mouse
  or without a pen `pressure` is 1. Its position and clicks are the mouse events that SDL
  synthesizes. They reach the tick and `core.Input`.
- `QUIT` and the window close request arrive as `close_requested`: the application decides.
- Events beyond `event_capacity` change the state but do not enter the list; the host reports what
  was lost in a frame as the [problem](../../mirai-core/references/core.md#problems)
  `input.events` of the game world that receives that input.

### Injection

`input_inject*` queue events that the next `frame_begin` applies through the same path as SDL's,
after them; with the queue full they return false. In headless, `window_set_size` injects a
`Resized`.

## Window

Without `Window_Desc.rect` the window is centered; `no_surface` creates it without Vulkan or Metal,
as the `dummy` driver requires. The state is read from the frame (`input_frame(p).window`), which
reflects what the system left after the events.

**It appears with its first image.** A window without `hidden` is created visible with its final
state (maximized, full screen), so the surface is born with its size, but it stays veiled until the
first `frame_end(p,presented=true)`: `DWMWA_CLOAK` on Windows, zero opacity on Linux and macOS. If
nothing is presented within `WINDOW_VEIL_FRAMES`, it is shown anyway. Since the system may not know
the frame when creating it, placement is repeated until it is known (on macOS it is measured with
AppKit, because SDL does not report it).

**Displays.** They are named by their index in the order in which the system lists them
(`display_names`). `window_set_display` centers the window on one: maximized it stays maximized
there and in full screen it fills it. Headless there are no displays: the lists come back empty and
moving fails.

### Display scale

- `Window_Frame.size` and the absolute pointer are in UI points; `pixel_size` is the physical
  drawable. `density` is the content scale (pixels per UI point); `pixel_density`, SDL's native
  density (pixels per SDL coordinate). They do not coincide outside Retina: on Windows at 200 % they
  are usually 2 and 1; on Retina, 2 and 2.
- `dpi.odin` converts SDL coordinates to points with `density/pixel_density`; creation, minimum
  size, resizing, the pointer and the hit test apply it.
- When the scale changes, absolute positions are re-based, and the deltas of the captured mouse
  stay in device units to preserve sensitivity. The metrics are updated before delivering input. In
  headless both densities are the desc's.

### Custom chrome

With `chrome=.Custom` the application draws its bar. On Windows and Linux the window has no
borders; on macOS it is an AppKit window with hidden title, transparent bar and the native buttons.

- Each frame delivers with `window_set_regions(p,regions,resizable)` rectangles in points:
  `Client` (common input, even at the edge), `Control` (a bar button; its outer strip
  `WINDOW_CONTROL_RESIZE` still resizes) and `Drag` (moves the window; double click maximizes).
- `window_hit` decides in order: `Client` and `Control`; borders and corners if the window can be
  resized now; `Drag`; the rest is `Client`. Maximized, full screen, fixed size or with
  `resizable=false` (while the application drags something of its own) it has no borders.
- On Windows and Linux, SDL translates the result into native drag and resize; on macOS
  `window_darwin.odin` does it with the screen coordinates of the native event.

### Live frame

While a border or the bar is dragged, the system can hold the loop and `frame_begin` does not
return until the button is released. `set_live_frame(p,proc,user)` registers a procedure that an
SDL watcher runs on `WINDOW_EXPOSED` or `WINDOW_RESIZED` with the query held for more than
`POLL_HELD_NS`. In that frame `input_frame` shows the held state without edges, the current size
and its own `dt`, without events. The procedure calls neither `frame_begin` nor `frame_end` and
does not nest.

### Surface for the graphics backend

Without importing `rhi`: `surface_source(p)` gathers the native window, what Vulkan needs for its
surface, the Metal layer and the size in pixels.

### Dialogs

`dialog_show` opens a native dialog, one at a time; the response arrives in a later frame through
`dialog_result`, only in that frame. SDL can answer from another thread and after the `Platform` is
destroyed: the response goes through a mailbox in the process heap, with a mutex, which is freed
when nobody uses it anymore. In headless it stays open until `dialog_answer`, which answers through
the same path.

## Crashes

`crash_handler_install()` is called by the launchers (`editor.launch`, `host.player_run`), never by
a library. When a failure ends the process it writes to stderr what it was and each stack frame as
module and offset; if `MIRAI_CRASH_REPORT` names a file, there too.

- Windows adds procedure, file and line of the modules with a PDB; without it it names nothing
  (`dbghelp` would give the nearest export, which is another procedure).
- A bounds check or an Odin assertion print their message first; the report goes below.
- The text is built on the stack, without heap. On Linux and macOS the handler runs on an
  alternate stack; on Windows a stack overflow may leave no room for the report.
- The engine binaries are always compiled with debug information; a project's libraries, with
  `build.debug`. Each program has its own PDB, distinct from its library's.
- **Events before the failure.** `crash_events_open(path)` memory-maps a file with a ring of
  `CRASH_EVENT_LINES` fixed-width lines and `crash_event` copies a line (seconds, kind and what)
  without allocating. The system keeps the file when the process ends, and if `MIRAI_CRASH_EVENTS`
  names it the report copies its lines after the stack, the oldest first. The state belongs to
  whoever opens it (`Crash_Events`), not to the package: the handler finds the file through the
  variable.

## File watching

Polling the same on the three systems, with a shortcut where the system notifies.

- `watch_poll(p,w,budget,events)` advances the walk and writes `Created`, `Changed` (size or date)
  and `Removed` with relative paths and `/` slashes, valid until the next call. If `events` fills
  up, the next one continues: nothing is lost. The budget is counted in listed files, and opening a
  folder or sweeping the table have their cost in that unit.
- **Quiet folder (Windows).** The watch asks for the change notification under the folder
  (`FindFirstChangeNotificationW`) before walking, so what changes during a pass triggers the next
  one; if nothing changed when a pass starts, it ends without listing. Linux and macOS always walk.
- The first pass records what exists without reporting it, except `report_existing`. What does not
  fit in the capacities is not watched and is counted (`untracked`). Links to folders are not
  walked, nor more than `WATCH_DEPTH` levels.
- If the watched folder disappears, its files come out as `Removed` and come back as `Created` if
  it reappears.

## Paths

`path_*` give the folders of the executable, of the user's data (created if missing) and temporary.
`trash(absolute path)` sends to the system trash, from where the user recovers it (on Linux, the
freedesktop.org one, which does not move across devices: a file on another disk fails).

## Audio device

`audio_device_open(p,mixer,desc)` opens the output that `desc.device` names (the default if it
names none or the system does not list it) with the mixer's sample rate and channels, in f32; SDL
converts to the hardware. `audio_device_switch` moves the same mixer to another output without
closing the subsystem or touching its state, and says whether it found the name;
`audio_device_names` lists the outputs. SDL's audio thread asks for frames and `audio.mixer_render`
fills them; the `"dummy"` driver plays to nowhere, at real pace. Closing or changing output
guarantees that the audio thread no longer touches the mixer with the previous stream. It works
with a headless `Platform`. The mixer is destroyed after closing the device or destroying the
`Platform`.

SDL moves a stream opened as the default to the next default by itself, but one opened on an
output by its name stays on it when it leaves, played to nowhere. `frame_begin` turns SDL's events
into `audio_device_changes`: `Lost` when that output leaves, `Added` when one is plugged in, each
taken once. `engine/audio`'s `audio_output` acts on them: it plays the default while the chosen
output is not connected, reports `audio.output` once, and returns to it when it is listed again.

## What it does not do

Sockets (`net` uses `core:net`), several windows, IME, text composition, touch and pen, native
notifications of file changes and child processes
([std/subprocess](../../mirai-std/references/subprocess.md)).
