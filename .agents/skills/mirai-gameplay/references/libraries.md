# Game libraries

Engine runtime packages under `engine/`: `scene`, `render` (`mirai:engine/render`), `inp`
(`mirai:engine/input`), `cam` (`mirai:engine/camera`), `audio`, `gui`, `save`, `volume`.
Controllers/seats/cameras: [control.md](control.md). Animation, physics, multiplayer, spawn,
cinematics and streaming are optional plugins.

## `scene`

Bridges `asset.Scene` documents (`Entity_Id`, named components) and live `World` tables:
- `instantiate(world, asset, types, desc)`: creates rows (`Id` unless `transient`, `Name`,
  `Transform`, known components; migrates schema diffs by field name, fills defaults; leaves
  `World_Transform` to propagation or `core.world_of`; rows settle next `settle`). `Report` tracks
  `migrated`, `unknown`, `dangling`, `missing`.
- `load` / `replace`: atomic swap via temporary cleaned `World` (`core.world_clear`), settled and
  propagated. `load_untrusted` enforces `max_bytes`, `max_entities`, component allowlist,
  `serial.value_check`, internal entity refs, registry assets and shipped-only `Scene_Reference`.
- `spawn(spawner, path_or_id, at)`: instantiates a `Prefab` (`Not_A_Prefab` -> problem
  `scene.spawn`, returns `NONE`). Never blocks on disk: unloaded prefabs return a root with
  `Prefab_Pending` (`scene.spawn_pending`, once per prefab until one is placed) filled by
  `scene_spawns` once background `assets_warm_begin` completes (`spawns_fill(all=true)` blocks
  for editor API). `Prefab_Preload` names prefabs only code spawns: the load reads them and the
  prefabs they place before tick 0; a scene change stops stale warms (`spawns_forget`). Roots carry
  `Prefab_Instance`; worlds cache `Prefab_Forms`. Project loads resolve stale prefab overrides;
  cooked builds load resolved files directly.
- `capture` / `save`: serializes IDed entities (depth order; `sections:true` includes section
  children for saves; preserves unknown components from `previous`; zeroes `transient` fields).
- **Scene changes & phased loading (`loading.odin`):** `scene.request` / `request_restart` push
  `Scene_Requests` (`scene_requests` emits `Scene_Results` and `scene.load` problems; first run
  loads `--scene` / `start_scene` or exits `PLAYER_SCENE`). Background workers
  (`LOAD_WORKERS_SHARE`) read/decompress/instantiate and upload assets under frame budget
  (`Scene_Loading`, `Section_Loading`, `Load_Waits` for library prep); `load_step(all=true)` runs
  synchronously.
- `Error`: `No_Assets`, `Not_Found`, `Invalid`, `Cycle`, `Not_A_Prefab`, `Corrupt`, `Duplicate_Id`,
  `Out_Of_Memory`, `Write_Failed`, plus untrusted `Too_Large`/`Not_Allowed`/`Out_Of_Range`/
  `Unknown_Reference`.

## Scene references

`Scene_Reference{scene, rule, state, extents}` (`reference.odin`, `sections.odin`) mounts a child
scene beneath an entity without copying into the parent document (`Id` combined via `id_in`).
Deleting/disabling removes the section; removing `Scene_Reference` dismantles it in place.
Singleton `Sky`/`Sun` arrive disabled in sections/prefabs.
- **Rules & states:** `With_Document`, `Manual`, or `Spatial`; states `Active`, `Loaded` (mounted
  under `Disabled` + `Section_Held`), or `Unloaded`. `section_request` queues `Section_Requests`;
  `scene_sections` runs up to `SECTION_LOADS` concurrent loads prioritized by source containment/
  distance (cancels unneeded loads; cycles -> `Cycle` + `section_path`; `Section_Views` overrides
  editor view only).
- **Hold & dormant (`scene_holds`, `dormant.odin`):** seats entering an unloaded section get
  `Section_Held` (kinematic hold unless `Section_Settings.wait == .Free`). Unloading retains
  modified/added entities as `Dormant` (`Disabled`), deleted ones as `Tombstone`, `Roaming` under
  root, and `@(component,far)` entities (terrain/foliage) as `Far_Kept` (or loads them alone via
  `far_load_begin`). Reloading reconciles dormant/tombstone/far state before join.
