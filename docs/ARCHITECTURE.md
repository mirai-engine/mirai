# Mirai architecture

Mirai is a native 3D engine written in Odin, with an editor, operable by people and agents through
code and API/MCP. The general rules are in [AGENTS.md](../AGENTS.md).

## Idea

A game is an in-memory struct and a list of functions that transform it.

- **A piece of data has one owner.** What several functions read is written by one of them, once.
  The physics solver owns the pose of a body: its step writes the pose to `Transform` and the
  velocity to `Motion` once per tick, for the bodies that moved, and the renderer reads them there.
  Nobody else writes them: the game moves a body with a request.
- **A function receives exactly what it uses.** The compiler prevents touching anything else.
- **The rules are verified.** What an agent might not know becomes a type error, a build error or
  a runtime failure with a message that says how to fix it.

The public API expresses the game's data and choices with names, references and default values.
Compiled indices, caches, work buffers and scheduling belong to the implementation and are
resolved when the data is prepared. Detailed diagnostics are queried explicitly. The same surface
serves people and agents, with no second API that replicates the functionality.

## Four concepts

- **Component**: a flat struct with `@(component)`; one row per entity in a `core.Table(T)`.
  It reaches the game if it is in a library.
- **Storage**: a flat struct with `@(storage)`; one per world.
  It is the state of a library, a queue of requests (`queue`), the occurrences it reports
  (`core.Events` fields) or the loop parameters. It reaches the game if it is in a library.
- **Library**: a package with components, storages and game functions. It reaches the game.
- **Plugin**: libraries (`runtime/`) plus an `editor/` package with editor-only components,
  storages and functions. Only its libraries reach the game.

A project's game is a library (`game/`) and, for its own tools, an `editor/` package. The engine
is libraries (`engine/*`) and an editor that is the engine's editor part.

The attributes belong to the compiler (`-custom-attribute`): `component`, `storage`, `step`,
`loops`, `stage`, `after`, `before`, `server`, `shared`, `locks`, `host`, `by_world`, `copy`,
`swap`, `free`, `replicated`, `setting`, `single`, `description`, `queue`, `keep`,
`persist`, `reset`, `net_message`, `from`, `reliable`, `params`. The CLI and `cook/build` pass them
on their own; a manual build needs the flag with `build.CUSTOM_ATTRIBUTES`.

## The generated world

`mirai generate <project>` reads the engine's libraries, the project's and those of its active
plugins, and writes to `<project>/.mirai/gen`:

- `world` packages: `editor_world` and, for the shipped game, `shipped_world` (nothing from the
  editor nor the development plugins).
- Two root packages: `editor`, which exports `mirai_project_info` (it returns the
  `core.World_Info` of its world) for the editor and the player, and `game`, the `main` of the
  shipped game.

Each `world` has:

- `World`: the entities, one `core.Table(T)` per component and a field per storage.
  It is copied into a new world for Play and saved in scenes and saves. Opening a document and
  network rollback replace it with `host.app_world_replace`: the copy is made into another world,
  which is then swapped in without allocating, so a copy that runs out of memory leaves nothing
  half done.
- `Shared`: the `@(storage, host)` storages, belonging to the application and never copied (GPU
  state, the renderer's scene). What it keeps of each world (the network session, voices,
  interfaces, derived meshes, its problems) is `by_world`: one value per world, looked up by
  `core.World_Id`, the handle the application gives it on creation and that copying or swapping
  worlds does not move. Each function receives that of its world, so several worlds in a frame do
  not step on each other, and it is released in that world's `release` phase.
  `World` stays plain data copied in blocks; sockets and pointers live outside.
- `Editor` (only in `editor_world`): the components and storages of the editor packages.
- The call of each function, the loops per phase and `info()`.
  `info()` returns the `core.World_Info`, which describes types, tables, storages, functions and
  loops for generic code (editor, scenes, network, saving) without knowing the game's types.
  With it `core` makes, frees, copies, swaps and clears any world (`core.world_init`,
  `world_destroy`, `world_copy`, `world_swap`, `world_clear`: entities, rows and derived
  storages); `world_init` and `world_copy` return `false` without memory and leave a world that
  `world_destroy` frees.

**Reflection.** The engine cannot find a project's types with `type_info_of(typeid)`: they live in
a library the project compiled.

- `core.Table_Info` and `core.Storage_Info` carry `info:^runtime.Type_Info`, taken in the library
  that declares the type.
