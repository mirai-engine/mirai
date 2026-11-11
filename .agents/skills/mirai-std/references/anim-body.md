# std/anim: body, metrics and clip editing

Body semantics of a skeleton and operations on whole clips, to declare intentions ("smoother",
"make it last 2 s", "head a little to the left") instead of editing keys. They are pure functions
over caller buffers, without allocating; the types and their comments in `body.odin`, `frames.odin`,
`metrics.odin` and `edit.odin` say each parameter. The animation plugin exposes them through the
API; the format that stores the map is the
[`.skeleton`](../../mirai-assets/references/kinds.md#skeleton).

## Body map (`body.odin`)

- `Body_Map` gives the bone of each `Body_Part` (-1 without a bone), its confidence, the up of the
  body at rest and what a person set (`manual`), which detection keeps. It stores no forward: a
  body faces `math.FORWARD`, and its left and right come from that and its up. The spine is not
  stored: `body_spine` gives it between pelvis and neck.
- `body_detect` reads the names by words with the side attached or loose (Unreal `thigh_l`, Mixamo
  `LeftUpLeg`, Biped `Bip01 L Calf`, Rigify `upper_arm.L`, capture `lfemur`) and discards twist, IK,
  fingers, ends and helpers (`BODY_EXCLUDED`).
  - It builds each limb from its end upward through the hierarchy; an unnamed intermediate bone
    takes the ancestor that departs most from the line of the limb. The pelvis is the one named
    above where the legs join, or that point.
  - A limb without a side in the name takes the side it is on. It lowers the confidence of a part
    that is out of place or does not mirror its pair; without recognizable names it does not invent
    parts.
- The regions distribute each bone through the branch of the first bone of each one;
  `body_unassigned` gives those that fall in none (IK helpers hanging from the root). `body_height`
  is the scale of thresholds and displacements.

## Sampled clip (`frames.odin`)

- `Frames` stores the local pose of each bone and the curves at each frame; in a loop the last frame
  is the first of the next pass.
- `frames_root` is the bone that carries the movement over the ground: the `root` of the rig or the
  highest one above the pelvis whose position changes.

## Metrics (`metrics.odin`)

- **Ground.** With root motion, `travel` is the velocity of the root. An in-place clip moves the
  ground under the feet that rest, and `travel` is the velocity at which the game must move the
  body. As a swinging foot also passes under, and faster, the ground is the velocity that more low
  frames of ankles and toes share (a vote in cells of `GROUND_CELL`). When no foot rests on that
  ground for a contact (a run that touches the floor a frame or two between flights) the travel is
  physical: the speed at which the joint of a foot that is down pushes back relative to the
  pelvis, the median over the frames it is down weighted by how far down, along the mean
  direction of those pushes. A flight phase does not slow it. Only a clip whose feet never come
  down falls back to the path the feet sweep relative to the pelvis along their main axis over
  the duration.
- The support height is estimated from the frames of the clip, independent of the rest pose;
  penetration is measured against the rest. An absolute height or a clip in the air without contact
  metadata do not make it possible by themselves to know where the ground of the world is.
- **Contacts.** A foot rests when the ankle or the toe is near its floor, rises slowly and moves
  slowly over the ground (`CONTACT_*`): one that slides keeps resting and one that swings does not.
  In a loop, the supports that touch both ends share their anchors across the seam.
- The rest (sliding, penetration, jitter, seam, limits of knees, elbows and head) is in the comment
  of `Clip_Metrics`.

## Editing verbs (`edit.odin`, `edit_body.odin`)

A `Clip_Edit` transforms a whole clip into another without touching the input; each variant says in
its comment what it does and its durations. A zero `Time_Range` is the whole clip, and
`Edit_Result.part` names the missing part.

- **Time.** `Retime`, `Hold` and `Extend` resample the input and carry the root; `Extend` repeats
  the segment as a cycle and the root continues from where each pass leaves it.
- **Filters.** `Smooth` and `Exaggerate` go by regions (empty is the whole body) and fade at the
  borders of a segment. In a loop they wrap the clip; otherwise they reflect it in time to keep a
  constant velocity.
- `Make_Loop` equalizes the ends in pose and velocity; the root keeps its advance and its turn.
- `Offset` carries `direction` in body space, which turns with the root, and an `amount` of
  `OFFSET_TURNS`, `OFFSET_SWINGS` or `OFFSET_MOVES` depending on the part:
  - Head, neck and the `Spine` region (distributed over its chain) turn the face: left and right
    turn, up and down nod, forward and back tilt.
  - Clavicle, shoulder, hip and toe point toward the direction, at most until pointing at it
    (`Along_Part` if they already point almost there).
  - Elbow and knee rotate the limb around its axis without moving the end; hand and foot are
    displaced with IK keeping their rotation; the pelvis is displaced and the legs keep the feet.
- `Lock_Feet` fixes each foot horizontally on its contact with leg IK, keeping the animated height
  and rotation: the ankle over its anchor while the heel rests, and turning on the toe as it lifts.
  The hip lowers or rises the minimum for the feet to reach; a distant target (or beyond
  `EDIT_SOFT_REACH` of the leg) is approached softly, without locking the knee. The contacts are
  those of the clip, or the feet and frames given in `contacts` (those of the clip a retarget was
  baked from), with their anchors where the feet of this clip stand.
- `Mirror` applies `pose_mirror` per frame and also reflects the roots from their rest.
- `Face_Rest` takes out the turn about up of the joint that turns the body away from its rest
  facing: the highest of the pelvis and its ancestors turned more than `FACE_REST_TURN` in some
  frame (the `Dummy01` with which a 2.5D game faces sideways inside its clips). The rest of the
  pose keeps its locals, sways included; without such a joint the clip stays as it was.
- The two-bone IK of the verbs admits intermediate bones between root, joint and end (Rigify).

## Verification

`mirai test std/anim` with `body_test.odin`, `metrics_test.odin` and `edit_test.odin`: metrics and
verbs over a synthetic walk with IK (with and without root motion, sliding, penetration, jitter and
backwards knees), and hostile cases with `ANIM_HOSTILE_ROUNDS`. Detection on the real mannequin is
tested when importing it, in `cook/import/sources`.