- **Persistent & cross-section refs (`unresolved.odin`):** `core.Keep` survives full scene
  replacement. Cross-section `Entity` fields wait in `Unresolved_References` until target loads
  (prefabs stay dangling). Saves include `Section_Member` rows so loaded sections persist.

### Sources and residency

`scene_sources` (`sources.odin`) builds `Streaming_Sources` from active view (with `SOURCE_PREFETCH`
extrapolation unless `View.cut`), seat bodies and `Streaming_Source` entities (`revision` bumps on
`SOURCE_MOVE`; overflow -> `scene.sources`). Shared distance residency (`box_near`, `resident`,
`RESIDENT_KEEP`) drives sections, terrain chunks and foliage cells. Simulation systems read
view-independent `Simulation_Sources` (`scene_simulation_sources`, `fixed`) for deterministic AI,
navmesh and foliage collision.

## Plugin `streaming`

- `streaming_sections` (`frame`) drives `Spatial` sections from `Streaming_Sources` (`load`/`active`
  distances, `RESIDENT_KEEP` hysteresis). `streaming_crossings` (`fixed`) reparents awake bodies
  crossing `Section_Boxes` (keeps world pose/velocity via `core.Places`; needs matching scales;
  re-attaches `Roaming` entities). `navigation` retains tiles of inactive `Spatial` sections.
- `streaming.status` (read-only): sources (with `ahead`), `Streaming_Settings`, loads under way
  (`Section_Loads`, far forms too) and each section's rule, asked/streamed/current state and far
  form, with loaded/on/far counts.
- **HLOD far mesh (`streaming_far`, `cook/far`):** displays `Section_Proxy` + transient
  `Mesh_Renderer` when a section is not active (warmed asynchronously up to `FAR_WARMS`; sections
  wait via `scene.section_stay`). Shipped games read cooked `asset.far_mesh_id`; dev projects build
  on demand into `project.FAR_CACHE` keyed by `asset.far_key` (`streaming_far_build`). Includes
  static opaque/cutout meshes (`far.FAR_ERROR` DAG cut, paged like archive meshes); skips hidden/
  dynamic/skinned meshes, terrain and foliage.

## `render`

- **Visibility:** `Hidden` hides rendering/lighting while physics/gameplay run (`core.Disabled`
  disables completely); `Drawn_Elsewhere` delegates mesh drawing (e.g. fractured pieces);
  `Mesh_Renderer.shadows=false` skips shadow casting.
- **Lights (shine `-Z`, `KHR_lights_punctual` units, `indirect`/`scattering` multipliers, `shadows`
  default on):** `Sun` (`@(component,single)`, lux, optional `height_fade`), `Point_Light`
  (candelas, `radius` of the sphere, `length` of a tube along +X; the entity scale is not read),
  `Spot_Light` (as a point, `angle` 1..89 deg, `inner` share of it lit whole before the fade,
  0.8 by default and 1 a hard edge, optional projected `texture`),
  `Rect_Light` (nits, entity XY scale, `texture` or `Light_Emission` from mesh slot),
  `Bounce_Light` (`@(component,single)` global indirect scale).
- **Camera & exposure:** `Camera` (`View_Camera` overrides `active`, handles blends/fade/
  `own_hidden`); `Exposure` (`Auto`/`Manual` + EV `compensation`, overrides `View_Volume`).
- **Sky (`@(component,single)`, `sky.odin`):** `luminance` + `image` or `atmosphere` (tracks active
  `Sun`), optional `use_background`, replicable `from`/`fade` transition, or local transition via
  `render.activate` (`Environment_Requests`; invalid -> `render.activate` problem).
- **`View_Volume` (`view_volume.odin`):** per-zone `exposure`, `tint` and up to 8 post-process
  `layers` (per split-screen `Camera.slot`; given again when the layers, or a material or program
  they name, change or load late; sky/sun stay global). An enabled layer whose material does not
  load or has no PostProcess program draws nothing and is a `render.postprocess` problem of its
  `View_Volume` naming the layer.