- Every generic traversal of world data receives that pointer and not a `typeid`:
  `raw_get`, `raw_find`, `raw_value`, `raw_add`, `value_copy`, `value_free`,
  `serial.schema_add_type_info`.
- `core.world_layout_hash` summarizes sizes, offsets and fields of the whole world;
  two libraries of a project with the same hash run on the same memory.

`mirai build` compiles the project's libraries and game with the generated world.
The generated code is not edited and can be read and debugged like any other.
Each package is imported in it as `p_<declared name>` (`p_core`, `p_multiplayer`, `p_game`), so
none clashes with the world's identifiers.
The field of each type is its `snake_case` name, with the package in front if two types coincide.

**Data attributes.**

- `@(component)`: a table in `World` (in `Editor` if the package is an editor one).
- `@(component, description="...")`: optional description in the type's metadata, available in
  the inspector and the API; it does not enlarge its rows.
- `@(component, shared)`: the table admits several writers.
- `@(component, locks="core.Transform")`: owner of those rows in the entities that have it.
- `@(component, replicated)`: the network sends its values in the entities it replicates.
- `@(component, single)`: the world uses one at a time (`Sky`, `Sun`): when the table settles, the
  row that was last turned on or added stays on and the others are turned off with their values;
  the active one is row 0. Which row is on belongs to each end of a network session.
- `@(net_message)`: a struct the network sends as a message (`from="client"`, `reliable`).
- `@(storage)`: a value in `World`; a single library writes it.
- `@(storage, queue)`: a queue of requests; many functions push and the owning library takes.
- `@(storage, events)`: what a library reports on each tick; the others read it.
- `@(storage, shared)`: several libraries write it, in loop order.
- Clearing a world (loading a scene or a save, opening a document) returns to their start the
  storages derived from its entities (by default; `@(storage, reset="f")` gives the procedure)
  and leaves the `@(storage, keep)` ones, run state, and the settings. What a save must keep goes
  in a component: it is saved and its `Entity` values are remapped.
- `@(storage, persist)`: a `keep` that is player progress, not of a save; the `save` library
  stores it in the player profile.
- `@(storage, host)`: a value in `Shared`.
- `@(storage, host, by_world)`: a value in `Shared` for each `World`, in a `core.By_World`.
  Functions receive it like any storage (`^S`, `core.Ref(S)`) and get that of their world; the
  world receives it on creation and loses it after its `release`.
