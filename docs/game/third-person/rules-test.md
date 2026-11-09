# Rules of a run with respawn and the test that plays it

The second read of [third-person](../third-person.md).

## The rules

One function in `game/game.odin` owns the state of a run. A character that falls in `Water` floats
at the surface, so a test of its height never fires: `Character_State.submersion` (0 to 1 of the
body under the surface) says it fell in, and `core.place` sends it back.

```odin
@(storage)
Run :: struct {spawn:[3]f32,spawn_ok:bool,deaths:i32}

@(step="fixed",stage="react")
game_fall :: proc(run:^Run,players:core.Read(Player),worlds:core.Read(core.World_Transform),
                  states:core.Read(phys.Character_State),placer:core.Placer) {
    for row in 0..<core.count(players) {
        e:=core.entity_at(players,row)
        world,placed:=core.get(worlds,e)
        if !placed {continue}
        if !run.spawn_ok {run.spawn,run.spawn_ok=world.position,true}
        if state,found:=core.get(states,e);found && state.submersion>0.2 {
            core.place(placer,e,run.spawn,at_rest=true)
            run.deaths+=1
        }
    }
}
```

Coins, enemies, checkpoints and goals take the same shape: a component on the entity, a storage
for the run, one `@(step="fixed")` that reads them. The HUD binds a storage field by name:
[hud-panels.md](../ui/hud-panels.md). The menus are in `game/shell.odin`.

## The test that plays it

`tests/scenarios/run.mirai`, then `mirai play test . run`:

```json
{"scene": "scenes/main.scene", "steps": [
  {"name": "the game opens", "method": "play.step", "params": {"for": 30}},
  {"name": "start playing", "method": "play.step", "params": {"segments": [
    {"for": 2, "keys": ["Enter"]}, {"for": 10}]}},
  {"name": "walk forward", "method": "play.step", "params": {"for": "1s", "keys": ["W"]}},
  {"name": "it walked", "method": "play.check", "params": {"conditions": [
    {"entity": "Player", "field": "world_position.2", "compare": "Below", "number": 4.5}]}},
  {"name": "into the water", "method": "play.set",
   "params": {"entity": "Player", "position": [16, 2, 0]}},
  {"name": "it falls and comes back", "method": "play.step", "params": {"for": 300, "until": [
    {"storage": "Run", "field": "deaths", "compare": "Equal", "number": 1}]}}
]}
```

More of what a scenario does: [scenario.md](../testing/scenario.md). What the player sees:
`capture` with a `path`.
