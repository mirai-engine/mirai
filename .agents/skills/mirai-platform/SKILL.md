---
name: mirai-platform
description: Mirai operating system layer (the `platform` package, over SDL3) and its audio library
  (the `audio` package). Use when working on window and custom chrome, per-frame and per-tick input,
  clock and frame pacing, file watching, paths, mixer, voices, buses, positional audio and WAV/OGG
  decoding.
---

# Mirai platform and audio

`platform` (layer 4) knows neither the editor, the renderer nor the data world: it delivers flat
data and handles, and receives rectangles and descs. `audio` (layer 3) is a pure library without
SDL; `platform/audio_device.odin` is the only thing that joins the two.

## Map

- Context, frame and pacing, input and injection, window, display scale, custom chrome, dialogs,
  crashes, file watching, paths, trash, audio device:
  [context](references/platform.md#context), [frame](references/platform.md#frame),
  [input](references/platform.md#input), [window](references/platform.md#window),
  [crashes](references/platform.md#crashes),
  [file watching](references/platform.md#file-watching), [paths](references/platform.md#paths) and
  [audio device](references/platform.md#audio-device).
- Mixer, threads, sounds, decoders, feeds and streams, voices, buses, sends, the master limiter,
  reverb, positional audio: [mixer](references/audio.md#mixer),
  [sounds](references/audio.md#sounds), [voices](references/audio.md#voices),
  [buses, sends and limiter](references/audio.md#buses),
  [reverb](references/audio.md#reverb) and [positional audio](references/audio.md#positional-audio).
- Code: one file per topic in `platform/` and `audio/`. What depends on the system goes in
  variants with build tags and the same signatures (`*_windows`, `*_posix`, `*_darwin`,
  `*_linux`, `*_other`). `events.odin` translates SDL; `mix.odin` is the voice on the audio
  thread.

## Workflow

1. Every event, from SDL or injected, goes through `input_apply`. A new input source is translated
   into an `Input_Event` and applied there; input state is not written anywhere else.
2. What the game thread asks of the mixer travels as a `Command` through the queue; what the audio
   thread reports comes back through atomics that `mixer_update` reads. A new voice or bus
   parameter follows that path and is ramped within the chunk.

## Invariants

- SDL state belongs to the process: a process has at most one `Platform` with a window, created on
  the main thread.
- A headless `Platform` starts no SDL subsystem; it only uses its clock and its waits. It accepts
  the same API as one with a window.
- These do not allocate: `frame_begin`, `frame_end`, `input_tick_take`, `input_inject*`,
  `window_set_regions`, `window_hit_at` and `watch_poll`. These are transactions: `create`,
  `watch_create`,
  `audio_device_open`, `audio_device_switch`, the lists of displays and audio outputs, the
  clipboard and the title with a window.
- `pressed` and `released` of `Input_Tick` hold for a single tick: `input_tick_take` delivers and
  clears them.
- The mixer is used by two threads at most: `mixer_render` on one and everything else on another;
  its own decoder thread, when it has one, only fills feeds. `mixer_render` is `"contextless"`: it
  can neither allocate nor take locks, and it never decodes: it reads what a decoder left.
- A sound loaded into the mixer stays encoded when it is lossless or a WAV of 16 bits or fewer;
  each voice decodes it. Loading never decodes those.
- An exhausted capacity returns an error or handle 0 and adds to the statistics
  (`platform.stats`, `watch_stats`, `audio.mixer_stats`); nothing grows.
- Handles (`Watch`, `audio.Sound`, `audio.Voice`) are generational `base.Handle`s: a
  freed one does not affect whoever reuses its place.
- Tests send no synthetic input to the desktop nor open visible windows: SDL's `dummy` driver or a
  `hidden` window.

## Verification

- `mirai test platform` and `mirai test audio` depending on the change; `platform` types with
  `-vet` and, for its macOS sources, `-target:darwin_arm64` (running `window_darwin.odin` needs a
  Mac).
- Windows: the test executable needs `SDL3.dll` from Odin's `vendor/sdl3` next to it
  (`bin/tests/`) or in `PATH`. Linux: `scripts/setup_linux_deps.py` builds SDL3 and Odin's stb and
  cgltf libraries in `.deps/linux-amd64`, which `mirai` finds by itself.
- Scale or coordinates: `platform/dpi_test.odin`.
- Everything that touches SDL video, events, gamepads or audio runs inside a single test,
  `windowed_platform_works_through_sdl` (those subsystems belong to the process and the tests run
  on several threads). A new check that uses them is added there, as a private procedure.
- Windows only: `platform/window_native_test.odin` (a real hidden window, regions with
  `WM_NCHITTEST`, and a visible window veiled until a presented frame; it never reaches the
  screen).
- Vulkan surface, on request: `-define:PLATFORM_TEST_VULKAN=true` with `VK_DRIVER_FILES` pointing
  to the driver (lavapipe avoids the GPU).
- Audio: the tests render to memory and compare samples; `audio/testdata/*.ogg` are tones
  generated once and not regenerated. Mixers of tests have no decoder thread, so the output is
  exact; a test that uses one decodes with `mixer_decode` before each render.
- Feeds: `audio/lossless_test.odin` (voices and offsets, an encoded sound against its decode,
  damaged input) and `audio/stream_test.odin` (the audio and game threads share a mixer without
  locks, with the decoder thread).
- Benchmarks, only if the change touches a measured path:
  `mirai test audio benchmark_mixing_ten_milliseconds --release -define:AUDIO_BENCHMARK=true`,
  `benchmark_encoded_sounds_against_decoded_ones` (load, memory and decode per voice) and
  `mirai test platform benchmark_watch_pass --release -define:PLATFORM_BENCHMARK=true`.
- Native dialogs, dragging and resizing the window with the mouse, maximizing and full screen are
  tested by a person.
