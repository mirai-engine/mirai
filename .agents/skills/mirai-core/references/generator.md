# The world generator

`cook/build/world.odin` (engine-time) reads the packages with `core:odin/parser`, finds the
attributes and writes the code that joins the libraries. `mirai generate <project>` runs it;
`mirai build`, `edit` and `play` run it before compiling.

`-custom-attribute:` carries `build.CUSTOM_ATTRIBUTES`: `component`, `storage`, `step`, `loops`,
`stage`, `after`, `before`, `server`, `shared`, `locks`, `host`, `by_world`, `copy`, `swap`, `free`,
`replicated`, `setting`, `scene`, `description`, `queue`, `events`, `keep`, `reset`, `net_message`,
`from`, `reliable`, `params`, `names`, `name_bits`, `name`, `name_requires`, `presentation`,
`record` and `actions`. The CLI and `cook/build` pass it on their own; a hand-compiled program needs it. The
`mirai` tool is compiled with `-ignore-unknown-attributes`: it does not use them, and one compiled
before a new attribute does not know it.

## Which packages it reads

In this order, which is also that of the libraries when ordering functions:

1. Engine: `core` and all of `engine/**` → `World` and `Shared`.
2. Active plugins, dependencies first: `plugins/<n>/runtime/**` of the project
   (`project:plugins/<n>/runtime`) or of the engine (`plugins:<n>/runtime`) → `World` and `Shared`.
3. Project: `game/**` → `World` and `Shared`.
4. Editor: `editor/**` of the engine, `plugins/<n>/editor/**` and `editor/**` of the project →
   `Editor`.

A package is each folder with some `.odin` that is not `_test.odin` (excluding those that start
with `.` and `testdata`); one without components, storages or functions is not imported. A folder
receives the place of its origin: a type or a function of an editor package never reaches the game.

## Attributes

```odin
@(component) @(component,shared) @(component,locks="core.Transform") @(component,replicated)
@(component,replicated="owner") @(net_message) @(net_message,from="client",reliable)
@(component,single) @(component,far) @(storage) @(storage,host) @(storage,setting)
@(storage,setting="machine")
@(storage,queue) @(storage,events) @(storage,shared) @(storage,keep) @(storage,persist)
@(storage,reset="state_reset")
@(storage,copy="state_copy",swap="state_swap") @(storage,copy=false) @(storage,free="state_free")
@(step="fixed late",loops="game editor",stage="end",after="a b",before="c",server)
@(params) @(record) @(record,description="...")
```

- `component`: one `core.Table(T)` per world; one row per entity.
- `single` (of a component): the world uses one at a time (`Table_Info.single`). The table
  remembers in which turn each row was enabled: of those that were ever enabled and whose entity is
  enabled, the last one stays enabled, in row 0, and the others wait disabled by themselves,
  without losing their values. Enabling one (`enable`) disables the one that was on; disabling the
  enabled one, its entity or removing it turns the previous one back on, in the order in which they
  were enabled. A row that arrives while another is enabled arrives disabled and does not wait for
  a turn; with none enabled, the first one to arrive rules. What belongs to a section, a prefab
  (placed at run time or stored in the scene document) or a joined world arrives disabled even if
  there is none (`world_union`, and `scene.instantiate` with a section, a placed prefab or the rows
  of a document instance): on load the one of the root rules, and a root without `Sky` has no sky.
  One disabled with `disable` no longer waits. Only `single` tables look at turns, and only when
  settling changes. The network does not replicate which one is enabled. `@(storage,scene)` no
  longer exists: the generator rejects it and says to make it a component.
