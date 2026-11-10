# Seats, cameras and movement

Who drives which body and with which camera is split across three packages, because the first two
are used by every game and the third only by one that makes bodies appear for its players:

- `engine/input` (`inp`): seats, their actions, which body each one drives and the body's movement
  request (`Move_Input`). It is the only writer of `Drivable`; the rest asks through
  `Seat_Requests`.
- `engine/camera`: the camera of each seat, the following cameras, their modes and the views that
  pass from one to another. It is the only writer of `render.View_Camera`, of `Camera_Follow` and
  of the lens of its cameras; the rest asks through `Camera_Requests`, `Camera_Changes` and
  `Camera_Input`.
- The `spawn` plugin: spawn points and bodies for the players ([spawn points](#spawn-points)).

- A **seat** (`Seat{slot, peer, player}`) is someone who plays: on this machine (`peer` and
  `player` zero, with its `slot`, `seat_local`) or at the other end of a connection (`peer`, which
  the network sets on a server, and `player`, the id its client presented). It exists even if it
  drives nothing: between one death and the next, in a menu, spectating.
- Each seat carries the actions of the tick's `Input_Map`. Actions are all of the player's
  (shoot, use, menus); `Move_Input` is the body's intent: movement, look direction and the held
  buttons, as action ids. A `Character` with a `Walk` of the `locomotion` plugin passes from the
  former to the latter without game code, with forward relative to its look direction, to the
  camera or to the world ([seat control](../../mirai-physics/references/engine.md#seat-control));
  with the `move_relative_to` `Game` of its `Drivable`, the game writes the `Move_Input`. What does
  not move the body (shoot, use) the game reads from the seat.
- `Move_Input` is what is asked of a body in the tick, and it is `shared`: `locomotion_seat` or the
  game writes it for what a seat drives, an AI for its own bodies (like `Follow` in the demo), the
  network for the replicas of others, and a replay. Each one writes the bodies it moves;
  [locomotion](../../mirai-physics/references/engine.md#locomotion) reads it and writes the
  physics `Character_Move`.

## Seats

`input_seats` (`fixed`, stage `input`) builds the seats of this machine and their actions of the
tick.

- **Local.** The count comes from `Run_Players` (the editor sets it for each run; it is `keep`) or
  from `--players`, otherwise from a `Local_Multiplayer` of the scene, and otherwise it is one. A
  server has none, unless they are requested (the editor's Play that serves a game, or
  `--server --players n`). Each slot has a seat: the scene's if there is one, otherwise one created
  at runtime.
- **From other ends.** On a server, the `multiplayer` plugin seats each connection and writes the
  actions it sent; when the connection leaves, the seat is destroyed, and its body with it if
  `spawn` gave it ([networking](#networking)).
- **Devices.** Keyboard and mouse go to the focused slot (`Seats.focus`). With one player, all
  gamepads are theirs; with several, gamepad `i` belongs to slot `i`.
- `Seat` is `shared`: `input` writes those of this machine with `seat_feed(seat, device,
  bindings, gained)` and the network those of the connections with `seat_receive(seat, bindings,
  sent)`, each only its own. Its actions,
  held buttons, re-arming and blocks are `transient` and `local`: `Seat` is replicated, and its
  `peer` travels.
- `inp.Actions` is the machine's entire device: it is used by actions that are not a player's
  (galleries, save, `Frame_Actions` for the camera).
- **Holds.** `hold(r, seat, action, value, ticks)` and `let_go` in `^inp.Hold_Requests` give a
  seat an action as if its player held it, by action and not by key: a test, or an agent through
  `play.input`. `input_holds` (`fixed`, stage `begin`) applies them before any seat reads its
  devices, so they act from the next tick for whole ticks and the same requests on the same World
  give the same ticks. `seat_feed` takes them as one more binding of the action, in the seat's
  contexts, with its blocks and re-arming; they do not reach `inp.Actions` nor `Frame_Actions`.
  Like the devices, they are of a seat of this machine: on a client they reach the server with
  the other actions of its seat, and a hold of the seat of a connection is refused
  (`input.hold_remote_seat`), since its client would not predict it.

## Actions

Each library declares its actions as an enum `@(actions)` of `u8`
(`@(actions) Action :: enum u8 {Mode,Layer_Back,Stamp}`); the name of an action is its member in
lowercase (`layer_back`). Nobody writes or sees a number: the generator gives the members of every
enum, the engine first (`inp.Look_Action`), then the active plugins in order (locomotion:
`locomotion.Walk_Action`) and the game, the next values of `inp.Action`, the `@(names,actions)` type
([named ids](../../mirai-core/references/core.md#named-ids)) that the map, the seats, the masks
and the data hold. The code is the only source of the names; `input.mirai`, the API and the
inspector use them.

- **Reading.** A step receives `inp.Input_Of(E)` for the enum whose actions it reads, and another
  for each enum of another library (`walk:inp.Input_Of(locomotion.Walk_Action)`): the generator
  binds it as a [parameter group](../../mirai-core/references/generator.md#parameter-groups) (the
  `Actions` of the tick, the seats and the `Drivable`s) and gives it the base of `E`. The machine:
  `inp.pressed(input, .Stamp)` and `down`, `released`, `tapped`, `holding`, `value`, `vector`; the
  seat that drives a body: `inp.pressed(input, body, .Jump)`; a seat: `inp.seat_pressed(input,
  seat, .Jump)` and the other `seat_*`. `inp.Frame_Input_Of(E)` reads the `Frame_Actions` of
  presentation the same way.
- **The action of the world.** What holds an action as data (`Camera_Activation.action`, a
  `Move_Input.buttons` mask, a hold, an interface by name) keeps an `inp.Action`; code that needs
  that of a member asks its `Input_Of` (`inp.action_of(walk, .Jump)`), and data names it.
  `inp.action`, `seat_action` and `body_action` read one of those. A scene, a prefab or a saved
  game keeps the name of each action it holds
  ([named ids](../../mirai-core/references/core.md#named-ids)).
- **Type and bindings.** Whoever declares an action (the engine, a plugin or the game) gives its
  kind and default bindings in code, next to it: `<enum>_defaults() -> [E]inp.Action_Default` (or
  a constant `<ENUM>_DEFAULTS`) of its package, found by name as `NAME_DEFAULT` is
  (`walk_action_defaults` of locomotion, `action_defaults` of the templates); the generator hands
  it to the map through `core.Actions_Info.defaults`, refuses a struct that carries
  `[E]Action_Default`, and the compiler asks for every member. The
  project's `input.mirai` only holds what Project Settings > Input and `input.set` changed of
  those, and is not written by hand; the player's options keep another one with what the player
  rebinds. A renamed or removed action has no backward compatibility: in the player's file it is
  left out (`input.options_gone`) and the rest holds, and it goes when the options are written
  again.
- **Building.** `input_map_build` builds the map once, in the first `input` phase, without a game
  function. A name in the file that the code does not declare leaves the file unread and is the
  world problem `input.unknown_action`, which says how to declare it; an action without a default
  or entry, `input.action_unbound`; an invalid default, `input.default_*`.
- **Renaming.** The member is renamed in code, with the types in view (the rename of an editor of
  code, or an agent), and the game built. Then `names.rename` on `Action` follows it: the project's
  `input.mirai` and the documents that keep the action (scenes, prefabs, records) take the new
  name, as edits, unsaved, one step of history each. It refuses while the built code still declares
  the old name or does not declare the new one; the inspector offers no rename for actions.
  Plugins' documents and players' saves keep the old name and lose it, as with the member of any
  enum. `names.create` does not declare actions: the member and its default are written in code.
- **Editing.** Project Settings > Input and `input.set` rewrite the project's `input.mirai` with
  only the actions and ticks that differ from the code (`input_map_text` against the defaults);
  without differences, the file does not exist. A file that is not read is not rewritten. When it
  is written, the edited world and those of the running Plays rebuild their map
  (`Input_Map.built`).

The state of an action of a seat is empty for what is not a seat, while the action is blocked or
while it waits for its release; that of a body is the one of the seat that drives it (empty if
nobody drives it). `inp.Players` is a
[parameter group](../../mirai-core/references/generator.md#parameter-groups) with the seats
and the `Drivable`s.

- **Re-arming.** When driving or swapping a body, when the keyboard passes from one slot to
  another and when a block is released, the buttons the seat holds wait for their release before
  acting. When its contexts change, those that went down with the change (jumping with the button
  that closed the menu). Axes continue. The slot that loses the keyboard reads `released` of what
  it held.
- **Blocks.** `input_block(r, owner, seat, mask)` removes the actions of `mask` from the seat until
  `input_unblock(r, owner)`; with `seat` null, from all local seats (a modal menu of the window).
  An `owner` has one block: requesting another replaces it. They apply when writing:
  `input_drive` leaves in `Seat.blocked` the union of the seat's active blocks, and the read only
  looks at that mask.

### Contexts

A context (`inp.Input_Context`, `@(names)`, less than `CONTEXT_CAPACITY`) is a set of actions with
their own bindings: a menu, an inventory, a vehicle. Each action is in one, the base one
(`CONTEXT_BASE`) if its default (`action_default_in`) or `input.mirai` (`"context"`) do not name
another; in the player's options file it does not change. A seat reads the actions of a context
only while it is in it, and it is always in the base one, below everything.

- `input_context_enter(r, owner, seat, context, modal)` in `^inp.Context_Requests` puts the seat
  (null: all local ones) in it until `input_context_leave(r, owner)`. An `owner` has one; the one
  that entered last stays on top. `input_contexts` (`fixed`, stage `begin`) applies them before any
  seat reads its devices and leaves the stack in `Seat.contexts`; those of an owner that no longer
  exists go away.
- **Capture.** A context on top takes from those below the keys, buttons and axes that its actions
  read: the menu confirms with South while jumping, also on South, waits. A code of one gamepad
  counts also for that of all, and the other way round. A `modal` one leaves them nothing.
- `inp.Actions` and `Frame_Actions` follow the contexts of the focused seat, without re-arming.
- A `UI_Screen` with `input_context` puts there the seats it covers while it takes input; if it is
  `Modal`, as a modal context instead of the block of all actions ([gui](libraries.md#gui)).
- **Contexts are evaluated where the devices are.** A seat of another end takes its actions already
  resolved in the contexts, blocks and re-arming of that end ([networking](#networking)); its own
  stack on this end does not change them. A game that enters a context for the seat that drives a
  body, in a fixed function that runs at both ends, enters it on the client for its local seat.

### Chords

`binding_chord(binding, code_key(.Left_Control))`, or `"chord": [{"key": "Left_Control"}]` in a
binding of `input.mirai`, makes the binding move its action only while those keys or buttons are
also held (up to `CHORD_CAPACITY`; the gamepad is the binding's). A held chord whose binding is in
use takes its inputs from the bindings with a shorter chord or without a chord: Ctrl+S saves
without pressing S or Ctrl. UI prompts show it before the rest, with a `+`.

## Driving

The body carries `Drivable{seat, camera}`: the seat that drives it (`NONE`: nobody) and an entity
with `render.Camera`, which may be outside the body and shared. Each end of a networked session has
its own seats; `Drivable` is not replicated.

- Requests of `^inp.Seat_Requests` (`drive`, `release`, `swap`, `focus` and the blocks) are applied
  in `input_drive` (`fixed`, stage `input`), at the start of the tick. A body that appears through
  `spawn` is driven in the same tick.
- A request that breaks a rule makes no partial changes and is a
  [problem](../../mirai-core/references/core.md#problems) with the cause and how to fix it: of the
  seat (`input.body_taken`, `not_drivable`, `server_decides`...), of the requested body if it is
  not a live seat, or of the `owner` of a block.
- A seat drives at most one body and a body has one seat (`body_of`, `seat_of`).
- `Seats` is derived: loading a scene or a save starts it anew, with its blocks, and whoever
  requested them requests them again.
- Cleanup removes dead references. A block whose `owner` died is released with re-arming; if its
  seat died, it disappears.
- An AI needs no seat: it writes the `Move_Input` of its body while no seat drives it, only where
  this end decides (`core.owned`). A seated `Nav_Agent` also walks a body its seat drives while it
  goes, keeping the seat's buttons
  ([navigation](../../mirai-world/references/navigation.md#agents)).

## Spawn points

The `spawn` plugin gives bodies to seats and places what the game spawns (enemies, pickups). A
game without driven bodies or spawn points (strategy, cards) does not activate it and uses seats,
`Move_Input` and cameras directly.

`Spawn_Point{prefab,players}` marks a place where bodies of its prefab appear (empty: the point only
places bodies the request or `Spawn_Settings.prefab` names). With `players` on it is one of the
players'; with it off only what the game spawns without a seat appears there, so the point of an
enemy never gives a seat its body. A turned-off point is not used. Without a requested point, the
points of the request's kind (the players' for a seat or for a body a seat drives, the others
otherwise) are used in turn in table order; a game with another criterion (teams, distance) picks
the point and passes it.

- Requests in `^spawn.Spawn_Requests`, which `spawn_step` (`fixed`, `input`) takes before driving.
- `spawn(r, seat, path="", point=NONE)`: takes the requested point or the next one of its kind with
  a prefab, instantiates the prefab at `path`, the point's or, for a seat, `Spawn_Settings.prefab`
  (the project's player body) with its world transform (`scene.spawn`; `transient` for a seat's
  body, while what the game spawns with `seat` NONE keeps its `Id`) and asks the seat to drive it,
  in the same tick. In the editor's Play, a scene without players' points makes a player's body
  appear at the editor camera (`scene.Play_Origin`, which the editor fills when Play starts). With
  Play from here or from camera (`Play_Origin.asked`), the first body of player 1 (`slot` 0 of this
  machine) appears there before at any point, once per Play (`Spawning.asked_given`), with the
  prefab the scene would give it (without a requested or project one, that of the point it was due);
  the other seats, their respawns and the shipped game use the points. What appears at `Play_Origin`
  and not at a point is left in the event `Spawned_At_Origin`: with `physics`, the `spawn_physics`
  bridge rests it with the collider of its root on what is below, without burying it; from inside
  something, or with nothing below within reach, it stays where the editor put it. Up to
  `SPAWN_CAPACITY` bodies per tick for seats (`spawn.spawns_full`). Without a point of its kind with
  a prefab it is the problem `spawn.no_spawn_point` of the seat, or of the world for what the game
  spawns; a prefab that does not appear, `scene.spawn` of the point. On a client it is rejected
  (`spawn.client_spawn`): the server decides.
- A body given to a seat carries `Seat_Body`: `spawn_seat_bodies` (`fixed`, `input`) destroys it
  when its seat no longer exists (a player who left). A body given by the game does not carry it,
  and the game decides what to do with it.
- `Spawn_Settings.players` (project setting in `settings.mirai`) gives a body to each seat, local
  or of a connection, that has none (it arrived, its body was destroyed) and did not receive one in
  this tick; if it fails, the seats wait `SPAWN_RETRY` ticks. It is the route to give players a
  body without code; turned off, the game gives them a body. `scene.spawn` remains for what
  appears at no point (effects, projectiles).
- What the body is (its collision kind, components, values) is its prefab: to change how the
  player collides, its `Collider` names the game's preset
  ([kinds of actors](../../mirai-physics/references/engine.md#collision-categories-and-presets)),
  not a step that patches the body after it appears.
- On a server, the body that appears is replicated if its prefab carries `Replicate` ([replicated
  entities](../../mirai-networking/references/multiplayer.md#what-the-game-declares)); its owner
  is the connection of its seat.
- `respawn(r, body, point)` places an existing body at a point with
  [`core.place`](../../mirai-core/references/core.md#requested-places).

## Cameras

`camera_selected` picks the camera of a seat: the most recent valid request (overrides have no
priority), otherwise `Drivable.camera` of its body, and otherwise `NONE`.

- `camera_override(r, owner, seat, camera, ...)` makes `seat` see through `camera` while `owner`
  asks for it, with its lens or another; with `blend` the view enters and leaves in a transition,
  without it, it cuts. An override that cannot be applied is a problem of the `owner` (`camera.*`).
- `camera_select` (`fixed`, `input`) settles the overrides with who drives what, before the
  `Move_Input` of the seats: a seat request and a camera request pushed together (a cinematic that
  ends) are in force in the same tick. It writes no `render.Camera`.
  `Cameras` is derived, like `Seats`: whoever requested an override requests it again after loading
  (a `Cinematic_Viewer` does it from its `Cinematic_View`).

### Cameras that an action brings

Aiming is another camera, not other values of the same one: crouching changes where the body is
and the same camera follows it; aiming changes how the player looks and another camera enters with
a transition.

- `Camera_Activation{action, blend}`, on a camera: the player who drives the target of its
  `Camera_Follow` sees through it while holding `action`. `camera_select` requests it as an
  override whose owner is the camera.
- Cameras without `aim` and with `turn` that follow the same body look where the visible one looks,
  so switching from one to another does not turn the view. With `facing`, the `Character` with
  `Drivable.move_relative_to` `View` looks where the camera looks: when aiming it walks sideways.
- The `Aim` preset is such a camera (Create > Cameras > Aim).

### Views and transitions

`camera_blend` (`late`, `end`) builds the view of each local slot in `Camera_Views` and leaves that
of the focused slot in `render.View_Camera`.

- The view changes when the chosen camera changes or when its camera takes a mode, with the
  transition of the override or of the mode; without a transition it cuts and marks `cut`.
- A transition starts from what the view was drawing, which travels with the seat's body and
  turns around it as the new camera turns (a player looking around) while it lasts; meanwhile,
  `View_Camera.posed` says the view comes from `pose` and does not cut: the
  temporal history of the render continues. One requested in the middle of another starts from
  what is drawn.
- Around the pivot of an `Orbit` the position rotates, so it does not cross the target. Between a
  perspective lens and an orthographic one the view is a dolly zoom, perspective until the end,
  when it already looks like the orthographic one.
- The view of an `Orbit` carries in `core.View.focus` the depth of its pivot, where the render
  centers the light it gathers
  ([volume](../../mirai-rendering/references/gi.md#probe-volume)); in a transition, the point
  it looks at goes from one camera to the other.
- With several players on one machine, `camera_local_views` draws each slot from its view in its
  part of the screen (`host.app_player_rect`, `host.app_views_set`). The editor numbers them
  ([Play](../../mirai-editor/references/editor.md#play)).

### Following cameras

`Camera_Follow` (`locks="core.Transform"`) moves a camera with a target `target`; `NONE` is the
body whose `Drivable.camera` is this camera or, without association, that of the focused player. It
is resolved every frame: it follows the body that is driven now.

- `Follow`: keeps `offset` from the target with a smoothed pivot (`half_life` seconds to close half
  the distance; 0: rigid); `look_at` orients it toward the target.
- `Orbit`: rotates around the pivot at `distance`, with `yaw`/`pitch` (limits
  `min_pitch`/`max_pitch`, both 0: almost vertical). Its arm starts at `shoulder` (right and above
  the camera: over the shoulder) and shortens when something is in the way (`probe_radius`, a
  sphere through [`core.World_Queries`](../../mirai-core/references/core.md#world-queries),
  which the `physics` plugin provides; with 0, or without it, it does not shorten).
  - What reaches the camera pulls it in instantly. What is only crossed between the pivot and the
    camera (a post, someone passing) is tolerated for `pull_grace` and then pulls it in with the
    half-life `pull_time`; once clear, it waits `return_delay` and returns with `return_time`, and
    stays `arm_margin` from what it touched (`Spring_Arm` of `engine/camera/rigs.odin`, which also
    provides `Follow`, `Orbit` and `Shake`: flat state and procedures that return a position or
    rotation, identical at any frame rate; `Shake` is trauma-based, with deterministic noise per
    seed). They are the Advanced section, which the inspector shows collapsed; a time of 0 is
    instant.
  - With the camera closer than twice `hide_within` to its pivot (Advanced; 0: never), its view
    fades the body it follows, and closer than `hide_within` it does not draw it. Fading by
    distance keeps no state and does not jump when crossing the threshold.
  - With `aim`, it turns with the `look_yaw`/`look_pitch` of the target's `inp.Move_Input` plus
    `yaw` and `pitch`: it looks where the body looks, which is what the server simulates.
  - Without `aim`, with `turn` the `look` action of the focused local player who drives the
    target turns it, and with `recenter` it returns behind a moving target that long after the last
    turn. `camera_look(&Camera_Input, camera, yaw, pitch)` turns it from the game.
- `Eyes`: first person. It sits at `offset` from the target and looks with the look of its
  `Move_Input` (that is how the cameras of the demo and template prefabs are).
- **The own body.** The body of each view is its player's (or, without one, the one its camera
  follows): `camera_blend` names it in `render.View_Bodies` and the render marks its meshes and
  what hangs from it, also the skinned copies. Of that body the view does not draw the layers of
  `own_hidden` of its lens, and fades it with `hide_within`. The head is the layer `HEAD_LAYER`: a
  mesh in that layer, or a bone with `Skin_Part` on a skinned mesh
  ([animation](../../mirai-animation/references/animation.md#components-and-shared-data)); the
  first-person preset leaves it out and `own_hidden` of all layers hides the entire body. The views
  of other players, local or networked, the shadow, the reflections and the mirrors keep showing it
  whole. Layers and `own_hidden` change when the blend arrives, not when it leaves: the head does
  not disappear before the camera is at the eyes.
- `offset`, the orbit and the look are measured in the frame of the target's vertical
  ([`core.Vertical`](../../mirai-core/references/core.md)); without it, in world axes. Around a
  planet the camera turns with the up of the character it follows, and the look yaw is the same as
  the body's.
- Framing of `Follow` and `Orbit`: the pivot leads the target by what it travels over the ground in
  `look_ahead` seconds (up to `look_ahead_max`), and lets it move within a box (`dead_zone`, half
  of each side to the right, up and behind the camera) before following it. A large side leaves it
  still on that axis, like the depth of a side view. Along the target's up the pivot can follow
  with its own half-life (`up_half_life`): a jump or a step moves the camera sooner or later than
  a walk.
- An `Orbit` shifts where its arm starts with the pitch (`look_up_offset`, `look_down_offset`, in
  the axes of the camera): the framing changes when looking up or down, and the probe of the arm
  still keeps the camera out of walls.
- `Camera_Input` is a per-frame queue that `camera_follow` (`late`) takes, and `Camera_Requests` a
  per-tick one that `camera_select` (`fixed`) takes: a view turn applies in the frame it arrives
  and an override is part of the simulation, so they do not mix.
- `camera_follow` runs with the target's interpolated transform; what it derives is `transient` in
  the same `Camera_Follow`. If another function writes the camera's transform, `core.fail` reports
  it.

### Modes

A mode is data: `Camera_Setup{follow, lens}`. `CAMERA_PRESETS` gives those of `Camera_Preset`; a
game with its own mode passes its setup. The editor offers them as recipes in Create > Cameras
([presets](../../mirai-editor/references/document.md#world-edit-procedures)).

- `camera_mode(&Camera_Changes, camera, preset or setup, blend)` requests a mode; `camera_follow`
  takes it in the frame. A camera without `Camera_Follow` receives one.
- The setup keeps the target and what is derived on the camera: a free `Orbit` keeps looking where
  it was looking.
- Requesting the mode it already has does nothing: the game can request it every tick, also in one
  that is simulated again.
- A mode that cannot be taken is a problem of the camera (`camera.mode_*`).
- For the body to move well in any mode, its `Drivable` uses `move_relative_to` `View`
  ([seat control](../../mirai-physics/references/engine.md#seat-control)).
- Seeing a camera and passing to others without playing:
  [camera preview](../../mirai-editor/references/editor.md#camera-preview).

### Environment that changes on passing

`Environment_Trigger{sky, sun, seconds}` (`engine/camera`, `environment_triggers`, `frame`): when
the focused player's body enters the [`Volume`](libraries.md#volume) of its entity by more than
`TRIGGER_MARGIN`, it requests turning on the `Sky` and the `Sun` it names, the sky in
`seconds`; to leave it has to move away by as much, so the edge does not alternate. It goes by the
body and not by the camera, and belongs to each end of a session. It is placed in a narrow passage,
where the geometry covers the change.

## Networking

- The server decides who drives what and makes the bodies appear. On the server the network derives
  the `owner` of each body from the `peer` of its seat, and a client drives with its first local
  seat the body it predicts
  ([authority and players](../../mirai-networking/references/multiplayer.md#authority-and-players)).
- `input` does not import networking: a client takes only bodies it decides (`core.owned`),
  rejects the rest (`input.server_decides`) and drops any, like the one the server gave to another.
  `spawn` does not make bodies appear on a client (`spawn.client_spawn`).
- A client sends the server only the actions of its first local seat, as `seat_remote` sees them
  there (`inp.Remote_Actions`: what is down, what was tapped inside the tick, what the mouse moved
  and the values of the axes away from zero); the server gives them to the seat of that connection
  with `seat_receive`, which derives edges, taps and holds with its own map. Devices, bindings and
  the player's rebinding stay on the client. To the other ends only the `Move_Input` of its body
  travels.
- The seat of a connection is replicated to all clients with what the game hangs on it, and when
  the connection leaves it waits turned off for its player; if it does not return in time, it goes
  away and `spawn` destroys the body it gave it
  ([players](../../mirai-networking/references/multiplayer.md#authority-and-players)).
- `Seats`, `Seat` and `Drivable` are part of the `World`: a network correction restores them with
  the copy of the world and the tick is simulated again.

## Verification

- `mirai test engine/input`: in `input_test.odin`, the map built with the defaults, the read by id
  and the names the code does not declare; in `seats_test.odin`, devices per slot, release and
  re-arming, rejected requests and what a client takes and drops; in `holds_test.odin`, a hold
  that acts from the next tick whatever the bindings, its contexts, blocks and capacity, and the
  same holds giving the same ticks; in `remote_test.odin`, the actions another end sent, a
  repeated tick and hostile ones. The rename that rewrites
  `input.mirai`: `mirai test editor renaming_an_action_follows_the_code_in_input_mirai`.
  `mirai test plugins/spawn/runtime`: the bodies of a seat that leaves.
- `mirai test engine/camera`: modes, views that enter and leave an override and a mode, the orbit
  and the dolly zoom of the blend, the dead zone, the lead and a camera that an action brings, and
  the arm (`rigs_test.odin`). `seat_test.odin` of `locomotion` covers `move_relative_to` `View`.
- Integration: the demo's control scene ([demo](demo.md#control)) without a window and with an
  input script; over the network, with a dedicated server and a client.
