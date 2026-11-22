# `core`: entities, tables and the world

`core` (layer 3) imports only `std/base`, `std/input`, `std/math`, `std/serial`.

## Entities

`core.Entity` (`base.Entity`) is a generational handle; `core.NONE` is zero (no entity uses
index 0). `std/serial` remaps `Entity` fields on save, load and replication.

- `destroy` bumps generation immediately (`alive` becomes false); rows clear at next `settle`,
  reusing indices in ascending order.
- `entities_clear` bumps all generations before releasing so old handles never revive across
  scene loads. `entities_*` belong to the generated world and `scene`/`save`, not loop code.

### Disabled entities

`Disabled` (`@(component,shared)` tag) disables an entity and its subtree:

- Components keep values but are invisible to `count`, `get`, `has`, `row_of`. Base `core`
  tables (`Transform`, `World_Transform`, `Parent`, `Name`, `Id`, `Disabled`) stay enabled
  (findable by `Id`, movable, reparentable).
- Own `Disabled` and effective `entity_off` are separate: enabling a parent keeps children with
  own `Disabled` or per-component `disable` off. Children born under disabled parents start off.
- `core.settle` recomputes off-state only when `Disabled` or hierarchy changes and moves rows
  in the same settle. Libraries see remove/add (no turn-on callbacks); networking keeps the
  object and disables the replica except section-disabled ones
  ([network](../../mirai-networking/references/multiplayer.md#what-the-game-declares)).

### Persistent identity

`Id` (`base.Entity_Id`, 0 = none) identifies entities in scenes, prefabs, saves, networking and
editor API. `Entities.ids` maps `Id` to `Entity` in O(1):

- `entity_of` reflects the last settle of `Id` (unsettled adds are not found; destroyed entities
  stop matching immediately); `id_of` reads the row.
- Index follows `Id` `changes`; `world_copy`/`world_swap` carry it (`ids_moved`). Duplicate
  `Id`s keep the first indexed until it leaves. OOM rebuilds at next settle.
- New `Id`s come from `base.entity_id_next`: `id_new` in a world (skips live settled `Id`s),
  `asset.scene_new_id` in documents.

## Tables

`core.Table(T)` stores dense parallel values, entities and stamps plus a paged entity-to-row map
(empty table = zero memory). Enabled rows occupy `0..<count(t)`; swap-remove never mixes
sections.

- **Access in type:** `^Table(T)` writes; `^Table(T,.Read)` reads (compile error on write); read
  helpers take `^Table(T,$A)`.
- **Reads stamp nothing:** `get`, `at`, `row_of`, `has`, `view`/`view_at` (borrowed read-only
  refs valid until settle), `join` + `each_joined` (copies) / `each_joined_ref` (refs, follows
  first table's order).
- **Writes stamp rows:** `edit`, `edit_at`, `free` (on `shared` tables) return `^T`, stamp with
  a new `version` and snapshot original bytes on first request; settle restores the old stamp
  (and `version` if nothing changed) when bytes are unchanged. `edit_dirty`/`edit_dirty_at` skip
  byte compare; `writable` stamps all enabled rows. `page_stamps` tracks max per `STAMP_PAGE`.
- **Pending structural ops:** `add` (add/replace), `remove`, `disable`, `enable` queue in
  `pending` until `table_settle`, which discards dead entities and reserves all adds up front
  (OOM applies none). `staged`/`staged_has` see pending adds in the same step.
- **Monotonic stamps & base tables:** `version` and `layout` only grow across `table_copy`/
  `table_swap` (unused edit rollbacks never reuse a published stamp). `disable` on a `base`
  table triggers `core.fail`.
- **Delta copy:** `table_copy_changed(dst, src, &mark)` copies only differently stamped rows for
  a same-origin mirror (network client history); call `copy_marks_follow` after
  `host.app_world_replace` ([replace](host.md#the-application)), or copy whole after foreign
  data.
- **New rows (`added`):** `added(t, row)` is odd stamp parity—true until the writer edits and
  settles the row (preserved across copy, rollback, disable/enable). Use it for first-tick setup
  instead of an `initialized` flag.
- **Owners (`locks`):** `@(component,locks="core.Transform")` locks that row by struct offset
  (copy-safe) while enabled. Non-owners use `free` (returns `nil` if locked). Two owners or an
  unowned write triggers `core.fail` naming both.

### What changed since the last read

Each reader keeps a `core.Seen` per table and calls `changes(t, &seen)` (advances `seen`):

- `each_changed(t, &c)` iterates rows written/added/enabled since (all rows if `c.all`, none if
  `!c.written`); `changed(t, c, row)` tests one row.
- `c.gone`: entities whose row left enabled state since last read (valid until next settle; may
  also reappear in stamped rows). `c.all`: table was copied, swapped, cleared or log overflowed
  (in-place rollback [replace](host.md#the-application) reports written rows, not `all`).
- Whole-rebuild readers use `touched(t, &seen)` (any change) or `reshaped(t, &shape)` (row-set
  change only), combinable with `|`.
- `gone` allocates on first leave (`max(2*rows, GONE_CAPACITY)`), never allocates in settle, and
  drops its oldest half when full (falling behind forces `all`).

### Per-entity maps

`core.Entity_Map(T)` holds external per-entity mirrors (voices, bodies, render handles) with
generation checks and a flat packed sparse index (owned across copies, no alloc on steady
frames):

- `entity_map_put` replaces an older generation at the same index: check `entity_map_held` first
  to release owned resources. Swap-remove invalidates stored indices/pointers.
- `entity_map_left` yields and removes entries that left a table per `changes`
  (`entity_map_prune` when nothing needs release).

```odin
c := core.changes(sources, &state.seen)
at, left := 0, Voice_Entry{}
for _ in core.entity_map_left(&state.entries, sources, c, &at, &left) {
    voice_release(left)
}
for row in core.each_changed(sources, &c) {
    e := core.entity_at(sources, row)
    if old := core.entity_map_held(&state.entries, e); old != core.NONE && old != e {
        if entry := core.entity_map_get(&state.entries, old); entry != nil {
            voice_release(entry^)
        }
    }
    _, _ = core.entity_map_put(&state.entries, e, voice_make(core.at(sources, row)))
}
```

## Creating with components of other libraries

`core.Commands` creates/destroys entities and adds/removes rows in any table at step end:

- `commands_add` adds only a row the entity lacks (existing row triggers `core.fail`);
  `commands_added` returns the pending row to finish setup; `commands_of(w)` builds from
  `World_Ref` (e.g. `scene.spawn`).
- The generator settles all tables after any step receiving `Commands`.

## Queues and references

- `Queue(T)` (`@(storage,queue)`): many push, one owning library calls `take` (valid until next
  `push`). Fixed-room queues use `offer`/`refuse` and owner `queue_serve` (reports drops/
  refusals once). All other non-`shared` storages have one writing library.
- `Events(T)` over `Log(T)`: owner pushes and never clears; loop readers receive `items` since
  their last read via generated cursors; outside code uses `log_since` (`whole` on trim overflow
  or foreign log). `host` ages logs at frame end (`World_Info.events_age`; `world_events_age`
  after manual `world_run`; `fixed`-read logs age only when a tick ran).
- Only two change channels exist: state (`changes`/`touched`/`added`) and cursor logs
  (`Events`).
- `Ref(S)` is a read-only storage pointer (writes through it are an unchecked bug).

## Waiting

Waits store a target tick (plain data, copied/rolled back/saved); no coroutines or `await`:

- `deadline(time, seconds)`, `due(time, at)` (0 = due, `NEVER` = never), `elapsed(time, since)`,
  `ticks_of`, `seconds_of`. Write rows only at start and end—never count down per tick.
- `Own_Pace` entities use `own_time(time, clock, paces, e)` (accumulate per tick if pace
  varies).
- Delayed queue requests: `later(&q, time, seconds, item)` + `take_due(&q, time)` (`take`
  refuses `later` items; queues are not saved—use a component deadline if persistence is
  needed).

```odin
for row in 0..<core.count(timers) {
    t := core.at(timers, row)
    if core.added(timers, row) {
        core.edit_at(timers, row).end_tick = core.deadline(time, t.duration)
    } else if core.due(time, t.end_tick) {
        core.edit_at(timers, row).end_tick = core.NEVER
    }
}
```

## Core storages

| Storage | Class | Role |
|---|---|---|
| `Time` | `keep` | Sole simulation clock (`tick`, `seconds`, `dt`, `playing`, `resimulating`); `time_advance`. |
| `Clock` | `keep` | `paused`, `scale` (<= `CLOCK_SCALE_MAX`) via `Clock_Requests` (`pause`/`resume`/`time_scale`); client accepts only `clock_follow` else problem `core.clock_network`. |
| `Input` | `keep` | Tick input (`*_down`/`pressed`/`released`, mouse, wheel, `window_size`, `device`); queried via `key_down`/`pressed`, `mouse_*`, `axis` ([platform](../../mirai-platform/references/platform.md#input)). |
| `View` | `keep` | Active camera (`Perspective`/`Orthographic`/`Custom`, `shift`, `clip_plane`, `layers`, `carried`); `view_ray`, `VIEW_DEFAULT`. |
| `Frame_Time` | `copy=false` | Frame state (`accumulator`, `dt`, `alpha`, `phase`, `dilation` by [network client](../../mirai-networking/references/multiplayer.md#the-tick)); never copied/swapped. |
| `Frame_Input` | `copy=false` | Current frame `Input` for presentation; does not consume tick deltas/edges. |
| `World_Id` | `copy=false` | Unique app world handle (index+gen) for `by_world`/`Shared` lookup (never raw addresses); 0 outside app. |
| `Jumps` / `Hierarchy` / `Propagation` | derived / `copy=false` | Teleport deltas (`jump`), child tree, propagation scratch. |

- **`Time.resimulating`:** true during rollback replay. Non-simulation sinks (`audio_requests`,
  `multiplayer.send`) drop output; tick inputs (including UI events,
  [gui](../../mirai-gameplay/references/libraries.md#gui)) replay identically.
- **`Own_Pace`** (`replicated` component): keeps entity running at `rate` of real time under
  slow motion (`pace_of = rate / scale`). Compensated by
  [locomotion](../../mirai-physics/references/engine.md#own-pace) and animation (`dt * pace_of`),
  not `Rigid_Body`. `rate` outside `(0, CLOCK_SCALE_MAX]` reports `core.own_pace`.
- `Simulation_Settings.tick_rate` sets fixed Hz. `Phase`: `Input, Fixed, Frame, Late, Ui,
  Render, Release`. `Loop`: `Game, Editor`.

## Network

- `core/network.odin`: `Network` (`keep`: `Standalone`/`Server`/`Client`), `Remote` tag (entity
  decided by another end; cleared on role change), `owned(remotes, e)` (false on client
  replicas; `save` refuses clients), `Sync_Check`/`Simulation_Hash` (non-table sim hash for sync
  tests). Only
  [multiplayer](../../mirai-networking/references/multiplayer.md#authority-and-players) writes
  `Network` and `Remote`.
- `core/motion.odin`: `Motion` (velocities, CoM, step group; written by physics), `Vertical`
  (planet-up frame, `vertical_of`), `Pose_Target` (`placed` teleports, `follow` pushes each
  tick; unowned ones handled by `pose_targets_place` in `fixed`).

## World queries

`core/query.odin`: physics sets `World_Queries.open` once; `world_query` opens a `World_Query`
(no-op if none) for cameras/rigs without importing physics. `support` tracks moving ground. Pass
`World_Read` or `World_Ref` for another world.

## Ground

`core/ground.odin`: single writer (terrain in `terrain_update`) sets `Ground_Queries.open` and
pushes world-box `Events`: `changed` (surface, for foliage) and `unloaded` (collision residency,
for navigation). `ground_query` probes highest ground along a line (`Ground`, `None`, `Empty`,
`Unloaded`); valid during the opening step and safe inside its jobs.

## Births

`core/births.odin`: `Births` queue keyed by `birth_channel` (`base.name_hash`); emitters push
without knowing `vfx`, which consumes in `fixed`
([channels](../../mirai-world/references/vfx.md#channels)).

## Transform and hierarchy

- `Transform` (`shared`, local; owners declare `locks`), `World_Transform` (written only by
  `transforms_propagate`; `scene.propagate` runs it on load; use `world_of` earlier), `Parent`.

### Requested places

`place(placer, e, position, rotation, teleport=true, at_rest=false)` via `core.Placer`
([parameter group](generator.md#parameter-groups)) writes free `Transform`s immediately or
queues into `Places` for owners (`fixed`/`simulate`, before `places_drop` which reports
`core.place`):

- `teleport=true` emits `jump` (no interpolation); `at_rest=true` zeros velocity (respawn/reset;
  default preserves velocity for portals).

### The `Hierarchy`

Child index of `Parent` in `order` order; written only by `core.settle` (read via
`core.Ref(core.Hierarchy)` or `core.world_storage_of`; reflects last settle).

- **Cycles & dead parents:** cyclic or dead `Parent` leaves entity as root (cycles log a warning
  and retry on link changes). Destroying an entity destroys its subtree at settle (reparent
  first to keep children).

### Queries

Downward via `Hierarchy` (`first_child`, `next_sibling`, `subtree_next`, zero-alloc); upward via
`Parent` (`ancestor_with`, `is_under`, capped at `HIERARCHY_DEPTH`). World poses: `world_of`,
`world_transform_or_compute`, `world_set` (preserves scale), `local_under`.

```odin
for at := root; at != core.NONE; at = core.subtree_next(h, root, at) {
    // parents before children
}
_ = core.place(placer, e, {0, 2, 0}, teleport = true, at_rest = true)
```

### Propagation

`transforms_propagate` (`fixed` and `late`, stage `end`) composes dirty `Transform`s,
`Hierarchy.moved` (`core.Log`), and children of lost `Transform`s top-down via `std/math` TRS.
Full walk runs only on unseen world/log overflow. `Jumps` transforms `previous` across the
subtree so interpolation starts on the arrival side.

## World reflection

`core/world.odin`, `core/world_data.odin`: generated `World_Info` drives generic code via
`World_Ref{data, info, place}` (or `World_Read` for read-only reflection without settling or
bumping revisions):

- `world_settle` settles a `World` outside loops; `world_run` runs selected library steps in
  phase order with binding, settle and temporary `Time` (`physics.step_world`,
  `anim.animation_evaluate`).
- `value_copy`/`value_free` handle dynamic arrays/slices (empty borrowed slices in storage
  `free`).
- `raw_*` see enabled and disabled rows; `raw_touch` stamps in-place `raw_find` writes;
  `raw_drop`/`raw_put` mutate immediately without allocating (undo/cancel).
- `Storage_Info.for_device` binds `<name>_for_device(rhi.Device_Info)` GPU defaults (untyped).
- Migration ([editor reload](../../mirai-editor/references/editor.md#build-and-reload)):
  `world_migration_make` (`Move`/`Convert`/`New`, `table_map`), `place_migrate`,
  `table_values_convert`. `world_info_index` builds type indices and `World_Schema`.
- Lifecycle: `world_init`, `world_destroy`, `world_copy` (fallible), `world_swap` (zero-alloc,
  keeps `copy=false`), `world_clear` (resets derived storages,
  [classes](generator.md#attributes)).
- `world_copy_changed`: copies changed tables and written storages (via `copy_kept` if present).
  Storage revisions (`core.Stamp(S)`) bump on `^S`, `world_storage*`, `Hierarchy` settle, copy/
  swap/clear. `MIRAI_CHECK_WRITES` fails on unbumped storage mutation (e.g. writing via `Ref`).
- `by_world` values use `world_attach`/`world_detach` and `host.app_world_storage`.

## Joining one world into another

`world_union(dst, src, parent, &entities)` (`world_union.odin`) merges settled `src` into `dst`
under `parent`, remapping `Entity` fields via `World_Schema` (`NONE` if outside `src`). All-or-
nothing reservation (no alloc when room exists); `single` rows arrive disabled. `roots` joins
selected subtrees (used for `Keep`). `world_run_copy(dst, src)` copies `keep` storages and
settings with `Entity` fields cleared to `NONE`.

## Named ids

`core/names.odin`: code is sole source of shared ids; data stores numbers (except actions):

- `@(names="PREFIX_") T :: distinct u16`: constants across engine/plugins/game named by
  lowercase suffix or `@(name="...")`; `@(name_requires="C")` gates inspector/use;
  `@(name_bits="T")` marks bitmasks. Duplicate names = generator error; duplicate values =
  `#assert`. Editor writes/renames in `game/names.odin` (engine/plugin values are read-only).
- `@(names,actions)` (`inp.Action`) + `@(actions)` `u8` enums (no explicit values): generator
  assigns sequential ids in library order (`World_Info.actions`, `core.actions_of`). Saved by
  name (`by_name`), networked by number; renumbering triggers migration
  ([actions](../../mirai-gameplay/references/control.md#actions)).

## Game data

`core/records.odin`: `.records` tables declare schemas
([format](../../mirai-assets/references/kinds.md#records)); build generates structs,
`NAME_DEFAULT` and enums into `records_gen.odin` (`@(record="<path>")`; `World_Info.record_codes`
for `type` columns). Non-declaring tables hold rows of another type.

- `core.Record(T)` (`Asset_Id` + `Record_Id`, zero = none); `core.Records(T)` step param reads
  all tables of `T` (read-only, app-owned, never copied on Play/rollback): `core.record`
  (reports `records.missing`), `record_get`, `records_count`, `records_at`, `record_name`,
  `records_generation` (bumps on hot-reload; failures in `host.app_records_failed`).
- `core.Text` + `^core.Texts` + `core.text(texts, key, lang)` resolve `.strings`
  ([one store](../../mirai-assets/references/kinds.md#texts), `gui.ui_language`).
- Editor edits by column schema directly; renamed columns retain `was` tags
  ([migration](../../mirai-assets/references/serial.md#stdserial)); `core.record_of_ref` maps
  `Record(T)` `typeid` to `World_Info.records`
  ([demo](../../mirai-gameplay/references/demo.md#game-data)).

```odin
if row, ok := core.record(weapons, slot.weapon, problems, e); ok {
    title, _ := core.text(texts, row.name, lang)
    if row.damage <= 0 {
        core.report(problems, e, "game.weapon", "%s has non-positive damage", title)
    }
}
```

## Problems

`core.Problems` (`@(storage,host,by_world,shared)`) records per-world runtime failures for
`engine.diagnostics` ([API](../../mirai-agent-api/references/methods.md#server-and-execution)):

- `core.report(problems, e, "library.cause", fmt, args...)` (`core.NONE` = world-level, asset
  names via `host.assets_name`). Deduplicated by `(entity, code)`: repeats bump `count` and
  `last`, keeping first message; zero-alloc, evicts oldest when full, nil-safe outside app.
- Survives `world_clear`, rollback and `app_world_replace`; Play starts clean; opening a
  document clears it. Resimulated ticks do not recount existing problems. Counters in storages
  are stats, not problems.

## `fail`

`core.fail(format, args...)` logs an invariant violation with fix guidance (aborts in
`ODIN_TEST`). Use return values for expected errors and [problems](#problems) for loop failures.

## Test worlds

Declare `@(test_world)` in `*_test.odin` (`using world: Test_World`, plus `core.Table(T)`, fixed
arrays of tables `<T>_<index>`, or storages; optional `host="S"`, `editor="E"` with
`core.By_World(T)` for `by_world`; field tags `mirai:"game"`, `mirai:"name=..."`). Top-level,
non-private types only.

- Generator writes `worlds_gen_test.odin` ([outputs](generator.md#outputs)) with package-local
  `test_world_init`/`destroy`/`settle`/`ref`/`copy` and `test_info`/`destroy`/`index` (auto-run
  by `mirai check`/`mirai test`; only `core`'s copy is tracked in git).
- Shared test fixtures embed library structs with `using` (e.g. `physics.Test_Physics`,
  `physics.test_step`). Temp folders come from `base.test_folder`.
