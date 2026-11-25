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
- Events, animation, layered moves, hitboxes against physics and a weapon drawn into the hand
  (`Ability_Held`): [what it asks of others](references/abilities.md#what-it-asks-of-others); fast
  dashes and swings that sweep between ticks: [selection](references/abilities.md#selection).
- Network, rollback and replicas: [network](references/abilities.md#network).
- `abilities.inspect`, `abilities.check`, `abilities.use`, and authoring with `records.*`:
  [API](references/abilities.md#api).
- Rows of game data, `core.Record`, `@(names)` and `@(name_bits)`:
  [core](../mirai-core/SKILL.md); the animation an ability plays (an action of the `.character`,
  `play`): [animation](../mirai-animation/SKILL.md); layered moves and the `Character`:
  [physics](../mirai-physics/SKILL.md); input actions and seats:
  [control](../mirai-gameplay/references/control.md#actions).

## Workflow

1. The game declares its names in code: statuses (`STATUS_STUNNED :: abilities.Ability_Status(1)`),
   tags (`Ability_Tag`), attributes (`Ability_Attribute`, 0 is none) and cues (`Ability_Cue`).
2. Make tables of rows of the plugin's types (`records.create` with `rows_of` `Ability` or
   `Ability_Kit`) and write the rows with `records.add` and `records.set` (or a CSV with
   `records.import`): one `Ability` per technique and one `Ability_Kit` per weapon or character.
   Then `abilities.check` until it returns no problems.
3. Give the character an `Ability_User` with its kit and attribute entries; the seat that drives
   it fires the inputs. The animation of each ability is an action of the `.character` of its
   `Animation`.
4. Sounds and particle births are data: `on_begin` of a window and `on_hit` of an effect
   (`audio.Cue`, [cues](../../../docs/game/audio/cues.md)). The game reacts to `Ability_Events`
   for the rest (cue ids for a camera shake or a decal; `Depleted` for death or a broken weapon)
   and asks through `Ability_Requests` (`ability_use`, `ability_cancel`, `ability_effect`,
   `ability_kit_set`).
5. In Play, `abilities.inspect` says what runs, what is open and what blocks each candidate.

## Invariants

- **No state machine and no transition graph.** What may follow an ability is decided by its
  open cancel windows and by the kit's interrupts against the tags of the candidate; among valid
  candidates the highest priority wins. `next` only adds one candidate when an ability completes.
- **The state is the start tick** (and, in `Ability_Local`, `own`, the user's own time since then,
  for windows on the `own` clock, plus `span_open` for clip-span-bound windows). Phase, open
  windows, granted statuses
  and modifiers (with optional `ramp_in`/`ramp_out`) are derived each tick from them against the
  immutable sheet: ending or rolling back an ability leaves nothing behind. One ability runs per
  user.
- **Combo input rules are data.** When a follow-up's input counts (`input.after`) and whether it
  waits for the branch of the running ability (`input.wait` `running`) are fields of its sheet; a
  branch that follows a clip in slow motion is a window on the `own` clock. The game does not
  watch inputs or integrate clip time to ask for the next technique.
- **Sheets are game data outside the `World`.** Play, copies and rollback copy only the rows of
  the users and the queues; times are seconds in data and ticks at run time.
- **One writer.** `abilities_step` is the only writer of `Ability_State`, `Ability_Tracking` and
  `Ability_Local` (and of `Ability_User.kit`, by request); the game, other plugins and hitboxes ask
  through `Ability_Requests`, which apply on the next tick.
- **Authored, replicated and local rows by write rate.** `Ability_User` is authored (an attribute's
  `base` is where it starts) and never written per tick. `Ability_State` (the run and the bases)
  and `Ability_Tracking` (cooldowns, timers, regeneration deadlines) are what a client cannot work
  out, written when they change. `Ability_Local` (statuses, current values, own time, input
  buffer, hits, held socket) is worked out at each end and never sent. A steady tick writes no
  replicated row.
- **Attributes are bases plus modifiers.** A base is a line from `Ability_State.since`: a cost,
  an effect, a drain that starts, pauses or stops and regeneration that resumes write a new one;
  `per_second` costs and regeneration are its rate, never a write per tick. Current values are
  recomputed every tick from timers and open windows, never accumulated. What lasts is a timer
  named by tags; immunity is a status, not a separate mechanism.
- **The end that decides an entity runs its abilities** (`core.owned`): a client predicts its
  own character and the server decides what hits others; a replica only derives its local row
  (statuses, values, window events).
- **One-shot presentation is a cue of the sheet.** A window's `on_begin` and an effect's `on_hit`
  play through `audio.cue_play` by the entity (no per-tick resimulation guard: the audio dedup
  keeps them once); the plugin never imports `vfx`. Anything else answers an `Ability_Cue` id.
- Pace and gravity changes during an ability (slow motion while charging, low gravity) are not
  part of the plugin: the game sets `core.Own_Pace` from events, and gravity belongs to locomotion.
  The plugin reads the pace for `own` windows and `Animation_Events` (`.Span_Begin`/`.Span_End`)
  for clip-span-bound windows; it does not sample animation state directly.
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
  requests, a stable tick without allocations, hitboxes that sweep between ticks but not when they
  open or across a teleport, and a held weapon in the hand while a window is open).
- Methods: `mirai generate demo`, `mirai build editor demo` and, in a session on a copy,
  `abilities.check`, `abilities.inspect` and `abilities.use` against rows written with `records.*`.
