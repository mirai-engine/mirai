---
name: core
description: Core of a Mirai game in Odin - project layout, components, storages, @(step) functions,
  phases (fixed, frame, late, ui), requests, events, records, hierarchy, runtime prefabs, saves.
---

# Game core

A game is data (components, storages) and functions (`@(step)`) that transform it. The generator
reads `game/` and the active plugins; `mirai generate` lists its errors.

## Map

- Folders and files: [Layout](#layout). New component or storage: [Data](#data). A function and
  its phase: [Functions](#functions), [Phases](#phases). Waits: [waiting.md](core/waiting.md).
- Order, asking a library, telling the rest what happened: [wiring.md](core/wiring.md).
- Children, runtime prefabs, destroying a subtree: [prefabs.md](core/prefabs.md).
- Catalogs as rows: [records.md](core/records.md). Saves, state of a run: [saves.md](core/saves.md).
- Characters: [character](character.md); scenes, light: [world](world.md); ids: [assets](assets.md).

## Layout

```text
project.mirai   manifest: name, start_scene, plugins, window, build
settings.mirai  project settings, only what differs; input.mirai: rebinds, never by hand
cook.mirai      roots only code names (assets)
assets/ source/ binary assets; art sources, never shipped    game/  the game package
plugins/<n>/    your plugins (plugins)   tools/content/  writes generated assets (assets)
tests/scenarios/  mirai play test .           .mirai/  generated, never edited (.mirai/gen)
```

## Data

```odin
@(component)
Health :: struct {
    hp:f32 `mirai:"min=0"`,
    regen:f32 `mirai:"unit=1/s"`,
    hurt_at:f64 `mirai:"transient"`,   // derived: neither saved nor replicated
}
HEALTH_DEFAULT :: Health{hp=100}       // NAME_DEFAULT: new rows and literals start from it
```

- `@(storage)` is one value per world, written by one library; a save keeps components only, and
  a run keeps its state in components on a `core.Keep` root ([saves](core/saves.md)).
  Flat data: no pointers, maps or owned memory; another entity is a `core.Entity` field.
- Tags: `transient`, `local`, `readonly`, `hidden`, `unit=`, `min=`, `max=`, `color`, `angle`.

## Functions

```odin
@(step="fixed")
game_regen :: proc(healths:^core.Table(Health),time:core.Time) {
    for &health in core.writable(healths) {health.hp=min(health.hp+health.regen*time.dt,100)}
}
```

- Parameters say what it touches: `^core.Table(C)` writes, `core.Read(C)` reads, `^S` writes a
  storage, `core.Ref(S)` reads one, `core.Time`, `core.Input`, `core.Commands`,
  `core.Placer`; of the application, its part (`^host.Assets`, `^render.Renderer`, `^audio.Mixer`,
  `runtime.Allocator`) or `^host.App`. No result or defaults. Names are unique in the whole world.
- `core.get` and `core.at` read any table. `^core.Table` writes: `core.edit`, `core.edit_at`,
  `core.writable` mark the row, `core.set` only a new value. `core.add` waits (`core.staged_has`).
- One function writes each table; the others push a request ([wiring.md](core/wiring.md)).
  `core.free(table, e)` is the row, or `nil` when a library owns it (`Transform` of a body).

## Phases

- `fixed`: the simulation, `time.dt` per tick; a network correction may replay it. Rules,
  movement, spawning, saves. Read actions with `inp.Input_Of(Action)`; no window or mouse calls.
- `frame`: once per drawn frame (`core.Frame_Time`: `dt`, `alpha`), for presentation that is not
  a rule. `late`: after movement (cameras). `ui`: interfaces. `input`: devices and the window.
- **Edges.** Outside `fixed` use `core.Frame_Input` or `inp.Frame_Input_Of(Action)`; the generator
  refuses `core.Input` and `inp.Input_Of` there, which hold the last tick's values.

## Pitfalls that fail silently

- Writing the `Transform` of a body is refused: `core.place` or a request. A request pushed
  in a later stage than its owner's waits for the next tick; events live one tick.
- A `fixed` function that reads `core.Frame_Input` differs when a tick is replayed: use actions.
