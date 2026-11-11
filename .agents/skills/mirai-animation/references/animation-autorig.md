# Animating a character that arrives without a rig

An uploaded or generated character or animal (a mesh without a skeleton, or with one that does not
animate) is animated with a [template
rig](../../mirai-imports/references/imports.md#template-rigs-cookrig) from the import and the
CC0 clips of Mesh2Motion, which share its skeleton. The agent decides what it is (a humanoid, or the
Mesh2Motion animal that most resembles it), imports it with that rig, reviews what the fit assumed
and sets it moving; there is no step that depends on looking at the mesh by hand.

## Workflow

1. **The template.** `humanoid` for a person. For an animal, the family by its shape: `fox`
   (quadruped with a tail: dog, cat, wolf), `horse` (hoofed, with a long neck), `bird` (open wings),
   `dragon` (four legs and wings), `kaiju` (biped with a tail, a dinosaur), `shark` (fish, whale),
   `snake` or `spider`. The engine does not recognize it: deformed, any template covers almost any
   mesh, so the choice is the agent's and is checked in the capture.
2. **The library.** `uv run scripts/fetch_mesh2motion.py --rig human --clips idle-a,walk` downloads
   those clips for a humanoid. For another rig, `--list` shows the available names. They are
   downloaded from the pinned commit to `<project>/.mirai/library/mesh2motion/<rig>` (`--list` names
   them) and joined into `<rig>.glb`. Importing it with `asset.import` gives an `.anim` with all of
   them and the `.skeleton` that animates them, the origin of the bake.
3. **The character.** `asset.import` with `rig`: `warnings` of its answer says what the fit
   assumed.
   - Humanoid: a crotch covered by clothing or a neck that was not found are corrected by importing
     again with `rig_crotch` or `rig_neck` (heights in meters in the model); arms stuck to the body
     have no fix by adjustment: the mesh has to separate them.
   - Animal: poor coverage says the template did not take the shape of the mesh; another family is
     tried, or the mesh is reoriented (on +Y, facing -Z once imported).
   - Importing the same source again writes where the first time did, even if `folder` changes.
4. **Placing it.** `scene.write` of an entity with `prefab` naming the character prefab gives the
   rig entity. Its rest pose is that of the template with the lengths of the character.
5. **The clips to the character.** `animation.retarget.bake` of the library `.anim` from its
   `.skeleton` to that of the character, without a `character`: both have the same bone names and
   the same rest, so each bone takes the bone of its name and keeps the length of the character.
6. **Moving it.**
   - Humanoid: `animation.character.setup` with the baked `.anim` as `library`
     ([character](animation-authoring.md#character)), and `animation.capture` with `plays` of a
     clip.
   - Animal: the setup finds a head but not the pelvis and feet of a humanoid body, so it does not
     build the locomotion without a `skeleton.body.set`. A clip is set with `animation.play`
     (`asset` the baked `.anim`, `clip`, `loop`) and looked at with `animation.capture`.

## Invariants

- The rest of the character is that of the template: a library clip, or a bake from its skeleton,
  leaves the pose the clip asks for without correcting the arm angle of the mesh.
- Correcting a joint is reimporting with what is known about the body: `skeleton.bone.set` changes
  the rest, not where the skin was bound.
- The model is on +Y and faces -Z once imported, like the templates: a source that faces its +Z
  arrives so. A humanoid, standing and with the arms separated from the torso.

## Verification

- `mirai test cook/rig` and `mirai test cook/import/gltf
  a_humanoid_rig_fits_the_joints_a_person_placed_and_rests_as_the_template
  a_humanoid_rig_fits_a_person_whose_arms_hang
  an_animal_rig_fits_the_joints_a_person_placed_and_rests_as_its_clips
  meshopt_clips_decode_to_continuous_keys`.
- The whole flow is checked in an editor session with a capture of the character moving; CPU tests
  do not vouch for how it looks.
