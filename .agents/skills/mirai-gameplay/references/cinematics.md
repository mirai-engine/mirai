# Cinematics

The `cinematics` plugin (`plugins/cinematics/runtime`, package `cinematics`) has timelines in fixed
ticks that move entities and cameras. A scene contains the components and the game controls
playback through code; the editor builds them with the Cinematics tool and the API
([editor and API](#editor-and-api)). `cinematic_advance` runs in `fixed` (`intent`, after
possession) and only advances while playing (`Time.playing`).

## Components

- **`Cinematic`** (`replicated`): the timeline; the library writes its state, its position and its
  anchor.
- **`Cinematic_Track`**: how a property of `target` (position, rotation, scale, `Fov` or `Near`)
  varies with `lib.Keyframe` keys of `std/anim` in ticks. Positions and rotations are in world
  space.
- **`Cinematic_Shot`**: from `tick`, the camera `camera` is the one the viewers see, blended from
  the previous shot.
- **`Cinematic_Marker`**: an event at `tick` with an `id` that the engine does not interpret (e.g.
  `base.name_hash` of a game action) and some values.
- **`Cinematic_Viewer`** (`locks="core.Transform"`): goes on an entity with `render.Camera`; it is
  what a seat sees while playing, as the most recent override of that seat, with the actions of
  `block_mask` blocked.

References (`timeline`, `camera`, `target`) are `Entity` fields: scenes, prefabs and saves remap
them.

## Playback

Requests in `^cinematics.Cinematic_Requests`: `cinematic_play`, `cinematic_pause`,
`cinematic_resume`, `cinematic_stop` and `cinematic_seek`.

- `play` starts from 0 and fires the markers at position 0; `resume` takes a new anchor.
- `seek` moves the position without firing markers of the past; if it was `Completed` and goes
  back, it stays `Paused`.
- Each tick the position comes from the anchor. If it is not the one a step from the previous would
  give (the server anchored again), it is taken without firing the markers it skips.
- With `looping`, crossing the end fires the markers of the end and then those of the start.
- Tracks move their targets while `Playing` or `Paused`, with
  [`core.place`](../../mirai-core/references/core.md#requested-places) (a simulation body is
  teleported), regardless of physics. A track whose `target` is the camera of a shot of that
  timeline does not move it: it changes what the viewer samples from it.
- `auto_play` starts the timeline once. A timeline with an invalid duration, a track that cannot
  move its target and a request to an entity without `Cinematic` are problems (`cinematics.*`).

## Viewers

A viewer is active with a timeline playing or paused, a current shot, a live seat and a valid
camera. Each tick an active viewer:

- Samples the camera of the current shot, blends it with the previous one (or with the one the seat
  saw on entry) and writes the result to its own `Transform`.
- On activation it registers, in the viewer's name, a camera override for its seat in
  [engine/camera](control.md#cameras) and, with `block_mask`, an input block. It releases only those
  on finishing, stopping, removing the viewer, changing its references or losing a valid camera;
  the selection goes back to the most recent override that remains or to the camera of the body
  that the seat drives.
- What it shows lives in the `Cinematic_View` component of its entity, which only
  `cinematic_advance` writes: a saved game keeps it with its references remapped, and on loading it
  the viewer requests its override and its block again, which `Cameras` and `Seats` (derived) do
  not keep.

## Events

`Cinematic_Events` is cleared and filled each tick; it is read in a `fixed` function after
`cinematic_advance`. A rollback produces them again: a sound or a message that comes out of them
passes the `core.Time` to its sink, which does nothing while `time.resimulating`
([Time](../../mirai-core/references/core.md#core-storages)).

## Networking

- Commands are only accepted where this end decides the timeline (`core.owned`: the server, or no
  network); on a client they are the problem `cinematics.client`. The plugin does not import
  networking.
- The server sends the state of `Cinematic` and the client derives the position from the same tick
  and the anchor, without receiving advances or historical events; `position` is `local`.
- The timeline entity carries `Replicate` and a stable `Id`, and its shots, tracks and markers are
  in the scene or prefab that both ends loaded.
- `Cinematic_Viewer.seat` is a seat of this end: each end has its own.

## Editor and API

`plugins/cinematics/editor`: the Cinematics tool (Tools menu) and the `cinematics.*` methods.
The sampling of tracks, shots and blends is the runtime's (`cinematic_track_value`,
`cinematic_camera_sample`, `cinematic_shots_at`, `cinematic_shot_blend`): the editor has no other.

- The tool edits one timeline: the one it had, the selection's or the first of the scene. At the
  bottom, the editor's time strip (`editor.timeline_strip`) with a lane of shots, one per track with
  its keys and one of markers; on the right, the timeline, its duration and what adds parts. Parts
  are created as entities under the timeline; a new track is born with a key of its target as it
  is.
- **Preview.** With the tool on, the scene shows the timeline at the playhead: a
  [cancelable preview](../../mirai-editor/references/extensions.md#cancelable-previews)
  puts the targets where the tracks say, like `tracks_apply` (the camera of a shot does not move).
  Playing advances the playhead at the fixed tick rate, without markers or game logic. Another
  change of the scene (undo, save, a write through the API, picking in Hierarchy) ends it and the
  scene returns to the document until the playhead moves; writes of the tool and of `cinematics.*`
  resume it.
- Shot view puts the viewport's view on the current shot with its blend, without roll; turning it
  off or leaving the tool restores the previous view.
- The gizmo moves the target of the track chosen in the strip; releasing it puts a key at the
  playhead on every position, rotation or scale track of that target. Dragging a mark moves it by
  tick; the lane's button adds at the playhead and the right button deletes.
- Keys stay in tick order; a key at the tick of another replaces it. Each write is a document undo
  step.
- `cinematics.control` in Edit drives the preview (turns the tool on) and in Play queues the
  command in `Cinematic_Requests` of the running world. `add` and `key.set` require Edit.

## Verification

- `mirai test plugins/cinematics/runtime` (sampling of tracks, shots and blend) and
  `mirai test plugins/cinematics/editor` (order and capacity of the keys).
- Reference walkthrough: the intro of the demo's control scene ([demo](demo.md#control)): playback,
  shot blending, markers and input blocking during the intro; in the editor, `cinematics.control`
  Seek with view Shot over that intro and `capture` with the UI.
- Cinematics over the network were not exercised.
