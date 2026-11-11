# Rules of a run with respawn and the test that plays it

The second read of [third-person](../third-person.md).

## The rules

One function in `game/game.odin` owns the state of a run. A character that falls in `Water` floats
at the surface, so a test of its height never fires: `Character_State.submersion` (0 to 1 of the
body under the surface) says it fell in, and `core.place` sends it back to where it started. The
deaths are of the run: a component on a `core.Keep` root, which passes to the next scene and that
a save keeps; the first tick makes it.

```odin
@(component)
Run :: struct {deaths:i32}

@(step="fixed",stage="react",server)
game_fall :: proc(runs:^core.Table(Run),players:^core.Table(Player),
                  worlds:^core.Table(core.World_Transform,.Read),states:^core.Table(phys.Character_State,.Read),
                  placer:core.Placer,commands:core.Commands) {
    if core.count(runs)==0 {
        root:=core.commands_create(commands)
        core.commands_add(commands,root,core.Keep{})
        core.commands_add(commands,root,core.name_make("Run"))
        core.commands_add(commands,root,Run{})
        return
    }
    run:=core.at(runs,0)
    for row in 0..<core.count(players) {
        e,player:=core.entity_at(players,row),core.at(players,row)
        world,placed:=core.get(worlds,e)
        if !placed {continue}
        if !player.spawn_ok {player.spawn,player.spawn_ok=world.position,true}
        if state,found:=core.get(states,e);found && state.submersion>0.2 {
            core.place(placer,e,player.spawn,at_rest=true)
            run.deaths+=1
        }
    }
}
```

`Player` holds `spawn:[3]f32` and `spawn_ok:bool`, where this body started in this scene. Coins,
enemies, checkpoints and goals take the same shape: a component on the entity, the state of the
run on its root, one `@(step="fixed")` that reads them. The HUD binds a field by name:
[hud-panels.md](../ui/hud-panels.md). The menus are in `game/shell.odin`.

## The test that plays it

`tests/scenarios/run.mirai`, then `mirai play test . run`:

```json
{"scene": "arena/main.scene", "steps": [
  {"name": "the game opens", "method": "play.step", "params": {"for": 30}},
  {"name": "start playing", "method": "play.step", "params": {"segments": [
    {"for": 2, "keys": ["Enter"]}, {"for": 10}]}},
  {"name": "walk forward", "method": "play.step", "params": {"for": "1s", "keys": ["W"]}},
  {"name": "it walked", "method": "play.check", "params": {"conditions": [
    {"entity": "Player", "field": "world_position.2", "compare": "Below", "number": 4.5}]}},
  {"name": "into the water", "method": "play.set",
   "params": {"entity": "Player", "position": [16, 2, 0]}},
  {"name": "it falls and comes back", "method": "play.step", "params": {"for": 300, "until": [
    {"entity": "Run", "field": "Run.deaths", "compare": "Equal", "number": 1}]}}
]}
```

More of what a scenario does: [scenario.md](../testing/scenario.md). What the player sees:
`capture` with a `path`.
