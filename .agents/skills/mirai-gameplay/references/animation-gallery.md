# Animation gallery

`demo/assets/animation_gallery/animation.scene` is the only animation scene of the demo: a hall that
the player walks with Mirai (`source/models/mirai/mirai.glb`), with one numbered station per feature
on each side of the walkway. The scene is authored; `tools/demo_content --animation-only` writes
its clips, `.character` sets, rigs and meshes ([generated content](demo.md#generated-content)).
Each station's actor plays its own `.character` (`Animation.asset`) over the gallery's clips: the
sets of the stations show one feature each.

## Invariants

- Every humanoid station shows Mirai. The other actors are what Mirai cannot show: the procedural
  spider, the chains of the rigs, the morph jellies and a taller Mirai for the retarget.
- Every station plays on its own, in a loop, from the start of Play. One with a panel (a
  `Gallery_Panel` with a `World_Widget`) is adjusted in the world: E at the station frames the panel
  with its camera (`camera_override`), frees the pointer and shows the panel, `Interactive`; E
  again hides it and gives the walk back. The first change a panel asks makes its station manual
  until its `Automatic` button.
- A panel shows only while it is adjusted and a plaque only near the body of the player:
  `gallery_widgets` is the only writer of their `World_Widget` and hides one by leaving it
  without size.
- E at the spider hands the seat to the spider; E again hands it back to Mirai.
- The clips of the gallery (`mirai_gallery.anim`) are derived from the imported idle and walk of
  Mirai: the steps of the walk come from where its feet land, the jog is the walk faster and wider,
  the wave raises the left arm over the idle and the stride is the walk with the advance its feet
  push, for root motion. The source clips hold the hands off their bind, so every clip of Mirai
  turns each hand around its bind instead of around its mean. Regenerating them never edits the
  glTF.
- The physical Mirais (the player, the slope and the jump stations) walk by motion matching over
  `mirai_matching.character` and the game has no locomotion code: `animation_physics` gives them the
  mode, velocity and request of their `Character`. The matching station has no `Character`: the
  game asks it for the velocity with `match_goal` over `mirai_gallery.character`.
- The tall Mirai is stretched upward with its skeleton, so each bone retargets by the bone of its
  name, keeping the lengths of the tall skeleton; its clips are baked when generating the content
  ([plugin retarget](../../mirai-animation/references/animation.md#offline-and-live-retarget)).
- The warp station walks between goals on either side of its origin and is never put back: it
  turns in place toward the next goal with its motor off, then strides by root motion warped to
  end there. Each goal is a share of what its stride covers unwarped (`stride` of its
  `Animation_Gallery`, which the scene keeps equal to what the stride clip covers), 0.8 to 1.2 on
  its own and 0.7 to 1.3 from its panel: a warp corrects what a clip nearly covers, and a goal far
  from it makes the feet slide.
- The constraints of the IK station and of the three rigs aim at points of the world: the tool
  puts them where the scene has those stations (`gallery_place`), so moving one of them in the
  scene moves its points in the tool too.
- The manual adjustments and the UI queue belong to the Play world and are discarded when it stops.

## Code (`demo/game`)

- `animation_gallery.odin`: `Animation_Gallery` (kind, title, origin, and what its panel adjusts
  that is not on its `Animation`), only writer of the `Animation` of the stations
  (`gallery_animate`), the walks of the bodies that walk on their own, root motion and foot
  contact after physics (`gallery_observe`).
- `animation_gallery_controls.odin`: the flat queue of up to 64 orders to the fixed tick, the rows
  and buttons of each kind of station (`gallery_controls`), what a panel's events ask
  (`gallery_panel_input`) and what each panel shows (`gallery_panels`).
- `animation_gallery_player.odin`: `Gallery_Player`, the walk of its body, the station it stands at
  and what E does there (`gallery_interact`).
- `animation_gallery_view.odin`: `Gallery_Hud`, what `animation_hud.ui` shows of the station and
  of what E does.
- `animation_motor.odin`: [the motor](#demo-animation-motor) of the actions and warp stations.

## API walkthrough

Open the editor with `--scene animation_gallery/animation.scene`, query `engine.describe` for the
schemas and `scene.inspect` for the ids of the stations, which are named after what they show. Start
`play.start`, pause and advance with `play.step`.

1. `Mirai warp to a target`: `animation.request` with
   `{"entity":"<rig>","motion":[{"name":"Reach","target":t}]}`, where `t` is
   `{"kind":"Entity","entity":"<Reach goal>"}`, then `animation.play` of `stride`. Its gallery
   restarts the stride every few seconds with the goal at another distance. `animation.inspect`
   part `Motion` publishes the window and the predicted error; `play.inspect` reports the position
   reached by physics.
2. `Mirai named actions`: `animation.request` with `{"entity":"<rig>","actions":[{"name":"Greet"}]}`
   starts the `Greeting` section; `Step` emits `Movement` windows. `animation.inspect` part
   `Actions` after one tick reads state and events.
3. `Mirai matching by speed`: `animation.request` with
   `{"entity":"<rig>","plays":[{"clip":"wave","fade":0.35}]}` plays the greeting and matching
   resumes at
   the end; `animation.inspect` part `Match` gives the clip, whether it is forced, and the jumps.
   `priority` or `wait` reject or delay an interruption.
4. A physical Mirai: `animation.request` with
   `{"entity":"<rig>","locomotion":{"velocity":[1.5,0,1.5],"source_velocity":[0,0,2.9154]}}` adapts
   orientation and stride; `source_velocity` is a manual calibration because the walk does not
   extract displacement, and both velocities are in world space.
5. `Mirai presentation every 4 frames`: `Animation_Budget` presents it every fourth frame while the
   simulation runs every tick; the one beside it, every frame.

## Demo animation motor

`Animation_Motor` is a gameplay capability of the demo, shared by the characters with root motion.

- `Move_Input` is `shared`: `locomotion_seat` (or the AI, or the network) writes the tick's
  request, and `animation_motor_drive`, after `animation_sample` and before `physics_step`,
  replaces it in the characters with a motor turned on by the horizontal delta and the yaw of their
  root motion, relative to the `max_speed` of their `Walk`. It writes only the rows that change.
- Functions before the animation, like `game_use`, read the players' request.
- The physical character keeps authority over the transform: contact, acceleration and saturation
  may prevent reaching a target.
- The component does not request actions, targets or distances, nor modify shared definitions.
- Vertical root motion and rotation other than yaw are not converted into character displacement.

## Verification

- `mirai test demo/game`: `animation_gallery_controls_test.odin`
  (manual and automatic stations, bounded queue), `animation_gallery_matching_test.odin` (the speed
  asked picks idle, walk or jog of `mirai_gallery.character`), `mirai_matching_test.odin`,
  `mirai_character_test.odin`, `grounding_physics_test.odin` and `animation_motor_test.odin`.
- New assets: `mirai asset verify`.
- Generate and build the demo editor and walk the gallery in Play with graphics validation: E at a
  station with a panel, a slider and a button. A type check does not prove physics execution,
  panel input or visual correctness.
