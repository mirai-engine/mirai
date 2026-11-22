# The world generator

`cook/build/world.odin` (engine-time) parses packages with `core:odin/parser` and generates the
glue joining libraries. Run via `mirai generate <project>` (auto-run by `mirai build`, `edit`,
`play`). Compiles need `-custom-attribute:` with `build.CUSTOM_ATTRIBUTES` (the `mirai` CLI
itself uses `-ignore-unknown-attributes`).

## Which packages it reads

Scanned in library priority order (also used for tie-breaking step order):

1. Engine: `core`, `engine/**` -> `World`, `Shared`.
2. Active plugins (deps first): `plugins/<n>/runtime/**` -> `World`, `Shared`.
3. Project: `game/**` -> `World`, `Shared`.
4. Editor: engine `editor/**`, plugin `plugins/<n>/editor/**`, project `editor/**` -> `Editor`.

Skips `_test.odin`, `.`-prefixed folders, `testdata`, and packages with no attributes. Editor
packages never reach game builds.

## Attributes

Attributes attach to top-level `Name :: struct` and `name :: proc` declarations (unique per
package).

| Target | Attributes & semantics |
|---|---|
| Component | `@(component)` -> `core.Table(T)` per world. Options: `shared` (multi-writer), `locks="Type ..."` (owns `shared` rows), `replicated` / `="owner"` / `="others"` / `="object"` ([multiplayer](../../mirai-networking/references/multiplayer.md#what-the-game-declares)), `single` (at most 1 enabled row at index 0 by turn order; section/prefab/joined rows arrive disabled; `@(storage,scene)` rejected), `far` (stays enabled on section unload: `Terrain`, `Foliage`, [unloaded](../../mirai-gameplay/references/libraries.md#scene-references)), `derived` (runtime-only; skipped by save/Duplicate/undo/doc), `description="..."`. Field line comments populate `Table_Info.fields`. |
| Storage | `@(storage)` -> single value per world (one writing library unless `shared`/`queue`). Options: `queue` (many push, owner takes), `shared`, `host` (in `Shared`, never copied), `by_world` (with `host`: `core.By_World(S)`, `nil` outside app, by-value is error), `presentation` (with `host,by_world`: GPU readback, forbidden in `fixed`, [readbacks](../../mirai-rendering/references/views.md#extension-stages)), `setting` / `setting="machine"` (`core.Setting_Kind`, `Generated.machine_settings`, forbidden on components/editor, [settings](../../mirai-projects/references/projects.md#project-settings)), `keep` (survives `world_clear`, unsaved), `persist` (`keep` + profile-saved plain data; rejects `Entity`/dynarray/slice/map/ptr/union/string, [profile](../../mirai-gameplay/references/libraries.md#save)), `save_prepare="f"` (`proc(^S, core.World_Ref) -> bool`, materializes before save; false aborts), `reset="p"`, `copy="p"`, `copy_kept="p"` (delta history copy), `copy=false`, `swap="p"`, `diff="p"` (`(a,b:^S,buf:[]byte)->string`), `free="p"`. |
| Step | `@(step="phases")` (`input`, `fixed`, `frame`, `late`, `ui`, `render`, `release`; `release` game-only; `ui` engine/editor-only). Options: `loops="game editor"`, `stage="..."` (default `intent`), `after="..."`, `before="..."`, `require="A B"` (early-return if any table empty), `server` (skipped on `Client` incl. resimulation; never on queue consumers). |
| Other | `@(net_message)` (`from="client"\|"owner"`, `reliable`, [messages](../../mirai-networking/references/multiplayer.md#what-the-game-declares)), `@(draw="name")` (`proc(^ui.Context, ui.Draw_Node)`, `World_Info.draws`, [gui](../../mirai-gameplay/references/libraries.md#gui)), `@(params)`, `@(names)`/`@(name_bits)`/`@(name)`/`@(name_requires)`/`@(actions)` ([named ids](core.md#named-ids)), `@(mind="name")`/`@(act="V ...")`, `@(record="...")` (`records_gen.odin` only, plain data, [game data](core.md#game-data)). |

- **Storage clear classes (`core.world_clear`):** derived (default, incl. `queue`/`Events`)
  reset via `reset` or `free` + default; `keep`, `persist`, `setting` and `copy=false` stay
  untouched.

```odin
@(component, replicated, description = "Health points.")
Health :: struct { current, max: f32 }
HEALTH_DEFAULT :: Health{current = 100, max = 100}

@(storage, queue)
Damage_Requests :: struct { queue: core.Queue(Damage_Event) }

@(step = "fixed", stage = "react", server, require = "Health")
damage_apply :: proc(reqs: ^Damage_Requests, healths: ^core.Table(Health)) {
    for d in core.take(&reqs.queue) {
        if h := core.edit(healths, d.target); h != nil { h.current -= d.amount }
    }
}
```

### Initial values

Generic creation and storage init/clear use package-level `NAME_DEFAULT` or `name_default()`
(uppercase or `snake_case`; zeros if absent). `@(actions)` enums use `<ENUM>_DEFAULTS` or
`<enum>_defaults()` returning `[E]Action_Bindings`. Saved scenes load saved bytes, not defaults.

- **Strict literals:** any `T{...}` / `pkg.T{...}` literal (outside its default declaration) for
  a type with a default MUST name every field that default sets nonzero, or generation fails.
  Start from the default (`v := phys.WALK_DEFAULT`) and override; use a variable (`none: T`) for
  intentional zeros. Comparisons/field reads are exempt.

## Where the data goes

```text
.mirai/gen/
  editor_world/world.odin    package world: World, Shared, Editor, info()
  shipped_world/world.odin   game world without dev plugins (game build only)
  game/main.odin             shipped game entry: host.player_run
  editor/main.odin           editor/player dynamic lib: exports mirai_project_info
```

`gen` is the `generated` collection (rewritten only on diff). Fields use `snake_case` (prefixed
with package name on collision/keyword); imports alias as `p_<name>`. `info()` builds
`core.World_Info` via `core.world_info_index` ([reflection](core.md#world-reflection));
`core.world_init`/`destroy`/`copy`/`copy_changed`/`swap`/`clear` loop over `World_Info` (leaving
`Id` index synced, [identity](core.md#persistent-identity)).

## Parameters

Bound by type in any order:

- Tables: `^core.Table(C)` (write), `^core.Table(C,.Read)` (read; helpers take
  `^core.Table(C,$A)`).
- Storages: `^S` (write), `core.Ref(S)` (read ptr), `S` (copy for small storages),
  `core.Stamp(S)` (for `core.touched`).
- World & entities: `core.Ref(core.Entities)`, `core.Commands`
  ([commands](core.md#creating-with-components-of-other-libraries)), `core.World_Ref`,
  `core.World_Read` (read-only reflection/queries, no settle or revision bump).
- App & data: `^host.Assets`, `^render.Renderer` (plugins via `engine/render`),
  `^host.Frame_Extras`, `^audio.Mixer` (games via `engine/audio`), `^jobs.Job_System`,
  `runtime.Allocator` / `mem.Allocator`, `^core.Texts`, `^host.App`, `core.Records(T)`,
  `core.Inbox(M)` (of `@(net_message)`, reads `core.Net_Messages`), `@(params)` by value.

### Parameter groups

`@(params)` bundles parameters into a by-value struct (expanded recursively; duplicate read-only
fields bound once; duplicate writes across loose params/groups are errors; write fields keep
single-writer rules):

```odin
@(params)
Placer :: struct {
    transforms: ^core.Table(core.Transform),
    parents:    ^core.Table(core.Parent, .Read),
    places:     ^core.Places,
    jumps:      ^core.Jumps,
}
```

- Generic `struct($E:typeid)` binds an `@(actions)` enum (`inp.Input_Of(Walk_Action)`), setting
  its `@(names,actions)` field to `E`'s base offset.

### Minds

A `behavior` mind pairs an action enum, `@(mind="name")` (`first param: ^ai.Think(Enum)`), and
one `@(act="Value ...")` per value (`first param: ^ai.Act(Enum) -> ai.Status`):

- Emits one `fixed` `server` `intent` step receiving `Mind_World` + union of remaining params,
  running `behavior.minds_tick` with context in `ai.Mind_Context.user`.
- Rejects missing/duplicate act values, orphan acts, wrong signatures, cross-package enums,
  duplicate names, app parts/`@(step)`/`@(private)` on mind procs, or missing `behavior` plugin.

## Rules the generator checks

`mirai generate` lists every error with file, line and fix:

- Unknown param type, wrong app-part form (e.g. `host.Assets` by value), defaulted param, or
  non-void step return.
- Multi-library write to non-`shared`, non-`queue` table/storage in same loop (use a `queue`).
- `queue` on non-storage or storage with `core.Events`; unknown `events` option; `keep`/`reset`
  on non-`World` storage, `setting`, `copy=false`, or both together.
- `order=` (removed—use `stage` + `after`/`before`), unknown stage/phase/loop, missing `after`/
  `before` target, cross-stage `after` to later stage, dependency cycles, duplicate step/type
  name.
- `server` without `core.Network`; editor step in `game` loop; `game`/`fixed` step reading
  editor data; `fixed` step receiving `presentation`; `ui` step in game/plugin runtime;
  `release` outside `game`.
- `locks` on non-`shared` component; invalid `@(params)` (empty, pointer param, editor bundle in
  library, duplicate write binding, bad generic); omitted nonzero default field in literal;
  `[E]Action_Bindings` inside a struct; invalid `replicated`/`net_message`/`record`; [dedicated
  server](#dedicated-server) violations.

### Dedicated server

`--dedicated` ([arguments](host.md#arguments)) skips `ui` and `render`. In every project, a
`game` step running only in `ui`/`render` (with or without `release`) is rejected if it:

- is `server`; writes a `replicated` component; takes `core.Commands`; or writes a non-`queue`,
  non-events table/storage that another phase reads and no other phase writes.

## Generated functions

Each step generates `call_<name>` (binding, settle, `app.step_ns`, profile zone
([profiling](host.md#the-frame)), `core.CHECK_WRITES` wrappers) and per-phase callers
(`game_fixed`, `editor_frame`, etc.) wired into `info.steps[i].call` and
`info.order[loop][phase]` for `core.world_run` ([reflection](core.md#world-reflection)).

- Settles each `^Table` after the step; `Commands`, `World_Ref`, `Disabled`, or `Parent`
  triggers full `core.settle` (only visits tables marked dirty via `raw_follow`—hand-built
  worlds scan all). `core.Ref(core.Entities)` triggers no settle.
- `^S` bumps storage revision before running (`queue`-only storages only when length/dropped/
  refused changes; `Events` cursors only on cursor movement; `World_Info.events_age` trims aged
  events). Table `version` moves only on actual row writes ([tables](core.md#tables)).

### Order

Every phase runs 7 fixed stages (`begin`, `input`, `intent` default, `apply`, `simulate`,
`react`, `end`). In `fixed`: `begin` (core/net start, pose targets) -> `input` (actions, seats,
`Move_Input`) -> `intent` (game logic/requests) -> `apply` (spawns, paths, anim sample) ->
`simulate` (locomotion, ragdolls, fields, terrain, places, physics step) -> `react`
(destruction, post-physics anim, contacts) -> `end` (transforms, particles, net publish).

- **Within a stage:** library order, respecting: (1) `after`/`before` names, (2) `queue` push
  before owner take, (3) write before read. Priority: **name > request > read** (cycles are
  errors resolved by one explicit name).
- Use `after`/`before` only for non-data edges (reading previous tick, breaking cycles,
  `shared`/`Commands`/app ordering, e.g. `before="physics_prepare"`, `net_tick_tail`). Name only
  engine or depended-plugin steps.

### What a parameter declares

- `^Table(C)` -> single writer (unless `shared`), `CHECK_WRITES`, settled after step
  (`Disabled`/`Parent` -> full settle). `^Table(C,.Read)` / `Ref(S)` / `S` -> read-only, no
  settle/revision.
- `^S` -> owner/queue/shared write, bumps revision. `Events` read -> per-step cursor view
  (copied with `World` for `fixed`, frame-local otherwise).
- Steps run serially; parallelize internally with `^jobs.Job_System`. `context.temp_allocator`
  clears on step return.

## Outputs

- `game/main.odin`: `os.exit(host.player_run(&info, <exe_dir>, "", os.args[1:]))` (shipped
  binary merges `settings.mirai`,
  [settings](../../mirai-projects/references/projects.md#project-settings)).
- `editor/main.odin`, `play/main.odin`: `package mirai_project` exporting `mirai_project_info`
  ([binaries](../../mirai-projects/references/projects.md#engine-binaries),
  [host](host.md#project-libraries)). `editor` imports `generated:editor_world`, `game` imports
  `generated:shipped_world`.
- `worlds_gen_test.odin`: generated per test package with `@(test_world)` via
  `test_worlds_write` ([test worlds](core.md#test-worlds)).

## Changing the generator

- Add new attributes to `CUSTOM_ATTRIBUTES`, `type_read`, `type_procs_write`/`table_row`/
  `storage_row` (shared by game and test worlds), and [attributes](#attributes); update all
  consumers together.
- Generator is syntax-only (compiler computes sizes/aligns). `info` pointers come from
  `type_info_of` inside the project library. `Table_Info.game` marks non-plugin `project:`
  types.
- Verify:

```sh
mirai test cook/build
mirai generate templates/empty && mirai generate templates/game && mirai generate demo
```

Then compile editor/game and run player
([project verification](../../mirai-projects/SKILL.md#verification)).
