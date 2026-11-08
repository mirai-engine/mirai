---
name: mirai-core
description: Mirai data core - `core` (entities, tables, queues, `Time`, `Frame_Time`, `Input`,
  `View`, transforms and hierarchy, world reflection, runtime problems with `core.report`, typed
  game data with `@(record)` and `core.Record`), the world generator (`cook/build/world.odin`, with
  `@(component)`, `@(storage)`, `@(step)`) and `host` (application, loops, player, assets, content
  and shaders at run time). Use when declaring components, storages or loop functions, when
  touching tables, entities or `settle`, when copying or replacing worlds, or on a generator error.
---

# Mirai data core

A game is a struct in memory and a list of functions that transform it
([architecture](../../../docs/ARCHITECTURE.md)).

## Map

- Entities, tables, stamps and owners: [core](references/core.md#tables).
- Finding an entity by `Id` and giving new `Id`s:
  [identity](references/core.md#persistent-identity).
- Queues, requests and events: [queues](references/core.md#queues-and-references).
- `Time`, `Frame_Time`, `Input`, `View`, `Jumps`, pause and slow motion (`Clock`) and an entity
  that keeps its pace in it (`Own_Pace`, bullet time):
  [storages](references/core.md#core-storages).
- Role of this end of a session, `Remote`, `owned`, `Motion`, `Pose_Target` and what a world opens
  to the network: [network](references/core.md#network).
- Teleporting or placing an entity without knowing who owns its `Transform` (`place`, `Places`):
  [requested places](references/core.md#requested-places).
- Rays and spheres against the world regardless of physics (`World_Queries`, `world_query`):
  [world queries](references/core.md#world-queries).
- Transforms and hierarchy: [transform](references/core.md#transform-and-hierarchy); children,
  subtrees, ancestors and world poses: [queries](references/core.md#queries).
- Code that does not know the game types: [reflection](references/core.md#world-reflection).
- Named values that the code declares and that the data, the API and the editor name (modes,
  actions, categories; `@(names)`, `@(name_bits)`):
  [named ids](references/core.md#named-ids).
- Game data catalogs (`@(record)`, `.records`, `core.Record(T)`, `core.Records(T)`, localized texts
  of a row): [game data](references/core.md#game-data).
- What a function could not do, with its entity and how to fix it:
  [problems](references/core.md#problems).
- Attributes and their rules: [generator](references/generator.md#attributes).
- Parameter types of a function: [parameters](references/generator.md#parameters).
- Grouping parameters in a struct that several functions or a helper receive (`@(params)`,
  `core.Placer`): [groups](references/generator.md#parameter-groups).
- Settle and call of the functions: [generated
  functions](references/generator.md#generated-functions); in which order they run (stages, `after`,
  `before`): [order](references/generator.md#order); which ones run at the same time: [concurrent
  functions](references/generator.md#concurrent-functions).
- A function that only runs where the rules are decided (`server`):
  [attributes](references/generator.md#attributes).
- Application, frame, several views and profiling: [host](references/host.md#the-application); a GPU
  that stops working: [GPU failure](references/host.md#gpu-that-stops-working).
- Arguments and exit codes of the player, and how a plugin takes its own (`launch_flag`):
  [player](references/host.md#the-player).
- Meshes, materials and assets at run time: [assets](references/host.md#loaded-assets).
- Loading the library of a project: [libraries](references/host.md#project-libraries).
- Project commands and build: [projects](../mirai-projects/SKILL.md); game libraries:
  [gameplay](../mirai-gameplay/SKILL.md).

## Workflow

### Declare data and functions

1. A component is a plain struct with `@(component)`; a storage, one with `@(storage)`. No pointers
   or dynamic ownership in components. `description="..."` gives an optional description of the
   component in its metadata, without per-entity data.
2. The options of each field go in the `mirai:"..."` tag: `transient`, `local`, `readonly`,
   `hidden`, `text`, `hex` (an exact `u64` in the inspector, without going through float), `color`,
   `angle`, `unit=`, `min=`, `max=`, `precision=`, `bits=`, `section=` (inspector subtitle,
   [inspector](../mirai-editor/references/inspector.md)), `owned` (an `Asset_Id` that the scene
   generates and [saves with it](../mirai-editor/references/document.md#tabs)), `advanced` (a
   field of a setting that sizes a pool or a per-tick budget, or tunes an internal algorithm: the
   settings dialog shows it under an Advanced fold,
   [settings](../mirai-editor/references/panels.md#project-settings)).
3. A nonzero initial value is declared with `NAME_DEFAULT` or `name_default()` in the same package
   (`SPIN_DEFAULT :: Spin{...}`).
4. A loop function is a `proc` without a result with `@(step="<phases>")`; each parameter says what
   it touches ([parameters](references/generator.md#parameters)). What is received together in
   several functions goes in a `@(params)` struct that the function receives by value and passes
   whole to its helpers ([groups](references/generator.md#parameter-groups)).
5. A table that is not `@(component,shared)` has a single function that writes it, and a storage a
   single library; the others send a request through a `@(storage,queue)` storage with
   `core.Queue(T)` and read the `@(storage,events)`.
6. Create entities with components of another library: `core.Commands`
   ([commands](references/core.md#creating-with-components-of-other-libraries)), or the service of
   that library (`scene.spawn`, `spawn.spawn`). What the function created is finished in it with
   `core.commands_added` or `core.staged`, without `world_settle`. `core.World_Ref` is only for code
   that does not know the types (scenes, saving, network, editor).
7. Order: the stage (`stage="react"`; without it, `intent`) and within it `after="a b"` or
   `before="c"` ([order](references/generator.md#order)). Function names are unique across the whole
   world. What only a lone game or a server decides carries `server`.
8. `mirai generate` lists the generator errors; the generated code is read in
   `<project>/.mirai/gen/` and is never edited.

### Change `core`, the generator or `host`

1. Update the reference and the consumers (`engine/*`, `editor/`, `templates/`, `demo/`) in the
   same task.
2. A `core` field or type that changes a layout affects the
   [reload](../mirai-editor/references/editor.md#build-and-reload).
3. A new attribute follows [changing the generator](references/generator.md#changing-the-generator).

## Invariants

- The generator does not detect mutable package variables: check for them when reading.
- **One table per component, not archetypes.** The world stores a dense table per component, without
  a query engine, and `core.changes` makes each reader process only what changed.
- **The loop order is named stages, not numbers.** A function says in which part of the tick it runs
  (`stage`) and, within it, which ones it waits for (`after`, `before`), naming only functions of
  the engine or of the plugins it depends on; `order=` is an error. Between plugins that do not know
  each other the stage orders ([order](references/generator.md#order)).
- **A function touches only what it receives.** Its parameters say what it reads and writes, and
  from them comes which functions of a phase run at the same time; what it reached by another path
  (a stored pointer, the application from a `World` storage) would run alongside its writer
  ([concurrent functions](references/generator.md#concurrent-functions)).
- **What decides the rules is `server`.** A function whose whole body belongs to the server or to a
  lone game is marked `@(step="fixed",server)` instead of asking `core.Network` and returning: a
  client neither runs nor resimulates it. One that also does something at every end is split or
  asks in the body ([attributes](references/generator.md#attributes)).
- **Structural changes are applied when the function ends.** `core.add`, `core.remove` and
  `core.destroy` wait in `pending`: no walk or pointer is invalidated inside a function, and what
  waits is written with `core.added`/`core.staged`. Between functions `core.Entity` is stored,
  never pointers.
- **What is disabled does not exist for the loop.** A disabled component (`core.disable`) or one of
  an entity with `Disabled` keeps its row and its values, but `count`, `get`, `has` and `row_of`
  do not see it; walking `t.values` whole or outside `0..<count(t)` would include it. To look at or
  save everything, `raw_*` and `raw_state` ([disabled](references/core.md#disabled-entities)).
- **The hierarchy is queried in `core`**: downward with the `Hierarchy`, upward with `Parent`, and a
  world pose is written with `world_set` or `local_under`. Nobody builds their own child index or
  walks `Parent` by hand ([queries](references/core.md#queries)).
- **Whoever reads processes what changed** with `core.changes(t, &seen)`: stamped rows and entities
  that left, or `all` ([changes](references/core.md#what-changed-since-the-last-read)).
- **An `Id` is looked up with `core.entity_of`, that of an entity is read with `core.id_of` and a
  new one comes from `core.id_new`** (in a document, `asset.scene_new_id`), never by walking the
  `Id` table or with another generator. An `Id` added before the settle that settles the `Id` table
  is not found yet ([identity](references/core.md#persistent-identity)).
- **Writing is requesting the row** with `get`, `at` or `free` on `^core.Table`, `writable`, or
  `raw_get`/`raw_touch` by reflection: the row takes a stamp and its readers process it
  ([stamps](references/core.md#tables)). A direct write into `values` is seen by nobody; what only
  looks uses `Read`, `row_of` or `raw_find`, also outside the loop (editor, UI, API).
- **A `@(params)` is only a way of writing the signature.** It counts as its loose fields: it gives
  the same write rights, with one writer per datum, and what the function writes reaches it only
  once among its parameters and groups.
- **A `shared` table with several writers uses owners**: `locks="core.Transform"` makes the
  component the owner of that row; the others write with `core.free`. A lock on something that is
  not `@(component,shared)` is a generator error.
- **`fixed` is simulation** and may be repeated by rollback: it touches only `World`, never the
  editor. While it is repeated, `core.Time.resimulating` is true: what leaves the simulation is not
  repeated and what enters the tick arrives as the first time, without the game asking. A new sink
  outside the `World` that is reached from `fixed` also respects it
  ([Time](references/core.md#core-storages)).
- **The clock of a world is `core.Time`**, the only one: it is copied with it, so a Play and a
  rollback carry it with the copy, and a save stores its tick and its seconds. `core.time_advance`
  advances it after each tick; there is no other per-world clock in `host`.
- **What belongs to the frame is not simulation and is not copied.** `core.Frame_Time` and
  `core.Frame_Input` are `copy=false`: a Play, a correction and opening a document do not overwrite
  them, and nobody saves them or restores them by hand. A function reads `Time` to simulate and
  `Frame_Time` to present.
- **The engine walks world data through `^runtime.Type_Info`, never through `typeid`**: the types of
  the project live in its library. `Table_Info.info`, `Storage_Info.info`, `raw_*`, `value_copy`,
  `value_free` and `serial.schema_add_type_info` receive that pointer; `serial.schema_add($T)` is
  for types the engine knows.
- **Copying a world can fail.** `init`, `copy` and every `copy="f"` return `bool`; a world that is
  shown or simulated is replaced with `host.app_world_replace` (separate copy and swap without
  allocating), never with `clear` and `copy` on top.
- **A copy that is kept copies only what changed.** `info.copy_changed` serves a destination that is
  a copy of the same world (the rollback history and the Play one); it relies on the stamps: a world
  into which another one of a different origin was copied is copied whole
  ([tables](references/core.md#tables)). That destination is only copied back with `copy`, it never
  runs: the storages with `copy_kept` keep there only what that return trip needs
  ([attributes](references/generator.md#attributes)).
- **Clearing a world takes its derived storages to their start.** Loading a scene or a save and
  opening a document call `info.clear`; what remains is only what `@(storage,keep)` says (state of
  the run), the settings and what is not copied. What a save must keep goes in a component, never
  in a storage ([classes](references/generator.md#attributes)).
- **`World` is plain data copied in blocks.** What the application stores for each world that is
  not copied with it (sockets, pointers, mirrors of its state: voices, interfaces, derived meshes,
  its problems) is `@(storage,host,by_world)`: each function receives the value of its world (nil in
  one the application did not make), several worlds in a frame do not overwrite each other and the
  value is released in `@(step="release")`. Only what is one per application (the renderer scene,
  the mixer listener) is a plain `host` storage; it recognizes a world by `core.World_Id`, never by
  the address of the world or of a table.
- **A per-entity mirror is a `core.Entity_Map`**: it grows checking memory and releases what left
  with `entity_map_left` over `changes`, without being walked
  ([maps](references/core.md#per-entity-maps)).
- **A runtime failure is a problem, not a counter.** The function receives `^core.Problems` and
  calls `core.report` with the entity, a `library.cause` code and a message that says what failed
  and how to fix it ([problems](references/core.md#problems)). A counter remains only if it is a
  statistic.
- A library does not import one of a higher layer or editor packages.
- `core.View` is the game view. Several views in a frame: `host.app_views_set`; local split screen:
  `camera_local_views` of `engine/camera`
  ([cameras](../mirai-gameplay/references/control.md#cameras)), each player in their part of the
  drawable (`host.app_player_rect`).
- The engine does not crash on valid input ([AGENTS.md](../../../AGENTS.md#principles)).

## Verification

- `mirai check` of the touched package (`core`, `host`, `cook/build`, `engine/<library>`) and of
  `demo/game` if a contract changes. `mirai test` of the touched one: `core` (tables, stamps,
  per-entity maps, transforms, hierarchy, `Id` index, problems), `host` (input, UI bridge, assets)
  or `cook/build` (generator).
- Hierarchy or propagation: also `mirai test` of `engine/render` (hidden subtrees),
  `plugins/vfx/runtime`, `plugins/animation/runtime` (child bind) and `editor`.
- Writes without requesting the row: `"defines": ["MIRAI_CHECK_WRITES=true"]` in the manifest of a
  project; after each function, `core.fail` names the function, component and entity that changed
  without being requested. It copies tables on every function: it is not for measuring.
- CPU copies of meshes (`host/assets_geometry_test.odin`, `assets_generated_test.odin`): repeat with
  `--release` only if a failure may depend on optimization.
- Fonts, texts and prompts of the content: `host/content_interface_test.odin`.
- GPU failure: `a_lost_gpu_leaves_the_frames_running_without_drawing` (`host`, with GPU).
- Entity pool: also `mirai test plugins/physics/runtime` (scene reload with physics storage).
- `Id` index or new `Id`s: also `mirai test engine/save` (borrowed `Id`s),
  `plugins/multiplayer/runtime` (rollback and adoption), `plugins/destruct/runtime` (groups) and
  `editor` (API and collaboration).
- Authority and requested places: `mirai test core` (`place_test.odin`) and
  `plugins/multiplayer/runtime` (`authority_test.odin`).
- Indices and schema of the `World_Info`: `mirai test core`; the generated `info()`, with a real
  build of the demo.
- `single` tables: `mirai test core` (`table_test.odin`) and `engine/render` (`sky_test.odin`).
- Copy, swap or replacement of worlds: `mirai test core`, `host` and `cook/build` (cases without
  memory), `plugins/multiplayer/runtime` (rollback), `plugins/physics/runtime` and
  `plugins/terrain/runtime` (their `copy` and `swap`) and `editor` (opening a document and edit
  transaction). The copy of what changed:
  `a_copy_of_what_changed_equals_a_whole_copy_after_writes_layout_changes_and_a_swap` (`core`) and
  `history_copies_of_what_changed_equal_whole_copies_through_writes_layout_changes_and_corrections`
  (`plugins/multiplayer/runtime`).
- Game data: `mirai test core`, `asset`, `cook/build` and `host` (their `records_test.odin`) and
  `editor` (`api_records_test.odin`: CSV and references by name); the grid and `records.*`, with a
  project that declares a `@(record)`, in a session.
- Meshes with UV1 on GPU: `mirai test engine/render` in the
  [GPU environment](../mirai-rendering/references/verification.md#gpu-environment).
- Generator or build: [project verification](../mirai-projects/SKILL.md#verification).
- Concurrent functions: `mirai test cook/build` (`graph_test.odin`: collisions, barriers, stages,
  `after`/`before`, `main`), `host` (`steps_test.odin`: the same `World` with one and with several
  workers) and `std/jobs` (fixed nodes to the one that runs the graph); also
  `plugins/multiplayer/runtime` (rollback).
