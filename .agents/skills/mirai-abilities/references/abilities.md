# Plugin `abilities`

`plugins/abilities/runtime`: `abilities.odin` (names, rows, component, queues), `check.odin`
(what makes a sheet valid and how to fix it) and `step.odin` (`abilities_step`).
`plugins/abilities/editor/api.odin`: the `abilities.*` methods.

## Sheets

An `Ability` is a `@(record)` row; its fields read top to bottom as the sheet of a technique.

- `input`: the input action of the seat that drives the user and when it fires: `pressed`,
  `released` (after being held at least `hold` seconds), `held` (the tick it reaches `hold`
  seconds) or `down` (every tick). `none` starts only by request, by `next` or by an effect.
  - `input.after`: while another ability runs, the input counts only from this many seconds into
    it; earlier it is ignored (Mantis `InputWindowDelay`). The release of the press that started
    the running ability does not fire the follow-up.
  - `input.wait`: `buffer` keeps a fired input the kit's buffer seconds; `running` also keeps it
    while the ability that ran when it fired goes on, so it starts on the first tick of a cancel
    window of that one however far it is (a combo's next technique pressed before the branch).
    It leaves with that run: an interruption or a cancel drops it after the kit's buffer.
- `requires` (all of them) and `blocked_by` (any) are status masks; `modes` are locomotion modes
  of the user's `Character` (none: any); `conditions` bound attributes; `costs` are taken from
  attribute bases when it starts and it cannot start with less; `cooldown` is per ability row.
- `duration` in seconds; `hold` ends it when its input is let go.
- `action` names an action of the user's `Animation` (a layer over locomotion); `clip` names a
  clip of its `.match` played over the whole body. One of them, or none.
- `windows`: spans `[from, to)` in seconds from the start, inside the duration. `clock` says what
  the seconds count: `world` (the fixed step) or `own`, the user's own time (`core.Own_Pace`) as
  its animation counts it, for a window that follows a clip played slower or faster (the branch of
  a charge clip in slow motion). An `own` window may close after the duration; the end of the
  ability closes it. A window can at
  the same time accept abilities by tag (`cancel_into`), put the user in statuses, modify one of
  its attributes, carry a hitbox with its effect, move its `Character` with a layered move along
  the axes it faces when the window opens, and carry a cue. A window with `to` at 0 is unused.
- `next`: a candidate when it completes (a charge that ends in its dash). It is checked in the
  statuses the windows gave on the last tick the ability ran, so a dash that `requires` the
  charging status of its charge (and so never starts while idle) still starts as its `next`.

An `Ability_Kit` lists the abilities a user starts by input, the seconds an input waits in the
buffer and the tags that may `interrupt` any running ability (reactions, death). A weapon swap is
`ability_kit_set`.

Times are seconds in the sheet and ticks of the fixed step at run time (rounded; a window lasts at
least one tick). The duration, `input.after` and `world` windows count ticks of the world; `own`
windows count `Ability_User.own`, the ticks of the user's own time since the start (each tick adds
`core.pace_of`). An `own` window shorter than the user's pace per tick can be passed over.

## Selection

Each tick, for a user its end decides:

1. The running ability advances to `local = tick - start`: windows that open or close at `local`
   emit their events, a window with a move asks for it on opening; at the duration it completes
   and `next` becomes a candidate; a `hold` ability whose input is up completes.
2. Each kit ability whose input fires enters the buffer with its tick, unless another ability runs
   and is not yet `input.after` seconds in; requests enter it the same way (`ability_use` waits as
   the sheet's `input.wait` says; an effect's `use`, the kit's buffer). An entry leaves after the
   kit's buffer seconds (with `wait` `running`, once the
   run it came in is also over) or when its ability starts.
3. Statuses and values are derived (below), and every candidate is checked: requirements, modes,
   conditions, costs, cooldown and, while another ability runs, an open window of that one whose
   `cancel_into` has one of its tags, or the kit's `interrupts`. Of the valid ones the highest
   `priority` starts; on a tie, the one buffered first.
4. Starting interrupts the running one (its open windows close and their moves are removed, its
   animation stops unless the new one plays one of the same kind), takes the costs, starts the
   cooldown, fires the animation and opens the windows at 0.
5. Open hitboxes touch each entity once per window of that use.

Why a candidate does not start is `start_block` (`Ability_Block`), which `abilities.inspect`
reports for each ability of the kit.

## Attributes and effects

