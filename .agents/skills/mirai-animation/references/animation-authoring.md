# Animation authoring by code and API

All authoring goes through `animation.*` and `skeleton.*` JSON-RPC/MCP methods. Schemas:
`mirai rpc describe animation.`; errors: [API](animation-api.md); runtime evaluation:
[animation.md](animation.md).

## Intent first

Declare intent first; drop to keys and tables only for fine tuning:
1. `skeleton.body.detect` (fix overrides with `skeleton.body.set`).
2. `animation.character.setup`: generates `.character` (locomotion, look-at, feet, hands, gestures).
3. `animation.request`: `locomote`, `look`, `reach`, `gesture` and modifier controls.
4. `animation.analyze` (clip metrics + verb fixes) and `animation.clip.edit` (whole-clip verbs).
5. `animation.preview` / `animation.capture` for isolated clip/set checks; real Play `capture`
   filmstrips (`debug`) + `animation.inspect` + `animation.history` for live physics/locomotion.

## Files and history

- `dry_run:true` validates without writing on every `create`, `set`, `patch`, bake and edit.
- `path` is asset-relative. `create` rejects existing files; `set` replaces keeping id
  (`replaced:true`, last writer wins). Responses serialize before writing; oversized responses
  abort without writing.
- Each call is one undo step attributed to the AI turn (flushed at step end); runtime/preview read
  via the registry, so Play sees unflushed edits. Requests during Play/Simulate are not saved.
- Validation failures include `data.{path,code,expected,actual,fix}`. Unknown fields, capacity
  overflows and non-finite numbers fail before the handler; unknown enums list valid members.

## Skeleton body

- `skeleton.body.detect` stores body parts and up axis in `.skeleton` (returning per-part
  confidence, missing parts and `fix`). Import auto-detects; without stored body, `clip.edit`,
  `analyze`, `character.setup` and `ragdoll.setup` detect transiently in memory.
- `skeleton.body.set` marks parts `manual` so they survive re-detection and reimport. Rigs face
  `-Z` (override non-turned imports with `asset.import {front}`). Unknown bones suggest close names.

## Clips: verbs and metrics

