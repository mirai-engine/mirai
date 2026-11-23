# The demo project and the templates

## Templates

```sh
mirai new --list
mirai new my_game --template game
mirai content my_game
```

- **`empty`**: minimal `game/` (1 component, step, action), `sample` plugin (`runtime/`), and a
  Surface shader.
- **`game`**: playable sample (physics character, destructible wall, animated UI, audio, save,
  networking); see [README](../../../../templates/game/README.md).
- Both ship `.mcp.json`, `.claude/settings.json` (`Stop` hook for
  [external agents](../../mirai-editor/references/ai-tasks.md#agents-outside-the-editor)),
  `AGENTS.md`, and `CLAUDE.md`. Authored scenes/prefabs/`.ui` are tracked; `tools/content` runs
  via `mirai content <project>` and is excluded from game builds.

## Demo

[`demo/`](../../../../demo) holds `project.mirai` (start scene `control/control.scene`, plugins
including `spawn`, `cinematics`, `physics`, `destruct`, `multiplayer`, `paint`, `terrain`,
`animation`, `previews`, `navigation`, `behavior`; `destruct_multiplayer` auto-activates),
`settings.mirai` (en/es, `prompts_kenney`, no player prefab), `cook.mirai`, `render_check.mirai`
([render check](../../mirai-rendering/references/verification.md#render-check)),
`captures.mirai`, `tests/flights/`
([profiling](../../mirai-agent-api/references/methods.md#profiling)), `game/`, and `assets/`.

| Scene | Coverage |
| --- | --- |
| `ai` | [AI arenas](#ai-arenas) around a plaza; navmesh visible in Edit, paths in Play/Simulate |
| `control` | Person + AI dog, possession, cameras, 100-tick intro cinematic ([Control](#control)) |
| `main` | GI bounce, metals/paints, glass, masked materials, imports, door, material swatch |
| `showcase` | `UI_Screen` HUD + `World_Widget` (`Showcase`), `.anim` elevator, spatial speaker |
| `interface` | `Interface_Demo` (`H` HUD variant, `M` options, `I` inventory, `T` dialogue; en/es) |
| `destruction` | Destructible walls/blocks broken by thrown cubes |
| `dig` | Grass/earth/rock `Volume` + ore, `Terrain_Dust`, `terrain_debris`, `Use` digs |
| `physics` / `vfx` | 23 physics stations; 5 `vfx` exhibits (`shaders/smoke_plume.slang`; `fluids` is external `tomaszbk/mirai-fluids`) |
| `raft` / `ocean` | Buoyant raft/boxes, `Swimmer` (`Walk`/`Swim`/`Diver`), [`water`](../../mirai-world/references/water.md); water shader |
| `animation` | Mirai [animation gallery](animation-gallery.md) (clips, motion matching, IK, [rigs](../../mirai-animation/references/animation-rigs.md), [morphs](../../mirai-animation/references/animation-morphs.md), budget) |
| `lights`, `night` | Many point lights without sun; no spawn points (viewed from scene camera) |
| `church`, `church_fog` | Volumetric `fog` + stained [glass in rays](../../mirai-rendering/references/materials.md#glass-in-rays) (static vs moving wisps) |
| `portal_chamber` | [Portal game](#portal-game) |
| `horror` | Fixed-exposure dark room with `use` switches and `flashlight` |
| `decals`, `deform`, `monitors`, `portals`, `portal_lab` | [Render plugin scenes](../../mirai-plugins/references/render-plugins.md#verification) |

Scene HUDs share `assets/interface/hud_kit.ui` and write their HUD component in a `frame` step
only on change (`Player_Hud`, `Portal_Hud`, `Raft_Hud`, `Dig_Hud`, `Vfx_Gallery_Hud`,
`Physics_Gallery_Hud`, `Gallery_Hud`).

## Code (`demo/game`)

| File | Key components & steps |
| --- | --- |
| `game.odin` | `@(actions) Action`, `game_use` (doors/swatches/cube throw), `game_projectiles` (`react`, `destruct.damage`), `game_glow` (sole writer of `Material_Values`) |
| `control.odin` | `Follow`, `game_dogs` (`server`), `game_seats`, `game_follow` (`input.move_set`), `game_barker` (`bark` / `intro.bark`) |
| `raft.odin` | `Diver` oxygen over `head_depth`, `raft_breath` respawn on `Raft_Game`, `raft_hud` |
| `portal_game.odin` | `Portal_Gun`/`Portal_Mouth`/`Portal_Surface`/`Portal_Cube`/`Grill`/`Floor_Button`/`Grill_Passes`; `portal_links` sole writer of `Portal` and `Hidden` |
| `dig_site.odin` | `Dig_Site`, `dig_site` (`react`, server-only: `terrain.dig`, `Dig_Inventory` from `Terrain_Digs`, `Dig_Pickup`), `dig_hud` |
| `horror.odin` | `Light_Switch`, `House_Lamp`, `Flashlight`, `horror_switches`, `horror_lights` (`react`), `horror_glow` |
| `ai_arena.odin` | [AI arenas](#ai-arenas): `arena_think`, `arena_targets`, `arena_carts` |
| `showcase.odin` | `Showcase`, `game_showcase` (`UI_Events`, `Animation_Events` `top` marker) |
| `animation_gallery*.odin`, `animation_motor.odin` | [Animation gallery](animation-gallery.md#code-demogame); `gallery_move_inputs` (`after="gallery_player_move"`) |
| `physics_gallery.odin` | `Physics_Gallery` (E trigger, R reset, 6s+2s debris fade via `game_glow`, rollback-safe counts) |

Editor-placed components declare `NAME_DEFAULT`; scenes store authored values.

## AI arenas

`AI_Arena` builds [mind](../../mirai-world/references/behavior.md#enemies-with-minds)-driven agents
in Play (and `arena_place` unless `place=false` as in `ai`, where navmesh is pre-built). Agents
carry `core.Id` for `behavior.inspect` and `nav.agent`.

- **`Horde`**: 3×3 buildings, roof-jump/drop `nav_follow`, 3 attack tokens, kinematic `Arena_Cart`
  (`Nav_Obstacle`), `Horde_Waves` on non-player `Spawn_Point`s.
- **`Firefight`**: 2 squads, 2 shoot tokens/enemy, cover place queries, ammo/health crates,
  turrets, and alarms as reserved smart objects.
- **`Boss`**: phase 1 scored attacks (strike/charge/summon), phase 2 (<50% HP) combos, stun
  override, 3 s revive.
- **`Swarm`**: air `Nav_Bounds`, `Fly` drones ducking under a hanging wall.
- **`Paths`**: patrol guards using `Ladder` `Nav_Link` (`ABILITY_LADDER`), drops, blocked
  `Nav_Area`, cart detour, `LINK_VAULT` smart-object fence.
- **`Senses`**: blind listeners investigating alternating `Arena_Bell` sounds.

## Game data

Demo `.records` examples ([game data](../../mirai-core/references/core.md#game-data)); views
refresh only when `records_generation` or language changes:

- **Inventory** (`interface_demo.odin`): `Item` rows (`assets/interface/items.records`), stack
  merge on drop.
- **Conversation** (`interface_demo.odin`): `Dialogue_Line` + `Dialogue_Choice` (flag
  require/hide/set), starting at `Interface_Demo.talk`.
- **Waves** (`ai_arena.odin`): `Horde_Waves` / `Horde_Wave` spawning point prefabs (`Walker`,
  `Runner`, `Brute`) via `spawn.spawn` with no seat.

## Local multiplayer

`mirai play --players 2` (or Play selector) creates two local seats, spawns two persons in
`control.scene`, and splits the screen (pad per orbit; F1 releases mouse, click refocuses slot).

## Generated content

Authored assets (scenes, prefabs, materials, particles, `.records`, `.ui`) are edited via API/CLI
or editor. Code-generated assets are deterministic via `tools/demo_content/main.odin`:

```sh
mirai content demo
# Single part: --physics-only | --features-only | --interface-only | --dig-only | --animation-only
mirai content demo -- --physics-only
```

- **Skies**: 4096×2048 (`assets/sky`: `sky_day`, `sky_sunset`, `sky_overcast`, `sky_night`),
  rotated so image sun matches `Sun` heading (`disc` off on overcast/night).
- **Lighting & exposure**: lamp scenes keep 50 cd/unit lamps with dim 50–200 lux dusk sun/sky;
  sun-only scenes (`animation`, `physics`) use 100000 lux. Scene-wide `Exposure` `View_Volume`
  compensations: `physics` +2, `portals` +1, template +0.75, `main` +0.6, `animation_features`
  −0.75, `showcase` −1, `monitors` −1.5, `portal_lab` −2.5; `night` uses Manual EV100 3.5. No demo
  camera carries `Exposure`.
- **Imports**: source beside assets, pinned in `demo/packages.mirai`
  ([identity](../../mirai-imports/references/imports.md#identity-and-reimport),
  [cache](../../mirai-imports/references/imports.md#import-cache)). Unversioned textures/meshes
  live in the store (`imported.odin` reads manifest ids; generated assets use `asset.content_id`).
- **Blockout**: `shapes` box Solids with `uv_scale` and box `Collider`
  ([shapes](../../mirai-world/references/shapes.md)); church glass via
  `scripts/demo_church_glass.py`.

## Portal game

`portals/portal_chamber.scene`
([`portals`](../../mirai-plugins/references/render-plugins.md#portals)): `Portal player.scene`
(`Portal_Gun`, capsule `dominance` 1).

- **Shooting**: `portal_blue`/`portal_orange` trace through 1 open portal onto `Portal_Surface`
  box colliders; `portal_fit` aligns/clamps without overlapping the pair; `portal_links` pairs and
  cuts walls.
- **Cube & room**: `grab` carries `Portal_Cube` (bullet sweep) across portals, drops if distant or
  stood on. Pit launch, belt + trigger `Floor_Button` -> door, `one_way` glass, exit `Grill`
  clears portals and resets cubes.

## Control

`control.scene` exercises [control](control.md) and [cinematics](cinematics.md): player person +
AI dog, `switch_body` (Tab), `overhead_view` (V, seat override blend), `camera_mode` (C, preset
cycle), `aim` (`Camera_Activation` `Aim`), and a 2-camera `Cinematic` intro blocking focused input.

## Networking

Zero game net code ([multiplayer](../../mirai-networking/references/multiplayer.md)): `@(component,
replicated)` syncs bodies; `multiplayer` seats peers, `spawn` gives persons (server adds dogs),
cleanup follows disconnect. Clients predict only their own person; doors/swatches/cubes are local.

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

- Control: headless `--input` script (`W` after intro, `Tab` to dog); server `--status` reports 2
  objects/connection.
- `demo/game` tests: `animation_gallery_controls_test.odin`,
  `animation_gallery_matching_test.odin`, `animation_motor_test.odin`, `portal_game_test.odin`,
  `grounding_physics_test.odin` (needs `animation` + `physics`).
- Determinism: run `tools/demo_content` and verify `git status demo/assets` is clean.
