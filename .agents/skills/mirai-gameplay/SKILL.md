---
name: mirai-gameplay
description: Write games with the game libraries of `engine/scene`, `engine/volume`,
  `engine/render`, `engine/input`, `engine/camera`, `engine/audio`, `engine/gui` and `engine/save`,
  with the plugins `spawn`, `spawn_physics`, `cinematics` and `streaming`. Covers per-zone values
  (gravity, wind, reverb, view and fog volumes), runtime prefabs, action-based input, player seats,
  driving bodies and cameras, spawn points, saves (slots, autosave, checkpoints), cinematics,
  section streaming, the `demo` project and the game templates. Use when writing game code against
  those libraries, building a game from a template, or looking for where a game feature lives
  (enemies, NPCs and mining games are in `mirai-world`, attacks and skills in `mirai-abilities`).
---

# Mirai gameplay

The game is a project library (`game/`) or a plugin library (`plugins/<n>/runtime/`) whose
`@(step=...)` functions transform the world; the libraries of `engine/` are the same thing, with
the same attributes and no private paths. Declaration and parameter binding:
[core](../mirai-core/SKILL.md).

## Map

- Writing a game: [the docs games read](../../../docs/game/core.md), and the requests and events
  of each library: [requests and events](references/game.md#requests-and-events) and
  [code style rules](references/game.md#game-code-style-rules).
- `scene`, `render`, `input`, `audio`, `gui`, `save`: [scene](references/libraries.md#scene),
  [render](references/libraries.md#render), [input](references/libraries.md#input),
  [audio](references/libraries.md#audio), [gui](references/libraries.md#gui) and
  [save](references/libraries.md#save).
- Per-zone values (`Volume`, `Wind`, `View_Volume`, `Audio_Reverb`, `Gravity`, `Fog_Volume`) and
  their single algorithm: [volume](references/libraries.md#volume).
- Particles (plugin `vfx`: emitters, effects, clocks and requests):
  [vfx](../mirai-world/references/vfx.md#game).
- Animation of transforms and skeletons: [plugin
  animation](../mirai-animation/references/animation.md#components-and-shared-data); the gallery
  that shows each feature: [animation gallery](references/animation-gallery.md#animation-gallery).
- Seats, driving bodies and `Move_Input` (`engine/input`), cameras (`engine/camera`), spawn points
  (plugin `spawn`), their networking: [seats](references/control.md#seats),
  [driving](references/control.md#driving), [spawn points](references/control.md#spawn-points),
  [cameras](references/control.md#cameras) and [networking](references/control.md#networking).
- Declare an input action (`inp.Action`), its default bindings, `input.mirai` and renaming it:
  [actions](references/control.md#actions). Input contexts (menus, vehicles) and chords:
  [contexts](references/control.md#contexts), [chords](references/control.md#chords).
- Walking, jumping and flying a character (`Character`, seat control, game modes):
  [locomotion](../mirai-physics/references/engine.md#locomotion).
- Slow or fast world time with the player at normal speed (bullet time: `core.Clock` and
  `core.Own_Pace`): [own pace](../mirai-core/references/core.md#core-storages).
- Cinematics (plugin `cinematics`): [components](references/cinematics.md#components),
  [playback](references/cinematics.md#playback), [viewers](references/cinematics.md#viewers),
  [events](references/cinematics.md#events), [networking](references/cinematics.md#networking) and
  [editor and API](references/cinematics.md#editor-and-api).
- Attacks, combos, dashes, skills and hit reactions with costs, cooldowns, charges and damage
  (plugin `abilities`): [abilities](../mirai-abilities/SKILL.md); no state machines.
- Enemies and NPCs (patrol, chase and attack, phased bosses, tactical bots, hordes, use of the
  environment): [enemies with minds](../mirai-world/references/behavior.md#enemies-with-minds);
  no state machines, trees or planners.
- Mining, craters and excavation (digging deeper gives another material, veins, caves, debris):
  a Volume with an [interior](../mirai-world/references/terrain.md#volume-interior), the
  game that calls `terrain.dig` and adds up `terrain.Terrain_Digs`, and the dust, pieces
  and drops per layer
  ([what digging leaves](../mirai-world/references/terrain.md#what-digging-leaves)); the example
  is the `dig` scene of the [demo](references/demo.md#code-demogame).
- Testing that the game plays as it should (walk there, press that, the door opens) in a file
  played again after each change and in CI:
  [scenarios](../../../docs/game/testing/scenario.md), written as the
  [player plays](../mirai-agent-api/SKILL.md#testing-like-a-player).
- Demo, templates, generated content, portal game: [templates](references/demo.md#templates),
  [demo](references/demo.md#demo), [AI arenas](references/demo.md#ai-arenas),
  [generated content](references/demo.md#generated-content) and
  [portal game](references/demo.md#portal-game).
- Physics and destruction: [mirai-physics](../mirai-physics/SKILL.md). Networking:
  [mirai-networking](../mirai-networking/SKILL.md).

## Workflow

1. Import `mirai:core`, the `engine/*` libraries and the `runtime` parts of the active plugins with
   aliases (`inp`, `cam`, `scene`, `spawn`, `phys`, `loco`, `multiplayer`), `mirai:host` if the
   application is needed, and `std/*`. Never `editor`, `cook/` or the `editor/` package of a
   plugin.
2. One component or storage per concept, flat. What a function derives (cursors, `ready`, `held`)
   is `transient` (not saved or replicated); what must not travel over the network is `local`.
3. The signature declares what the function reads and writes. A table owned by someone else that
   is not `shared` is not written: a request is sent to its owner (`core.place`,
   `phys.set_velocity`, `destruct.damage`, `inp.drive`, `save.request_save`, `scene.spawn`,
   `multiplayer.send`).
4. Phase of the function: simulation in `fixed`, camera and presentation in `late`, own interfaces
   in `ui`, reading to draw in `render`.
5. Stage of `fixed` ([order](../mirai-core/references/generator.md#order)): gameplay goes in
   `intent` without saying so. Before it, in `begin` and `input`: the network, the seats and their
   actions, spawns, who drives what, and the `Move_Input` of whoever drives a seat; after it, in
   `apply`: the camera of the focused player, spawns and the sampled animation; and in `simulate`:
   locomotion and physics.
   - What corrects the sampled pose before physics (`animation_motor_drive`) goes in
     `stage="apply"`: reading `anim.Playback` puts it after `animation_sample`.
   - A game that reacts to contacts or damage of the tick goes in `stage="react"`; what it pushes
     to `Destruct_Requests` there breaks in the same tick.
   - What only the server or a single-player game decides carries `server` instead of asking
     `core.Network` ([attributes](../mirai-core/references/generator.md#attributes)).
6. `time.dt` (`core.Time`) in `fixed`; `frame.dt` and `frame.alpha` (`core.Frame_Time`) in
   `frame`/`late`/`render`; in the editor loop `time.dt` is 0. An effect that is not simulation (a
   sound, a message) passes the `core.Time` to its sink (`audio.play_asset(app, time, ...)`,
   `multiplayer.send(&outbox, time, ...)`), which does nothing while a rollback replays the tick
   (`time.resimulating`); the game does not ask.
7. Runtime prefab: `scene.spawn(spawner, path_or_id, ...)` with `core.Commands`; its rows wait
   until the end of the function and are finished with
   `core.commands_added`. With `transient=true` the entities do not get an `Id` and a save does not
   include them as scene entities.
8. Game code names a prefab or a scene by its path in the assets; data fields hold its
   `base.Asset_Id`.

## Invariants

- **Flat data, no dynamic ownership in components.** A storage may have dynamic arrays if it
  declares `copy`/`free` or if `core.value_copy`/`value_free` suffice (dynamic arrays and slices;
  not maps or pointers).
- **A library is the only writer of its own data.**
  - `engine/input`: `Drivable`. `engine/camera`: `render.View_Camera`, `Camera_Follow`, the lens of
    its cameras and the `Transform` rows of the ones that follow; a mode is requested with
    `cam.camera_mode`.
  - `physics`: `Transform` of the bodies; locomotion, the `Character_Move` of the characters (in a
    game mode, after the step of that mode).
  - `animation_sample`/`animation_advance`: buffers and results of `Playback`.
  - The rest is requested.
- **Input arrives through actions**, members of an enum `@(actions)` of each library, with their
  kind and default bindings (`[E]inp.Action_Default`), read by member through `inp.Input_Of(E)`;
  nobody writes an action's number. `input.mirai` is not
  written by hand: it holds only what Project Settings > Input, `input.set` or the player changed.
  The menu of the game is the engine's `Menu` action (`gui.menu_pressed`); pausing and capturing
  the mouse are the engine's too (`UI_Screen.pause`, `input=.Modal`), never game code.
- **Seats and movement.** A player is a seat (`inp.Seat`), of this machine or of a connection,
  without telling them apart; it drives a body with `Drivable` and carries its actions. Locomotion
  turns the body's `Move_Input` into movement: the seat writes it according to `move_relative_to`,
  the game does (with `Game`, from `inp.seat_*` or `inp.pressed(players, body, ...)`), or an AI for
  its own bodies; an own mode (swimming, climbing) is requested with `phys.set_mode`. Player bodies
  appear at the `Spawn_Point`s of the `spawn` plugin, not through game code
  ([control](references/control.md)).
- **Volumes: one algorithm and an unbounded base value.** Gravity, wind, reverb, view and fog
  change per zone with a single algorithm: each volume has a priority and says whether it adds to
  or replaces what is below, and the base value is a volume without bounds. An unbounded volume of
  a referenced section applies only inside the box of its section. No `@(storage,scene)`: level
  rules are components of a root entity, which are replicated and saved.
- **What draws the far shape of an entity is not unloaded with its section.** An entity with a
  `@(component,far)` component (a terrain, a foliage) stays on with what hangs from it, and the
  library that draws it keeps only its far shape, without colliders or the near part.
- `scene.spawn` and asset loading are transactions.
- **What fails at runtime is a problem of an entity**, not a counter: a library that rejects a
  request or cannot do something calls `core.report` with the entity, a `library.cause` code and
  how to fix it, and `engine.diagnostics` lists it
  ([problems](../mirai-core/references/core.md#problems)). A game reports its own the same way.
- **Everything the server decides goes through `fixed` functions** that run on the server or
  without a network; a client only applies (`core.owned`: without `core.Remote`).
- When changing a library of `engine/*`, update its section of this skill and the consumers
  (`demo/`, `templates/`, `tools/demo_content`) in the same task.

## Verification

- Types of the affected library and its consumers:
  `mirai check demo/game -collection:plugins=plugins`, `mirai check templates/game/game` and
  `mirai check tools/demo_content -collection:plugins=plugins`.
- `engine/input`: `mirai test engine/input` (map built with the defaults, read by id, names that
  the code does not declare, devices per slot, re-arming, contexts and their capture, chords in
  `input.mirai` and the problems of a rejected request); the chord tie-break, in
  `mirai test std/input`.
- `engine/scene` and `engine/save`: `mirai test engine/scene engine/save` (instantiating leaves the
  poses to propagation; a prefab spawned again from the form its World keeps is the one read anew;
  a save returns without `Id` what it borrowed and does not touch the tables
  of the session; a load that fails halfway leaves the world as it was; the header and thumbnail
  of a slot; the rotation and triggers of autosave; the checkpoint; the slot that waits for its
  thumbnail). The real thumbnail is seen in Play in an editor session.
- `engine/volume`: `mirai test engine/volume` (order, edge, add and replace); its values, with the
  tests of `engine/audio` (reverb), `plugins/physics/runtime` (`gravity_test.odin`),
  `plugins/vfx/runtime` (`fields_test.odin`) and the capture of `church` (fog).
- Plugin `vfx`: `mirai test plugins/vfx/runtime`
  ([verification](../mirai-world/references/vfx.md#verification)).
- `engine/audio`: `mirai test engine/audio`, with assets in a temporary folder and the mixer in
  memory: voices per world, the repeated tick that does not sound again, the choice of a set, the
  buses according to `Audio_Settings`, the listener in the `View` with its velocity, occlusion with
  a fake query and the reverb of the volumes. The per-voice filter and the reverb tail:
  `mirai test audio`.
- Extraction and visual meshes of `engine/render`: [GPU
  validation](../mirai-rendering/SKILL.md#verification).
- Integration: [demo verification](references/demo.md#verification) and the `templates/game`
  template without GPU for 120 frames ([the player](../mirai-core/references/host.md#the-player)).
- After touching the demo assets: [generated content](references/demo.md#generated-content).
