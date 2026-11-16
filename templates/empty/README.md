# Minimal project: a scene, a spinning component, a sample plugin and a Surface program

- `project.mirai`: name, version, identifier, icon, start scene, active plugins, window and build
  options. Besides the sample plugin, the ones a first game needs are on: bodies and colliders
  (`physics`), walking characters (`locomotion`), spawn points (`spawn`), editable solids
  (`shapes`) and writing interfaces (`ui_inspector`).
- `assets/main.scene`: the start scene, with a sky and a sun: what the editor opens, so that its
  agents build in a scene of the project from the first message.
- `game/game.odin`: the game library: the `Spinner` component and the `game_spin` function, which
  runs in the `fixed` phase and spins the entities that have it (backwards while the `reverse`
  action is held, R or East by default in `action_defaults`). Project Settings > Input writes what
  it changes of those keys in `Input_Settings` of `settings.mirai`.
- `plugins/sample/`: a plugin with a `runtime/` part: the `Lifetime` component and the `sample_age`
  function, which counts how long each entity that has it has been simulated.
- `shaders/pulse.slang`: a Surface program (`Pulse`), an emissive color that pulses.

`mirai generate` reads the components (`@(component)`) and functions (`@(step="phase")`) of `game/`
and `plugins/*/runtime/` to build the project world; `mirai edit` and `mirai play` generate and
compile it. A plugin that needs editor tools adds an `editor/` part and declares it in `parts` of
its `plugin.mirai`.
