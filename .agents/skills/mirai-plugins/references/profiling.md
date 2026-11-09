# Profiling plugins: `profiler` and `tracy`

Two development plugins (`"development": true`): they enter the editor and the player and never a
shipped game ([manifests](../../mirai-projects/references/projects.md#manifests)). Both read
what `host` records when someone asks for it
([profiling](../../mirai-core/references/host.md#the-frame)): the zones of each thread and the GPU
time of each pass.

## `profiler` (`Editor`)

View > Profiler panel. **Record** records frames into a
[`profile.*`](../../mirai-agent-api/references/methods.md#profiling) capture: the panel and an
agent see the same captures, and the panel shows the last finished one.

- It shows the capture summary and a chart with one bar per frame colored by what it waited on
  (CPU, GPU or pacing); under it a tab per track for the chosen frame: CPU (the zones of the main
  thread, one row per worker and the most expensive zones), GPU (the passes of what the frame
  submitted, where they ran, and the most expensive passes) and Memory (the process and GPU memory
  frame by frame). A track the capture did not record says so.
- It draws with [`editor.drawing`](../../mirai-editor/references/extensions.md#a-panel); what it
  computes from a capture it computes when it starts showing it.

## `tracy` (`Runtime`)

Client of the [Tracy](https://github.com/wolfpld/tracy) protocol written in Odin: the program
listens and the Tracy GUI (`tracy-profiler`) or `tracy-capture` connect.

- Off except with `MIRAI_TRACY=1`; `MIRAI_TRACY_PORT`, `MIRAI_TRACY_ANY` (all interfaces instead
  of loopback) and `MIRAI_TRACY_NAME` configure it. It announces the port by UDP broadcast while
  it waits.
- On-demand sessions: a GUI that connects late receives the frames counted before, and what
  precedes the session is not recorded. While there is a session, `tracy_frame` (once per
  application frame) requests profiling with `host.profile_request` and sends the frame mark, the
  GPU intervals and the zone trees of each ring whose outer zone finished.
- The zones of a tree come out in stack order, the outer one first; a tree that does not fit in the
  queue is discarded whole.
- Nothing waits on the network: a frame that the socket does not take is completed at the next
  poll, what does not fit in the queue is discarded and counted, and a server that does not
  identify itself in time is cut.
- GPU times arrive in the CPU clock (`rhi.Gpu_Timing`), so the GPU context is born with the two
  clocks equal: Metal calibrated, Vulkan approximate
  ([statistics](../../mirai-rendering/references/frame-graph.md#statistics)).
- `tracy_protocol.odin` mirrors the subset of `TracyProtocol.hpp` and `TracyQueue.hpp` of the
  version that `PROTOCOL_VERSION` names: `Queue_Type` uses their exact positions, zone names are
  copied deduplicated into a fixed pool and each queue frame travels compressed with the LZ4 block
  of `lz4.odin`, the format the Tracy server reads.

The GUI is the official Tracy one, of the protocol's version (`brew install tracy` on macOS; on
Windows x64, the binaries of [5hif7y/tracy](https://github.com/5hif7y/tracy/releases)). It does
not ship with the engine.

## Verification

- `mirai test plugins/tracy/runtime`: LZ4 against a decoder that demands the block-end rules, the
  welcome and the records as server bytes, a fake server over loopback (on-demand session, a
  server that stops reading does not hold back the frames, a mute connection is cut) and the order
  of the zone trees.
- `mirai test host a_request_reserves_the_rings_and_lasts_a_frame`.
- Panel: generate and build the demo editor, `profile.capture` and a capture of the editor with
  View > Profiler open.
- A session with the real Tracy GUI is tested on a machine with the GUI installed.
