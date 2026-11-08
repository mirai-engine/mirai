---
name: core
description: Core of a Mirai game in Odin - project layout, components, storages, @(step) functions,
  phases (fixed, frame, late, ui), requests, events, records, hierarchy, runtime prefabs, saves.
---

# Game core

A game is data (components, storages) and functions (`@(step)`) that transform it. The generator
reads `game/` and the active plugins; `mirai generate` lists its errors. Fields: `engine.describe`.

## Map

- Folders and files: [Layout](#layout). New component or storage: [Data](#data).
- A function and its phase: [Functions](#functions), [Phases](#phases).
- Order, asking a library, telling the rest what happened: [wiring.md](core/wiring.md).
- Children, runtime prefabs, destroying a subtree: [prefabs.md](core/prefabs.md).
- Catalogs as rows: [records.md](core/records.md). Saves: [saves.md](core/saves.md).
- Characters: [character](character.md); scenes and light:
  [world](world.md); ids: [assets](assets.md).

## Layout

```text
project.mirai   manifest: name, start_scene, plugins, window, build
settings.mirai  project settings, only what differs; input.mirai: rebinds, never by hand
cook.mirai      roots only code names: {"roots":["prefabs/Enemy.prefab","sounds/"]}
assets/ source/ binary assets; art sources, never shipped    game/  the game package
plugins/<n>/    your plugins (plugins)   tools/content/  writes assets (assets)
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
HEALTH_DEFAULT :: Health{hp=100}       // NAME_DEFAULT: what a new row starts as
```

- `@(storage)` is one value per world, written by one library; a save keeps components only.
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
  storage, `core.Ref(S)` reads one, `core.Time`, `core.Input`, `core.Commands`, `^core.Entities`,
  `^host.App`, `core.Placer`. No result, no default values. Names are unique in the whole world.
- `core.Read` hands out copies; a write needs `^core.Table`, whose `core.writable`, `core.at` and
  `core.get` mark rows changed (read with `core.read(table)`). `core.add` waits for the end.
- One function writes each table; the others push a request ([wiring.md](core/wiring.md)).
  `core.free(table, e)` is the row, or `nil` when a library owns it (`Transform` of a body).

## Phases

- `fixed`: the simulation, `time.dt` per tick; a network correction may replay it. Rules,
  movement, spawning, saves. Read actions with `inp.Input_Of(Action)`; no window or mouse calls.
- `frame`: once per drawn frame (`core.Frame_Time`: `dt`, `alpha`), for presentation that is not
  a rule. `late`: after movement (cameras). `ui`: interfaces. `input`: devices and the window.
- **Edges.** In `frame`, `late` and `ui` this frame's presses are in `core.Frame_Input` or
  `inp.Frame_Input_Of(Action)`; `core.Input` holds the last tick's values (its edges last a tick).

## Pitfalls that fail silently

- A literal `Health{}` or `Walk{}` drops the defaults: copy `HEALTH_DEFAULT`, change fields.
- Writing the `Transform` of a body is refused: `core.place` or a request. A request pushed
  after its owner ran waits for the next tick; events live one tick.
- A `fixed` function that reads `core.Frame_Input` differs when a tick is replayed: use actions.
