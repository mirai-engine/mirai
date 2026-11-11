# Cinematics

The `cinematics` plugin (`plugins/cinematics/runtime`, package `cinematics`, depends on
`animation`) is what the players see of a
[timeline](../../mirai-animation/references/animation-timeline.md). The timeline itself is the clip
of the `Animation` of an entity: its tracks move the cameras and the actors and write their fields
(a lens is `<camera>/@field/Camera.fov`), `anim.animation_command` plays, pauses, stops and seeks it
as any other clip, and its markers arrive in `anim.Animation_Events`. Its markers on entities stage
it ([shots and actions](#shots-and-actions)). A scene contains the components and the game controls
playback through code; the editor builds them with the Cinematics tool and the API
([editor and API](#editor-and-api)). `cinematic_advance` runs in `fixed` (`react`): it reads the
`Playback` that `animation_advance` writes, so it sees what the clip wrote in the tick.
`cinematic_follow` asks the clip of a client to go where the server's is; it runs only while
playing (`Time.playing`). `cinematic_advance` runs in the editor too, where it only drives the
actors to the head of the clip.

## Components

- **`Cinematic`** (`replicated`), on the entity with the `Animation`: the library writes its status
  (`Stopped`, `Playing`, `Paused`, `Completed`, from the clip), where the clip is and its anchor.
  `seat` (none: the focused local player) and `block_mask` are `local`: each end has its own.

An entity out of the timeline that the clip moves or puts markers on (a camera, an actor) carries
an `anim.Animation_Target` that names the timeline. References are `Entity` fields: scenes, prefabs
and saves remap them. There is no other cinematics component: a shot is not an entity and there is
no camera of the cinematic's own.

## Playback

- The timeline starts by itself when its `Animation.playing` is set in the scene, repeats with
  `Animation.loop` and lasts what its clip lasts (its last key or marker).
- `Play` starts from 0; `Seek` moves the clip without firing markers of the past; `Stop` returns it
  to its start, which ends the view.
- A clip that does not move leaves its actors where they are: a body the cutscene placed is the
  game's again when the clip ends.
- A `Cinematic` whose entity has no `Animation` is the problem `cinematics.animation`.

## Shots and actions

A marker of the clip whose target names an entity is on that entity, bound as the tracks of that
target are (`anim.animation_markers`, `anim.animation_bound`).

- **A shot** is a marker on an entity with `render.Camera`. The shot in force at a time is the last
  one at or before it (`cinematic_shot`, which the editor uses too). While the clip plays or is
  paused with a shot in force and a live seat, the timeline is the owner of a
  [camera override](control.md#cameras) of that seat through the camera of the shot, with the
  duration of the marker as the seconds of its blend: the cut and the blend between shots are
  those of `engine/camera`. With `block_mask`, it also owns an input block of the seat. Both go
  when the clip stops, ends or has no shot in force; the view leaves with the blend of the last
  shot, as any override does.
- **An action** is a marker on another entity: from its time to the end of its span, or of the clip
  for a moment, the action of its name there is driven by the clip
  ([`anim.play_at`](../../mirai-animation/references/animation-actions.md#requests-and-lifecycle)),
  at the time of the clip less that of the marker: paused it holds, sought or scrubbed it shows the
  pose of that time, and leaving the span stops it if it still plays. One that ended by itself
  inside its span is not started again until the clip is sought. Every end drives its actors by
  its own clip, which follows the anchor.
- `Cameras` and `Seats` are derived: after a saved game loads, the timeline asks for its override
  and its block again. An action does not resume after a load.
- A marker whose target no entity has, or whose entity is gone, is the problem
  `cinematics.marker_target` and is left out.

## Events

The markers of the clip are those of any `Animation`: `anim.Animation_Events`, filled each tick by
`animation_sample`, with the timeline as `entity`; shots and actions arrive too. A rollback
produces them again: a sound or a message that comes out of them passes the `core.Time` to its
sink, which does nothing while `time.resimulating`
([Time](../../mirai-core/references/core.md#core-storages)).

## Networking

- `Animation` is not replicated: each end plays its own clip. Where this end decides the timeline
  (`core.owned`: the server, or no network) `Cinematic` takes its status from the clip and anchors
  it: the tick, the time of the clip then and its rate. The plugin does not import networking.
- The server sends `Cinematic` only when the anchor moves (a command, a clip that left it); `time`
  and `duration` are `local`. A client gives its clip the commands that take it where the anchor
  says for the tick, so what its own game asks of that clip is undone.
- The timeline entity carries `Replicate` and a stable `Id`, and its actors and clip are in the
  scene or prefab that both ends loaded. Every end shows its own seat the shots of its clip.

## Editor and API

`plugins/cinematics/editor`: the Cinematics tool (Tools menu) and the `cinematics.*` methods. The
choice of shot is the runtime's (`cinematic_shot`) and its blend is `engine/camera`'s `pose_mix`:
the editor has no other.

- The tool shows one timeline: the one it had, the selection's or the first of the scene. It is
  the [Tracks tool](../../mirai-animation/references/animation-authoring.md#tracks-tool) opened on
  the clip of the timeline (its strip with a lane of markers for each camera and actor, its head
  and the scene shown there, its keys), with the timeline, the shot view and what adds a shot, an
  action or an actor above the tracks in its panel. A shot or an action is
  `animation.marker.set` at the head with the target of its actor, which the tool makes an actor
  first; an actor is an `Animation_Target` on its entity.
- The keys and the markers are the clip's: the Tracks tool, `animation.key.capture`,
  `animation.track.set`, `animation.key.set` and `animation.marker.set` write them, with the
  `target` of an actor as `cinematics.inspect` gives it.
- Shot view puts the viewport's view on the shot at the head with its blend from the shot before,
  without roll; turning it off or leaving the tool restores the previous view.
- `cinematics.control` in Edit moves the head of the Tracks tool on the timeline (turns the tool
  on) and in Play queues the command with `anim.animation_command`. `add` requires Edit.

## Verification

- `mirai test plugins/cinematics/runtime`:
  `the_markers_of_a_clip_cut_between_cameras_and_play_actions_while_it_plays` (the override and
  the block a shot asks, as `camera_override` asks it, the action a span drives and stops, a marker
  on an entity that is gone, the release at the end and a client following the anchor),
  `a_head_of_a_scrubbed_clip_shows_one_shot` (and the action it drives to the head) and
  `an_anchor_gives_the_time_of_a_clip_at_a_tick`,
  `a_scrubbed_timeline_plays_from_its_start_in_a_play` (the copy Play starts from); the driven
  play itself:
  `a_driven_action_shows_the_time_of_its_driver_played_or_sought` in `plugins/animation/runtime`.
- Reference walkthrough: the intro of the demo's control scene ([demo](demo.md#control)): playback,
  the cut and the blend between its two shots, the bark marker and input blocking during the
  intro; in the editor, `cinematics.control` Seek with view Shot over that intro and `capture` with
  the UI.
- Cinematics over the network were not exercised.
