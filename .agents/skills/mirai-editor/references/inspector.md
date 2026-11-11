# Inspector

Code: `inspector.odin`, `inspector_clipboard.odin`, `inspector_provider.odin`,
`inspector_held.odin`, `defaults.odin`, `materials.odin` and `material_defaults.odin`; a
collider's preset and the collision settings belong to the `physics` plugin
(`plugins/physics/editor/collision.odin`), and the section of a particle emitter, to the `vfx`
plugin, through its `Inspector_Provider`. The Details panel is in [layout](panels.md#layout).

## Details

- A fixed line above the scroll shows the identity of the active entity: its checkbox
  (`Disabled`), name, Create prefab or the actions of its prefab
  ([instance header](prefabs.md#operations)) and visibility; with several, `N selected` with
  Group selection and Create prefab. Below go a fixed search, the `Transform` (rotation in
  degrees), Hierarchy and a card per component that the scene stores.
- Components with controls of their own have no card: `Transform`, `Name`, `Id`, `Parent`,
  `Hidden`, `Disabled` and `Material_Values`.
- The checkbox of each card, except that of `Transform`, turns its component on or off without
  losing its values, like the entity's does for the entity; both are undo steps.
- With several entities it shows the sections they all have and an edit goes to all; in the
  `Transform`, an axis that differs is marked as mixed.
- The sections of the engine and the plugins, except those of `core`, Static Mesh, the lights and
  Spawn, start folded so that what the game provides stands out (`Table_Info.game` says so, which
  the generator writes).
- The right click on a card's band offers Copy, Paste, Reset and Remove: there is no cross to
  remove a component.
- Static Mesh gathers primitives and meshes in a geometry selector; changing geometry keeps the
  materials and is an undo step. A numeric field dragged or typed is a gesture
  ([document](document.md#edits-and-undo)).
- Adding a `Character` or a `Destructible` adds its collider (capsule or fracture) if missing.

### Descriptions

- That of a component comes from `Table_Info.description`, declared with the
  [component attribute](../../mirai-core/references/generator.md#attributes); a continuous hover
  over the header shows it (`DESCRIPTION_DELAY`), next to the pointer and in several lines if long.
  A type without a description shows nothing.
- A field with a [description](../../mirai-core/references/generator.md#attributes) (the comment on
  its line) shows it the same way on leaving the pointer over its name, not over the value
  control. Read-only fields do not show it.

### Hierarchy

- To the right of the title (`Section_Button`), View as tree replaces the boxes with the entity's
  line: its parents from the farthest, it and what hangs from it, with scroll; its rows select.
  What is neither its parent nor hangs from it does not appear.
- The icon of the Details header takes the color of what contains the entity (a prefab instance or
  a section) and, inside one, a click on it selects its root.
- Parent and Children as boxes with a preview or icon. Click selects; the x or right click unlinks
  keeping the world pose.
- Children shows only authoring children (it filters the derived ones before its limit and counts
  the rest); `entity_children` keeps the complete hierarchy.
- The + chooses a parent or a child in the scene or in Find; the left panel and Details are hidden
  while choosing and Escape cancels. A member of a prefab is not released to the root
  ([prefabs](prefabs.md#hierarchy-of-an-instance)).

## Reversion and review

- Each editable row shows a Revert arrow if it differs from its reference: the value inherited
  from the prefab or, without it, the component's declared default. The arrow restores only that
  field; in multiple selection, with each entity's reference and in one transaction.
- The `Transform` of an instance's root is placement: without a reference or arrows, and a
  reversion of a mixed selection skips those roots. The linked name is restored with the header's
  entity reversion.
- In material and particle parameters the reference is the prefab's value, then the asset's and,
  without an asset, the engine's default.
- `Inspector.defaults` keeps the references per selection, code generation and prefab base; it
  migrates schemas and resolves entity references when building them, not in stable frames. An
  entry without bytes says the component does not admit reversion, and if the migration of a
  component cannot be prepared, an incomplete default is not published
  ([prefab errors](prefabs.md#errors)).
- Project settings and Graphics rows return to the declared default by the settings' common path.

While an AI turn awaits review ([review](ai-review.md#finish-revert-and-retry)):

- The field the turn changed is tinted with its agent's color and its arrow is the turn's: it
  returns the value from before the turn and keeps what another wrote afterwards; when resolved the
  arrow returns to gray if the value still differs from its reference. A field that keeps a
  reference to another entity offers no turn arrow.
- A component with pending changes is shown unfolded. Above Details, each turn that touched the
  entity has a bar with its glyph, revert the entity and accept it; accepting keeps the values and
  removes the marks, also on an entity created by the agent, which is only reverted with the
  turn's Revert. An entity the agent deleted is shown as it was, read-only, with the same bar.
- The marks belong to the document: they are not offered in Play or Simulate.

## Rows by reflection

Rows come from the schema of the type (`inspect_schema`, `fields_rows`, `field_row`): the world's
for components, settings it saves and records, one made for the frame for another value; the kind
of the field's type and what its tag says (`serial.Field`) choose the row:

- A number with minimum and maximum is a slider with an editable number. An `enum` is a segmented
  control if there are few short names (`ENUM_SEGMENTS`) and otherwise a searchable list. A
  `bit_set` of an enum is checkboxes, and groups `Name_X`, `Name_Y`, `Name_Z` go in one row per
  name with X/Y/Z switches. Two consecutive masks of a type with names (Belongs and Collides) are
  a table with a column of checkboxes per mask and an arrow that reverts both.
- A `quaternion` is three angles in degrees. With `mirai:"color"`, 3 or 4 floats are the swatch
  that opens the color picker. `[N]u8` with `mirai:"text"` is a text field; with `data`, a list of
  the world's components and storages; with `kind=.scene` (or another extension), the path of an
  asset of that type under the assets folder, chosen as a `base.Asset_Id` from the list of the
  project's (without those of plugins). An array of texts, of references or with `trim` shows those
  that have a value and one more empty.
- `core.Entity`: a slot chosen with a click in the scene, in Find or by dropping an outliner row
  ([relations](extensions.md#a-component-with-an-inspector)).
- `base.Asset_Id`: the thumbnail, a button that opens the list of assets of the types of its tag
  (`kind=.ui`) or, without it, of the one the field name suggests, and the magnifier that shows it
  in the content browser (`content_reveal`); double click on the thumbnail opens the asset in its
  document. A field that does not take any asset says so in its tag: an engine type or that of a
  plugin whose editor declares it ([asset types](extensions.md#asset-types-of-a-plugin));
  several go separated by spaces (`kind=.anim .character`) and the first gives the empty
  thumbnail. It receives a dropped asset of its types; one
  of another type is warned about. A `.sound` field also takes a `.sound_set` (`asset_kind_takes`)
  and carries Play or Stop; that of an `Audio_Source` sounds as configured (`eaudio.play_source`,
  without a place even if spatial) and follows its changes.
- `core.Record(T)`: the list of the rows of the tables of `T` by name, with the table in front when
  there are several, `None` and, for a row that no table has, `Missing`; the arrow opens the table
  with the row chosen ([records document](panels.md#records-document)).
- `Collision_Responses` (with `physics`): a summary of what is not Default that opens the list of
  the code's categories with Default, Ignore, Overlap and Block. Profiles, categories and
  `Collision_Layers` are named ids that the row of their type shows.
- An array of structs of up to 4 numbers is a table with a column per field, the non-empty elements
  with their x and one empty to fill. A struct of 2 to 4 arrays of the same length of numbers or
  colors (a particle curve) is a table of keys with a cell per array. Another array shows up to
  `INSPECTOR_ARRAY_ROWS` elements (of asset references, the assigned ones and one more); one of
  structs, each element folded in a button with its name and number.
- A nested struct shows its fields with the parent's name in front, up to `INSPECTOR_FIELD_DEPTH`
  levels.

Tags `mirai:"..."`:

- `hidden` is not shown; `transient` is neither shown nor saved; `readonly` goes disabled.
- `axes=` names each axis of a vector, with one letter each (`LTRB`) or words separated by spaces;
  the sides (`LTRB`) and corners (`TL TR BR BL`) of a box show an arrow per cell. `angle`: radians
  shown in degrees. `hex`: a `u64` is edited as exact hexadecimal, without going through float.
  `unit=` goes inside a number's field and, in another field, is added to its name. Also `label=`,
  `min=`, `max=` and `icons=`.
- `section=Title`: a fold before the field that groups those that follow until the next section; in
  the [settings](panels.md#project-settings) dialog, each section goes under its band. Only in
  components and settings of more than 12 rows and without reordering fields: in one with sections,
  the first field also carries its own. On a line with several names the tag belongs to all, so the
  field that opens the section goes on its own line. A struct in a section of its same name does not
  repeat that name in its fields (`Compensation` under `Exposure`). Every section folds the same
  way (`editor.fold_section`); `Advanced` starts folded. When searching, sections are shown open.
- `mode=A|B`: the field shows only while the enum field `mode` of its struct is one of those values
  (the fields of one mode of `Camera_Follow`); a section starts at the first of its fields shown.

A field whose initial value matters is declared with `NAME_DEFAULT` or `name_default()` in the
component's package, which the inspector uses when adding it (`component_default`). Names are
shown readable (`readable`: `linear_damping` is "Linear damping"). A plugin can replace a section
or a field with an [`Inspector_Provider`](extensions.md#a-component-with-an-inspector).

## Copying and pasting values

`editor/inspector_clipboard.odin`. A right click on a field's label, a `Transform` row, a section
header or Add component opens Copy and Paste. The text is the JSON of the
[API](../../mirai-agent-api/references/methods.md#scene): a field's value, three numbers for a
Transform row (Rotation in degrees), `{"Spot_Light":{...}}` for a component and `position`,
`rotation_deg` and `scale` for the Transform.

- Paste reads the whole clipboard and validates it before writing: type, `min=` and `max=`
  (`api.value_check`) and that the referenced entities exist. A field accepts any value of its type
  (Position is pasted into Scale); a component accepts the object under its name or alone and
  writes only the fields it names; Add component adds or replaces on the selection the components
  the object names, with the default for what it does not mention.
- Each Paste is an undo step for the whole selection; an error is shown as a toast and writes
  nothing.
- Project settings and values a panel or plugin retains (`Held_Values`) do not offer the menu.

## Collision

- `Collision_Settings`, in Project settings, has Categories (the code's, with New category),
  Presets (each preset except custom, with Sensor and the Belongs and Collides table, and New
  preset) and Pushes (pairs of categories that yield, with their force). Returning to a preset's
  defaults deletes its entry; one for a preset the code does not declare is shown apart with
  Remove. Typing a new category name declares it (`names_create`).
- The editor rejects with a notice every edit that leaves the settings invalid: a repeated preset,
  an entry for custom or a repeated push.
- A `Collider`'s Preset is a list of those the code declares; typing a new one declares it. With a
  preset, Sensor and the table show what belongs to the preset disabled; choosing Custom copies it
  as its own into each selected entity, in one undo step.
- Collision model in
  [physics](../../mirai-physics/references/engine.md#collision-categories-and-presets).

## Material

- The `Mesh_Renderer` section aligns Mesh and Material in the same label column. With one entity,
  the Material label unfolds the **material parameters**, folded, in a box of their own: those of
  the standard model with its maps and layers (coat, fuzz and anisotropy show their other values
  with weight greater than zero) or the Surface program's parameters. Unlit hides the light values.
  With several slots, each one's label (`Material 1`, `Material 2`...) unfolds below it, with its
  own open state, the parameters of its material, with its Apply and its Revert; the color and
  the emission of the entity, which apply to all, go once above them. With a single one, Color and
  Emission show the material with them.
- Everything changed there belongs to the entity (its `Material_Values`): values, maps,
  program textures and overlays. The inspector never writes the material; Apply to material and the
  [material document](panels.md#material-document) change it for everyone.
- Apply to material (`material_apply`, `material.instance.apply`) writes into the material what the
  entity changes of that slot and removes it from the entity, in one undo step, and the flush writes
  the file. The other entities that show it take it, except in what they
  change. Revert material changes removes from the entity what it changes of that slot
  (`material_revert`); the overlays belong to the first one. Reverting a shader parameter keeps the
  other overrides.
- Material and effect references have an arrow; a texture's returns to the prefab's or, without
  it, to the material's.
- What the source gave is read from the material's file when the registry has other content for it
  (`material_base`). Reimporting a model with a material changed rebases it
  (`material_rebase`): it follows the source like the file and keeps what was changed.
- **Overlays** goes below Material, outside its box. Its layers (`Overlay`) are the material's
  until the entity changes one: from then on the entity has its own list, which replaces the
  material's, and its arrow returns to the prefab's or the material's.
- `Material_Values` is edited in the material properties and never as a section; without a
  `Mesh_Renderer` its data is kept but not shown.
- A material of the content browser is assigned to the first slot of the selected meshes with a
  click, or by dropping it on a mesh in the scene (`material_assign`, one step).

## Post process

`editor/post_process.odin`: an `Inspector_Provider` draws the layers (`layers`) of a single
entity's `View_Volume` as a stack, in Edit and in the Play's world; with several, the rows by
reflection remain.

- The stack is scene data: each layer names a material whose program is `Postprocess`, and the
  parameters stay in the material, which opens its document.
- The layers are grouped by stage (before and after tonemap); up and down move a layer only among
  those of its stage, and adding puts it at the end of its own. Removing compacts the array.
- The selector lists the registered materials that have a `Postprocess` program, read once on
  opening.
- A layer's eye shows in the viewport the image up to that layer: the effects of its stage up to it
  and, if it is after tonemap, all those before. It applies only to the stack the renderer takes
  (the view's) and turns off if the layer stops being valid. It is not scene data nor goes through
  undo.
- Each change is an undo step.

## Particle

The `Particle_Emitter` section belongs to the `vfx` plugin, with its `Inspector_Provider`: a box
with the effect, like a material's, and the instance's values
([section](../../mirai-world/references/vfx-editor.md#particle_emitter-section)). Without the
plugin, the editor shows nothing of particles.
