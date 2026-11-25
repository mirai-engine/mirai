# Plugin `multiplayer`

Connects the data world with [`net`](networking.md): authoritative server, client prediction, and
rollback (`plugins/multiplayer/runtime`; `import multiplayer "plugins:multiplayer/runtime"`,
`wire "mirai:net"`). Shares only [`core` tables](#what-another-library-simulates) with physics.
`Net_Session` is `@(storage,host,by_world)` (outside `World`, survives rollback; fetched outside
the loop via `host.app_world_storage(app, world, Net_Session)`). Types and defaults: `types.odin`.

## What the game declares

The generator builds the protocol catalog identically at both ends (verified by handshake hash).

- **Entities (`Replicate`):** First replication captures `Pose` (1 mm pos, 15-bit quat, scale,
  persistent `Id`, `scene.Prefab_Instance`, [sections](#sections), `off`/`absent`/`disabled`
  bits), `Motion_State` (if `core.Motion`), `Move_Input` driver (if `input.Move_Input`), and all
  `@(component,replicated)` components (enabled or disabled).
- **Dynamic types:** Each distinct set composes a protocol type from creation's fragment list
  ([types](networking.md#protocol-and-descriptors)). Removed components travel as `Pose.absent`;
  never-seen ones widen the type in place (`object_retype`, keeping the replica and holder).
  `Each`-simulated entities replicate creation only.
- **Tags & visibility:** `replicated="owner"` (owner only), `replicated="others"` (non-owners),
  `replicated="object"` (auto-replicates without `Replicate`: `Server`, `Always`). `local` skips
  a field; `precision`, `bits`, `min`, `max` pick serializers. `single` components (`Sky`, `Sun`)
  omit `Pose.off`.
- **Disabled entities:** Server `core.Disabled` keeps the object alive (`Pose.disabled`, consumes
  `max_objects`/`state_words`); updates pause until re-enabled while scope tracks position.
  `scene.Section_Held` on server ends the object; client respects its own `Section_Held`.
- **Spawning & references:** Clients resolve replicas by scene `Id`, `scene.spawn` (`transient`,
  deferred via `scene.Prefab_Pending` if unread), or empty entity. Unresolved `Entity` refs strip
  their component (`Joint` stays unanchored) until the target arrives.
- **Tuning & scope:** `update_hz` staggers publish turns; `simulation` (`Server`, `Lent`, `Each`),
  `audience` (`Near`, `Always`, `Owner`), `predict`, `radius` (extends `Near` without grid
  rebuild). `Visibility` (`mask` on entity, `sees` on `input.Seat`) filters on table change only.
- **Network parent:** Closest ancestor with `Replicate` (recomputed on `core.Hierarchy`/`Replicate`
  layout change); child inherits parent visibility and spawns after it.
- **Limits:** Exceeding `COMPONENTS`, `MAX_STATE_WORDS`, or `wire.TYPE_CAPACITY` reports
  `net.object`; unserializable component/message blocks session open (`net.protocol`).
- **Collections:** `multiplayer.Collection(Item, capacity)` gives fixed `u32`-id slots (0 = empty,
  no alloc); `collection_set` returns `Invalid` (id 0) or `Full`. Mutate via `core.get`/`core.add`.
- **Messages:** `@(net_message)` (server-sent; `from="client"`, `from="owner"`, `reliable` streams
  any size). Send with `multiplayer.send(&outbox, val, about?, to?)` (returns `false` during
  `Net_Outbox.replaying`). Read via `core.Inbox(T)` (`core.Message(T)`), filled in
  `net_tick_head`. Client holds entity-targeted messages until the replica reaches that tick
  (`Server_Object.said`). `Net_Outbox` (`copy=false`) retains queued/backpressured `Full` reliables
  across rollbacks; other failures report `net.event_send`.
- **Settings (`Net_Settings`, 0 = default):** `max_clients` 32, `max_objects` 1024, `timeout` 10 s,
  `connect_timeout` 5 s, `view_radius` 128 m, `port` (`DEFAULT_PORT`), `absent_seconds` 300 s (<0
  none), `rewind_entities` 64, `sync_test` 0, `max_resimulate` 0.3 s, `resimulate_budget` 1 s/s,
  `critical_ticks` 0.5 s; tolerances: pos 0.05 m, vel 0.5, rot 0.07 rad, scale 0.001. Invalid
  port or field reports `net.settings`.

```odin
import multiplayer "plugins:multiplayer/runtime"
import "mirai:core"
import "mirai:std/base"

@(component, replicated)
Inventory :: struct {items: multiplayer.Collection(u32, 16)}

@(net_message, from="client", reliable)
Use_Item :: struct {id: base.Entity_Id, slot: u32}

@(step="fixed", loops="game")
on_use :: proc(
    inbox: core.Inbox(Use_Item),
    outbox: ^multiplayer.Net_Outbox,
    inv: ^core.Table(Inventory, .Write),
) {
    for msg in inbox.items {
        if row, ok := core.get(inv, msg.about); ok {
            _ = multiplayer.collection_set(&row.items, msg.value.slot, 1)
        }
        multiplayer.send(outbox, msg.value, about=msg.about, to=msg.sender)
    }
}
```

## What another library simulates

Shared `core` tables (single writer each):

- **`core.Pose_Target` (net writes):** Pose, velocities, monotonic request counter. Predicted omits
  `follow` (snaps on correction); interpolated sets `follow` (kinematic body pushes contacts).
  Physics consumes at tick start (`physics_pose_targets`); free transforms use
  `core.pose_targets_place`. Same-frame corrections chain from the last request (`replica_now`).
- **`core.Motion` (physics writes):** Velocities, COM, and `island` (drives criticality grouping).
- **`core.Simulation_Hash`:** Enabled via `core.Sync_Check` when `sync_test > 0`.
- **Physics & bridges:** `Collider`, `Joint`, `Joint_State` replicate directly
  ([joints](../../mirai-physics/references/engine.md#for-networking-and-saves)).
  `destruct_multiplayer` ([fractures](../../mirai-physics/references/engine-destruct.md#network))
  and `terrain_multiplayer` ([terrain](../../mirai-world/references/terrain.md#network)) use
  [operation journals](#operation-journal). `behavior` runs server-only via `Animation_Played`
  ([minds](../../mirai-world/references/behavior.md#minds)).

## Operation journal

`Journal` (`journal.odin`, per-world host storage) networks deterministic library ops (fractures,
terrain digs). Library supplies `Journal_Op.body` + region/checksum and applies handed items.

- **Order & replay:** Server sequences ops per `Journal_Key` reliably; clients apply at server
  tick (`journal_due` / `journal_result`). Entries record first-applied and done ticks so rollbacks
  replay exactly once without `World` cursors. Late ops request `rewind`.
- **Prediction:** Client applies locally and sends `journal_ask`; server holds until its tick
  (`journal_asks`), accepts or rejects (`journal_refuse`).
- **Parts & resync:** Checksum mismatch, gap, or refused/expired prediction requests region/base
  parts (`journal_resync` with `since`); server also offers bases on join (`journal_offer`).
  `journal_serves`/`journal_part` LZ-compresses and streams on `JOURNAL_CHANNEL` (bounded by
  `JOURNAL_QUEUE`), ordered among ops via `Net_Journal_Part`. Retries wait `JOURNAL_ASK_TICKS`.
  Scene replacement clears the journal (`journal_world`).

## Authority and players

- **Roles:** `authority_follow` syncs [`core.Network`](../../mirai-core/references/core.md#network)
  (clearing `core.Remote` on role change) and marks `core.Remote` on lent server objects and
  unpredicted client replicas. Gameplay gates authority with `core.owned`.
- **Seats & identity:** On connect, client sends one `Net_Player` (128-bit secret from persisted
  `Net_Identity`, or per-world with `--new-player`/`Open_Request.new_player`); empty or duplicate
  closes with `Denied_Player`. Server seats it in a replicated (`Always`, `core.Keep`)
  `input.Seat` (`remote`) with a server-only `Net_Seat{connection, player}` holding only the
  SHA-256 hash; `input` knows no connection or player.
- **Absence & reconnect:** Disconnect disables the seat (`core.Disabled`, `Seat_Absent`) for
  `absent_seconds` (unlimited in loaded saves); same secret reclaims it (preserving game-disabled
  state); live duplicate kicks old connection with `Replaced`. `spawn` ties bodies via `Seat_Body`
  (`spawn_seat_bodies`).
- **Ownership:** Body owner is its driving seat's connection (`owner_of`, tables resolved once per
  publish in `Owners`); connection view tracks owned bodies, not seats. `Seat.body` replicates:
  every client knows each seat's body. A client makes no local seats (`input_seats`); it plays at
  the replica it owns (local slot 0), `client_seats` marks the others `remote` and drops seats
  made before its own arrived.
- **View as input:** `input.Seat_View` (where the seat's camera looked as the tick began, from
  `input.Slot_Views` that `camera_blend` writes) travels in `Remote_Actions` with the actions, is
  kept in `Taken` and runs again in corrections: `camera_drive` moves bodies by it and `inp.aim`
  aims from it (its `eye` is where the camera was from the body) on every end, never by this
  end's camera transforms.

## Opening and closing

`net_begin` (`input`, `begin`) opens from `Session_Request.open`, else `app.launch` flags
([plugin arguments](../../mirai-core/references/host.md#plugin-arguments)): `--server [port]`,
`--dedicated`, `--invite`, `--connect <invite|addr>`, `--new-player`, `--until-empty`,
`--status <file>`, `--status-ticks <n>`, `--latency <ms>`, `--jitter <ms>`, `--loss <pct>`. Bad
flags or `--server`+`--connect` exit `host.PLAYER_USAGE`.

- Switches to real time (`host.app_real_time`), holds client input scripts (`app.script_hold`)
  until joined, logs status/disconnect reasons, and exits `PLAYER_NET` on bind/join failure or
  headless disconnect (`--until-empty` exits normally when empty).
- `--latency`/`--jitter`/`--loss` wrap the socket in [`Conditioner`](networking.md#transport)
  (ping = `2 * latency`). `--status` logs tick-aligned session + object snapshots (`rtt_ms`,
  `sent`, `received`, `problems=`).
- **Entry modes:** Direct (`--server`/`--connect <addr>`) or invitation (`--server --invite` ->
  `invite_code(session)` once port-mapped; `invite_give` injects a key without mapping; zeroed on
  close). Only servers may `save` (clients return `Unavailable`).

## Scene change

- **Server:** Ends prior world objects (detached), keeps connections/`Keep` seats/`Remote_Inputs`,
  holds connections ([scope](networking.md#replication)), sends reliable `Net_World`. On
  `Net_World_Ready`, releases connection and emits `Entered`.
- **Client:** Calls `scene.request` if not already in that scene, drops replicas/history, and
  acknowledges. Missing scene disconnects with `Scene_Missing` (`net.scene`). Local scene swap
  while synced reports `net.scene`. Stale `Net_Link`/`core.Remote`/`core.Pose_Target` are stripped.
  Cross-world game messages are discarded. Loading a server save triggers a scene change.

### Sections

Replicas in `scene.Scene_Reference` sections replicate only to clients that loaded them.

- Entity joins host groups ([groups](networking.md#replication)) for its owning section plus any
  non-enclosing overlapping sections whose boxes contain it; exceeding `OBJECT_GROUPS` or
  `Net_Settings.replication.groups` reports `net.sections`.
- Clients report loads/unloads via `Net_Section`. Replicas bind the section's `Id` when loaded,
  else spawn an un-ID'd copy (`scene.spawn_member` -> prefab -> empty) and swap on load.
- Server state wins: `Net_Gone` (`scene.section_gone`) removes scene entities destroyed or moved
  out of a section on clients that loaded it.

## Networked Play

`plugins/multiplayer/editor` implements `Play_Provider`
([extensions](../../mirai-editor/references/extensions.md#a-plugins-game-and-player-processes),
[editor](../../mirai-editor/references/editor.md#networked-play)).

- **Online players** (`play.start` with `online`, `ping_ms`) or shared hosting write
  `.mirai/play/play.scene`, open a server on the first free port from `Net_Settings.port` with an
  invite key, and launch `mirai-player` per online client over `127.0.0.1` (`--latency` = ping/2)
  using the editor library. `play.network.status` exposes `Net_Play` and `invite`, and the
  session of the run of the call (or of `player` N of a turn): links, rollbacks and the recent
  corrections of `Net_Session.diagnostics` (`diagnostics.odin`). Those rings are fixed, live in
  the session outside the `World` (no copy carries them, a rollback keeps them) and note without
  allocating: each state that differs (`replica_differs`) and each rollback (`client_rollback`).
- **Agents & guests:** Agent `play.start` runs in-process client worlds
  (`NET_PLAY_STEPPED_TIMEOUT` for stepped ticks). Collaborators join via `play.join` over
  `.mirai/play/host.scene`
  ([collaboration](../../mirai-editor/references/collaboration.md#the-hosts-networked-games)).

## The tick

```text
input  -1000     open net; apply datagrams; compare/rollback predicted; adjust client clock
input   -800     client: rewind to oldest library Net_Rewinds tick and replay
fixed -100000    push Net_Connections & core.Net_Messages; server: remote inputs; client: snapshot
                 World & place interpolated replicas at display tick
fixed  100000    publish dirty/due objects; host sends
frame  -10000    client: decay Draw_Offset correction smoothing
late   100000    host send/receive; status output
```

- **Clock:** `net_begin` feeds `Time.tick` + `Frame_Time.accumulator` to
  [`clock_advance`](networking.md#time-and-inputs) and sets `Frame_Time.dilation` (-1 until synced;
  0 on close; never dilated under `step=true`). Server `core.Clock` travels with ticks; client
  requests it via `core.Clock_Requests` (game requests on client report `core.clock_network`).
- **Paused games:** Caller invokes `pump` each frame to keep sockets alive, mark server clock
  paused, and buffer events up to `PENDING_EVENTS` (overflow: `Net_Stats.events_dropped`,
  `net.events_pending`).
- **Server publishing:** Dirty stamps/layouts, moving motion + rest transition, `Pose.off`,
  owner/priority/scope updates go on turns; frame-full items retry next turn. Client actions arrive
  as `Remote_Inputs` (`multiplayer.remote_input` -> `input.seat_receive`; `Repeated` holds buttons
  without repeating taps/mouse; overflow reports `net.input_axes`), plus wrapped look +
  `look_behind` (`remote_look` in `server.odin`) and `Clock.display` (`Remote_Input.view`).
  `phys.Collider` replicates whole; unresolved `Entity` refs suspend `Joint`/re-evaluate on bind.
- **Client replica modes (`replica_wanted`):**
  - *Simulated here:* `Each` or `Held` (no `Pose_Target`, no correction).
  - *Predicted:* Driven body, same `core.Motion.island` or swept-bounds reach within
    `critical_ticks`, `Replicate.predict`, or predicted spawns (past `predicted_capacity`:
    `net.predicted`, stays interpolated).
  - *Interpolated (`follow`):* Shown at `clock_interpolation_tick` minus per-replica delay; pose,
    components, and `Move_Input` match one tick (`replica_show`). Kinematic body overrides local
    manipulation while interpolated.
  - *Timeline switch (`replica_switch`):* Turning predicted rewinds to newest server state; turning
    interpolated places at display tick; both fade via `Draw_Offset` (`SWITCH_HALF_LIFE`).
- **Prediction & rollback:** Per-tick incremental `World` ring copy (dirty tables/rows/storages;
  physics `copy_kept`). Mismatch past `Net_Settings` tolerances replays via
  `host.app_world_replace` + `host.app_tick_replay` within `max_resimulate` and
  `resimulate_budget` (OOM: `net.rollback`). Too old/over budget calls `replica_place_now`
  (`unverified`) and drops old records. Library rewinds use `multiplayer.rewind(&rewinds, tick)`.
- **SyncTest (`sync_test > 0`):** Re-runs recent ticks on input alone, hashing tables + physics;
  divergence reports `net.sync_test` and restores live world.
- **Game rules:** `fixed` steps must depend only on `World` + `Input`; external sinks must skip
  when `core.Time.resimulating` ([`Time`](../../mirai-core/references/core.md#core-storages)); gate
  decisions with `core.owned` (or `core.Network`/`is_server`/`is_client`).

## Predicted spawns and input delay

- **Predicted spawns:** In `fixed`, mark entities spawned on both ends with
  `multiplayer.predict_spawn(&spawns, e, seat)` (or `predict_kept` for library-owned entities).
  `spawns_take` assigns deterministic `spawn_id` (connection, tick, kind, per-kind index) and
  `Predicted_Spawn` on client. Server replica adopts by `Id`
  (`replica_adoptable`/`replica_adopt`), surviving rollbacks (`replicas_relink`/`spawns_settle`);
  unconfirmed ones expire after history.
- **Input delay:** Client delays local seat actions by clock input delay
  (`Net_Settings.replication.input_delay`), submitting immediately so tick runs less ahead.
  Delayed seat uses `input.seat_receive` (`net_input_take`/`net_input_delay`), matching server
  edges. `Taken.delay` preserves delay across rollbacks; `Input_Packet.look_behind` aligns
  `remote_look`.

```odin
@(step="fixed", loops="game")
fire_projectile :: proc(
    seats: ^core.Table(input.Seat, .Read),
    spawns: ^multiplayer.Net_Spawns,
    cmds: ^core.Commands,
) {
    for row in 0..<core.count(seats) {
        seat := core.at(seats, row)
        if !input.pressed(seat^, .Fire) {continue}
        proj := core.spawn(cmds)
        multiplayer.predict_spawn(spawns, proj, core.entity_at(seats, row))
    }
}
```

## Lag compensation

`rewind.odin`. Server evaluates instant hits at the past `Clock.display` tick the shooter saw
(interpolated targets; predicted targets were seen in the present).

- Client reports `view_behind` per input; server stores `Remote_Input.view` and clamps to estimated
  latency if off by more than `Net_Settings.rewind_tolerance` (`views_corrected`; <0 trusts client
  within `REWIND_SECONDS`).
- `rewind_record` saves `Transform` (not bones) of `Rewind` entities in `Rewind_History` (ring of
  history + 1, cap `rewind_entities`; overflow/OOM reports `multiplayer.rewind`). Zero cost when no
  `Rewind` entities exist. `rewind_pose` interpolates between ticks unless distance exceeds
  `REWIND_TELEPORT`. Nothing moves in the world.

```odin
import pm "plugins:physics_multiplayer/runtime"

net, _ := core.get(net_seats, seat) // multiplayer.Net_Seat: the connection of a remote seat
if tick, ok := multiplayer.rewind_tick(inputs, net.connection, time); ok {
    if hit, hit_ok := pm.rewind_raycast(
        history, physics, rewound, tick, origin, dir, 200, ignore=shooter,
    ); hit_ok {
        // apply server-authoritative damage to hit.entity
    }
}
```

The rays of abilities are judged this way by themselves, hit zones included: the
`abilities_multiplayer` bridge
([network of abilities](../../mirai-abilities/references/abilities.md#network)).

## Delegated authority

`Simulation.Lent` entities simulate on server until lent via
`multiplayer.authority_grant(session, e, conn)` (0 reclaims) or client `authority_request` /
`authority_release`. Holder uploads pose/velocity/components; server applies via `core.Pose_Target`
(no `follow`) and replicates to others.

## Connection events

`Net_Connections.events` (`core.Events`) delivers `Connected`, `Disconnected` (with reason), and
server `Entered` (ready for world messages, on join and after scene change) once per tick at
`net_tick_head`. Same cadence for `core.Net_Messages`; replayed ticks replay their original
messages.

## Problems

Network steps populate `Net_Session.problems` (`^core.Problems`, nil outside steps);
`Net_Session.stats` tracks counters and `--status` logs `problems=`.

| Area | Problem IDs |
| --- | --- |
| Server object | `net.object`, `net.objects_full`, `net.states_full`, `net.frame_full` |
| Open / settings | `net.protocol`, `net.settings` (`Host.refused`) |
| Client | `net.replicas`, `net.predicted`, `net.snapshot`, `net.rollback`, `net.sync_test` |
| Messages / input | `net.event`, `net.event_about`, `net.event_send`, `net.events_pending`, `net.input_axes` |
| World / clock | `net.scene`, `net.sections`, `core.clock_network`, `multiplayer.rewind` |

## Verification

```sh
./mirai check plugins/multiplayer/runtime
./mirai play templates/game --headless --frames 600 --server --until-empty \
  --status bin/server.status
./mirai play templates/game --headless --no-gpu --frames 300 --connect 127.0.0.1 \
  --latency 100 --status bin/client.status
```

Run `mirai test plugins/multiplayer/runtime` (and `plugins/multiplayer/runtime/api_test`,
`plugins/destruct_multiplayer`). `--latency 100` raises `rtt_ms` by ~200 ms; loss/port/protocol
failures exit `PLAYER_NET`. `scripts/bench_compare.py` (`netpublish`) benchmarks server publish.

- **Publish & capacities (`publish_test.odin`):**
  `a_body_replicates_the_collision_and_contact_rules_of_its_collider`,
  `an_object_the_host_has_no_room_for_names_the_capacity_to_raise`,
  `settings_the_host_refuses_name_their_field_and_its_range`.
- **Authority & players (`authority_test.odin`, `players_test.odin`, `identity_test.odin`):**
  `a_replicated_component_that_does_not_fit_the_protocol_is_refused_with_its_fix`,
  `an_entity_with_more_replicated_components_than_an_object_carries_is_not_replicated`,
  `a_client_composes_the_type_of_a_creation_from_its_fragments` (`net`),
  `a_server_owns_each_body_to_the_connection_of_its_seat`,
  `a_seat_waits_for_its_player_and_is_given_back_when_it_connects_again`,
  `the_seats_of_a_saved_game_wait_for_their_players`,
  `a_client_plays_at_the_replica_of_the_seat_of_its_player`,
  `a_free_orbit_turned_by_its_player_moves_the_body_alike_on_both_ends` (`view_test.odin`),
  `a_seat_the_game_turned_off_stays_off_when_its_player_comes_back`,
  `a_client_that_presents_the_id_of_another_player_does_not_take_its_seat`,
  `a_player_that_comes_back_with_its_secret_gets_its_seat_back`,
  `a_connection_that_presents_no_player_or_two_is_closed`.
- **Scope & parent (`scope_test.odin`):**
  `an_entity_off_on_the_server_stays_off_on_the_clients_and_comes_back_where_it_got`,
  `visibility_replicates_an_entity_only_to_the_connections_whose_seat_shares_a_bit`,
  `entities_of_the_same_frequency_take_turns_instead_of_publishing_together`,
  `the_parent_on_the_network_is_the_closest_replicated_ancestor`,
  `object_scope_controls_relevance_radius_and_follows_the_replicated_ancestor`.
- **Rollback & SyncTest (`world_copy_test.odin`, `correction_test.odin`):**
  `a_rollback_replays_its_ticks_and_leaves_the_clock_and_the_frame_where_they_were`,
  `rollback_copy_failure_keeps_live_world_and_warm_publication_does_not_allocate`,
  `history_copies_of_what_changed_equal_whole_copies_through_writes_layout_changes_and_corrections`,
  `a_tick_a_library_asks_to_go_back_to_runs_again_from_the_copy_it_started_from`,
  `a_rollback_places_interpolated_replicas_as_far_behind_as_each_tick_did`,
  `an_error_too_deep_for_the_frame_puts_the_replica_where_the_server_carries_it`,
  `corrections_on_a_damaged_link_fit_the_frame_and_go_back_instead_of_placing`,
  `a_correction_notes_its_tick_entity_field_and_magnitude_outside_the_world`,
  `the_diagnostic_rings_keep_the_newest_notes_newest_first`,
  `predicted_transforms_compare_rotation_scale_and_quantized_components` (`integration_test.odin`),
  `play_network_status_says_how_the_run_predicts_and_corrects` (`plugins/multiplayer/editor`),
  `sync_test_names_what_a_fixed_function_reading_outside_the_world_changes`,
  `sync_test_leaves_out_the_ticks_that_states_arriving_late_change`,
  `sync_test_after_a_correction_compares_with_what_the_correction_left`.
- **Lag comp & input (`rewind_test.odin`, `input_packet_test.odin`):**
  `rewind_pose_interpolates_between_ticks_and_not_across_a_teleport`,
  `rewind_tick_is_what_the_client_showed_within_the_limit`,
  `what_a_client_does_not_drive_is_shown_in_the_past_unless_it_is_asked_to_predict_it`,
  `a_claimed_view_far_from_the_latency_takes_the_expected_one`,
  `an_input_delay_acts_on_what_the_devices_gave_that_many_ticks_ago`,
  `a_look_of_some_ticks_ago_corrects_the_look_of_the_server_once`,
  `a_state_older_than_the_history_puts_the_replica_where_the_server_had_it`,
  `a_following_target_leads_a_character_where_it_says` (`physics`).
- **Journal & switching (`journal_test.odin`, `switch_test.odin`):**
  `operations_reach_a_client_once_and_in_order_and_a_late_one_gets_the_base_whole`,
  `a_correction_hands_each_operation_again_at_its_tick_and_never_twice`,
  `what_a_client_receives_without_memory_is_left_out_and_reported`,
  `a_replica_changes_between_interpolated_and_predicted_without_a_jump_in_what_is_drawn`,
  `a_predicted_spawn_is_taken_by_its_replica_once_across_a_loss_and_a_correction`.
- **Timing & world (`timing_test.odin`, `world_test.odin`, `integration_test.odin`):**
  `a_client_at_144_hz_draws_what_it_predicts_always_forward`,
  `a_client_whose_frames_jitter_a_millisecond_draws_what_it_predicts_always_forward`,
  `an_interpolated_replica_that_moves_steadily_is_drawn_steadily_at_144_hz`,
  `an_interpolated_replica_published_ten_times_a_second_keeps_moving`,
  `an_interpolated_replica_over_a_jittery_link_keeps_moving`,
  `an_interpolated_body_is_kinematic_until_this_client_simulates_it`,
  `an_interpolated_body_follows_the_server_over_a_manipulation_of_the_game_and_gives_it_back`,
  `replicas_joined_to_any_of_many_driven_bodies_are_critical`,
  `physical_joints_inputs_and_components_converge_on_a_damaged_network`,
  `authoritative_physics_joints_and_inputs_converge_over_real_udp_localhost`,
  `a_scene_change_keeps_the_players_and_replicates_the_new_world_once_the_client_loaded_it`,
  `a_client_without_the_scene_of_its_server_leaves_saying_so`,
  `a_client_follows_the_pause_and_the_time_scale_of_its_server`,
  `the_connections_and_the_messages_that_arrive_reach_the_first_tick_after_them`,
  `a_typed_message_of_6_kb_with_4_kb_of_bytes_reaches_the_inbox_of_its_type_whole`,
  `a_message_about_an_entity_is_read_after_the_state_of_its_tick`,
  `a_status_that_comes_and_goes_on_a_lent_object_keeps_its_type_and_its_holder`,
  `a_ball_thrown_at_a_driven_body_turns_predicted_before_it_hits`,
  `what_is_in_a_section_reaches_a_client_while_it_has_the_section_loaded`,
  `a_replica_of_a_section_that_is_not_loaded_waits_for_it`,
  `what_is_in_sections_that_overlap_reaches_a_client_that_has_either`,
  `what_the_server_keeps_of_a_section_wins_over_what_a_client_kept`,
  `an_object_of_several_groups_reaches_a_connection_that_has_any_of_them_once` (`net`),
  `a_section_says_which_entities_of_its_scene_are_gone` (`engine/scene`).
- **Optional sweeps/benches:** `corrections_on_a_conditioned_link_by_tolerance`
  (`-define:NET_CORRECTION_SWEEP=true`), `cost_of_the_history_of_a_client`
  (`--release -define:NET_HISTORY_BENCH=true`).