- `Ability_User.attributes` are entries of an attribute, its base, its max (0: none) and its
  regeneration per second. Bases stay in 0..max. `values` (transient) are
  `(base + add) * (1 + more)` over the modifiers of the timers and of the open windows;
  `statuses` (transient) join the statuses of the timers and of the open windows.
- An `Ability_Effect` adds `amount` (times the current value of the source's `scale_by`
  attribute, if named) to the base of an attribute of its target, at once or every `period` while
  it lasts; grants statuses and a modifier for `seconds`; gives a `knockback` velocity along the
  axes of its source as an override layered move of the target's `Character`; and may ask the
  target to `use` an ability (a hit reaction, which reaches a running ability through the kit's
  `interrupts`).
- What lasts is a timer of the target. Its `tags` say what it is: an effect with the same tags
  applied again stacks up to `max_stacks` (its modifier and periodic amount count once per stack)
  and lasts `seconds` from then, keeping the phase of its period. `remove` ends the timers with
  any of its tags (a cleanse). A target in any status of `blocked_by` takes nothing from the
  effect: immunity is a status, granted by a window (a dodge) or by another effect. A timer that
  starts or ends emits `Effect_Begin` / `Effect_End` with its cue.
- A hitbox's effect and `ability_effect` go through `Ability_Requests` and apply at the start of
  the next tick. A base that falls to 0 emits `Depleted`.

## What it asks of others

- `Ability_Events` (cleared and filled each tick): `Started`, `Completed`, `Interrupted`,
  `Canceled`, `Window_Begin` and `Window_End` with the window and its cue, `Hit` with the target,
  `Depleted` with the attribute, `Effect_Begin` and `Effect_End` with the cue of a timer (at the
  end that decides the user). VFX, sound and camera shake are the game's answer to cues.
- Animation: `anim.play` / `anim.stop` of the action of the user's action set that `action` (one
  in a layer) or `clip` (one over the whole body) names. The animation action should allow
  cancellation: the ability decides the timing and the animation follows. An ability interrupted
  or cancelled stops its action unless the one that follows plays the same action: in another
  layer nothing else would end it, and a looping section would play on.
- Movement: `phys.add_move` with the window's velocity and length, `phys.remove_moves` when the
  ability ends before the window closes; knockback is a move of the target. The dash is a layered
  move, not a teleport.
- Hitboxes: `phys.overlap_box`, `overlap_sphere` and `overlap_capsule` at the user's
  `World_Transform`, against the physics of the tick before. Tests pass their own overlap to
  `abilities_tick`.

## Network

- `Ability_User` is replicated; its derived fields are transient. A replica adds its own pace to
  `own` between the values the network gives it. A rollback copies the rows and
  the queues with the world and repeats the ticks; the sheets are the same rows in every world.
- Only the end that decides a user (`core.owned`) applies requests to it, starts, ends and hits:
  a client predicts its own character, the server decides the rest. A replica derives its
  statuses and the window events from the ability and start tick the network gives it.

## API

- Authoring is `records.*` on the `Ability` and `Ability_Kit` tables, by row and field names.
- `abilities.check`: every row checked as the game runs it, with table, row and how to fix it;
  also references to rows that no table has (`next`, an effect's `use`, a kit's abilities).
- `abilities.inspect {entity}`: kit, running ability, seconds (`own_seconds` of the user's own time)
  and open windows, statuses, attributes with base and value, buffer (`waits_for_running` on an
  entry kept by its run), cooldowns, timers and what blocks each ability of the kit.
- `abilities.use {entity, ability, table?}`: in Play, asks a user to start an ability by row name.

## Verification

`plugins/abilities/runtime/abilities_test.odin`:

- `a_blade_combo_hits_once_per_window_and_branches_only_inside_cancel_windows`
- `a_charged_dash_spends_charges_and_is_blocked_without_them`
- `a_copy_of_the_state_halfway_runs_the_same_future_and_a_cancel_leaves_nothing`
- `invalid_sheets_and_requests_are_problems_and_never_run`
- `lasting_effects_stack_by_tags_end_by_cleanse_and_skip_blocked_targets`
- `a_stable_tick_allocates_nothing`
- `an_input_counts_from_its_delay_and_waits_for_the_branch_of_the_running_ability`
- `a_window_on_the_own_clock_follows_the_pace_of_the_user`

The methods need a build with the plugin (the demo enables it) and a session on a copy; hitboxes
against real colliders need Play with physics.
