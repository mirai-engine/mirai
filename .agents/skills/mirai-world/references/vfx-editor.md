# The vfx plugin in the editor

`plugins/vfx/editor` (package `vfx_editor`) is everything the editor knows about particles.
Without the plugin enabled, the editor has no particle code, types, presets, families or methods,
and a project without `vfx` builds and opens its editor. It provides this through the generic
extension points ([extensions](../../mirai-editor/references/extensions.md)), each one an Editor
storage whose only field is the provider, with its default:

- The manifest (`plugin.mirai`) declares `.particle` as **Particle**, with its icon and color: a
  family of its own in the content browser filters; an `Asset_Id` field whose name has `particle`
  (`sub_particle`) takes effects; git merges its files field by field.
- `Vfx_Clicks` (`editor.Asset_Click_Provider`): a click on an effect assigns it.
- `Vfx_Documents` (`editor.Asset_Document_Provider` with `between`): the
  [document](#particle-document), which also makes the content browser list the type.
- `Vfx_Thumbnails` (`editor.Thumbnail_Provider` with `image`): the [thumbnails](#thumbnails).
- `Vfx_Cards` (`editor.Card_Provider`): the **Particles** card of Create, in Logic, which places
  `recipes/particles.scene`; `scene.write` with `preset` `particles` creates it. It is the card of
  `Particle_Emitter`: the icon of its entities and of its section.
- `Vfx_Inspector` (`editor.Inspector_Provider`): the [section](#particle_emitter-section) of
  `Particle_Emitter`; `within` says that `Particle_Override` is shown inside it, with no section
  of its own or place in the scene API.
- `Vfx_Api` (`editor.Api_Provider`): the `particle.*` methods
  ([methods](../../mirai-agent-api/references/methods.md#components-and-assets)), with
  [debugging](#debugging).

Content browser gestures:

- **Click on an effect** (`effect_clicked`): assigns it to the selected emitters, in one step.
- **Dropping it on an entity with an emitter** (`vfx_drop`, with `editor.asset_drop_take`): the
  emitter shows it.
- **Double click**: opens its document.

An effect's file is one shape in the editor, `Particle_File` (`effect_file.odin`): its tables in
room of its own, copied, compared and merged as a value by the document, the section and the API,
and sliced into the `effect.Particle_Desc` that the file is read as and written from. It is written
with `particle_write`: with `editor.file_write`, as a history step where it
is written ([files in the history](../../mirai-editor/references/document.md#edits-and-undo)).

## Particle_Emitter section

Code: `instance.odin`.

- At the top go the component's fields; the `particle` field is taken by a box after them
  (`editor.asset_box`) with the preview and the name of the effect, which opens the list of effects
  with their previews (`editor.asset_list_open`); Default is the default effect. An effect dropped
  on the box is assigned.
- With an entity, an arrow unfolds the **effect values**, folded by default: those of
  `Particle_Info` that the effect does not hide, with the common Details rows
  (`editor.held_field_row` with `write`). A drag or a session of the color picker is one step.
- A changed value belongs to the entity (`Particle_Override`). The assets that the effect names
  (material, mesh, sub effect) and its Vfx program belong to the effect: changing them writes its
  file, in the same step as what changes on the entity.
- A value's arrow returns it to its reference: the prefab's value, then the effect's and, without
  an effect, the default.
- On the box, revert returns the entity's values and parameters (`Particle_Override`) to the
  effect, and apply writes them into the effect for all the entities that use it.
- What is hidden is defined by the `hidden` list of the effect's file (by its document, code or
  `particle.set`).
- The default effect has no file: its values are changed on the entity but not applied.
- Effects are created by API (`particle.set` with `path`) or by code.

## Effect preview

Code: `preview.odin`. The document and the thumbnails show the particles as the game does: the
GPU simulation and drawing, with Vfx programs, collisions, events and sub effects. There is no
other simulation on the CPU.

- `Effect_Preview` is a world of its own (`host.app_world_create`) with a single emitter
  (`Particle_Emitter` with `active`, without `loop` or `preview`) and a sun (`SUN_DEFAULT` toward
  `SUN_DIRECTION`), under a new world's sky. The first thing that asks to show something creates
  it.
- It is drawn **between frames** in a texture view with `host.app_world_draw`, in texture-only
  frames ([texture views](../../mirai-rendering/references/views.md#texture-views)): the `Fixed`
  phase of the editor loop moves the emitter's clock and the game's `Render` phase draws it.
- To show a time, the emitter advances from where it is in frames of at most `FRAME_MAX` (up to
  `PREVIEW_FRAMES`; past that, each one advances more). When the time goes back or what it shows
  changes (the effect, the assets revision, the shaders or the values on top), `vfx.restart`
  starts it again and the view cuts its history.
- The camera frames, from a little above, the box that `effect_reach` estimates: the shape, what
  velocity, forces and drag carry over the longest life and the largest particle. Noise, attractors
  and programs can take particles out of the frame.
- The world's pool capacity is the larger of `PREVIEW_CAPACITY` and twice `max_particles`.
- With a document in front the frame is `ui_only` and `render_sync` does not touch the GPU scene:
  drawing the preview on each frame does not rebuild the edited scene. A thumbnail drawn with the
  scene in view changes world in the renderer twice.
- A frame without requests does nothing: without an effect document in front its world is freed,
  and that of the thumbnails, `PREVIEW_IDLE` frames after the last one.

## Particle document

Code: `document.odin`. The state is `Vfx_Editor.document`, in the plugin's storage: **Preview** on
the left and **Effect** with the rows on the right, in the editor's document columns
(`editor.asset_column_begin`).

- **Image**: the [preview](#effect-preview) at the document's time, in a texture
  `PARTICLE_SIDE` pixels on a side, square and as large as fits in its area. What the rows change
  and the file does not have yet is shown as the values of an instance (`preview_values`, a
  `Particle_Override`); the assets and the program are written at once.
  The signature of what it shows (time, values, parameters, assets revision) is computed in the UI;
  `Asset_Document_Provider.between` draws it between frames when it changes.
- **Playback** (`editor.asset_playback_strip`, that of the animation document without lanes): one
  cycle until its last particle dies (`particle_span`); Loop starts it again, like an emitter in
  the editor (`Particle_Emitter.preview`). It opens playing.
- **Rows**: those of Details (`editor.held_field_row`) over the document's values, with the arrow
  that returns each field to the value it had when the document read the effect
  (`Effect_Document.base`). The `Particle_Info` fields go in foldable groups, each the one its
  `group` tag names, or that of the field before it: there is no other list of the fields.
  Curves are key tables
  ([rows by reflection](../../mirai-editor/references/inspector.md#rows-by-reflection)).
- **Hidden**: each field's eye toggles whether the instances show it (`hidden` list).
- **Program parameters**: those that the named Vfx program declares according to the renderer's
  catalog, with the value that the effect stores or its default. Bools as switches, colors,
  numbers within their range and textures chosen from the asset list or dropped from Assets; each
  with its arrow. Stored ones that the program does not declare are listed with an x that removes
  them.
- **Writing**: what the rows change is written with `particle_write` when the UI releases it
  (without an active widget, text editing or open popup), one history step of the document each
  time. With a program that the shaders have, it rejects what it does not take
  (`vfx.particle_program_check`), like `particle.set`; an invalid value is rejected with the
  message of `effect.particle_validate`. When rejected, the toast says so and the rows return to
  the file.
- If the file is read again (undo, the API, another write), each value that the rows did not
  change takes the file's; the parameters and the hidden ones, whole.
- A frame without changes does not draw the image.

## Debugging

Code: `watch.odin`, over `runtime/inspect.odin`: the rows of one emitter (its range, Attributes
and counters) and the counters of every emitter, read back from a `Simulate` pass; Attributes go
by the names of the fields the catalog reflects (`Program.attribute_fields`).

- One world is watched at a time (`Particle_Watch`): the one `particle.instance.inspect` or
  `particle.pool.inspect` names, the document or the caller's Play. Each frame its `Simulate` pass
  asks for what is watched: the rows of one emitter (`WATCH_MAX`) and the counters of every
  emitter. A world that goes (the end of a Play) stops it.
- Rows that come back are scanned: values that are not finite are the `vfx.nan` problem of the
  entity, which names the fields.

## Thumbnails

Code: `preview.odin`. An effect's thumbnail, that of its field's box and the Default row of the
list are its [preview](#effect-preview) when its particles have lived half their life, in a world
apart from the document (`Vfx_Editor.thumbnail`). `Thumbnail_Provider.image` draws it between
frames at `PREVIEW_THUMBNAIL` pixels, reads it back and reduces it to the cell. The subject carries
the effect and its values in `Thumbnail_Subject.data` (`Effect_Shown`); without a file (`subject`
without `file`) it is the default effect. They are stored in `.mirai/thumbs` like the others
([thumbnails](../../mirai-editor/references/panels.md#previews)).

## Verification

- `plugins/vfx/editor` (CPU):
  `particle_document_shows_every_field_of_the_effect_once_in_its_group`,
  `particle_document_keeps_its_edits_over_a_file_read_again_and_builds_the_file_to_write`,
  `particle_document_parameters_take_the_kind_the_program_declares_and_go_back_to_the_file`,
  `particle_document_builds_the_rows_of_every_field_and_its_eyes_hide_them` (rows without layout
  errors, a frame without changes does not allocate, the eye hides) and
  `the_preview_of_a_document_shows_what_its_rows_hold_and_frames_where_its_particles_reach`
  (unwritten values like those of an instance, framing). The rows that write through `write`:
  `curves_show_as_keys_and_held_values_take_what_a_popup_chose` (`editor`). Debugging:
  `instance_inspect_names_the_attributes_of_its_program`.
- In an open editor with `vfx` enabled (the demo): `editor.document` with `Open` and the path of a
  `.particle`, `capture` with the UI and the content browser filtered by Particle,
  `particle.inspect` and `particle.instance.inspect`. The preview (document and thumbnails) is
  only seen there, with validation: an effect with a Vfx program, the time strip backward and
  forward, and a document frame without changes that does not draw. A project without `vfx` (the
  `game` template) opens its editor with none of this. That the rows of the document and of the
  instance show their fields is only seen there: in the tests, plugin and editor share the type
  table.
