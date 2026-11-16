# std/input

Package declared `mirai_input`, imported as `si` (`import si "mirai:std/input"`). It depends on
`std/base` and `std/math`. These are the device types and the action map that `platform`, `core`,
`engine/input` and `multiplayer` share; a game uses them through `core` and `engine/input`.

- `core` re-exports as aliases its key, button and gamepad types (`core.Key`…).
- `Input` receives its capacities in `input_init` and does not allocate afterwards; what does not
  fit is rejected.
- `Action_State` is plain and pointer-free: it goes into the world snapshots.

## Actions (`input.odin`)

- The game reads actions, not keys, and the package knows no windowing system: the host reports
  codes and axes (`u16` that the host decides; `CODE_*` suggests a layout) and calls `input_update`
  once per tick.
- Each `input_bind_*` accepts only its type of action and codes of the declared range; with several
  bindings the one of greatest magnitude wins. `input_bind_delta*` read axes without limit or dead
  zone (the mouse or a wheel since the previous tick): its vector may exceed length 1.
- `input_chord` asks the last binding for held codes in addition to its own; a chord in use removes
  its codes from the bindings with shorter chords
  ([chords](../../mirai-gameplay/references/control.md#chords)).
- A press released between two `input_update` calls is not lost: it gives `pressed`, `released` and
  `tapped`. `input_release_all` releases everything (focus loss).
- In a Mirai game the actions arrive ready-made: `engine/input` maintains the `Actions` storage with
  this package ([input](../../mirai-gameplay/references/libraries.md#input)).

## Devices (`devices.odin`)

- `Key` (US keyboard), the buttons, the axes and `Gamepad` are the types that `platform` writes and
  a game reads as `core.Key`…: a game does not link the windowing system.
- New keys go at the end of `Key`: their values are indices of `Keys`.
