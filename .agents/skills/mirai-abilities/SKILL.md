---
name: mirai-abilities
description: Mirai gameplay abilities - the `abilities` plugin (`plugins/abilities/runtime` and
  `plugins/abilities/editor`) with `Ability` and `Ability_Kit` rows of game data, `Ability_User`,
  statuses, tags, attributes, effects, hitboxes, cancel windows, input buffer, cooldowns, charges
  and durability, and the `abilities.*` methods. Use when building attacks, combos, dashes, blocks,
  skills, spells, hit reactions, weapons or a gameplay ability system (GAS, Mantis, fighting-game
  moves), when touching that plugin, or when diagnosing why an ability does not start.
---

# Mirai abilities

`abilities` is an optional plugin (runtime and editor) over `physics` and `animation`. An ability
is a row of game data that reads like a sheet; the runtime keeps per user only which ability runs
and the tick it started, and derives everything else from the tick against the sheet.

## Map

- The sheet (input, requirements, costs, timeline windows, hitboxes, moves, cues) and the kit:
  [sheets](references/abilities.md#sheets).
- Which ability starts (candidates, input buffer, cancel windows, interrupts, priority, `next`):
  [selection](references/abilities.md#selection).
- Statuses, attributes, modifiers and effects (damage, knockback, a reaction, damage over time,
  stacks, cleanse, immunity, scaling by the source):
  [attributes and effects](references/abilities.md#attributes-and-effects).
- Events, animation, layered moves and hitboxes against physics:
  [what it asks of others](references/abilities.md#what-it-asks-of-others).
- Network, rollback and replicas: [network](references/abilities.md#network).
- `abilities.inspect`, `abilities.check`, `abilities.use`, and authoring with `records.*`:
  [API](references/abilities.md#api).
- Rows of game data, `core.Record`, `@(names)` and `@(name_bits)`:
  [core](../mirai-core/SKILL.md); the animation an ability plays (an action of the action set,
  `play`): [animation](../mirai-animation/SKILL.md); layered moves and the `Character`:
  [physics](../mirai-physics/SKILL.md); input actions and seats:
  [control](../mirai-gameplay/references/control.md#actions).

## Workflow

1. The game declares its names in code: statuses (`STATUS_STUNNED :: abilities.Ability_Status(1)`),
   tags (`Ability_Tag`), attributes (`Ability_Attribute`, 0 is none) and cues (`Ability_Cue`).
2. Write the rows with `records.create`, `records.add` and `records.set` (or a CSV with
   `records.import`): one `Ability` per technique and one `Ability_Kit` per weapon or character.
   Then `abilities.check` until it returns no problems.
3. Give the character an `Ability_User` with its kit and attribute entries; the seat that drives
   it fires the inputs. The animation of each ability is an action of the action set of its
   `Animation`.
4. The game reacts to `Ability_Events` (cues for VFX, sound and camera; `Depleted` for death or a
   broken weapon) and asks through `Ability_Requests` (`ability_use`, `ability_cancel`,
   `ability_effect`, `ability_kit_set`).
5. In Play, `abilities.inspect` says what runs, what is open and what blocks each candidate.

## Invariants

- **No state machine and no transition graph.** What may follow an ability is decided by its
  open cancel windows and by the kit's interrupts against the tags of the candidate; among valid
  candidates the highest priority wins. `next` only adds one candidate when an ability completes.
- **The state is the start tick** (and `own`, the user's own time since then, for windows on the
  `own` clock). Phase, open windows, granted statuses and modifiers are derived each tick from
  them against the immutable sheet: ending or rolling back an ability leaves nothing behind. One
  ability runs per user.
- **Combo input rules are data.** When a follow-up's input counts (`input.after`) and whether it
  waits for the branch of the running ability (`input.wait` `running`) are fields of its sheet; a
  branch that follows a clip in slow motion is a window on the `own` clock. The game does not
  watch inputs or integrate clip time to ask for the next technique.
- **Sheets are game data outside the `World`.** Play, copies and rollback copy only the
  `Ability_User` rows and the queues; times are seconds in data and ticks at run time.
- **One writer.** `abilities_step` is the only writer of `Ability_User`; the game, other plugins
  and hitboxes ask through `Ability_Requests`, which apply on the next tick.
- **Attributes are bases plus modifiers.** Costs and effects change bases (kept in 0..max);
  current values are recomputed every tick from timers and open windows, never accumulated.
  What lasts is a timer named by tags; immunity is a status, not a separate mechanism.
- **The end that decides an entity runs its abilities** (`core.owned`): a client predicts its
  own character and the server decides what hits others; a replica only derives statuses and
  window events.
- **Presentation is not in the sheet.** A window carries a cue and the game plays it; the plugin
  does not import audio or effects.
- Pace and gravity changes during an ability (slow motion while charging, low gravity) are not
  part of the plugin: the game sets `core.Own_Pace` from events, and gravity belongs to locomotion.
  The plugin reads the pace for `own` windows; it does not read animation state (the end that
  decides may not sample animation).
- A sheet, kit, attribute entry or effect that is not valid is a problem of its user that says
  what to fix (`abilities.invalid`, `abilities.kit`, `abilities.attributes`, `abilities.effect`)
  and never runs; `abilities.check` returns the same text.

## Verification

- Types: `mirai check plugins/abilities/runtime` and `plugins/abilities/editor` (with
  `-collection:plugins=plugins`).
- Tests: `mirai test plugins/abilities/runtime` (`abilities_test.odin`: the blade kit combo,
  the input delay and the wait for the branch, a window on the own clock, the charged dash with
  charges, a copy halfway that runs the same future, a cancel that leaves
  nothing, replicas, lasting effects with stacks, cleanse and immunity, invalid sheets and
  requests, and a stable tick without allocations).
- Methods: `mirai generate demo`, `mirai build editor demo` and, in a session on a copy,
  `abilities.check`, `abilities.inspect` and `abilities.use` against rows written with `records.*`.
