# `core`: entities, tables and the world

`core` (layer 3) imports `std/base`, `std/input`, `std/math` and `std/serial`. It knows nothing of
the application, the GPU, the renderer or the game libraries. Everything a loop function receives
comes from here or from a library.

## Entities

`core.Entity` is `base.Entity`, a generational handle; `core.NONE` is zero and no entity has index
0. `std/serial` remaps the `Entity` fields on save, load and replication.

- `destroy` bumps the generation immediately (the entity stops being `alive`); the rows are removed
  at the next `settle`, after which indices are reused in ascending order.
- `entities_clear` advances all generations before releasing: no earlier handle comes back to life
  when another scene loads. The `entities_*` belong to the generated world and to `scene`/`save`,
  not to the loop.

### Disabled entities

`Disabled` (`@(component,shared)`, a tag) turns off its entity and everything hanging from it:

- Its components keep their values and no function sees them (`count`, `get`, `has`, `row_of`).
  The base ones stay on: the components of `core` (`Transform`, `World_Transform`, `Parent`, `Name`,
  `Id`, `Disabled`). A disabled entity can be found by its `Id`, moved and reparented.
- The own state (`Disabled`) and the effective one (`entity_off`) are kept apart: turning a parent
  on does not turn on a child with its own `Disabled`, nor a component that was disabled by itself.
  A new entity under a disabled parent is born disabled.
- `core.settle` recomputes what is off only if `Disabled` or the tree changed, and the tables
  that hold a row of an entity that changed state move it in that same settle.
