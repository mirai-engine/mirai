# Actions and seats

The engine gives `move`, `look`, `jump`, `sprint`, `crouch` and `menu` (Escape, Start); the game
adds its own. Nobody writes an action's number: members of an `@(actions)` enum, bound by default
in code. A game reads `menu` with `gui.menu_pressed` ([UI](../ui.md#events)).

## Declare

```odin
@(actions)
Action :: enum u8 {Use,Fire}

action_defaults :: proc "contextless" () -> [Action]inp.Action_Bindings {
    return {
        .Use=inp.action_default(.Button,inp.binding_key(.E),inp.binding_gamepad_button(.East)),
        .Fire=inp.action_default(.Button,inp.binding_mouse_button(.Left),
            inp.binding_gamepad_axis(.Right_Trigger)),
    }
}
```

The defaults are found by name, as `NAME_DEFAULT` is: `<enum>_defaults` beside the enum
(`Weapon_Action` takes `weapon_action_defaults`).

Kinds are `.Button`, `.Axis` and `.Axis2`; bindings come from `inp.binding_key`,
`binding_key_axis`, `binding_keys` (four keys, an `Axis2`), `binding_mouse_button`,
`binding_mouse_delta`, `binding_gamepad_button` and `binding_gamepad_axis`. The compiler asks for a
default of every member. What a project or a player changes goes in the section
`Input_Settings` of `settings.mirai`: an entry per action, by its name, which replaces the one of
the layer under it (the code, the project, the player). Project Settings > Input and
`settings.set` write it; an entry the kind of its action does not take is refused with what to
give. A player's rebinding is the same setting in the player's options: the game changes
`inp.Input_Settings` (`inp.input_settings_put`, `inp.input_settings_remove`) and the save library
writes it.

## Read

```odin
@(step="fixed",server)
game_fire :: proc(players:core.Read(Player),actions:inp.Input_Of(Action)) {
    for row in 0..<core.count(players) {
        body:=core.entity_at(players,row)
        if !inp.pressed(actions,body,.Fire) {continue}   // the seat that drives body
        // inp.pressed(actions,.Use) would be the focused player's, for a menu or a debug key
    }
}
```

- `pressed`, `down`, `released`, `tapped`, `holding`, `value` (a button or `Axis`), `vector`
  (an `Axis2`). A seat that does not exist or is blocked reads as released.
- Actions of the engine: `inp.Input_Of(inp.Move_Action)` (`.Move`), `inp.Input_Of(inp.Look_Action)`
  and `inp.Input_Of(locomotion.Walk_Action)` (`.Jump`, `.Sprint`, `.Crouch`).
- In `frame`, `late` and `ui` take `inp.Frame_Input_Of(Action)`; the same `inp.pressed` reads
  it, so a press is not missed between ticks.
- To hit, dig or throw from where the player looks, `cam.aim(sight,body)` (`sight:cam.Sight`) gives
  the ray of the camera that player sees through, in any camera mode; no eye height or look angles
  in game code.
- Contexts (a menu with its own bindings): `inp.action_default_in` and, in `^inp.Context_Requests`,
  `inp.input_context_enter` and `inp.input_context_leave`; chords: `inp.binding_chord`. Block
  actions while a menu is open with `inp.input_block(seats,owner,seat)` and `inp.input_unblock`.

## Seats and bodies

A seat is a player of this machine (`slot`) or of a connection (`peer`); it exists with no body.

- `inp.drive(seats,seat,body)`, `inp.release(seats,seat)` and `inp.focus(seats,slot)` push into
  `^inp.Seat_Requests`; they apply at the start of the tick. Any entity can be driven: entering a
  car is driving it, leaving it is driving the person again. The body a seat lets go of stops.
- `inp.body_of(seats,seat)` and `inp.seat_of(seats,body)` read `core.Read(inp.Seat)`.
- Bodies appear at spawn points: with a player prefab (`Spawn_Settings.prefab`, or one on the
  point) each seat gets one, or ask with `spawn.spawn(requests,seat,PLAYER_PREFAB)` and
  `spawn.respawn(requests,body,point)` in `^spawn.Spawn_Requests` (a client cannot: the server
  decides).
- How many players share the screen is of the run: `--players`, or the Play selector of the editor.
- A body no seat drives is moved by writing its `inp.Move_Input`: `move` (in the world, up to
  length 1), `look_yaw` (where it faces; it turns there at its own rate), `look_pitch`, `buttons`.
  An AI writes it only where the rules are decided. A car reads the same `Move_Input`, so a player
  and an AI drive it alike.

## Pitfalls that fail silently

- A new action without a default: the project does not build.
- A button held when a body is driven, a menu closes or a block ends waits for its release.
- `inp.pressed(actions,.Fire)` is the focused player's: with several players or a server use the
  body form, or `inp.seat_pressed(actions,seat,.Fire)`.
- A request that breaks a rule (a body already driven) changes nothing and is a problem of the
  seat or the body: `engine.diagnostics` (`input.*`).