- `@(storage, setting)`: a project setting; its value comes from `settings.mirai` when the world
  is created and the editor shows it. With `setting="machine"`, a machine setting, which the
  engine's file also stores on this machine
  ([settings](../.agents/skills/mirai-projects/references/projects.md#project-settings)).
- `@(storage, copy="f")`, `@(storage, free="f")`: package procedures that copy (`-> bool`, `false`
  without memory) or free what the storage contains, instead of `core.value_copy` and
  `core.value_free` (which reach dynamic arrays and slices, but not maps or pointers).
  `@(storage, swap="f")` swaps the contents of two worlds without allocating, instead of their
  bytes. `@(storage, copy=false)`: the storage is neither copied nor swapped.

**Initial values.**

- A new row created by generic code (adding a component from the editor) starts at the constant
  `NAME_DEFAULT` or at the procedure `name_default()` that the package declares for the type; the
  generator links them in `Table_Info.default`.
- A storage starts at its own when its place is initialized.
- Without them, zeros. A saved scene reads the values it saved.

## Functions and loops

```odin
@(step="fixed", stage="react")
door_move :: proc(
    doors:core.Read(Door), states:^core.Table(Door_State),
    transforms:^core.Table(core.Transform), requests:^Door_Requests, time:core.Time,
) {...}
```

- `@(step="<phases>")`: `input`, `fixed`, `frame`, `late`, `ui`, `render`, `release`.
  Several phases separated by spaces run the function in each one.
- `@(loops="game editor")`: which loops it runs in.
  By default `game` in a library and `editor` in an editor package.
- `@(stage="react")`: the part of the phase it runs in, of a fixed order (`begin`, `input`,
  `intent`, `apply`, `simulate`, `react`, `end`); by default `intent`, the game logic. No numbers:
  between packages that do not know each other, the stage orders.
- `@(after="a b")` and `@(before="c")`: order within the stage. Position first (engine libraries,
  plugins in dependency order and the project's; files and declaration); a function runs after
  those it waits for
  ([order](../.agents/skills/mirai-core/references/generator.md#order)).
- `@(server)`: only where the rules are decided (a single-player game or a server); a client
  neither runs nor resimulates it.
- Parameters are bound by type:

| Parameter | Meaning |
| --- | --- |
| `^core.Table(C)` | Writes the table of component `C` |
| `core.Read(C)` | Reads the table of `C` |
| `^S` | Writes storage `S` |
| `core.Ref(S)` | Reads storage `S` without copying it |
| `S` | Reads a copy of storage `S`; for small ones (`Time`, `Input`, `View`) |
| `core.Stamp(S)` | Asks `core.touched` whether storage `S` was written since it looked |
| `core.Ref(core.Entities)` | Reads which entities are alive |
| `core.Commands` | Creates and destroys entities, with rows of any component |
| `core.World_Ref` | The whole world by reflection: scenes, saving, network, editor |
| `^host.Assets`, `^host.Frame_Extras`, `^render.Renderer`, `^audio.Mixer`, `^jobs.Job_System`, `runtime.Allocator` | A part of the application: its assets, what is added to the frame, its renderer, its mixer, its job system, its allocator |
| `^host.App` | The application itself: its worlds, its window and views, its clock, its content |

The generator rejects with a message:

- a parameter without a table or storage;
- two writers of a non-shared table;
- two libraries that write a storage that is neither `queue` nor `shared`;
- a parameter with a default value (the generator binds all of them);
- an `after` that does not exist;
- a cycle;
- a repeated function name;
- an editor function that asks for the `game` loop;
- a `fixed` function that asks for something from the editor;
- a `ui` or `render` function the game depends on
  ([dedicated server](../.agents/skills/mirai-core/references/generator.md#dedicated-server)).

**Phases.**

- The game loop runs `input`, then `fixed` zero or more times (fixed step; network rollback runs
  it again with `core.Time.resimulating` and it may only touch `World`), and then `frame`, `late`,
  `ui` and `render`. The clock of each world is its `core.Time`, which is copied with it; what
  belongs to the frame (`core.Frame_Time`, `core.Frame_Input`) is `copy=false` and a copy does not
  overwrite it.
- The editor loop runs the same with `fixed` once per frame and `dt` 0.
- A dedicated server (`--dedicated`) runs neither `ui` nor `render`, which belong to whoever
  watches.
- `release` belongs to no frame: it runs once, when the application frees a `World`, with the
  functions of the game loop, before destroying it.
- A tool that advances only a part of a world (a preview's physics, the animation of a copy) runs
  the functions of some libraries in a phase with `core.world_run`, with the loop's binding and
  settle; nobody binds parameters by hand.

**Between libraries.**

- A library does not write another's table or storage: it sends a request through a `queue`
  storage (the owning library takes it) and reads events from it. A table or storage that several
  write says so (`shared`) and each one receives it with `^` in its signature.
- To create an entity with components from several libraries, a function receives
  `core.Commands`: it creates and destroys entities and gives them rows they do not have
  (`core.commands_add`), and what waits at the end of the function is read and finished with
  `core.commands_added` or `core.staged`. `scene.spawn`, the `spawn` plugin, terrain, destruction
  and portals use it.
- `core.World_Ref` is left for code that does not know the types beforehand: loading scenes,
  saving, replicating over the network, binding an interface to a component by name and the editor
  ([reflection](../.agents/skills/mirai-core/references/core.md#world-reflection)).

## Tables

```odin
Table :: struct($T:typeid) {
    values:[dynamic]T, entities:[dynamic]core.Entity,
    stamps, rows, pending, added, version, layout, owners, locks, name,
}
```

- `values` and `entities` are parallel and dense, with the enabled rows first: traversing a
  component is traversing `0..<core.count(t)`.
- `core.get(t,e)` on a `^Table` gives the row to write or `nil`; on a `Read`, the value.
  `core.has(t,e)` answers in constant time.
- **Turning off without losing data.** `core.disable(t,e)`/`core.enable(t,e)` turn a component off
  and on; `core.Disabled` turns off an entity and what hangs from it, except its identity,
  transform and hierarchy. What is off keeps its values and no loop function sees it; reflection
  (editor, scenes, network) sees everything
  ([disabled](../.agents/skills/mirai-core/references/core.md#disabled-entities)).
  `Hidden` is something else: it only stops drawing.
- **Adding and removing are applied when the function ends** (`core.add`, `core.remove`,
  `core.destroy`): no traversal or pointer is invalidated inside a function.
  Created entities have a handle right away; their components appear for the next function, and
  the same function reads and writes them where they are expected (`core.added`, `core.staged`),
  without settling the world in between.
- Between functions, handles are kept (`core.Entity`: index and generation), never pointers.

**How a change is detected.**

- Each write raises the table's `version` and the written row takes that value as its stamp
  (`stamps`). These write: `core.get`, `core.at`, `core.free` or `core.staged` on a `^Table`,
  `core.writable` (all rows), `core.raw_get` and `core.raw_touch` by reflection, and the `add`
  that replaces a row.
- Reading (`Read`, `core.row_of`, `core.raw_find`, traversing `values`) does not stamp.
- `layout` rises when rows are added or removed or the whole table is replaced.
  `version` and `layout` only grow, also in a table copied over.
- Whoever reads keeps what it saw in a `core.Seen` and `core.changes` gives it the rows stamped
  since then and the entities whose row stopped being enabled or was removed while off, or asks it
  to read everything if the table was replaced. It is also valid to keep the version it saw and
  reread everything if `layout` moved. `transforms_propagate` recomposes what was written and what
  hangs from it, `render_sync` moves or tints only those instances, and the editor's journal (undo
  and collaboration) compares only those rows with its single image of the edited world.
  Nothing is recomputed if nobody wrote.
- The network server publishes a replicated table when its version moved and the protocol sends
  the fields that changed against the last confirmed state.
  The index by `Id` follows its table with `core.changes`; animation uses `layout`+`version` as
  its stamp.
- A storage has no version: whoever watches it keeps a counter of its own.
- Asking for a row and leaving it unchanged makes its readers work: what only looks, reads.
- With `-define:MIRAI_CHECK_WRITES=true` the generated world checks, after each function, that it
  asked for every row that changed in the tables it receives with `^`.

## Owners per entity

A `@(component, shared)` table (like `core.Transform`) admits several writers in loop order. A
component with `@(locks="core.Transform")` makes its library the owner of those rows in the
entities that have it:

- If another component already owns the same row, adding fails with an error that names both.
- The others write with `core.free(t,e)`, which returns `nil` on rows of another owner.
- The owner compares with what it wrote and warns with the entity's name if someone wrote the
  same.

## Build

The engine is compiled into dynamic libraries, one per group of layers, with declarations that
allow compiling each library and the project separately. The editor and the player load the
project's world through
`World_Info`. The distributed game is compiled from source and excludes the engine-time packages.

- Targets, collections, outputs and binary updates:
  [projects](../.agents/skills/mirai-projects/references/projects.md#engine-binaries).
- Usage commands:
  [common commands](../.agents/skills/mirai-projects/references/projects.md#common-commands).
- Reload of an open project and its relation to the layout:
  [Build and reload](../.agents/skills/mirai-editor/references/editor.md#build-and-reload).

## Errors

- Build errors are shown by the running editor, which only reloads or restarts if the build
  succeeds.
- Expected ones are return values or enums.
- What a loop function could not do (an asset that does not load, an invalid request, out of
  memory) is a problem: `core.report` stores it in the world's `core.Problems` with the entity, a
  code and a message that says how to fix it, and `engine.diagnostics` lists it
  ([problems](../.agents/skills/mirai-core/references/core.md#problems)). Statistics count what
  is not a failure.
- Rule violations (`core.fail`) are logged with names and, in a test build, stop the program.
- Bugs stop the program with the assertion that failed and where.

## Threads

- Each phase runs its functions one after another on the thread of the loop
  ([order](../.agents/skills/mirai-core/references/generator.md#order)), and a function's
  parallelism goes inside it (`std/jobs`): physics, destructible cutting and asset loading use the
  application's threads.
- Background threads (audio, network, asset loading) only talk to the world through queues that a
  loop function drains.

## Package map

Numbered layers; a package only imports lower layers.

- **0** `std/*`: standard library (base, math, serial, compressor, jobs, spatial, geom, anim, ai,
  input, subprocess, ui_format). It does not depend on the engine. `std/compressor` decodes LZ
  streams and `std/compressor/bc7split` restores BC7Split blocks; `std/compressor/lz` encodes the
  streams with `std/compressor/lz/entropy`, `match` and `parse`, on top of the decoder's format,
  at the levels a program saves with. `std/ui_format` is what the structure of a `.ui` is judged
  by (node kinds, override fields, limits), which `ui` builds and `asset` checks without
  importing each other.
- **1** `project`: `project.mirai` and `plugin.mirai` manifests, the layout of a project.
- **1** `net`, `asset`, `ui`, `audio`, `rhi`: network transport, asset formats, UI, mixer and GPU;
  independent of each other. `rhi/shared_device` is the device the GPU tests share; only tests
  import it, also the GPU tests of `rhi`, in `rhi/tests`.
- **2** `render`, `platform`: hybrid renderer and SDL3. `render/abi` declares the constants the
  renderer shares with its shaders, on top of `asset` alone: `cook/shaders` imports it to write
  them for the shaders, since the tool cannot import `render`.
- **3** `core`: entities, tables, queues, owners, transforms and hierarchy, `Time`, `Input`,
  `View`, world reflection, the authority of this end (`Network`, `Remote`, `owned`), the motion
  and pose that another owner requests (`Motion`, `Pose_Target`), the requested places (`Places`,
  `place`, the only way to teleport) and world queries (`World_Queries`).
- **4** `host`: the application (window, device, renderer, mixer, assets, content, shaders), the
  game and editor loops and the player, which does not know the network: it leaves the arguments
  it does not read to the libraries (`Launch`).
- **5** `engine/*`: the engine libraries `scene`, `volume` (the regions of the world, the per-zone
  values in them, how they combine, and wind), `render`, `audio`, `gui`, `input` (devices,
  actions, seats, driving and `Move_Input`), `camera` (each seat's camera and the game view),
  `save`.
- **6** `cook/*`: engine-time; world generator and project build, `cook/cache` (what is built,
  stored by what makes it), `cook/compressor/lz` (the optimal levels of the LZ encoder, which only
  a cook writes with), textures (with the encoders `cook/compressor/texture`, of BC1 to BC7, and
  `cook/compressor/bc7split`), importers, shaders, `cook/workspace` (a worktree's main
  checkout, the dependencies folder, shared cache and locks between processes), `cook/image` (PNG
  to RGBA8, difference, statistics, montage, crop, enlargement and pixels of captures),
  `cook/movie` (the files of a recording: half EXR, 16-bit PNG and WAV) and `cook/install` (a
  project's plugins that come from git, and the catalog). The importers are `cook/import` (core,
  no formats), one package per format (`cook/import/obj`, `gltf`, `usd`, `fbx`, which reads with
  the C library of `third_party/ufbx`) and `cook/import/sources` (the table of formats and
  `import_source`, on top of `cook/prefab`). `cook/author` is what an interface or a scene
  is authored with as a nested document, between its text and the file of the asset, on
  top of `asset`, `ui`, `core`, `host` and `engine/*`: the editor's `ui.*` methods and `mirai ui`
  and `mirai scene` go through it, and the presets an entity is made from are there.
- **6** `editor` and `editor/*`: engine-time; the editor, the JSON-RPC and MCP API,
  collaboration, prefabs and AI, whose chat search uses the C library of `third_party/sqlite`.
- **7** `plugins/<name>`: first-party plugins, imported as `plugins:<name>/runtime` and
  `plugins:<name>/editor`. What only some games use is a plugin and adds nothing to the core, so
  physics, game networking and player spawning are plugins too. A plugin imports the layers below
  and only the plugins in the `dependencies` of its `plugin.mirai`, which the generator enforces;
  one that only joins two others is an automatic bridge and neither of them knows the other. A
  plugin extends the renderer through `engine/render`, never by importing `render`. The solver is
  its own package (`plugins:physics/runtime/sim`, without `core`), and `physics` and `multiplayer`
  understand each other only through `core` tables (`Pose_Target`, `Motion`).
  `plugins/*/plugin.mirai` lists the plugins with their parts and dependencies;
  [first-party plugins](../.agents/skills/mirai-plugins/references/plugins.md#first-party-plugins)
  says what each one does.
- **no layer** `tools/mirai`: the `mirai` CLI; `mirai --help` lists its commands.
- **no layer** `demo`, `templates`, `tools/demo_content`: the demo project, the `mirai new`
  templates and the generator of the demo's assets.
- **no layer** `shaders/`: the single Slang source.

The low-level packages `render`, `audio` and `std/anim`, and the `physics` solver, are declared
`mirai_render`, `mirai_audio`, `mirai_anim` and `mirai_physics` so they do not clash with the
libraries that use them; these import them with aliases (`gpu`, `mixer`, `lib`, `sim`). For the
same reason `cook/compressor/bc7split` is declared `bc7split_encode`, apart from
`std/compressor/bc7split`, and `cook/compressor/lz` is declared `lz_optimal`, apart from
`std/compressor/lz`.