- Libraries have no turn-on callbacks: they see it as a remove and an add (physics rebuilds the body
  with the velocity of `core.Motion`, audio cuts the voice). The network keeps its object and turns
  off the replica, except for what its section turns off
  ([network](../../mirai-networking/references/multiplayer.md#what-the-game-declares)).

### Persistent identity

`Id` (`base.Entity_Id`, zero is none) names an entity in its scene or prefab, in a save, at each end
of a network session and in the editor API. `Entities.ids` translates it to the entity in constant
time:

- `entity_of` answers according to the last settle of the `Id` table: one that was added and not
  yet settled is not found; a destroyed entity stops being found immediately. `id_of` reads the row.
- The index follows the `changes` of the `Id` table; `world_copy` and `world_swap` carry it with
  the world without rereading it (`ids_moved`), and a hand-copied world rereads its table.
- If two entities have the same `Id`, the first one indexed has it and, when it leaves, another.
  Without memory it is rebuilt at the next settle and in the meantime it does not find what it did
  not add.

A new `Id` always comes from the `base.entity_id_next` sequence, whose state belongs to the caller.
In a world, `id_new` gives the next one that no live entity has (those added and not settled do not
count, but the state advances): the editor seeds one per session and per end of a collaboration,
`save` starts at zero for borrowed `Id`s, and `destruct` derives that of each group from the `Id` of
the root, the same at each end. In a document, `asset.scene_new_id` walks the same sequence from
the id of the asset and its `id_counter`.

## Tables

`core.Table(T)` stores values, entities and stamps, dense and parallel, with an index map from
entity to row. The map comes in pages made for the entities that have had a row, and an empty
table holds no memory: a table costs what its rows cost, not what the entities of its world would.
The enabled rows come first: walking a component is walking `0..<count(t)`. Removing a row moves
another into its place, with its stamp, without mixing the two sections.

- **Reading stamps nothing.** `get` (value and whether it was found) and `at` (the value of a row)
  answer the same on a `Read` and on a `^Table`, as `row_of` and `has` do. None of them sees a
  disabled row.
- **Writing is requesting the row.** `edit`, `edit_at` and `writable` on `^Table`, and `free` on a
  `shared` table, give `^T` and stamp the row with a new `version`, written or not. `set` and
  `set_at` take the value and stamp only when its bytes differ from those of the row: what a
  function computes every tick and seldom changes goes through them.
- **Stamps come in pages.** `page_stamps` keeps, for each `STAMP_PAGE` rows, the newest stamp
  written in them: a reader of what changed skips the pages written before it looked.
- **Structural changes wait.** `add` (adds or replaces), `remove`, `disable` and `enable` wait in
  `pending` until `table_settle`, which applies them in order and discards those of entities that
  are not alive. It reserves room for all the additions first: without memory it applies none and
  they wait for the next settle. There are never two rows per index: the new generation replaces
  the old one.
- **What waits is finished in the function.** `added(t, e)` gives the value of the last pending
  `add` to write (valid until the next `add` to the table) and `staged`, that or the enabled row: a
  function finishes what it created without settling the world. `staged_has` says whether the entity
  will have the row on, with what waits counted.
- `version` and `layout` only grow, also after `table_copy` and `table_swap`: a reader never sees a
  repeated stamp.
- The `base` tables (the components of `core`) follow their entity even when it is disabled;
  `disable` on them is a `core.fail`.
- **Copying what changed.** `table_copy_changed(dst, src, &mark)` is for a `dst` that is kept as a
  copy of `src` (the history of a network client) and copies only the rows with a different stamp.
  It relies on the stamps identifying the write across copies of the same world, even after a
  `table_swap`: a world into which another one of a different origin was copied is copied whole
  before it is used again. After `host.app_world_replace`, `copy_marks_follow` keeps the marks
  valid. Going back to such a copy with its marks brings back only what the world changed since
  ([replace](host.md#the-application)): a table says it changed with its `version` and its
  `layout`, which also move when who owns its rows does, and a storage with its revision.
- **Owners.** `@(component,locks="core.Transform")` makes each row the owner of the `Transform` row
  of its entity; the others write with `free`, which gives `nil` on an owned row. The lock names the
  locked table by its distance within the world, not by a pointer, because the world is copied in
  blocks. Only an enabled row is an owner. A second owner, or one that finds its row written by
  another, is a `core.fail` that names both.

### What changed since the last read

A reader keeps one `core.Seen` per table and calls `changes(t, &seen)`, which advances it:

- `each_changed(t, &c)` gives, in a `for`, the rows written, added or enabled since: every row with
  `all`, none when `written` is false. It is the only walk of what changed; `changed(t, c, row)`
  answers for one row, for a reader that walks another table and looks up the row of its entity.
- `gone`: the entities whose row stopped being enabled since the last read (some may have come
  back, among the stamped ones); valid until the next settle.
- `all`: the reader did not see the rows that exist (the table was copied, swapped or cleared, or
  the log discarded entries) and walks all of them.
- **A reader that makes again whole what it derives** does not walk rows: `touched(t, &seen)` says
  whether anything changed in the table since it looked, and `reshaped(t, &shape)` whether its rows
  are others (added, removed, turned on or off, replaced whole) whatever was written in them, for
  what orders or indexes the rows of a table written every tick. Both advance what they are given;
  a reader of several tables joins them with `|`, which asks every one.
- The `gone` log gets its room when the first entity leaves a table, and from then on never
  allocates in a settle: its room grows with the rows, when they are reserved (twice those that
  exist, `GONE_CAPACITY` at least), and when full it discards its oldest half. What leaves between
  two reads, the rows that existed and those that arrived, fits in the half that remains: a load
  that creates and removes many entities does not make whoever reads every frame read the whole
  table. A reader that falls behind more than that, or a log left without memory for its room,
  reads it whole.

### Per-entity maps

`core.Entity_Map(T)` stores one value per entity outside the tables: what a library maintains about
the entities of a table (a voice, what the renderer received, a body).

- Lookups check the generation. `entity_map_put` also replaces the value of another generation of
  the same index: whoever stores something that must be released releases the old one first
  (`entity_map_held`).
- Removing moves the last one into the gap: a stored index or pointer stops being valid. A frame
  that adds no entities does not allocate.
- `entity_map_left` takes out, in a `for`, the value of each entity that left the table according
  to its `changes`, so the caller releases what it stores (`entity_map_prune`, if it stores
  nothing): a mirror releases what left without being walked.
- `value_copy` copies the map, so a `World` storage that contains it is copied with the world.

## Creating with components of other libraries

`core.Commands` (a parameter of a loop function) creates and destroys entities and gives them or
takes from them rows of any component when the function ends, also of tables the function does not
write: a prefab, a piece of terrain, a piece of something broken.

- `commands_add` gives only a row that the entity does not have: one that exists belongs to whoever
  writes its table, and giving it again is a `core.fail`. `commands_added` gives the one that is
  waiting, to finish it.
- `commands_of(w)` builds it from a `World_Ref`, for generic code that hands it to a service
  (`scene.spawn`).
- The generator settles all the tables after a function with `Commands`.

## Queues and references

- `Queue(T)`: `take` returns what was accumulated and empties it, valid until the next `push`.
  A request queue of a library has fixed room: its procs `offer` (or `refuse` what is invalid) and
  return nothing, and the owner's `queue_serve` step keeps the room from its settings and reports
  once what was dropped or refused.
- In a **request** (`@(storage,queue)`) many push and one library takes; in an **event**
  (`@(storage,events)`) the owning library empties it and fills it every tick and the others read.
  Any other storage is written by a single library, except `@(storage,shared)`.
- `Ref(S)` is a read-only pointer to a storage: writing through it is a bug that the generator does
  not see.

## Waiting

A wait is the tick it ends at, plain data in a component or a storage: it is copied and rolled
back with the world, and a save keeps it with the clock.

- `deadline(time, seconds)` is the tick that many seconds after the one that runs, and
  `due(time, at)` says whether it came; a deadline nobody set, 0, has, and `NEVER` never does.
  `elapsed(time, since)` gives the seconds since a tick; `ticks_of` and `seconds_of` convert.
  Seconds become ticks with the `dt` of the clock, so a wait lasts the same at any tick rate.
- The row is written when the wait starts and when it ends: nothing counts down tick by tick.
- An entity with an `Own_Pace` waits on `own_time(time, clock, paces, e)`, the clock at the pace it
  has now. What must follow a pace that changes during the wait adds its own time up every tick.
- A request waits in its queue: `later(&q, time, seconds, item)`, and its owner takes with
  `take_due(&q, time)` what was pushed and what is due. An owner that takes with `take` refuses
  what was pushed for later, and its `queue_serve` reports it. A queue is not saved: a wait that
  a save must keep is a deadline in a component.
- There is no coroutine and no `await`: what waits and then acts is a component with its tick.

## Core storages

`Time`, `Input` and `View` are `keep`: clearing the world does not touch them (loading a scene
keeps counting ticks; loading a save sets its clock). `Frame_Time`, `Frame_Input` and `World_Id`
are `copy=false`: they are neither copied nor cleared. `Jumps` and `Hierarchy` are derived.

- `Time`: the simulation clock of the world, the only one, which is copied with it. `tick`,
  `seconds` (simulated at the start of the tick), `dt` (0 in the editor loop), `playing` (false in
  the editor loop) and `resimulating`. `time_advance(&t)` adds one tick and `dt` after a tick: the
  game loop and the rollback use it.
  - `resimulating`: the network repeats ticks that already ran to correct a prediction. The
    rollback sets it; `tick`, `seconds` and `dt` come back with the copy of the world and the
    repeated ticks advance them up to the present. What is not simulation is not repeated:
    `audio.play*` makes no sound and `multiplayer.send` does not enqueue. What entered the tick is
    repeated: each repeated tick receives the UI events it received the first time
    ([gui](../../mirai-gameplay/references/libraries.md#gui)).
    What stays in the `World` (a prefab, a counter, the clock of a particle emitter) is repeated the
    same as the first time.
- `Frame_Time` (`copy=false`): the frame the world runs, not its simulation. `accumulator` (seconds
  of frames that the ticks have not simulated yet), `dt` (of the frame), `alpha` (fraction of the
  frame between the last two ticks; 1 in the editor loop and when creating the world), `phase` (the
  one that is running) and `dilation` (how much faster or slower than the frames the ticks run; -1
  stops them). A Play and a rollback neither copy nor swap it: it stays as the frame has it. `host`
  writes it, except `dilation`, which is written by whoever carries the world's clock with another
  one (the
  [network client](../../mirai-networking/references/multiplayer.md#the-tick)); it is read by the
  presentation (`render.drawn_transform` and what draws interpolated), by what advances with the
  frame in the editor and by `transforms_propagate` (its `phase`).
  `core.world_run` acts as the host while a part of a loop runs and hands it back afterwards.
- `Input`: keys, mouse buttons and gamepads (with their `family`). `*_down` held, `*_pressed` and
  `*_released` for one tick, `mouse_position`, `mouse_delta` and `wheel` accumulated, `window_size`
  and `device`, the device used last
  ([platform](../../mirai-platform/references/platform.md#input)). It is queried with `key_down`,
  `key_pressed`, `mouse_*` and `axis`.
- `Clock` (`keep`): how the simulation requested by the game runs, `paused` and `scale` (slow
  motion, up to `CLOCK_SCALE_MAX`). The game requests with `pause`, `resume` and `time_scale` in
  `Clock_Requests`, which `clock_requests` takes (`input`, stage `begin`). `host` multiplies the
  frame time by it: when paused no ticks run but `frame`, `late`, `ui` and `render` do, so a pause
  menu works without per-function rules, and the voices of the world are paused. In a network
  session the clock is carried by the server: the network of a client follows the server's with
  `clock_follow`, the only request a client takes; another is the problem `core.clock_network`.
- `Own_Pace` (a `replicated` component, not a storage): an entity that keeps its pace while the
  `Clock` scales the world (bullet time: the player at normal speed in slow motion). Its time runs
  `rate` times that of the frames, whatever the scale; `pace_of(clock, paces, e)` gives its seconds
  per simulation second (`rate / scale`; 1 without `Own_Pace`). There is no per-entity `dt`: the
  fixed step is a single one, and each library that moves an entity through time compensates:
  - the locomotion of its `Character` and the turn of the seat
    ([locomotion](../../mirai-physics/references/engine.md#own-pace));
  - its animation, its pose modifiers and its `Keyframe_Path` advance `dt * pace_of`.
  - The camera that follows it already runs with the `dt` of the frame (`late`), which does not
    scale.
  - What it throws or fires follows the world clock unless the game gives it its own `Own_Pace`; a
    `Rigid_Body` does not compensate. A `rate` outside (0, `CLOCK_SCALE_MAX`] is the problem
    `core.own_pace` and the entity follows the clock.
  - In a network the `Clock` is carried by the server and `Own_Pace` is replicated: the client
    predicts its player with the same compensation.
- `Frame_Input` (`copy=false`): `input: Input` of the current frame, even without a tick. For
  presentation; it does not consume the deltas or the pending edges of `Input`, and a copy of the
  world does not overwrite it.
- `View`: the camera of the player with input focus, or that of the editor viewport. Position,
  rotation, `fov`, `projection` (`Perspective`, `Orthographic` with `height`, `Custom` with
  `custom`), `shift`, `clip_plane`, `layers` and `carried`: the rigid transformation that carried
  the camera since the last frame together with what it sees (it keeps the image history).
  `view_ray(v, pixel)` uses pixels local to the view; `VIEW_DEFAULT`.
- `Jumps`: jumps of the tick. `jump(jumps, e, by)`: `e` appears somewhere else without passing
  through the middle, carried by the rigid transformation `by`.
- `Hierarchy`: the tree of `Parent` ([the `Hierarchy`](#the-hierarchy)).
- `Propagation`: order and scratch of `transforms_propagate`.
- `World_Id` (`copy=false`): which world of its application this is, a handle (index and
  generation) that no world made later repeats. `host` sets it when creating the world; copying and
  swapping worlds do not move it, so a replaced world keeps its own. What the application stores
  for each world lives in a `by_world` storage, which is looked up by this id; a `Shared` storage
  that is one per application (the renderer scene) stores the id of the world it holds, never the
  address of the world or of a table. Zero in a world that the application did not make.

`Simulation_Settings.tick_rate` (a project setting) gives the fixed ticks per second. `Phase` is
`Input, Fixed, Frame, Late, Ui, Render, Release` (`Release` runs once, when a world is released; no
frame runs it); `Loop` is `Game, Editor`.

## Network

What the network and the libraries that simulate share without knowing each other. A lone world
decides everything; in a network session the server decides, and a client only what it predicts.

`core/network.odin` says only who decides:

- `Network` (`keep`): the role of this end, `Standalone`, `Server` or `Client`.
- `Remote`, without fields: on an entity that another end decides (on a server, what it has lent
  and the client of a connection simulates; on a client, a replica that it neither predicts nor
  has). What the server simulates is decided by the server, even if a client predicts it. The
  network removes all of them when the role changes.
- `owned(remotes, e)`: whether this end decides `e`. Seats, cinematics, destruction, portals and
  physics fields use it. `save` refuses to save on a client.
- `Sync_Check` / `Simulation_Hash`: with `Sync_Check.on`, what simulates outside the tables leaves
  at the end of each tick a hash of its state, which the sync test of a client compares.
- Only the network
  ([multiplayer](../../mirai-networking/references/multiplayer.md#authority-and-players)) writes
  `Network` and `Remote`; without a network the role is `Standalone` and `Remote` stays empty.

`core/motion.odin` says how it moves and where it is asked to go:

- `Motion`: the velocities, the center of mass and the group of the step (what touches or is joined)
  of what a library simulates; only it writes it (physics). The network reads them to send and to
  choose which replicas to correct first.
- `Vertical`: the frame of the vertical of an entity that its simulation rotates (a character on a
  planet): its +Y is up and the yaw of its look turns around it; only that library (physics) writes
  it and without it up is +Y. `vertical_of` gives it, or the identity. The camera that follows it
  reads it to turn with its target.
- `Pose_Target`: the local pose and the velocities that another owner requests for an entity (the
  network, with the state of another end). When `placed` grows it is set there immediately; with
  `follow` it also goes toward the pose on every tick, pushing what it touches. Whoever owns the
  `Transform` takes it at the start of the tick without knowing who requested it (physics, for a
  body); `pose_targets_place` (`fixed`, -99000) writes that of a `Transform` that nobody owns.

## World queries

`core/query.odin`: what looks at the world without knowing who simulates it (the arm of a camera,
the feet of a rig) asks through a single contract, instead of a probe storage per consumer. The
library that simulates sets `World_Queries.open` once (physics); `world_query` gives the
`World_Query` of a world or, if nobody provides one, one that touches nothing. `support` says where
the touched support is now, to follow what moves underneath. A query of another world is opened
with its `World_Ref`.

## Transform and hierarchy

- `Transform` (`shared`) is local to the parent; the libraries that own it declare `locks`.
- `World_Transform` is written only by `transforms_propagate`. A load runs it before returning
  (`scene.propagate`); what appears during a tick has its pose with the propagation of that tick,
  and whoever needs it earlier uses `world_of`.
- `Parent` is the data of the hierarchy: whoever changes it adds, removes or writes `Parent`.

### Requested places

`place(placer, e, position, rotation, teleport=true, at_rest=false)` is the only public way to place
an entity
without knowing who owns its `Transform`: a free one is written immediately, under its parents; an
owned one is requested in the `Places` queue. `core.Placer` is a
[parameter group](generator.md#parameter-groups) with what that needs.

- With `teleport` it is a jump (`jump`) and the drawing does not interpolate the path;
  `teleport=false` is for what moves frame by frame (a cinematic).
- The owning library takes its requests in `fixed`, in the `simulate` stage, and leaves the
  others: a function that receives `^core.Places` runs before `places_drop`, which reports what
  nobody took as the problem `core.place`. What is requested in a later stage waits for the next
  tick.
- `at_rest` stops what the owner moves (a respawn, a reset); the owner takes it from the request.
  The default keeps the velocity, which a portal needs.
- This is how the `spawn` plugin, portals and cinematics place things without importing physics.

### The `Hierarchy`

The child index of `Parent`, in `order` order. Only `core.settle` writes it, when settling
`Parent` and following its `changes`; a function reads it with `core.Ref(core.Hierarchy)` and code
outside the loop with `core.world_storage_of`. It reflects `Parent` as of the last settle: a change
inside a function is seen after it.

- **Cycles.** A `Parent` that would put its entity under itself is left out of the tree: the entity
  is a root until a link changes, and it is retried every time (a log warning names it). A `Parent`
  to an entity that is not alive also leaves it a root.

### Queries

Downward, over the `Hierarchy` and without allocating (`first_child`, `next_sibling`,
`subtree_next`, `destroy_tree`); upward, over `Parent`, which is always up to date
(`ancestor_with`, `is_under`). Nobody builds their own child index or walks `Parent` by hand.

- `subtree_next` gives parents before children:
  `for at:=root; at!=core.NONE; at=core.subtree_next(h, root, at) {...}`.
- What goes up through `Parent` passes through `HIERARCHY_DEPTH` parents at most: a chain that loops
  back ends there.
- `world_of` composes the chain without waiting for the propagation, for a function that moved
  something and needs it now. A world pose is written with `world_set` (without touching the scale)
  or converted with `local_under`.

### Propagation

`transforms_propagate` runs in `fixed` and `late` (stage `end`) with the TRS composition of
`std/math`, which keeps the shape of the child under parents with uneven scale. The authoring
hierarchy is not a spatial structure: culling, physics and queries use their own.

- It sorts everything only if the `layout` of `Transform` or the `version` of the `Hierarchy`
  changes; otherwise it composes the stamped rows and what hangs from them, and only stamps a
  `World_Transform` whose value changed.
- A jump (`Jumps`) carries by `by` also the `previous` of the entity and of what hangs from it: who
  interpolates does so on the arrival side and never shows the path. The owner of the transform
  requests it on the tick where it applies it; physics, on every teleport.

## World reflection

The generator writes one `World_Info` per project. Code that does not know the game types (scenes,
saving, network, the binding of an interface by name, editor) works with
`World_Ref{data, info, place}` (`core/world.odin`). A loop function that only creates entities or
requests changes does not receive it: it uses `core.Commands` and the requests of the owning
library.

- `world_settle` applies what is pending outside the loop, only on a `World`: it is `core.settle`,
  [the settle the loop runs](generator.md#generated-functions), without the tables of the editor.
- `world_run` runs outside the loop the functions of some libraries in a phase, with their order,
  their binding and their settle, and with the given `Time` while they run: this is how
  `physics.step_world` and `anim.animation_evaluate` advance a preview or a copy.
- `value_copy` and `value_free` copy and release a value with its dynamic arrays and slices
  (pointers, maps and procedures, as they are); `value_copy` can fail and leaves a destination that
  `value_free` releases. A slice that is a view of other memory is emptied beforehand, in the
  `free` of its storage.
- `raw_*` see every row, enabled or disabled: the editor, scenes, saving, network and collaboration
  show and save what is disabled too. `raw_touch` stamps the row that a pointer from `raw_find`
  wrote in place (a bound widget). `raw_drop` and `raw_put` remove and put a row immediately,
  between functions and without allocating: undo and the editor's cancellation use them.
- `Storage_Info.for_device` exists when the package declares `name_for_device(device:
  rhi.Device_Info)`: the value on that GPU, which replaces `default` in the settings. It arrives
  untyped, like `app` in the loop functions: `core` does not import `rhi`.
- `world_migration_make(m, from, to)` says what happens to each table and storage between two
  `World_Info` of the same project (`Move` with the same name, place and layout hash, `Convert` with
  another layout, `New`) and gives `table_map`, the new index of each old table. `place_migrate`
  carries a struct from one place to a fresh one of the new library: what moves is swapped, so the
  old one remains for the `destroy` of the old library; it converts by field name and
  `table_values_convert` does the same with loose values (undo, the records of the turns). The
  [editor reload](../../mirai-editor/references/editor.md#build-and-reload) uses it.
- `world_info_index` completes the generated `World_Info` once with the indices per type and the
  `World_Schema` of each table and `scene` storage (without `transient` fields; another layout hash
  migrates by field names), which scenes and saves use without rebuilding it.
- A world of any project is made, freed, copied, swapped and cleared by `core` from its
  `World_Info` (`core/world_data.odin`). `world_init` and `world_copy` can fail without memory and
  leave a world that `world_destroy` releases; `world_swap` does not allocate and what is not
  copied stays in its world. `world_clear` takes the derived storages to their start
  ([classes](generator.md#attributes)).
- `world_copy_changed` takes only the tables that changed and the storages that were written,
  with their `copy_kept` if they have one, and keeps `copy_marks_count` marks for it. A `World`
  holds a revision for each storage, which moves when a function receives the storage with `^S`
  ([generated functions](generator.md#generated-functions)), when code outside the loop asks for it
  (`world_storage`, `world_storage_of`, `world_storage_at`: what writes a storage outside the loop
  reaches it through one of these), when `core.settle` changes the `Hierarchy`, and when the world
  is copied over, swapped or cleared. A storage written through a `core.Ref`, or through a pointer
  kept from an earlier function, changes without it: `MIRAI_CHECK_WRITES` makes
  `world_copy_changed` compare the storages it left alone and `core.fail` on one that differs. A
  World made by hand has no revisions (`World_Info.revisions`), and its storages are copied every
  time.
- The `by_world` values of a world are given and taken by `world_attach`/`world_detach`;
  `world_storage` does not return them: `host.app_world_storage` looks up that of a world.

## Joining one world into another

`world_union(dst, src, parent, &entities)` (`world_union.odin`) adds to `dst` what `src` has,
settled: one new entity for each, with all its rows, enabled and disabled, and its `Entity` fields
remapped with the offsets of `World_Schema` (one that named nothing of `src` is left as `NONE`). The
roots of `src` hang from `parent`, after the children it already has. `src` stays as it was; the
rows appear at the next settle of `dst`, where that of a `single` table arrives disabled
([single](generator.md#attributes)). It is all or nothing: it reserves in `dst` what it adds before
adding, and without memory it returns `false` with `dst` as it was; with room in `dst` and in
`entities` it does not allocate. This is how the `World` where a job instantiated a scene (a
section, a generated level) is joined. `world_run_copy(dst, src)` gives `dst` what belongs to the
run of `src`: the `keep` storages (`Storage_Info.keep`) and the settings, with their `Entity` set to
`NONE`, because they named entities of `src` (the camera of `View`); a scene loaded separately uses
it before replacing the world. With `roots`, `world_union` joins only those entities and what
hangs from them, as roots: this is how those with `Keep` (`shared`) pass to the new world, and their
`Entity` fields toward what stayed outside are left as `NONE`.

## Named ids

A value that the game, the plugins and the data share by name (a locomotion mode, an input action,
a collision category) is a constant of a type with names (`core/names.odin`): the code is the only
source of its names, and the data only configure through them.

- `@(names)` marks a `distinct` integer (`@(names="MODE_") Locomotion_Mode :: distinct u16`); its
  values are the constants of that type in any package of the project, of the engine or of a
  plugin, named by the identifier without the prefix, in lowercase, or by `@(name="...")`.
- `@(name_requires="C")` says which component an entity needs to take that value: the inspector
  does not offer those it lacks, and whoever uses the value checks it.
- `@(name_bits="T")` marks a mask whose bit i is value i of `T`; it can be an alias of a `distinct`
  of a lower package that does not know `T`.
- Two constants with one name are a generator error; two with one value, a `#assert` of the
  generated world.
- What is saved stores the number of a constant: renaming changes neither data nor layout. The
  text and the API write and read them by name, or by number when they have none.
- The editor creates a value by writing the constant in `game/names.odin` and renames by putting
  `@(name)` on it without touching its identifier; both compile the game. The values of the engine
  and of the plugins are not renamed from the editor.
- `@(names,actions)` marks the type whose values are the members of the enums `@(actions)`
  (`inp.Action`), not constants: the generator gives each enum, in the order of the libraries
  (engine, active plugins, game), the next values, names them by their members in lowercase and
  records each enum with its base in `World_Info.actions` (`core.actions_of`). A constant of that
  type, an enum that is not `u8` or gives its members values, one name in two enums and more
  members than the type and its masks hold are generator errors
  ([actions](../../mirai-gameplay/references/control.md#actions)). Those numbers move when a
  library adds an action, so what is saved stores the name of an action and of each bit of its
  masks, as it stores the member of an enum (`Named_Type_Info.actions`, `serial` `by_name`); the
  network sends the number. A new library that gives an action another number converts the tables
  and storages that hold actions (`world_migration_make`); one that only renames it moves them as
  they are.

## Game data

A catalog (weapons, dialogues, waves, loot tables) is a code struct with `@(record)` and `.records`
tables that fill it ([format](../../mirai-assets/references/kinds.md#records)): the code declares
the schema and the editor and the API, the rows.

- A row is named with `core.Record(T)`: the table (`Asset_Id`) and the `Record_Id` of the row in it,
  never its position. Its zero value names none. The dependencies of an asset that stores it come
  out by themselves from the table it names.
- A function reads with a `core.Records(T)` parameter: all the rows of all the tables of `T`.
  `core.record(rows, ref, problems, e)` returns a copy of the row and, if the table or the row are
  missing, reports `records.missing` on the entity that names it; `record_get` looks without
  reporting, `records_count` and `records_at` walk in the order of the tables and their rows, and
  `record_name` gives the name of a row. Looking up does not allocate.
- The rows are read-only and live outside the `World`, in the application: Play, copies and
  rollback do not copy them, and all worlds read the same ones. What changes in a save goes in
  components that name rows.
- `core.Text` is a localized text of a row: the table stores the text in the language the game is
  written in and its translations under its id. `core.record_text(rows, text, language)` gives it in
  the language of the `name_hash` of its code (that of `gui.ui_language`) and, without a translation
  or with 0, the original.
- `host` loads the tables of a type the first time a function asks for it, and again when one of its
  files changes (on disk or in the editor's memory), appears or leaves: editing a row during Play
  is seen on the next tick; `records_generation` changes with each load, so what a function builds
  from the rows (the texts it shows) is rebuilt only then. A table that does not load is left out
  (`host.app_records_failed`). The demo uses rows for its inventory, a dialogue and the waves of a
  horde ([demo](../../mirai-gameplay/references/demo.md#game-data)).
- If the struct changes, the rows are read by field name, like every asset: a new field takes the
  default of the type (`NAME_DEFAULT`) and a renamed one starts over.
- `World_Info.records` describes each type; `Record_Info.ref` is the `typeid` of its `Record(T)`,
  because reflection does not know which `T` it is: `core.record_of_ref` gives the type of a field.

## Problems

`core.Problems` stores what the loop functions could not do in a world: on which entity, why and
how to fix it. `engine.diagnostics` lists it
([API](../../mirai-agent-api/references/methods.md#server-and-execution)).

- A function receives it like any storage it writes and reports with
  `core.report(problems, e, "library.cause", format, args...)`. The message says what failed and how
  to fix it with the names of whoever uses the API: fields, assets by path (`host.assets_name`),
  bones, actions. `core.NONE` is a problem of the world.
- It is deduplicated by entity and code: repeating adds to `count` and keeps the message of the
  first report. Reporting does not allocate and without failures it costs nothing; when full, the
  new one takes the place of the oldest. A problem whose `last` is greater than a `serial` read
  earlier kept happening.
- It is `@(storage,host,by_world,shared)`: all libraries write it, in loop order. Clearing the world
  does not empty it; Play starts without problems, the rollback does not undo them and
  `app_world_replace` does not move them. Opening a document empties them: its entities are
  different ones.
- A re-simulated tick does not count again a problem that is already there; one that only has the
  corrected state enters as new.
- In a world that the application did not make the function receives `nil` and `report` does
  nothing.
- A counter that stays in a storage is a statistic (`loads`, `built`), not a failure.

## `fail`

`core.fail(format, args...)` records a rule violation with how to fix it; in a test build
(`ODIN_TEST`) it also stops the program. Expected errors are return values or enums, not `fail`;
those that happen in the loop are reported as [problems](#problems).

## Test worlds

A test that needs a world declares a struct and lets `core` describe it
(`core/test_world_test.odin`): no test writes `Table_Info` or `Storage_Info` rows, nor the init,
destroy, settle, copy and swap of its tables.

- The struct starts with `using world:core.Test_World`; each other field is a `core.Table(T)` of a
  component or the value of a storage. What the attributes of `T` say is read from the source that
  declares it, through the `core.declared_read` the generator uses: a test world cannot say
  something else of a type than a generated one. A type a test file declares may have no attribute,
  and takes the default its test gives it.
- What the application and the editor hold go in two more structs, given to `core.test_info`: a
  `@(storage,host)` as a value, a `by_world` one as a `core.By_World(T)`.
- `core.test_world_init` makes a world that holds its own `World_Info`, for a test of one world;
  `core.test_info` gives the `World_Info` alone, which says of each table and storage what a
  generated one says, for a test that hands it to the application, the editor or a history.
- Reflection does not find the defaults (`NAME_DEFAULT`, `name_default()`) nor the procedures the
  attributes name. A library that declares them exports `test_types` from a test file, which adds
  them with `core.test_type` and calls the `test_types` of the libraries it uses; the world is
  given the one of its library. A world that lacks one fails saying which entry to add.
- A library whose tables other libraries need in their tests exports them as a struct those hold
  with `using`, with the step that runs on them: `physics.Test_Physics` and `physics.test_step`.
- Test files of an imported package are compiled into every build of tests, and into no other.
- A test that writes files takes its folder from `base.test_folder`, which removes it when the test
  ends.