- `animation.analyze` measures travel, contacts, sliding, penetration, jerk, seam and joint limits,
  returning ready-to-apply `fixes` verbs
  ([metrics](../../mirai-std/references/anim-body.md#metrics-metricsodin)):

```bash
mirai rpc --project . animation.analyze '{"asset":"anims/hero.anim","clip":"walk"}'
```

- `animation.clip.edit` applies verbs in order, resampling to `rate` while keeping curves, root and
  shifted markers (`loop:"Auto"` checks seam). Empty `edits` copies a clip as-is into `path` (new
  or same-skeleton `.anim`, else `Other_Skeleton`; `replace:true` overwrites same name).

## Character

`animation.character.setup` builds a `.character` from the rig's skeleton body and clip library (or
from `skeleton` + `library` without touching an entity):
- Classifies clips by name tokens (`idle`/`stand`/`walk`/`jog`/`run`/`sprint` -> walk; `start`/
  `stop`/`turn`/`pivot` non-looping; `fall`/`air` -> fall; `jump`/`takeoff` -> fall entry; `land`
  -> walk entry; `swim`, `fly`/`hover`; other in-place clips -> gestures). Mode ids come from
  `Locomotion_Mode` (needs physics, else `Missing_Plugin`).
- `clips` narrows classification; exceeding `.character` capacity fails with `Capacity` + `fix`
  (never drops clips silently). `speeds` overrides measured foot-travel speeds.
- `blends` adds phase-locked locomotion blends (2..`MATCH_BLEND` looping clips of one mode with
  positive-sum `weights` and optional `speed`), replacing individual match entries.
- `min_rate`, `max_rate`, `trajectory_direction`, per-clip `rates`, `landing_marker` and
  `landing_rates` override set defaults.
- `want` enables capabilities: locomotion (`In_Place` with `animation_physics` when clips have root
  motion; idle + walk is already `Ready` via stride warp), look-at, hands (fixed world IK poles),
  feet (grounding, needs physics), and gestures (upper-body/arm layers + actions). Sideways clips
  can be fixed with `animation.clip.edit` verb `Face_Rest`.
- Stored skeleton body emits portable `@part`/`@region` names; transient detection writes raw bone
  names. Existing `.character` requires `replace:true` (preserves id). Returns per-capability
  `Ready`/`Partial`/`Missing` + `fix`.

## Clips and timeline

- `animation.clip.create` adds a unique-named clip; `clip.set` edits name/root only.
- `animation.track.set` creates/replaces/removes a track by `(target,property,slot)`; `key.set`
  inserts/moves/deletes single keys (works past `track.set` capacity); `marker.set` edits markers
  or timed spans (`duration` for sections/windows/warps; `target` for cinematic shots/actions).
- `animation.key.capture` keys every track driving an entity at `time` from its live transform and
  `@field` values in one step. Rotations are finite non-zero XYZW quaternions.

### Tracks tool

`plugins/animation/editor/tracks.odin` (`editor.tool` `tracks`; `animation.request {seek}` moves
playhead in Edit). Holds only view state; every gesture calls `animation.key.set`, `track.set`,
`marker.set` or `key.capture` as one undo step. Releasing the transform gizmo on a keyed entity
auto-keys it via `animation.key.capture` in the move's undo step. Other tools (Cinematics) embed it
via `tracks_open` and `tracks_rows`.

## Inspection

Verify real Play locomotion numerically and visually before guessing:

```bash
# 1. Inspect matching candidates, rejection reasons, and exact world/local bone & socket poses
mirai rpc --project . animation.inspect '{
  "entity": "Player", "parts": ["Match", "Pose", "Actions"],
  "pose_stage": "Finished", "names": ["@pelvis", "@foot_l", "@foot_r", "grip"]
}'

# 2. Replay match/pose across Play history ticks (leaves live Play unchanged)
mirai rpc --project . animation.history '{"entity":"Player","from":0,"to":60,"every":5}'

# 3. Real Play filmstrip with skeleton + collision + trajectory overlays (no ui:true needed)
mirai rpc --project . capture '{
  "path": ".mirai/tmp/play_loco.png", "every": 6, "count": 8, "follow": "Player",
  "debug": ["skeleton", "match", "bounds", "collision", "trajectory"],
  "segments": [{"for": 48, "keys": ["W"]}]
}' --select path,ticks
```

- `animation.asset.inspect` pages `.anim`, `.skeleton` and `.character` sections.
- `animation.inspect` reads parts (`Rig`, `Match`, `Modifiers`, `Actions`, `Motion`, `Morphs`,
  `Pose`, plus `diagnostics`). In Play/Simulate, pass hex handle for spawned entities. Unsupported
  parts return `{available:false, code, reason}`; broken sets return `Program_Error`.
- `Match` lists database clips, candidate per-feature costs, and why excluded clips were rejected.
- `Pose` returns `Finished` or `Sampled` world/local transforms for named bones (`path`, unique
  name, or `@body_part`) and sockets (unknown name fails).
- `animation.history` replays Play history without mutating the run, reporting `searched`/`jumped`.

## Skeletons, sockets and profiles

- Skin weights live in the mesh asset; these methods edit only `.skeleton` hierarchy, sockets and
  body. `skeleton.create` requires parents before children; `skeleton.bone.set` edits name/ref;
  `skeleton.bone.add` appends a bone (preserving mesh indices) and optional `clips` rebinds matching
  leaf track paths. Removing/reparenting requires a new skeleton.
- Sockets live on `.skeleton`; equipped entities use `Bone_Attachment`.
- `animation.modifier.set` edits `.character` modifier tables by key (entity targets arrive at
  runtime via `animation.request {goals}`). `animation.modifier.poses` extracts facial `curve_poses`
  and ARKit remap drives from a multi-pose clip. `animation.retarget.bake` bakes a retargeted
  `.anim` between skeletons (using destination `.character` chains for differing topologies).

## Motion matching and additive spaces

- `animation.character.setup` writes the match table, with `biases` per clip, `extras` (bone tips
  the search matches) and `libraries` (the `.anim` a weapon's set swaps in, built ahead,
  `no_mirror`); `animation.asset.inspect` shows clips, modes, blends, libraries and loaded-skeleton
  database stats/errors; candidates split their cost into features, `extra` and `bias`.
- `animation.space.set` edits `.character` aim-offset/additive spaces (rejects duplicate axes,
  duplicate points or degenerate triangles); `animation.space.sample` evaluates weights without
  advancing the world. Attach to a layer via `animation.action.set`.

## Per-instance control and preview

- `animation.play` assigns `Animation` asset/clip (missing clip -> `Missing_Clip`). Everything else
  uses `animation.request` (same schema as `animation.preview`): `stop`/`seek`, named layer/axis
  parameters, `actions`, modifier `goals`/`controls`, warp targets, and intents (`locomote`,
  `look`, `reach`, `gesture`). In Edit only `stop` succeeds; others point `fix` to
  `animation.preview`.
- Modifier controls multiply weights independently of targets (`enabled:false` fades out). Goals
  name operations as `animation.inspect {parts:["Modifiers"]}` lists them; ambiguous names fail.
- `animation.preview` clones the world and runs ticks without touching the document or Play,
  returning local poses, `program`, and per-tick `trace`.
- `animation.capture` renders `animation.preview` on an **isolated preview copy without physics or
  world collision** ([previews](../../mirai-plugins/references/previews.md#animation-capture)); use
  it for quick clip/set checks, and use Play `capture` filmstrips + `debug` for live locomotion:

```bash
mirai rpc --project . animation.capture '{"entity":"Player","time":0,"seconds":1.0,"frames":6}'
```

- `animation.pose.bake` bakes `start..end` on a preview copy (including intents, curves, morphs
  `<path>/@morph/<target>` and markers; `root_motion`: `Preserve` or `In_Place`).
- Props/fields: create clips with `animation.clip.create` + `animation.track.set` (empty target =
  owning entity, `@field/Component.field` for fields) and assign via `animation.play`.

## Verification

Tests in `plugins/animation/editor` (`-collection:plugins=<root>/plugins`):
- `body_api_test.odin`, `clip_edit_test.odin`, `setup_test.odin`, `request_test.odin`,
  `inspect_test.odin`, `program_api_test.odin`, `tracks_test.odin`, `authoring_actions_test.odin`,
  `authoring_constraints_test.odin`, `preview_trace_test.odin`, `pose_bake_test.odin`,
  `morph_api_test.odin`; file history in `editor/edits_files_test.odin`.
- Live: verify with `mirai rpc describe`, `animation.capture` (isolated) and Play `capture`
  filmstrip + `debug` + `render.inspect_entity` with GPU validation.