- **`Material_Values` (`shared`) & `Material_Live` (derived):** per-entity `color`/fade, `emission`,
  named parameter/field overrides (`material_value`/`drop`, updated in place via `values_settle`),
  or texture/overlay overrides (derived content-shared material row). `Material_Live` layers
  runtime overrides (`material_live`, `material_screen`) without dirtying scenes or undo.
- **Outlines & offset:** `Highlight` (editor) overrides `Outline` (15 `Outline_Styles` styles read
  by `mirai_outline`); `Draw_Offset` smooths network visual corrections.
- **Sync & settings:** `camera_view` writes `core.View`; `render_sync` diffs via `core.changes`
  (interpolated by `Frame_Time.alpha`), storing only `drawn`/`extras` indices. Plugins hook via
  `extend.odin`. `Graphics_Settings` (`graphics_apply`) and `Display_Settings` (`display_apply`,
  game window only; bad monitor -> `render.display`) are machine settings.

## `input`

Action-based input (`Input_Map`, `Actions`, `keep` across loads): `Button`, `Axis`, `Axis2`
(unit-length key diagonals) producing `Action_State` (`down`/`pressed`/`released`/`tapped`/
`holding`/`held`/`value`/`vector`; tick-rate-independent tap/hold).
- `input_seats` (`fixed` `input`) evaluates devices per seat without allocating (deterministic on
  rollback); `Frame_Actions` evaluates `core.Frame_Input` for cameras/UI in `late`.
- `input_map_build` merges code defaults with `Input_Settings` (project/player layers; bad action
  -> world problem). Helper constructors: `binding_key*`, `binding_mouse_*`, `binding_gamepad_*`;
  call `input_map_compile` after manual edits. Read via `down|pressed|...|vector(input, .Action)`.

## `audio`

Syncs mixer voices to `Audio_Source`s, listeners to `Audio_Listener`s (up to
`AUDIO_LISTENERS_MAX`, split screen) or `View`, buses to
`Audio_Settings`, plus room reverb, medium and occlusion (game loop only):
- **Sources (`audio_sources`, `late`):** plays `.sound`/`.sound_set` (spatial attenuation + `-Z`
  directivity or 2D `pan`; invalid range/NaN -> `audio.source`). `voices_assign` ranks by priority
  and gain at the nearest listener (`VOICE_KEEP` hysteresis); overflow voices run virtually on
  mixer clock without stealing. Each spatial voice is heard from one listener slot: the nearest,
  switching only when another is nearer than `LISTENER_SWITCH` (0.88) of the distance to its own;
  a switch re-tests its occlusion at once from the new one. With more than one listener the
  mixer drops listener velocity from Doppler.
  `pitch` changes speed and tone; paused `core.Clock` pauses world voices (not one-shots).
- **Layers & parameters (`layers.odin`):** a source holds `Sound_Voices`, one voice per sound of a
  Layered set, started in one mixer batch on one frame `LAYER_LEAD` ahead and retuned together;
  `voices_assign` gives an entry all its voices or none, and a stolen layer sends the others
  virtual to restart in step. `Audio_Source.parameters` (by name: `audio.parameter_set`) glide
  over the set's `glide`; its curves (`asset.sound_set_shape`) shape gain, pitch and low-pass of
  each layer when the values move.
- **One-shots:** `audio.play` offers to `Sound_Requests` within the room of `SOUND_REQUESTS` that
  `audio_requests` keeps (more are dropped and reported as `audio.requests`; it drains at end of
  `fixed`/`late`; skipped past `max_distance` of every listener; heard from the nearest). A
  `fixed` tick of the game loop plays a key once: `(tick, by, sound)`, or `(tick, sound, place)`
  within `SOUND_SAME_DISTANCE` when `by` is `NONE`. `Sounds_Played` (`host,by_world`, a ring of
  `SOUNDS_PLAYED_CAPACITY`, never rolled back) keeps the keys, so a resimulated tick skips what it
  played and plays what only the correction asks; a clock that goes back clears it. A `Layered`
  set starts every layer in one `mixer_batch_begin`/`mixer_batch_end` batch, each at its sample
  delay.
