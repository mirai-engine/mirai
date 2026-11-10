# Cinematics

The `cinematics` plugin (`plugins/cinematics/runtime`, package `cinematics`, depends on
`animation`) is what the players see of a
[timeline](../../mirai-animation/references/animation-timeline.md). The timeline itself is the clip
of the `Animation` of an entity: its tracks move the cameras and the actors and write their fields
(a lens is `<camera>/@field/Camera.fov`), `anim.animation_command` plays, pauses, stops and seeks it
as any other clip, and its markers arrive in `anim.Animation_Events`. A scene contains the
components and the game controls playback through code; the editor builds them with the Cinematics
tool and the API ([editor and API](#editor-and-api)). `cinematic_advance` runs in `fixed` (`react`):
it reads the `Playback` that `animation_advance` writes, so it sees what the clip wrote in the tick.
`cinematic_follow` asks the clip of a client to go where the server's is. Both run only while
playing (`Time.playing`).

## Components

- **`Cinematic`** (`replicated`), on the entity with the `Animation`: the library writes its status
  (`Stopped`, `Playing`, `Paused`, `Completed`, from the clip), where the clip is and its anchor.
- **`Cinematic_Shot`**: from `time` of the clip, the camera `camera` is the one the viewers see,
  blended over `blend` seconds from the previous shot.
- **`Cinematic_Viewer`** (`locks="core.Transform"`): goes on an entity with `render.Camera`; it is
  what a seat sees while the clip plays or is paused, as the most recent override of that seat, with
  the actions of `block_mask` blocked.

An entity out of the timeline that the clip moves (a camera, an actor) carries an
`anim.Animation_Target` that names the timeline. References (`timeline`, `camera`, `animation`) are
`Entity` fields: scenes, prefabs and saves remap them.

## Playback

- The timeline starts by itself when its `Animation.playing` is set in the scene, repeats with
  `Animation.loop` and lasts what its clip lasts (its last key or marker).
- `Play` starts from 0; `Seek` moves the clip without firing markers of the past; `Stop` returns it
  to its start, which ends the view.
- A clip that does not move leaves its actors where they are: a body the cutscene placed is the
  game's again when the clip ends.
- A `Cinematic` whose entity has no `Animation` is the problem `cinematics.animation`.

## Viewers

A viewer is active with a clip playing or paused, a current shot, a live seat and a valid camera.
Each tick an active viewer:

- Takes the camera of the current shot where its transforms put it in the world in this tick, with
  the lens it has, blends it with the previous one (or with the one the seat saw on entry) and
  writes the result to its own `Transform`.
- On activation it registers, in the viewer's name, a camera override for its seat in
  [engine/camera](control.md#cameras) and, with `block_mask`, an input block. It releases only those
  on finishing, stopping, removing the viewer, changing its references or losing a valid camera;
  the selection goes back to the most recent override that remains or to the camera of the body
  that the seat drives.
- What it shows lives in the `Cinematic_View` component of its entity, which only
  `cinematic_advance` writes: a saved game keeps it with its references remapped, and on loading it
  the viewer requests its override and its block again, which `Cameras` and `Seats` (derived) do
  not keep. The time of the clip is in `anim.Animation_Progress`.

## Events

The markers of the clip are those of any `Animation`: `anim.Animation_Events`, filled each tick by
`animation_sample`, with the timeline as `entity`. A rollback produces them again: a sound or a
message that comes out of them passes the `core.Time` to its sink, which does nothing while
`time.resimulating` ([Time](../../mirai-core/references/core.md#core-storages)).

## Networking

- `Animation` is not replicated: each end plays its own clip. Where this end decides the timeline
  (`core.owned`: the server, or no network) `Cinematic` takes its status from the clip and anchors
  it: the tick, the time of the clip then and its rate. The plugin does not import networking.
- The server sends `Cinematic` only when the anchor moves (a command, a clip that left it); `time`
  and `duration` are `local`. A client gives its clip the commands that take it where the anchor
  says for the tick, so what its own game asks of that clip is undone.
- The timeline entity carries `Replicate` and a stable `Id`, and its shots, actors and clip are in
  the scene or prefab that both ends loaded.
- `Cinematic_Viewer.seat` is a seat of this end: each end has its own.

## Editor and API

`plugins/cinematics/editor`: the Cinematics tool (Tools menu) and the `cinematics.*` methods. The
choice of shot and its blend are the runtime's (`cinematic_shots_at`, `cinematic_shot_blend`): the
editor has no other.

- The tool shows one timeline: the one it had, the selection's or the first of the scene. It is
  the [Tracks tool](../../mirai-animation/references/animation-authoring.md#tracks-tool) opened on
  the clip of the timeline (its strip, its head and the scene shown there, its keys), with the
  timeline, the shot view and what adds a shot or an actor above the tracks in its panel. A shot is
  an entity under the timeline, added at the head and timed by its `Cinematic_Shot.time`; an actor
  is an `Animation_Target` on its entity.
- The keys and the markers are the clip's: the Tracks tool, `animation.key.capture`,
  `animation.track.set`, `animation.key.set` and `animation.marker.set` write them, with the
  `target` of an actor as `cinematics.inspect` gives it.
- Shot view puts the viewport's view on the current shot with its blend, without roll; turning it
  off or leaving the tool restores the previous view.
- `cinematics.control` in Edit moves the head of the Tracks tool on the timeline (turns the tool
  on) and in Play queues the command with `anim.animation_command`. `add` requires Edit.

## Verification

- `mirai test plugins/cinematics/runtime`: `a_viewer_shows_the_shots_of_a_clip_while_it_plays` (a
  clip that moves a camera by reference and writes the lens of another, the shots, the blend and the
  release at the end), `the_shot_in_force_blends_in_from_the_one_before_it` and
  `an_anchor_gives_the_time_of_a_clip_at_a_tick`.
- Reference walkthrough: the intro of the demo's control scene ([demo](demo.md#control)): playback,
  shot blending, the bark marker and input blocking during the intro; in the editor,
  `cinematics.control` Seek with view Shot over that intro and `capture` with the UI.
- Cinematics over the network were not exercised.
