# Animation

Optional `animation` plugin (Runtime + Editor); import as `anim "plugins:animation/runtime"`.
Math: [`std/anim`](../../mirai-std/references/anim.md); bind:
[assets](../../mirai-assets/references/formats.md); imported hierarchy:
[imports](../../mirai-imports/references/imports.md#skinned-meshes); layers/actions:
[actions](animation-actions.md); authoring: [authoring](animation-authoring.md). No state machine
or animation graph ([what replaces them](#what-replaces-the-state-machine)).

## Components and shared data

| Component | Role |
| --- | --- |
| `Animation` | Plays `.anim` (clip) or `.character` set; `library` override, `mirror`, `root_motion` |
| `Animation_Progress` | Saved clip clock/selection materialized by `Playback` on slot capture |
| `Pose_Source` | Shares the finished pose of a rig of its skeleton or [follows one of another](#following-a-rig-of-another-skeleton); other proportions [retarget their clips](#retarget) |
| `Bone_Attachment` | Attaches entity to bone or `Skeleton_Socket` (local offset after socket TRS): where it rests; `attach` switches it to another socket in Play |
| `Animation_Budget` | Update cadence/LOD ([budget](animation-budget.md)) |
| `Morph_Weights` | Blendshape weights ([morphs](animation-morphs.md)) |
| `Animation_Target` | Hidden imported rigid-target identity; survives entity renames |
| `Skin_Part` | Collapses bone + subtree onto bone when camera excludes its layers (`own_hidden`); shadows/reflections stay whole ([own body](../../mirai-gameplay/references/control.md#following-cameras)) |

- **Rigs.** Entity with skinned `Mesh_Renderer` and no same-skeleton `Pose_Source`; needs no
  `Animation` for procedural poses. Each rig owns its pose; prefabs create no bone entities. Rig
  list revision advances only when rig entities or skeletons change (unrelated reloads keep
  constraints/springs).
- **`.character` set.** Shared per body: locomotion (`Match_Profile`), layer stack, actions +
  sections, aim/additive spaces, warp windows, and modifiers (`Pose_Profile`: IK, Look,
  limits, [grounding](animation-grounding.md), [rigs](animation-rigs.md)). Limbs/pelvis come from
  `.skeleton` body; sections/windows reference clip span names, never raw seconds.
- **Bone refs & modifiers.** `Bone_Ref` accepts canonical path, unique short name, or `@part` /
  `@region` from [body map][body] (region wins over part in layer `over`); invalid/ambiguous refs
  never fall back to root. `animation_bone_bind` returns `Bone_Handle` (invalidated on rig
  revision). Contacts are IK rows with world [`Spatial_Target`][spatial]; Look aims from `offset`
  (e.g. eyes/muzzle). Modifiers are driven via `Animation_Requests` ([rigs][rig-req]);
  deactivating fades to zero then disables; repeating the same control does not restart fade.
- **Asset/memory contract.** Skeletons, skins, sets load via `host.assets_file` (sees unflushed
  assets) and refresh only on `assets_stamp` changes. Stable ticks and fades never allocate; OOM on
  load/reload keeps previous runtime and retries.

### Following a rig of another skeleton

A `Pose_Source` (`Finished`) targeting a rig of another skeleton makes a follower rig (`Rig.leader`,
e.g. face/head rig on body):

- Shared bones copy the leader's finished pose (by name, or path on duplicates); follower-only
  bones keep its own `Animation` and set under moved parents. Pairs build on bind, never per tick.
- A follower reads the curve of its leader where the leader animates it and its own otherwise
  (`rig_curve`: lookups, curve poses, `@field/Material_Live` values), so the face a body plays
  poses a modular head; its morphs read its own curves and the leader's where its own do not play.
- `rigs_update` topologically sorts `Playback.follow_order` for single-pass `animation_finish`;
  cycles run last and report `animation.follow_rig`, zero common names report
  `animation.follow_bones`. Leader `Playing.world_final` builds once per tick; follower entity
  transform may sit anywhere.

## Locomotion by motion matching

Locomotion is the `Match_Profile` of `Animation.asset` (`.character`):

- **Sources & blends.** Each `Match_Source` lists `modes` bitmask (physics `Locomotion_Mode`),
  optional `entry` (non-looping mode-entry clip like jump/land), explicit `speed`, and `mirror`
  (`Off`/`Both`/`Only`; missing side names report `animation.match_mirror`), and `bias` (cost
  added to its rows and to playing on: negative favors it). A source with `blend` samples
  phase-locked looping clips at `Match_Sample` weights; missing blend clips report
  `animation.match_blend`. Up to `MATCH_CLIPS` (256) sources and `MATCH_SAMPLES` samples.
- **Database.** `std/anim/matching.odin` features (feet, hips, body velocity, past/future
  trajectory, and the `extras` of `Match_Info`: up to two bone tips, `offset` in the bone's frame,
  such as a blade's tip) build on first rig load into `Character_Assets`, capped by `memory`
  (`animation.match_memory`; a missing extra bone reports `animation.match_extra`). Looping,
  non-entry clips that travel (above `MATCH_STILL`) with the body turned away from `-Z` in every
  frame (`body_turn`, so pivots stay quiet) report `animation.match_forward` once per build
  (`animation.asset.inspect` lists them as `turned`): turn them with the `Face_Rest` verb of
  `animation.clip.edit`. 8 lanes a row, 12 with extras. Linear SIMD below `MATCH_LINEAR_ROWS`,
  bounded runs above. A database of an
  older library generation or skeleton revision is released when its successor builds.
- **Per tick.** `match_goal` feeds mode, velocity, desired velocity, accel/braking, facing, wall
  normal, and `time_to_land`. An animated entity with `core.Motion` and no `Character` or
  `Rigid_Body` walks by its Motion (`motion_goal`). With physics, `animation_physics` feeds it
  automatically (model faces `-Z`, [facing](../../mirai-physics/SKILL.md#library-invariants)) and
  drives `mantle` warp/root motion. Optional spring `lag`/`lag_half_life` offsets root up to `lag`
  (never into wall; closes only while moving at `<= MATCH_LAG_CLOSE * clip_speed`).
- **Search & transitions.** Every `interval`, picks lowest-cost row scaled within
  `min_rate`..`max_rate` if saving `bias` past `hold`, skipping `reselect` window (or whole loop
  with `keep_loop_phase`). `spans`: `Exclude` forbids search and forces immediate re-search;
  `Block` forbids search while allowing continuation; `Keep` allows search and holds the clip
  against searches nothing forces (mode change, entry, end, `Exclude`) until it plays out of the
  span (unknown/full-clip spans report `animation.match_span`). `stationary_speed` separates idle
  vs travel clips. Entering a mode with entry clips searches their starts first. Jumps enter via
  inertialization (`blend` s).
- **Library swap & whole-body actions.** Swapping `Animation.library` keeps lag/mode and blends
  into new clips once loaded (while compressing, previous library keeps playing); its first search
  asks for the pose the rig has without the extra points (`skip_extras`), which are of the old set.
  `libraries` of the `.character` lists the `.anim` a swap brings (a weapon's set): their databases
  are built with the first one of a skeleton (`match_prebuild`), not on the swap tick, and
  `no_mirror` plays their mirrored sources as authored (the sword stays in its hand). Whole-body
  `play` (no layer) takes over and returns via inertial blends ([actions][actions-life]); the
  search after it ends asks for the pose it left, extra points included. Query state with
  `animation_match`.

### Landing

Clips carrying `landing_marker` (`Animation_Match.landing_modes`) time impact using `time_to_land`
(`animation_physics` queries `character_landing`): searches restrict to rows whose marker lands at
rate within `landing_rates`, adjusting rate each tick. Passing the marker in air resumes normal
matching; entering a new mode past the marker lets the clip tail finish naturally.

## Additive spaces

1D/2D aim offsets or additive poses named by a layer's `space` (missing space reports
`animation.layer_space`). Axes normalize to finite ranges (`blend_space_prepare`, projected to hull
edge outside; duplicate/degenerate points rejected). Driven by `set` parameters matching axis names
(or queried with `blend_sample`); clips loop without firing markers. Program buffers reserve on
bind/reload, copy per world, and retain previous output on OOM.

## What replaces the state machine

| Legacy concept | Mirai equivalent |
| --- | --- |
| Locomotion states / transitions | `Match_Profile` modes + search (`entry` for jump/land) |
| Whole-body / upper-body states | `play` action without layer / in a stack layer |
| Locomotion blend space | `Match_Source` clips + `Match_Sample` blends |
| Aim offset / breathing / mood blend | Additive layer (`space` or clip) + `set` parameter |
| Animation graph / triggers / wait | Layer stack / `play` + `Animation_Events` (`Ended`) |
| Props (door, lever) | `play_clip` + `Animation_Events` |
| Game/AI state logic | Game tables/steps; AI in `std/ai` |

Small clip sets work too: run `skeleton.body.detect` (or `skeleton.body.set`), then
`animation.character.setup` (with explicit `speeds` for sliding walks). Drive speed via
`Walk.max_speed`, swap enemy variants via `Animation.library`, and align scripted entries with
`body_move` + [root motion targeting][rmt].

## Playback, outputs and order

- Direct `.anim` with empty `clip` plays clip 0 (`ANIMATION_DEFAULT`). `library` overrides clips
  of a `.character` by name (absent clip: `Missing_Clip`); ignored on direct `.anim`.
- **Edit vs Play.** Editor previews/scrubbing stay in derived storages, never in components. First
  Play tick restarts from component state and drops queued preview requests.

```odin
// Drive motion matching (without animation_physics), play actions, set params, query outputs.
anim.match_goal(reqs, {
    rig = e, mode = mode, velocity = vel, desired = wish * speed,
    facing = wish, acceleration = 20, braking = 20, turn_rate = 8,
})
anim.play(reqs, e, "attack", section = "windup") // whole-body or layered per .character
anim.set(reqs, e, "aim_yaw", yaw)                // space axis or layer weight (0..1)
anim.look(reqs, e, {position = target_pos}, weight = 1, name = "@head")
smile := anim.animation_curve(playback, e, "smile", default_value = 0)
delta, has_root := anim.animation_root_delta(playback, e)
```

```odin
// Attach a face/clothing rig to a body rig, or read finished pose in entity space.
core.add(&pose_sources, head, anim.Pose_Source{rig = body, stage = .Finished})
if pose, ok := anim.pose_space(playback, body, context.temp_allocator, .Finished); ok {
    _ = pose // bone i of .skeleton is at pose[i + 1]
}
```

### Multiple sources

Any match source, space sample, layer or action may specify `animation` (empty
uses set or `library`). Main source keeps clip names; extra sources use `source_clip_name`
(collisions fail with `Invalid_Asset`). `Source_Assets` shares merged libraries across worlds,
rebuilding only on asset change. Inspect via `animation_playing_content`, `source_clip_source`,
`source_clip_label`.

### Storages

- `Playback` (derived world storage): clocks, fades, dense poses, curves, root deltas, shared
  `Track_Map` (blends by bone, never target name). Materializes `Animation_Progress` on save.
- **Stack only when layered.** `Playing.stack` (`Stack_Playing`: layers, actions' slots, inertia,
  parameters, masks) is made the first time an entity plays more than its base clip (a `.character`
  with layers, actions or locomotion, a `play_clip` in a slot, `set`) and kept; a prop or timeline
  playing one clip has none.
- **Copies carry simulation only.** `playback_copy` (Play, rollback snapshots) copies states,
  stacks, rigs and track maps; each copy keeps its own `Playback.work`, `Stack_Playing.scratch` and
  `Playing.scratch` (sized by the next tick, so copying back into a world that played allocates
  nothing) and drops `Playback.searches`, the last search of matching kept only for inspection.
- Names a tick compares are hashed when bound, never per tick: action, clip, exit marker and
  section names in `Action_Plan`, warp windows in `Motion_Instance`, `Morph_Weights.path` per row
  stamp; `@field` tracks remember the row of their curve (`curve_find`).
- Modifier, field-track, action, motion, and budget storages copy for Play/rollback.
- Shared caches live on host (`Character_Assets`, `Skeleton_Assets`, `Skin_Runtime`); per-world GPU
  deformed meshes live in `Skin_Instances` (`animation_skin_release` on world free).

**Fixed-step order:** `animation_prepare` (`apply`) -> physics `simulate` -> `animation_sample` +
`animation_fields` (`simulate`) -> `animation_advance` (`react`: root removal, warping,
grounding, IK/Look, rigs, limits, final poses, attachments).

- **Root motion:** `None`, `Extract`, or `In_Place` (`Pose_Lock` per fading clip). Blended clips
  must match root bone/channels (`Incompatible_Root`). Seeks emit zero delta; inertialization
  corrects root delta. Target windows/warping: [motion](animation-motion.md).
- **Queries & events:** `animation_curve`, `animation_vector`, `animation_progress`,
  `animation_command`, `animation_pose`, `animation_bone_transform`, `animation_sample_pose`,
  `animation_pose_final` (`animation.final_pose_binding` / `animation.final_pose_bone`; reserve
  extra room with `animation_requests_reserve` for [Ragdoll][ragdoll]). `Animation_Events` filters
  markers by `Dominant`, `Weighted` (`event_threshold`), or `Always`.
- **Editor & GPU skinning:** `animation_evaluate` runs `anim`+`core` fixed steps (see
  `pose_bake_test.odin`). `animation_skin` interpolates last two poses (no interpolation when newly
  shown after `Hidden`), shares base mesh while `palette_at_bind` (allocates deformed copy + BLAS
  only once posed or morphed; large uploads stream [over several frames][geom-frames]), applies
  `Skin_Part` collapse and the `@field/Material_Live` values of the clips. GPU contract:
  [GPU skinning](../../mirai-rendering/references/scene.md#gpu-skinning).

## Retarget

A rig plays clips made on another skeleton (the `.skeleton` each clip of an `.anim` names) as the
retarget of that `.anim` onto its skeleton: an ordinary compressed `.anim` made once per `.anim`
and skeleton, never in a tick (`asset.animation_retarget`, `asset/animation_retarget.odin`):

- A clip binds by name as it is when every bone it moves has, on the rig, a bone of its path with
  the same parent and rest: a skeleton variant with an extra bone or one imported twice plays the
  `.anim` itself (`direct`). Clips of no skeleton or of the rig's are never looked at.
- Otherwise bones pair by name or path, else by the parts of the body both `.skeleton`s mark, the
  spine by its share of the chain (`lib.retarget_map`); the crotch keeps off the floor when both
  bodies have pelvis, hips and feet. Each clip is sampled at its own rate, channels that stay at
  rest left out, and the result is compressed by `asset.animation_compress` like any `.anim`;
  curves, markers (with their `.anim`) and names stay, the root bone follows its pair or its root
  flags turn off.
- **Cooked:** the cook writes the retarget of each `.anim` onto each skeleton a scene or prefab
  plays it on (an entity with `Animation` naming it, its `.character` or library, and a
  `Mesh_Renderer` of that skeleton) beside the `.anim` as `<anim>.<skeleton id>.anim`, id
  `asset.animation_retarget_id` ([build](../../mirai-projects/references/build.md)). A shipped game
  reads it and retargets nothing; a pair only game code makes is not cooked and its rigs report
  `Uncooked`.
- **Editor and dev:** `host.content_animation_retarget` makes it in a job, like the compression of
  an `.anim`, keeps it in `App_Desc.animation_cache`, and the frame after takes it. The rig waits in
  its rest pose meanwhile, as for a skeleton that loads. The plan of the rig (`Source_Key.skeleton`,
  `Playing.rig`) resolves it when its library, its skeleton or the content changes; a tick only
  looks its entry up. Every rig and world of that skeleton shares it; a joined set over retargets is
  keyed by the skeleton and marks them used once a frame.
- **Budget:** retargets held stay within `App_Desc.retarget_budget` (`CONTENT_RETARGET_BUDGET`,
  64 MB): one that does not fit evicts those no rig asked for in `CONTENT_RETARGET_IDLE` frames and
  otherwise fails with `Budget` until there is room.
- **Never unretargeted:** a source `.skeleton` that cannot be read or pairs no bone, an `Uncooked`
  pair or a `Budget` failure leaves the rig in its rest pose (nothing of the library plays) with
  `animation.retarget_skeleton` or `animation.retarget_budget` naming the library, the skeleton and
  the fix. It is made again when the `.anim` or a skeleton changes (`content_retarget_stamp`).
- A rig keeps only the generation it bound (`Playing.generation`), never a place in a cache: a
  snapshot restored after the retarget was made again finds nothing of the old one and binds the
  new one; a world copy or rollback plays the same poses.
- What retargets on load does not do: a pose made at run time (ragdoll, IK, another rig's result)
  is not carried onto a rig of other proportions; `Pose_Source` follows only bones shared by name.

`animation.retarget.bake` writes the same mapping into an editable `.anim`
([bake](animation-rigs.md#bake), compressed on load per
[storage](../../mirai-std/references/anim-storage.md)).

## Mirroring

`Animation.mirror` reflects the full pose and root delta after layers/actions (requires `.skeleton`,
else `animation.mirror`). Skeleton load pairs sides via [`mirror_name`][mirror-fn] (`thigh_l`,
`hand.L`, `LeftArm`, `Bip01 L Thigh`; inspect via `animation.inspect` part `Rig`). Bind deduces
lateral plane and reserves buffers (zero tick allocations). Warping uses reflected root motion;
markers/curves keep original names.

## Problems

Runtime failures report `animation.*` codes in
[`core.Problems`](../../mirai-core/references/core.md#problems) (listed by `engine.diagnostics`,
`animation.inspect`, `animation.preview`):

- **Assets:** `animation.asset`, `program_asset`, `skeleton`, `skin_mesh`.
- **Binding/data:** `animation.clip`, `layer_clip`, `layer_bone`, `pose_bone`, `attachment_socket`,
  `attach`, `attach_socket`, `parameter`, `match_clip`, `layer_space`, `match_database`,
  `match_memory`, `match_blend`, `match_mirror`, `match_span`, `match_extra`, `match_forward`,
  `rig_*`, `constraint_*`, `grounding_*`,
  `retarget_*`, `motion_*`, `morph_*`, `action_*`, `modifier_*`, `match_goal`.
- **Follow/curves/limits:** `follow_rig`, `follow_bones`, `follow_pose`, `curve_pose_bone`,
  `curve_pose_value`, `material_field`, `material_values`, `final_pose_binding`,
  `final_pose_bone`, `mirror`,
  `markers_lost`, `events_lost`, `animation.memory` (keeps last pose and retries).
- `Playback.stats.skipped` counts skipped writes when another component owns `Transform` (not an
  error).

## Verification

Run `mirai test plugins/animation/runtime` (CPU; GPU skinning needs validation + project run):

- `program_test.odin`, `character_test.odin`, [actions](animation-actions.md#verification).
- Matching (`matching_test.odin`, `std/anim`):
  `matching_walks_mirai_avatar_with_its_feet_planted_without_pose_jumps_and_follows_the_stick`,
  `match_database_finds_each_frame_by_its_features_and_the_clip_a_trajectory_asks_for`,
  `match_trajectory_follows_a_walk_that_accelerates_brakes_and_turns_at_its_rates`.
- Async load (`source_content_test.odin`):
  `an_animation_that_compresses_in_a_job_plays_once_it_is_ready_without_problems`,
  `a_library_that_compresses_in_a_job_keeps_what_plays_until_it_is_ready`.
- Blending & body (`runtime_test.odin`, `skeleton_test.odin`):
  `direct_clip_weights_preserve_zero_full_and_partial_trs_without_allocations`,
  `body_labels_name_the_parts_and_regions_the_skeleton_keeps`,
  `layers_play_over_a_region_of_the_body_without_stable_allocations`,
  `body_labels_of_a_skeleton_without_body_say_how_to_give_it_one`,
  `skeleton_bone_find_takes_a_path_a_unique_name_or_a_part_of_the_body`.
- Retarget (`retarget_test.odin`, `matching_test.odin`, `cook/build/cook_test.odin`): one
  retarget shared by rigs without stable allocations, made again when a skeleton changes; the
  first play waits in the rest pose for a job; clips whose moved bones match bind by name; an
  unreadable source holds the rest pose until it arrives; the budget evicts only what no rig plays;
  a cooked retarget plays as the one a job makes; a restored copy plays the same poses;
  `a_library_made_on_another_skeleton_builds_its_database_over_its_retarget_ahead` and
  `a_cook_ships_the_retarget_of_an_animation_a_scene_plays_on_another_skeleton`.
- Follow/GPU (`follow_test.odin`, `skin_bind_test.odin`):
  `followers_finish_after_their_leaders_in_the_order_found_once`,
  `rigs_at_the_bind_pose_share_their_mesh_until_a_pose_leaves_it`.

[body]: ../../mirai-std/references/anim-body.md#body-map-bodyodin
[spatial]: animation-rigs.md#spatial-targets
[rig-req]: animation-rigs.md#requests-and-diagnostics
[actions-life]: animation-actions.md#requests-and-lifecycle
[rmt]: ../../mirai-std/references/anim-motion.md#root-motion-directed-at-a-target
[ragdoll]: ../../mirai-plugins/references/ragdoll.md
[geom-frames]: ../../mirai-rendering/references/scene.md#geometry-over-several-frames
[mirror-fn]: ../../mirai-std/references/anim.md#mirroring-mirrorodin