- **Cues:** `audio.Cue` (sound, birth channel, `align_up`) and `audio.cue_play` (by the entity,
  through the keyed dedup, with a birth on the channel its owner resolved at load) are the one
  path of the cues of a `.character` (`anim.Marker_Cue`) and of ability windows and effects
  ([cues](../../../../docs/game/audio/cues.md)).
- **Reverb & medium:** `Audio_Reverb` zone volume blends at each listener, averaged, onto
  `reverb_bus`; `Audio_Medium` (per listener slot, written by `water`) overlays underwater reverb.
  The master low-pass applies only while every listener is under a medium (`medium_lowpass`, the
  highest cutoff); else the voices of submerged listeners lose highs through their EQ
  (`medium_bands` -> `mixer.lowpass_bands`).
- **Occlusion (`Audio_Occlusion`):** raycasts via `core.World_Query` (`OCCLUSION_SAMPLES`,
  `TRANSMISSION_SURFACES`, `Audio_Material.transmission`) fading `Audio_Source_State.occlusion`.
- **Buses & state:** named `Audio_Bus` (`master`, `music`, `effects`, `voice`, `ui` + game buses),
  project `Audio_Settings` (dB gain, `filters` chain, `delay`, ducking, reverb, acyclic sends else
  `audio.send`; invalid filter -> `audio.filter`). `Audio_Settings.stream_capacity` (0:
  `STREAM_CAPACITY_DEFAULT`, clamped to `STREAM_CAPACITY_MAX` with `audio.stream_capacity`) is
  applied by `audio_buses`, which reports refused streams once per frame (`audio.streams`, from
  `streams_busy`).
- **Snapshots (`snapshots.odin`):** `Audio_Settings.snapshots` name per-bus gain dB, filter cutoffs
  and reverb wet dB. Weights add up as rooms do: the game's state whole (`Audio_Mix`,
  `audio.snapshot_blend(mix,"pause",0.5)`; an unknown name -> `audio.snapshot`) and each
  `Medium.snapshot` by weight and share of listeners (`medium_snapshots`; `water` names
  `"underwater"`, absent from the settings: nothing). `audio_buses` blends `Mixer_Buses.blend`
  (`mix_blend_step`: dB and wet linear, cutoffs by octaves; the medium over `REVERB_FADE`). Game
  code never names a snapshot for where the listener is.
- **Player options:** machine `Audio_Volumes` & `Audio_Output` (fallback + `audio.output` on
  unplug). `Voices` (`host,by_world`) isolates worlds; failures report
  `audio.{sound,bus,voices,memory}`.

## `anim`

Optional `animation` plugin (`anim "plugins:animation/runtime"`):
[animation.md](../../mirai-animation/references/animation.md).

## `gui`

Game `.ui` runtime over per-world `Gui` (`host,by_world,shared`; game loop only; games cannot add
`ui`-phase steps—use `@(draw="name")` on `Draw` nodes, missing -> `gui.draw`):
- **`UI_Screen`:** screen overlay ordered by `order` (`player` 0 binds to seat/body owner or whole
  window). `UI_Input` modes: `Passive` (HUD), active (highest order), `Modal` (blocks seat actions,
  releases cursor, or activates `input_context`). Remembers focus; keeps hidden screens building
  until exit animations set `present=false`.
- **`World_Widget`:** `preview` renders in Edit; `Overlay` draws per-player billboard/screen panel;
  `Mesh` renders into `Material_Live` texture (`material_screen`) while visible and raycasts mesh
  UVs (`render.mesh_ray`, respects `depth_test`); `Interactive` takes focus/nav when aimed.
- **Bindings, events & requests:** copies bound storage/component fields when row stamps move
  (storage controls commit directly; component edits wait for tick events). `UI_Events` delivers
  frame events (`Clicked`, `Changed`, `Submitted`, `Dragged`, `Dropped`, `Finished`, `Back`, `Menu`)
  once via `gui_events_deliver` (or `gui_events_frame` when paused; rollback ring
  `DELIVERED_CAPACITY`). `UI_Requests` queues `gui.play_animation` and `gui.focus`.
