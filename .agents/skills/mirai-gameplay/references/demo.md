# The demo project and the templates

## Templates

`mirai new <folder> [--template T]` copies `templates/<T>`; `mirai new --list` describes them with
the first line of their README.

- **`empty`**: `game/` with one component, one function and one action, a `sample` plugin with its
  `runtime/` and a Surface program in `shaders/`.
- **`game`**: playable game with the public API (character with physics, destructible wall,
  animated interface, sound, save and networking). Its
  [README](../../../../templates/game/README.md) explains the files and how to play it with
  `--server` and `--connect`.

Both bring `.mcp.json`, which gives an agent outside the editor the `mirai` MCP server,
`.claude/settings.json`, whose `Stop` hook ends the turn of Claude Code in the editor
([outside the editor](../../mirai-editor/references/ai-tasks.md#agents-outside-the-editor)), and
the `AGENTS.md` the agents of the project keep, which `CLAUDE.md` brings to Claude Code.

The scene, the prefab and the `.ui` of `templates/game` are its source: files kept in the
repository and written through the API. Its `tools/content` writes only what code generates (the
badge and the hum); `mirai content <project>` runs it. It does not go into the game: only `game/`,
`editor/` and the plugins are compiled.
## Demo

[`demo/`](../../../../demo) is a complete project:

- `project.mirai`: start scene `control/control.scene`; plugins `spawn`, `cinematics`,
  `physics`, `destruct`, `multiplayer`, `paint`, `terrain`, `animation`, `previews`,
  `navigation`, `behavior` and others. The `destruct_multiplayer` bridge
  activates on its own.
- `settings.mirai`: `Spawn_Settings` with `"players": true` and `UI_Settings` in English and
  Spanish, with the prompt pack of `prompts_kenney`.
- `cook.mirai`: the prefabs and materials that only code picks by path.
- `render_check.mirai`: the fixed views that `mirai render check` measures
  ([render check](../../mirai-rendering/references/verification.md#render-check)).
- `game/` and `assets/`, with the art sources beside what they make.

Scenes:

- **`ai`**: the AI level, the [arenas](#ai-arenas) around a plaza with the player and a sign per
  exhibit. It has the arenas' places, so in Edit the Navigation mode shows tiles, areas and links;
  in Play and Simulate, also the paths of the chosen agents.
- **`control`**: person and dog with physics, human/AI possession, camera per body, shared aerial
  view and a 100-tick intro with a cinematic ([Control](#control)).
- **`main`**: gallery of bounced light, metals and paints of increasing roughness, glass that
  refracts, masked materials, imported models, a door and a sample that changes material.
- **`showcase`**: HUD (`UI_Screen`) and sign over the elevator (`World_Widget`) that show the
  `Showcase` component; elevator moved by an `.anim` and a speaker with spatial sound.
- **HUDs of the other scenes**: each is a component a `frame` step writes only when what it shows
  changed, and a `.ui` with the styles of `assets/interface/hud_kit.ui`, on the body it is of
  (`Player_Hud` on `Player.scene`, `Person.scene` and `Dog.scene`, `Portal_Hud`, `Raft_Hud`) or
  on an entity of its scene (`Dig_Hud`, `Vfx_Gallery_Hud`, `Physics_Gallery_Hud`, `Gallery_Hud`).
- **`interface`**: the interfaces of `assets/interface/` over the `Interface_Demo` component
  (`game/interface_demo.odin`). H changes the HUD variant (`minimal`, `neon`), M opens the options
  menu (controls, tooltip, two buttons from another `.ui` with overrides, language), I the
  inventory (a grid of objects that are dragged between slots or to the hand) and T a conversation
  with a merchant. The buttons of each screen respond to the action that opens it, and the texts
  are in English and Spanish. The objects and the conversation are [game data](#game-data).
- **`destruction`**: destructible walls and blocks that the cubes the player throws break.
- **`dig`**: a grass Volume over earth over rock with ore pockets, which digs a pit by itself when a
  Play starts; Use digs where the player looks. It raises dust of each layer's color, drops pieces
  of earth and rock and ore drops that are picked up on passing (`Terrain_Dust` and
  `terrain_debris`).
- **`physics`**: gallery of 23 stations.
- **`vfx`**: gallery of the `vfx` plugin (`game/vfx_gallery.odin`), five exhibits that the camera
  tours in Play (left and right, Home the overview) with their title and explanation in the HUD:
  particle lights with shadow, particles from the skin and bones of Mirai walking, impacts that the
  game gives to a channel (E fires a burst), a smoke column in a 3D grid with `Particle_Volume`
  (`shaders/smoke_plume.slang`) and sprite materials. The effects translated from Unreal are in
  the imported-maps project, not in the demo. The `fluids` plugin lives in its own repository,
  tomaszbk/mirai-fluids.
- **`raft`**: a raft and boxes that float in the sea, a beach that rises to an island and the
  first-person swimmer (prefab `Swimmer`, with `Walk`, `Swim` and `Diver`): it jumps into the water,
  swims on the surface and under it, climbs back and drowns if it runs out of air. The sea is drawn
  by the [`water`](../../mirai-world/references/water.md) plugin, with waves, shore foam and
  splashes.
- **`ocean`**: a water material program.
- **`animation`**: the only animation scene, a hall that the player walks with Mirai, with a
  numbered station per feature: clips, events, root motion, a prop moved by a clip, layers,
  additives, actions, motion matching, physical locomotion with foot IK, warping,
  constraints, retargeting, rigs ([rigs](../../mirai-animation/references/animation-rigs.md)),
  procedural gait, morphs
  ([morphs](../../mirai-animation/references/animation-morphs.md)) and budget. Each plays in a
  loop; E adjusts the ones with a 3D panel ([Animation gallery](animation-gallery.md)).
- **`lights`** and **`night`**: many point lights without a sun, for the cost and noise of direct
  light; without spawn points, in Play they are seen from their camera.
- **`church`**: nave with volumetric fog (`fog` plugin) and stained glass windows that a sun crosses
  and draws in the haze and on the floor
  ([glass in the light](../../mirai-rendering/references/materials.md#medium-filter)). Its haze is
  even because the render check takes as boiling what changes in a still view; **`church_fog`** is
  the same nave with the haze in wisps that move on their own through the beams.
- **`portal_chamber`**: the [portal game](#portal-game).
- **`horror`**: a dark room with lamps on a switch (`use`) and a flashlight (`flashlight`), with
  fixed exposure: the dark stays dark when turned off.
- **`decals`, `deform`, `monitors`, `portals`, `portal_lab`**: scenes of the render plugins
  ([what each one shows](../../mirai-plugins/references/render-plugins.md#verification)).

## Code (`demo/game`)

- **`game.odin`**: the demo's actions (`Action`, `@(actions)`) with their default bindings
  (`Demo_Actions`), and the components of the scenes.
  - `game_use` reads the actions of the body's seat: opens doors, changes the material sample and
    throws a cube with `scene.spawn`.
  - `game_projectiles` (`stage="react"`) damages with `destruct.damage` what the cube touches, and
    destruction applies it in the same tick.
  - `game_glow` is the only writer of `Tint`: it also serves the portals' buttons, the lamps of
    `horror` and the fade of the physics gallery.
  - The cameras of the prefabs are `Camera_Follow`: `Eyes` the player's, `Orbit` with `aim` those of
    the person and the dog, whose `Drivable` walks them with `move_relative_to` `View`.
- **`control.odin`**: `Follow` is an AI that takes the body behind its leader while no seat drives
  it.
  - `game_dogs` (`server`) gives each person a dog with `Follow`; `game_follow` writes the
    `Move_Input` of the body that follows.
  - `game_seats`: the dog leaves with its leader; `switch_body` makes the seat drive the dog and the
    person follow it; `overhead_view` uses `cam.camera_override` with a transition and
    `camera_mode` passes the body's camera to the next mode (`cam.camera_mode`).
  - `game_follow`: the AI writes the `Move_Input` of the body that follows its leader.
  - Person and dog are `Character`s relative to what their camera asks: the seat that drives one
    walks it; that of one without a seat is left to its AI, and on a client that of the others, to
    the network.
  - `gallery_move_inputs` (`animation_gallery.odin`, `after="gallery_player_move"`): the
    `Move_Input` of the animation gallery's bodies. The look of a body that crosses a portal is
    turned by the `portals` plugin.
  - `game_barker`: counts a bark when its seat presses `bark` or the intro asks for it with the
    marker `intro.bark`.
- **`raft.odin`**: a swimmer's air is a rule of the demo over `head_depth`: `Diver` spends oxygen
  with the head under the surface and recovers it outside; without air, `raft_breath` puts it back
  on the raft of `Raft_Game` with full air. `raft_hud` shows how it moves, its air and the notice
  that it drowned.
- **`portal_game.odin`**: [portal game](#portal-game). Components `Portal_Gun`, `Portal_Mouth`,
  `Portal_Surface`, `Portal_Cube`, `Grill`, `Floor_Button`, `Grill_Passes`; functions
  `portal_gun`, `portal_links` (only writer of `Portal` and `Hidden`), `portal_chamber`
  (`stage="react"`), `portal_hud`. `game_doors` and `game_glow` also serve the buttons
  (`door_opened`).
- **`dig_site.odin`**: `Dig_Site` (on the terrain: how many balls it digs by itself and every how
  many ticks) and `dig_site` (`stage="react"`, nothing on a client), which requests the balls with
  `terrain.dig`, adds to `Dig_Inventory` the cubic meters per material of
  `terrain.Terrain_Digs` and picks up the `Dig_Pickup`s that a `Player` touches; `dig_hud` shows
  the inventory. It is the game's rule: the engine has no inventory.
- **`horror.odin`**: `Light_Switch`, `House_Lamp` (its `Point_Light` gives its intensity while its
  switch is on and its flicker leaves it) and `Flashlight` (follows the first player's look);
  functions `horror_switches` and `horror_lights` (`stage="react"`); `game_glow` turns on each
  lamp's globe with `horror_glow`.
- **`ai_arena.odin`**: the [AI arenas](#ai-arenas).
- **`showcase.odin`**: `Showcase` and `game_showcase`; the sign's button (`UI_Events`) stops and
  resumes the elevator, and each `top` marker (`Animation_Events`) counts an arrival.
- **`animation_gallery*.odin`** and **`animation_motor.odin`**: the
  [animation gallery](animation-gallery.md#code-demogame).
- **`physics_gallery.odin`**: `Physics_Gallery`, its camera selection and requests reproducible by
  trigger, input E and reset by R.
  - Removal and the Size debris keep fragments for 6 s and fade them over the next 2 s, reading the
    physical timer from `game_glow` (only writer of Tint).
  - Particles come from the public destruction event, omitting Remove events. Counts and prefabs
    stay in the `World`: a rollback brings them with the copy and repeats them the same.
  - Internal Strain keeps a collection suspended until the second E; the recorded geometry station
    starts paused.

Each component assigned to objects in the editor carries its `NAME_DEFAULT`; scenes store the
values.

## AI arenas

An entity with `AI_Arena` builds in Play, where it is, agents that decide with
[minds](../../mirai-world/references/behavior.md#enemies-with-minds), walk or fly through
navigation and perceive through behavior, and its place (`arena_place`, in pieces), unless `place`
is false because the scene has it, as the `ai` scene does, so that the navmesh exists in the
editor.

- `Horde` (`agents` zombies): a block of 3 by 3 buildings of 3.5 and 4.5 m with streets of 2.5 m.
  Zombies wander, chase the runner they see (`nav_follow`) jumping from roof to roof and falling to
  the street through the generated links, and bite it three at a time (attack tokens); the rest
  surround it until a spot is freed. A cart (`Arena_Cart`, kinematic with `Nav_Obstacle`) parks on a
  street: the tiles under it are redone. With `Horde_Waves` more arrive in [waves](#game-data) at
  the `Spawn_Point`s of an edge street, which have `players` off.
- `Firefight` (`agents` per squad): two squads of tactical bots in a walled yard. Each soldier
  shoots with one of two tokens per enemy, takes cover on the side of a wall chosen by a place
  query over the cover offers (that its enemy does not see, close and with little enemy
  influence), reloads, goes for ammo and health to the crates on its side, operates the turret on
  its side and sounds the alarm, which its squad hears: smart objects that it reserves while using
  them.
- `Boss`: a boss in phase one picks a strike, charge or summon by score and finishes each attack;
  under half its health it moves to combos (steps it chooses according to where the hero is); the
  hero stuns it with a field of its `Boss` that wins over everything else and, dead, it gets up
  after 3 s.
- `Swarm` (`agents` drones): a yard split by a wall that hangs from 3.5 m to 14 m and leaves the air
  on both sides, with pillars and an air `Nav_Bounds`. Drones with `Fly` and the zombies' mind fly
  after the runner and go down under the wall to cross; when wandering they also go up and down.
- `Paths` (`agents` guards): they patrol their points; climb a platform by a ladder (a manual
  `Nav_Link` of type `Ladder`, which asks for `ABILITY_LADDER`), go down by the drops the build
  generates, go around a blocked `Nav_Area` and the cart that parks in their lane, and vault one at
  a time a fence that crosses the yard (a `LINK_VAULT` link that the game crosses, with its smart
  object).
- `Senses` (`agents` listeners): bells (`Arena_Bell`) ring in turns behind walls; the listeners,
  who barely see, go to the one they hear with the zombies' mind and forget it.
- `arena_think` runs the minds of each kind (`zombie`, `soldier`, `boss`, `guard`) and carries the
  boss's health; `arena_targets` moves the runner and the hero, and `arena_carts` moves the carts
  and rings the bells. The agents receive a `core.Id` so that `behavior.inspect` and `nav.agent` can
  name them.

## Game data

The demo shows how a game builds its rules over `.records` tables
([game data](../../mirai-core/references/core.md#game-data)): the engine brings no
inventories, dialogues or waves, and these are demo code that can be copied and changed.

- **Inventory** (`interface_demo.odin`): a slot of `Interface_Demo` stores the `Item` row
  (`assets/interface/items.records`) and how many units it has; name, icon and rarity are read from
  the
  row in the chosen language. Dropping an object on another equal one completes its stack up to the
  row's `stack`.
- **Conversation** (`interface_demo.odin`): `Dialogue_Line` says who speaks, what, and which line
  follows; `Dialogue_Choice` is an answer to a line, with a flag by name that it requires, another
  that hides it and another that it sets. The answers of a line are the rows that name it, in their
  order, so in the grid they are added without touching the line. `Interface_Demo.talk` is the line
  it starts with.
- **Waves** (`ai_arena.odin`): `Horde_Waves` in the `Horde` arena sends zombies after those the
  arena builds. Each `Horde_Wave` says when, how many and how often, and names the next wave; one
  that names an earlier one repeats it. Each zombie appears at the next spawn point without
  players (`spawn.spawn` with no seat), and the prefab of that point (`ai/Walker zombie.scene`,
  `Runner zombie`, `Brute zombie`) is its kind.
- What is shown of a row (names, texts) is redone only when `records_generation` of its table or
  the language changes, so editing a row during Play is seen in the next tick at no cost to the
  others.

## Local multiplayer

`control.scene` carries an `inp.Local_Multiplayer{players=2}`, which applies with `mirai play`
without `--players`; in the editor the Play selector rules. `input` creates one seat per player,
each receives its person through `Spawn_Settings.players` and `engine/camera` splits the screen. In
Play, F1 releases the mouse and the click that returns it chooses who receives keyboard and mouse.

## Generated content

The scenes and prefabs of the demo are authored assets, changed with `scene.write`,
`mirai scene write` or the editor; no code writes them. `tools/demo_content` writes what code
computes and gives the same bytes on every run:

```sh
mirai content demo
```

A `--<part>-only` flag after `--` regenerates only one part
(`tools/demo_content/main.odin`).

- `--control-only`: the intro clip of `control`. `--physics-only`: the fractures, their meshes,
  the baked cuts, the dust and the ragdoll rig of `physics`.
- `--raft-only`: the particles of the sea of `raft`.
- `--features-only`: the meshes of the render plugins' scenes, the blockout slabs and the decal
  images.
- `--ai-only`: the horde's wave and zombie-kind tables.
- `--interface-only`: the icons of the items, the tables of items and of the conversation
  (`tools/demo_content/records.odin` writes a table with fixed ids) and the `.strings` of their
  texts, in English and Spanish.
- `--dig-only`: the dig terrain, its layer materials and its dust.
- `--animation-only`: imports Mirai and writes what the [animation gallery](animation-gallery.md)
  uses: the locomotion and gallery clips of Mirai and their programs, the taller Mirai and its
  baked clips, the spider, the rig chains and the morph jelly. Contracts:
  [animation plugin](../../mirai-animation/references/animation.md).

Content:

- **Skies**: whole-sky images of 4096×2048 in `assets/sky` (`sky_day`, `sky_sunset`,
  `sky_overcast`, `sky_night`). A scene's `Sky` entity is turned around the vertical so that the
  image's sun has the heading of the scene's `Sun`, at the height it has in the image. Overcast
  and night have `disc` off.
- **Scene light**: the lights of a scene compare as in a unit where a white surface that faces a
  light of 1 shows 1, times one factor of nits per unit for the whole scene, so sun, lamps, sky,
  background and emission compare alike.
  - Scenes with lamps, by day or by night: the lamps stay at plausible candelas (50 cd per unit)
    and the sun and sky as dim beside them as the demo has them: by day they are the light of dusk
    (50 to 200 lux), which the light meter exposes like a noon; a manual exposure has to be that
    of that light, not that of a sunny day.
  - Scenes lit only by the sun (`animation`, `physics`): the sun gives 100000 lux.
  - Panels and screens emit their brightness and give the light of one π times brighter.
- **Scene brightness**: the one their art direction gives them, as compensation over the light
  meter (the `Exposure` entity, a scene-wide `View_Volume`): `physics` +2,
  `portals` +1, the template +0.75, `main` +0.6, `animation_features` −0.75, `showcase` −1,
  `monitors` −1.5 and `portal_lab` −2.5. `night` has fixed exposure, Manual at EV100 3.5:
  its lamps are wells of light in the dark and no compensation works from all its views. The
  others, the light meter alone: `lights` used to be clipped and `skeletal`, without light. No demo
  camera carries `Exposure`: the viewport and the game expose the same.
- **Imports**: each image is a source beside the materials that show it (`assets/surfaces/bricks`,
  `assets/sky`, `assets/gallery`), read as its sidecar says; each model is a source beside a
  folder with its materials and the prefab of its nodes (`assets/gallery/plant.gltf` and
  `assets/gallery/plant/`). The textures and the meshes are not versioned: they are in
  `demo/.mirai/imported`, which `mirai build` makes again from the sources.
  Re-importing keeps the ids, which the sidecars list
  ([identity](../../mirai-imports/references/imports.md#identity-and-reimport)), and what the
  demo generates over what was imported reads them from there (`imported.odin`); what it generates
  on its own uses `asset.content_id`. What did not change is kept
  ([cache](../../mirai-imports/references/imports.md#import-cache)).
- **Blockout**: floors, walls and edges are `assets/blockout/slab_*.mesh`, a box per size with UVs
  in metres (a scaled primitive would stretch the image); the tool rebuilds each from the size and
  the metres a unit of UV covers that its name gives, in centimetres. The image of the `church`
  stained glass is generated by `scripts/demo_church_glass.py`, with colors that survive the
  averaging of the haze and the bounce.
- **Authored assets** (with `scene.write`, the editor or `mirai asset set`): every scene and
  prefab, the `.ui`, the model prefabs and the materials of `assets/surfaces`.

## Portal game

`portals/portal_chamber.scene` uses the
[`portals`](../../mirai-plugins/references/render-plugins.md#portals) plugin. The player
(`Portal player.scene`) carries `Portal_Gun`; its capsule has `dominance` 1: it pushes the cubes
and they do not push it.

- **Shooting.** `portal_blue` and `portal_orange` fire a ray from the eyes that crosses an open
  portal once. If it hits a panel with `Portal_Surface` whose collider is a `Box` (or the frame of
  a portal's hole in it), `portal_fit` puts the opening on that face, with its up according to the
  wall or the look, shifted so that it fits and does not step on the other portal; if it does not
  fit, it opens nothing. `portal_links` joins the two openings and gives them their wall, which the
  plugin cuts.
- **The cube.** `grab` lifts the `Portal_Cube` in the crosshair and carries it in front of the eyes;
  if the look enters a portal and the cube is on the other side, it carries it where the portal
  takes that point. It is released on its own if it ends up far from its place or if the player
  stands on it. The cubes are bullets: the sweep of a thrown cube finds thin walls and grills.
- **The room.** A pit with a portal at the bottom launches the player through the other exit; a
  belt carries a cube to a button (trigger) that opens its door; the glass is `one_way`; the grill
  at the exit threshold is a thin trigger: whoever crosses it loses the portals and a cube returns
  to where it started, like one that falls out of the level.

## Control

The `control` scene walks through the contract of [control](control.md) and of
[cinematics](cinematics.md).

- Each player receives a person at a `Spawn_Point` and an AI dog that follows it.
- `switch_body` makes the player drive the dog and the AI take over carrying the person behind.
- `overhead_view` toggles, with a transition, a camera shared through a seat override.
- `camera_mode` passes the body's camera through the presets, each time with a transition.
- `aim` brings the prefab's `Person aim camera`, a camera with the `Aim` preset and a
  `Camera_Activation`; the person walks sideways looking toward it.
- The intro is a `Cinematic`: a clip with two cameras as actors, a marker and two shots (a cut and
  a blend, markers on the cameras); it blocks the input of the focused player.

## Networking

The demo is a networked game with a dedicated server and no network code of its own
([multiplayer](../../mirai-networking/references/multiplayer.md)): `--server` and `--connect`, or
Play > Network in the editor.

- What is replicated of each body is its `@(component, replicated)` components.
- `multiplayer` seats each connection, `spawn` gives it its person, whose owner is the connection,
  and the server gives it its dog. When the connection leaves, `spawn` destroys the person and its
  dog leaves with its leader.
- A client does not make bodies or dogs appear: its seat drives the person it predicts; those of the
  others arrive interpolated. The server has no local players.
- Doors, samples and thrown cubes are not replicated: each end simulates them on its own.

## Verification

```sh
mirai check demo/game -collection:plugins=plugins
mirai check tools/demo_content -collection:plugins=plugins
mirai play demo --headless --validation --frames 64 --capture bin/play-demo.png
mirai play demo --headless --scene showcase/showcase.scene --frames 120 \
  --capture bin/play-showcase.png
mirai play demo --server --no-gpu --until-empty
mirai play demo --connect 127.0.0.1:27500 --headless --players 1 --frames 600 \
  --capture bin/play-client.png
```

- Look at the captures. The server stays running; the client is launched in another terminal when
  the server reports the port.
- Control: `--input` script without a window (walk with `W` after the intro and `Tab` to switch to
  the dog). The capture shows the AI dog behind the person and, afterwards, the camera behind the
  dog. Over the network, the server's `--status` reports two objects per connection.
- Tests of `demo/game`: `animation_gallery_controls_test.odin`,
  `animation_gallery_matching_test.odin` (the matching station with the Mirai assets),
  `animation_motor_test.odin`, `portal_game_test.odin` (`portal_fit`) and
  `grounding_physics_test.odin` (grounding with real bodies, which needs the `animation` and
  `physics` plugins). Real clips are checked with the demo integration.
- Mouse, keyboard and gamepad (shooting, jumping, throwing the cube) are tested by the user.
- That a change did not alter what is generated: run `tools/demo_content` and check that
  `git status demo/assets` shows no differences.
