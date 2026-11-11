# Saves: slots, autosave, checkpoints, profile

`engine/save` writes the world into a slot, a file in the user's folder of the project. Add the
requests and read the results in a `frame` step; the library serves them at the start of the next
frame, also while the clock is paused.

```odin
import save "mirai:engine/save"

@(step="frame")
game_saves :: proc(actions:inp.Frame_Input_Of(Action),saves:^save.Save_Requests,
                   results:core.Ref(save.Save_Results),network:core.Ref(core.Network)) {
    if network.role!=.Standalone {return}          // a network session does not save
    if inp.pressed(actions,.Save) {save.request_save(saves,"quick")}
    if inp.pressed(actions,.Load) {save.request_load(saves,"quick")}
    for result in results.queue.items {            // one per request served, for one frame
        if result.error!=.None {continue}          // a save.Error: .Not_Found, .Corrupt...
        // result.op is .Save or .Load; result.kind .Manual, .Autosave or .Checkpoint
    }
}
```

## What a save keeps

- The components of every entity, the ones code made too. A `transient` field is not stored and a
  component stored by an older layout migrates by field name.
- Never a storage: what must survive is a component, the state of a run on a `core.Keep` root
  ([below](#the-state-of-a-run)). Bodies, caches and voices are rebuilt by their libraries from the
  components.
- Loading replaces the world: every handle changes and events in flight name entities that are
  gone. Hold `core.Id`s, not `core.Entity`, across a load; `core.entity_of(es, id)` finds one.
- The clock returns to the saved tick. A slot that does not load whole leaves the world as it was.

## Requests

- `request_save(r, slot)`, `request_load`, `request_delete`; `request_checkpoint(r)` and
  `request_load_checkpoint(r)` use one reserved slot; `request_autosave(r)`.
- `request_new_game` starts a game from zero, `request_end_game` turns it off (a menu does that:
  no autosave and no time counted); `request_label` names the slots.
- They return nothing; each leaves its `Result`, served at the start of the next frame.
  `.Invalid_Slot` (a name of letters, digits, spaces, `-`, `_`) and `.Invalid_Label` are also the
  problem `save.request`; `.Busy` is too many slots waiting to be written, and
  `.Unavailable` a client of a network session.
- Autosave is a project setting (`Save_Settings`): it rotates slots by time and
  when a scene replaces another.

## The state of a run

A score, an inventory or the lives are components on a `core.Keep` root: it passes to the scene
that replaces this one with what hangs from it, a save keeps it and it replicates as any entity.
The seat of a player is one (`inp.seat_of(seats,body)`); for the run of all, make one once.
`@(storage,keep)` is for state only an interface shows, as the page of a menu.

```odin
@(component)
Run :: struct {score:i32}

@(step="fixed",server)
game_run :: proc(runs:core.Read(Run),commands:core.Commands) {
    if core.count(runs)>0 {return}
    root:=core.commands_create(commands)
    core.commands_add(commands,root,core.Keep{})
    core.commands_add(commands,root,Run{})
}
```

## Progress that is not a save

A `@(storage,persist)` of plain data is written to the player's profile, outside any slot:
achievements, unlocks, the last level. No `Entity`, string, slice, map or pointer fields.

```odin
@(storage,persist)
Progress :: struct {best_ms:u32, unlocked:u32}
```

The profile is read once when a world first runs and written by itself when the value changes:
when it rests, after it changes for a while without resting, and when the world goes. So are the
machine settings and rebinds of the player.

## Pitfalls that fail silently

- A function that ignores the `save.Error` of a request loses it silently (`.Busy`, bad name).
- Thumbnails need a renderer: a headless run saves without one.