- **Cursor:** the game writes `UI_Cursor` (`hidden`, a `.tex` per `ui.Cursor` shape), one per
  window; `gui_frame_end` declares it with the hovered shape to `host.app_cursor_game` only while
  the game has the input (not `game_input_blocked`/`game_mouse_off`). `host/cursor.odin` is the
  one writer of the OS cursor: relative mouse > editor while it holds the pointer (bars, input
  released, pointer off `app.scene`; never a game image) > hidden > shape; it reads an image only
  when it, its file (`content_hash`) or the density changes
  ([cursor](../../../../docs/game/ui/cursor.md)).
- **Settings & caching:** `UI_Settings` (`reference`, `source` lang, `prompts`, `prompt_images`)
  and `UI_Preferences` (`language`, `scale`). `Game_Source` tracks last input device family, prompt
  textures, camera views, `Particles` nodes and sounds. Unchanged static contexts skip rebuild
  (`Gui.skipped`) and keep unchanged screens (`Gui.kept`). Problems: `gui.{asset,bind,action,
  screens,widgets,mesh,events,draw,play,request,draws,nesting}`.

## `save`

Slot saves in `<user_folder>/saves/<slot>.save` (`saves_serve`, `input`, game only):
- **Requests (`Save_Requests` -> `Save_Results`, bad -> `save.request`):** `request_save`,
  `request_checkpoint`/`load_checkpoint`, `request_autosave`, `request_load`, `request_delete`,
  `request_new_game`, `request_end_game`, `request_label` (`Invalid_Slot`/`Invalid_Label`).
- **Format & thumbnails:** header + PNG thumbnail + `scene.capture` (IDed entities, non-transient
  fields, `save_prepare` hook; storages not saved—persist in components) + borrowed ids. Hooks run
  on a partial snapshot copying only entities and their own library's tables (hooks may only write
  components of their own library; unsettled worlds still copy whole). Captures immediately; waits
  up to `THUMBNAIL_WAIT` frames for view thumbnail then compresses (MDC2) and writes atomically in
  a job. `thumbnail_texture` / `thumbnail_release` display slot thumbnails in `.ui`
  (`THUMBNAIL_TEXTURES` cap).
- **Autosave & load:** `Save_Settings` rotates `autosave 1..N` on interval, scene change or `Manual`
  section activation (server/singleplayer only, never when `Save_Game` is off). Loading swaps world
  atomically (`scene.replace`, restoring clock; client load/save -> `Unavailable`; handles change).
- **Profile & options:** `@(storage,persist)` flat storages auto-save to `profile.save` on rest
  (problem `save.profile`); machine settings save via `host.app_options_save` to `settings.mirai`.

## `volume`

`Volume` is the sole spatial shape (unbounded, box, sphere, plane, or closed `Spline` outline);
`Spline` (`spline.odin`) is the sole path (`spline_sample`, `spline_lay`, `spline_nearest`).
Behavior lives in sibling components (`Zone`, `Fluid`, `Force_Field`, `Strain_Field`, `Nav_*`,
`Foliage_Bender`, `Fog_Volume`, `Audio_Reverb`, `View_Volume`, `Wind`, `Gravity`):
- **Sensor:** bounded `Volume` without `Collider`/`Rigid_Body`/`Character` acts as physics overlap
  sensor (`Physics_Events.overlap_begin`/`end`).
- **Zone blending (`volume.odin`, `shaders/include/volume.slang`):** applies matching volumes from
  lowest to highest `zone.priority` (largest first on ties), blending over `zone.blend` or adding
  (`zone.mode`). Unbounded volumes in sections clip to `Scene_Reference` bounds. `Index` accelerates
  per-tick queries (`Gravity`, `Wind`); `at` serves single-point frame queries.
- **`Wind`:** `speed` along `-Z` + `gusts` (read by foliage & particles, not physics).
- **`Gravity`:** `Down` (`-Y`) or `Center` (planet inverse-square outside `radius`, linear inside;
  default `GRAVITY_WORLD`), shared by physics and `vfx`.

## `vfx`

GPU particles live in the [`vfx`](../../mirai-world/references/vfx.md#game) plugin.