- `far` (of a component): its entity draws its own distant shape (`Table_Info.far`): when its
  section is unloaded it stays enabled together with what hangs from it
  ([what is unloaded](../../mirai-gameplay/references/libraries.md#scene-references)).
  `Terrain` and `Foliage` declare it; the core does not know them.
- `description="text"`: optional description of the component in `Table_Info.description`. It
  accepts Odin literals, with escapes and raw strings; it takes no space per entity.
- The comment on the line of a component field (`radius:f32, // of the sphere that glows`) is its
  description, in `Table_Info.fields`: `component.list` and the inspector show it. It is written
  only where the name and the unit are not enough.
- `storage`: one value per world: state of a library, requests, events, loop parameters. It is
  written by a single library (any of its functions).
- `queue` (of a storage): a queue of requests; any function receives it with `^` to push and the
  owning library takes it.
- `events` (of a storage): what a library empties and fills every tick; the others read it with
  `core.Ref`.
- `shared`: several functions may write the table, in loop order. In a storage, several libraries
  write it in loop order: the UI context of each world (`gui.Gui`), the input registries
  (`Input_Map`), the view (`core.View`), the simulation that physics and destruction share
  (`Physics_State`) and the editor session.
- `locks="Type ..."`: the table owns the rows of those components (which must be `shared`) in its
  entities. `Type` is resolved in the package or by the imported alias (`core.Transform`).
- `replicated`: the network sends its values on the entities it replicates, to everyone or, with
  `replicated="owner"` or `"others"`, only to the owner or to the others
  ([multiplayer](../../mirai-networking/references/multiplayer.md#what-the-game-declares)). A
  storage is not replicated.
- `net_message`: a struct that the network sends as a message: from the server (the default), a
  client (`from="client"`) or the owner of the entity it talks about (`from="owner"`); `reliable`
  arrives once and in order. It belongs to a library or to `game/`, never a component or storage; it
  ends up in `World_Info.messages`, which the network registers
  ([messages](../../mirai-networking/references/multiplayer.md#what-the-game-declares)).
- `host`: a storage in `Shared`, one per application, never copied.
- `by_world` (with `host`): `Shared` stores one value of the storage per `World`, in a
  `core.By_World(S)`. A function that receives `^S` or `core.Ref(S)` gets that of the world it runs
  in (`by_world_get` with its `core.World_Id`; nil in a world that the application did not make,
  such as that of a test, and the function checks for it); by value it is an error. The world gets
  its own when it is created (`NAME_DEFAULT` or zeros) and loses it after its `release`, with the
  `free` of the storage. For what the application stores for each world and is not copied with it:
  sockets, pointers and mirrors of its state (voices, interfaces, derived meshes and caches), which
  this way are not rebuilt when the editor runs several worlds in a frame.
- `presentation` (with `host` and `by_world`): what comes back from the GPU, frames later
  ([readbacks](../../mirai-rendering/references/views.md#extension-stages)). It is not
  deterministic and does not enter a rollback: a `fixed` function that receives it is an error, and
  the `frame` or `late` ones read it for presentation (the particle reports of the `vfx` plugin).
- `setting`: a `World` or `Shared` storage of a library that is a project setting, with its value in
  the settings files
  ([settings](../../mirai-projects/references/projects.md#project-settings)). On a component or
  in an editor package it is an error.
- `setting="machine"`: a machine setting, a preference of whoever uses the engine on this machine;
  the engine file stores it and the project may override it. Another value of `setting` is an error
  that says what to write. `Storage_Info.setting` is `core.Setting_Kind` (`None`, `Project`,
  `Machine`) and `Generated.machine_settings` names the machine ones.
- `copy="proc"`: a `World` storage; a procedure of the package `(dst, src: ^S) -> bool` that
  replaces the default copy (`core.value_copy`). `false` without memory, with `dst` half done but
  releasable.
- `copy_kept="proc"`: a `World` storage that is copied; a procedure of the package
  `(dst, src: ^S) -> bool` that `copy_changed` uses, the copy that a history keeps and that is only
  copied back with `copy`: it may store only what that return trip needs (physics, its pools sized
  to what is used and not to their capacities).
- `copy=false`: the storage is neither copied nor swapped: it stays in its world (what a world is
  and not its content).
- `swap="proc"`: a procedure of the package `(a, b: ^S)` that replaces the default swap (the bytes),
  without allocating: for the storage that tells its readers that its content changed worlds (the
  epochs of physics and terrain).
- `free="proc"`: a procedure of the package `(^S)` that releases what the storage contains; by
  default `core.value_free`.
- **Class of a `World` storage.** Clearing a world (`clear_world`: loading a scene or a save,
  opening a document) removes its entities, and a storage is of one of these classes:
  - derived (the default, also `queue` and `events`): state that a library derives from the
    entities or requests about them; it goes back to its start. What a save must keep goes in a
    component, which is saved and whose `Entity` fields are remapped.
  - `keep`: state of the run, not of its entities (`Time`, `Input`, `View`, the input map, the save
    requests and results, `Run_Players`); it stays as it was and is not saved.
  - `persist`: a `keep` that is player progress (`Storage_Info.persist`): the `save` library writes
    it to the profile and reads it at start
    ([profile](../../mirai-gameplay/references/libraries.md#save)). Plain data, without `Entity`
    fields; it is not a component, application storage, queue, events, setting or `reset`. The
    generator walks its struct, with the types of its package and of the other packages of the
    world, and rejects a dynamic array, a slice, a map, a pointer, a union, a string or an `Entity`:
    the error names the field and what to store instead.
  - The settings (`setting`, `scene`) and what is not copied (`copy=false`: `World_Id`, the frame
    in `Frame_Time` and `Frame_Input`, what awaits sending in `Net_Outbox`) are not cleared either.
- `reset="proc"`: a procedure of the package `(^S)` that takes a derived storage to its start,
  instead of its `free` and its initial value: for the one that notifies its readers with an epoch
  (`physics.state_reset`, `terrain.terrain_data_reset`).
- `step="phases"`: `input`, `fixed`, `frame`, `late`, `ui`, `render`, `release`, separated by
  spaces. `release` runs when the application releases a `World`, from the game loop, with that
  world, the `Shared` and `^host.App`: there a `by_world` storage releases what its value holds, and
  an application one what it had of that world (it recognizes it by `core.World_Id`). A `release`
  function that is not in the `game` loop (that of an editor package) is an error.
- `loops="game editor"`: in which loops it runs; by default `game` in a library and `editor` in an
  editor package.
- `stage="stage"`: in which stage of its phases it runs; by default `intent` ([order](#order)).
- `after="a b"` and `before="c, d"`: after or before those functions, separated by spaces or
  commas, within its stage ([order](#order)).
- `server`: runs only where the rules are decided, a lone game or a server (`core.Network.role` is
  not `Client`). On a client the generated code returns before calling it, also when a correction
  resimulates ticks, like the `if` it replaces: what it decides reaches the client over the network.
  A function that also does something at every end is split in two, or looks at `core.Network` in
  the body; the one that empties a `queue` is not `server`, because on a client the queue would
  grow with nobody taking it.
- `actions`: an enum of `u8` whose members are the input actions of a library; with `names`, the
  type whose values they take ([named ids](core.md#named-ids)).
- `params`: a struct whose fields are function parameters ([groups](#parameter-groups)); it is not
  world data.
- `record`: a struct that is the row of game data tables ([game data](core.md#game-data)); it
  is not world data. It ends up in `World_Info.records` with its default, its description and that
  of its fields, like a component. It belongs to a library or to `game/`, with no other attribute,
  and of plain data: the generator rejects the same as in a `persist` (also an `Entity`), and two
  with one package and one name, because the `.records` names its type that way.

Attributes go on `Name :: struct` and `name :: proc` declarations. A type is declared only once per
package.

### Initial values

A row created by generic code (adding a component from the editor) and a storage when it is created
or cleared start at what the package declares: a constant `NAME_DEFAULT` or a procedure
`name_default()`, with the type name in uppercase or in `snake_case`; without them, zeros. A saved
scene does not use the default: it reads what it saved.

## Where the data goes

```text
.mirai/gen/
  game_world/world.odin      package world: World, Shared, info()
  editor_world/world.odin    package world: World, Shared, Editor, info()
  shipped_world/world.odin   game_world without the development plugins (only for the game build)
  game/main.odin             main of the shipped game: host.player_run
  editor/main.odin           editor library: exports mirai_project_info
  play/main.odin             player library: exports mirai_project_info
```

`gen` is the `generated` collection; a file is rewritten only if its text changed.

- **`World`**: `entities`, one `core.Table(T)` per component and one field per `World` storage. It
  is what is cloned for Play, copied for network rollback and saved. **`Shared`**: the `host`
  storages. **`Editor`** (only `editor_world`): components and storages of the editor packages.
- The field of each type is its name in `snake_case`; if two types give the same one, or it is a
  reserved word, the package is prepended (`physics_state`). Each package is imported as
  `p_<declared name>`, so no identifier of a package collides with those of the world.
- `info()` returns the `core.World_Info` ([reflection](core.md#world-reflection)), completed with
  `core.world_info_index`.
- `init_*` builds the tables with the allocator received and sets up the `locks`. `copy_world`,
  `copy_changed_world` (with fewer marks than tables, it copies whole) and `swap_world` leave the
  `Id` index following the table that arrived with it ([identity](core.md#persistent-identity)).
- `clear_world` clears entities and tables and takes each derived storage to its start: its
  `reset`, or its `free` and its initial value. Without memory for the entities it answers false
  and leaves the World as it was.

## Parameters

Each parameter is bound by its type; the order in the signature is free.

- `^core.Table(C)` writes the table of `C`; `core.Read(C)` reads it.
- `^S` writes the storage `S`; `core.Ref(S)` reads it without copying; `S`, a copy, for the small
  ones (`Time`, `Input`, `View`).
- `^core.Entities` creates and destroys entities; `core.Ref(core.Entities)` reads which are alive.
- `core.Commands`: creates and destroys entities and gives them or takes from them rows of any
  component, also of tables that the function does not write
  ([commands](core.md#creating-with-components-of-other-libraries)).
- `core.World_Ref`: the whole world by reflection, for code that does not know the types (scenes,
  saving, network, the binding of an interface by name, the editor).
- `^host.App`: the application (window, renderer, mixer, assets).
- `core.Records(T)`, with `T` a `@(record)`: the rows of its tables, read-only
  (`host.app_record_set`).
- A `@(params)` struct, by value ([groups](#parameter-groups)).

### Parameter groups

A `@(params)` groups what several functions or a helper receive together, to pass one value instead
of three or four loose tables:

```odin
@(params)
Placer :: struct {transforms:^Table(Transform),parents:Read(Parent),places:^Places,jumps:^Jumps}

@(step="fixed")
doors_open :: proc(doors:core.Read(Door),placer:core.Placer,time:core.Time) {...}
```

- The generator expands it field by field: each field is bound as that loose parameter, and the call
  builds the struct. For the order, the writer rules, the settle and `CHECK_WRITES`, the function
  receives each field.
- A write field gives the right to write that data under the same rules as a loose parameter: a
  table that is not `shared` still has a single writer function.
- What a function writes reaches it once: also receiving it loose, in another field or in another
  `@(params)` is an error; what it only reads, or a `queue` it pushes to, may arrive twice.
- It is declared in any package that the generator reads and is used by the functions that import
  it, also those of a plugin compiled as a library.
- One with a type parameter, `struct($E:typeid)`, is received for an enum `@(actions)`,
  `B(E)` (`inp.Input_Of(Walk_Action)`): its field of the `@(names,actions)` type takes the base of
  `E`, and the others are bound as in any group.

## Rules the generator checks

Each violation is a message with file and line that says how to fix it; `mirai generate` lists them
all. The ones most often stumbled on:

- A parameter without a table or storage: a type that is not `@(component)`, `@(storage)` or one of
  those above.
- A parameter with a default value: the generator binds them all; whoever calls the function
  outside the loop uses `core.world_run` or passes all of them.
- A function that returns something.
- Two writers of a table that is not `shared` in the same loop (the second sends a request through
  a storage).
- Two libraries that write (`^S`) a storage that is neither `queue` nor `shared` in the same loop:
  the other pushes a request to a `queue` storage of the owner.
- `queue` or `events` on something that is not a storage, or both on one.
- `keep` or `reset` on something that is not a `World` storage, on a setting or a `copy=false`
  (which already stay), or both on one.
- An `order=`: functions are not ordered by number; the message says to use a stage and
  `after`/`before`. A stage that does not exist.
- An `after` or `before` that names a function the project does not have; one against the order of
  the stages (an `after` of a function of a later stage); a cycle of `after` and `before` within a
  phase, which the message names function by function.
- A `server` function in a world without `core.Network`.
- Two functions with the same name; a phase or a loop that does not exist.
- A function of an editor package that asks for the `game` loop; one of the `game` loop or of
  `fixed` that receives something from the editor (`fixed` is repeated in the rollback); one of
  `fixed` that receives a `presentation` storage.
- A type declared twice; a `locks` on something that is not a `shared` component.
- A `@(params)` that is not a struct without type parameters or with one `$E:typeid` (then with a
  field of the actions type, and received for an enum `@(actions)`), that has no fields, that is also a
  component, storage or message, with a field that is not a valid parameter or that is another
  `@(params)` (they do not nest); a function that receives it by pointer, or a library one that
  receives one from an editor package.
- A function that receives twice a datum it writes, when either of the two is a field of a
  `@(params)`.
- A `replicated` on a storage or with a value that is neither `owner` nor `others`; a `net_message`
  that is also a component or storage, of an editor package, or with an unknown `from`.
- What breaks the [dedicated server](#dedicated-server).

### Dedicated server

A dedicated server (`--dedicated` of the [player](host.md#arguments)) runs neither the `ui` nor
the `render` phase: they belong to whoever watches. So that it decides the same as a game with
players, the generator refuses, in every project, a function of the `game` loop that runs only in
those phases (with or without `release`) and that:

- is `server`;
- writes a `replicated` component;
- creates or destroys entities (`^core.Entities`, `core.Commands`);
- writes a table, or a storage that is neither `queue` nor `events`, that a function of another
  phase reads and that no function of another phase writes.

Queues and events are left out: what an interface pushes is a request of a player of this end,
and on a dedicated server those requests arrive through the network. Writes by reflection
(scenes, network, editor) do not count: they give initial values.

## Generated functions

Each function is written once, as `call_<name>`, with its binding, its settle, its time and its
profile zone, and each loop and phase with functions as `game_fixed`, `editor_frame`, etc., which
calls them in the computed order; the host also runs them at the same time
([concurrent functions](#concurrent-functions)). `info.steps[i].call` and
`info.order[loop][phase]` give them to `core.world_run`: a tool runs a part of a loop, in order,
with the same binding and settle ([reflection](core.md#world-reflection)). Nothing binds
parameters by hand.

- After each function it applies the pending changes with `table_settle` of each `^core.Table` it
  received.
- A function with `^core.Entities`, `core.Commands` or `core.World_Ref`, or that writes `Disabled`
  or `Parent`, may touch any table, destroy entities or change what is disabled: after it `settle`
  runs on all of them and releases the destroyed indices.
- `settle` settles `Disabled` and `Parent` first, follows `Parent` into the `Hierarchy`, recomputes
  what is disabled and then settles the others, which move the rows of the entities that were
  disabled or enabled.
- It adds the time of each function to `app.step_ns` (`engine.status` reports the most expensive
  ones) and opens its profile zone in the ring of the worker that runs it, which records only
  during a capture ([profiling](host.md#the-frame)).
- With `core.CHECK_WRITES` it wraps each function that receives tables with `^` in
  `write_check_begin`/`write_check_end`.

The generated code does not touch `version`: each row requested for writing bumps it
([stamps](core.md#tables)). Receiving a table with `^` and not writing it does not move it.

### Order

Each phase of a loop runs its functions by stages, in a fixed order that is the same in every
phase. The stages say which part of the tick each function is, without numbers to coordinate
between packages; in `fixed`:

- `begin`: the core and the network at the start of the tick: inputs and seats of the connections,
  pose targets.
- `input`: actions and seats of this machine, bodies that appear, who drives what and the
  `Move_Input` of what a seat drives.
- `intent`, the default stage: the game logic, which writes `Move_Input` and pushes requests.
- `apply`: what does what was requested before simulating: spawns, the camera of each seat, paths
  and animation sampling.
- `simulate`: what feeds physics (locomotion, ragdolls, fields, terrain), the requested places and
  the step.
- `react`: what reads physics: destruction, animation after physics, game contacts.
- `end`: transform propagation, particles and network publication.

Outside `fixed` almost everything stays in `intent`: `begin` and `end` give the first and the last
of the frame (the network, the UI and editor frame, `input.mirai`) and in `late` `input` moves the
cameras before `camera_follow`. A function of several phases has the same stage in all of them.

- **Within a stage**, in the order of the libraries (engine, plugins with their dependencies first,
  game; files by path and declaration within the file). A function runs after those it waits for,
  its `after` ones and those that name it in `before`, in that same order: `before="b"` puts the
  function right before `b`.
- **Between stages** the order is already given: an `after` toward an earlier stage is met on its
  own, and one toward a later one is an error. Toward another phase or loop it orders nothing.
- **What is named.** Functions of the engine or of the plugins the library depends on; one that is
  not a dependency may be missing in a project. Between plugins that do not know each other the
  stage orders, and within it the order of the project's plugins: that is why `begin` and `end` stay
  for the core and the network (`net_tick_tail` is the last of the tick), and what feeds physics
  goes in `simulate` with `before="physics_prepare"`.

### Concurrent functions

That order is the result; within it, the generator gives per loop and phase the edges of a graph
(`info.edges[loop][phase]`, by position in `info.order`): a function waits for an earlier one if it
is of a later stage, if `after` or `before` say so or if they collide, and only the edges that
others do not imply remain. Two functions collide if one writes a datum that the other reads or
writes:

- A table: `^core.Table` writes it and `core.Read` reads it. Writing a table with `locks` also
  writes those it locks; writing `core.Id`, the index that `core.Ref(core.Entities)` reads.
- A `World` storage: `^S` writes it, also when pushing to a `queue`; `core.Ref(S)` and `S` read it.
- A `Shared` storage (`host`, `by_world`, `core.Problems`) or an editor one counts as written
  however it is received, and `^host.App` and `core.Records` collide with all of them: they are the
  application, to which they can lead.
- A whole-world function (`^core.Entities`, `core.Commands`, `core.World_Ref`, or one that writes
  `Disabled` or `Parent`) collides with all: it is a barrier, because `settle` runs afterwards.

Those that collide keep the loop order, so the graph gives the same `World` as the in-order
execution, with any number of workers: what the `fixed` rollback requires. `host` runs the phase as
a `jobs.Graph` on the application's workers, built the first time it runs with a library and
without allocating afterwards ([host](host.md#the-frame)):

- Each function receives the index of its worker: its profile zone goes to the ring of that worker
  and `app.step_ns` adds at the index of the function.
- Those that receive the application or a `Shared` or editor storage (`Step_Info.main`) run on the
  loop thread: they use the job system as its owner and what the application does not share.
- It runs in order, with `info.loops`, with a single worker, with
  `-define:MIRAI_STEPS_SEQUENTIAL=true`, when the phase runs again from inside itself (a network
  correction that resimulates ticks) or with a `World_Info` without `parallel` (one built by hand).
- A function touches only what it receives: what it could reach outside its parameters (a pointer
  stored in a `World` storage) would run at the same time as its writer.
- What it requests from `context.temp_allocator` is released on return; the rest of the `context` is
  that of whoever runs the phase.

## Outputs

- `game/main.odin`: `os.exit(host.player_run(&info, <executable folder>, "", os.args[1:]))`. It is
  the only `main`: the shipped game is compiled whole with the engine. Without the engine, the game
  reads only its `settings.mirai`, which the build merges
  ([settings](../../mirai-projects/references/projects.md#project-settings)).
- `editor/main.odin` and `play/main.odin`: package `mirai_project` that exports
  `mirai_project_info :: proc() -> core.World_Info`, without `main`. They are compiled as a dynamic
  library against the engine declarations
  ([binaries](../../mirai-projects/references/projects.md#engine-binaries)) and loaded by
  `mirai-editor` and `mirai-player` ([host](host.md#project-libraries)).
- `editor` imports `generated:editor_world`; `play`, `generated:game_world`, and `game`,
  `generated:shipped_world`, as `world`.

## Changing the generator

- A new attribute goes into `CUSTOM_ATTRIBUTES`, the attribute reader and the list of
  [attributes](#attributes); the consumers of the `World_Info` are updated in the same task.
- Error messages say what to do, not only what failed.
- The generator does not run code of the project or of the engine: it reads syntax. Sizes and
  alignments are computed by the compiler when it compiles the written world.
- The `info` of a table or storage is taken by the generated world with `type_info_of` inside the
  project library; the engine's generic code never resolves a world type by `typeid`.
- `Table_Info.game` is true for a component of a `project:` package that is not under
  `project:plugins/`: what the game declares, which the inspector shows open.
- The editor reverts properties, also those of plugins, to the default declared by the type, the
  same as the generated initialization.
- Verify: `mirai test cook/build` and generate `templates/empty`, `templates/game` and `demo`;
  compile editor and game and run the player
  ([project verification](../../mirai-projects/SKILL.md#verification)).
