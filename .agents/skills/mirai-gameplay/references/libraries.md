# Game libraries

Each one is a package under `engine/` with components, storages and functions over the generated
world. Import aliases: `scene`, `render` (`mirai:engine/render`), `inp` (`mirai:engine/input`),
`cam` (`mirai:engine/camera`), `audio`, `gui`, `save`. Controllers, possession and cameras:
[control](control.md). Animation is the optional `animation` plugin; physics, networking, spawn
points and cinematics are also plugins.

## `scene`

Scenes and prefabs between their document (`asset.Scene`, entities by `Entity_Id`, components by
the name of their type) and a world (handles and tables).

- `instantiate(world, asset, types, {parent, transient, entities, documents, salt, path})` creates
  one entity per row (`documents`: where the scenes of its references and the prefabs of its
  instances come from; `assets_documents(a)` for the application's assets):
  - It sets `Id` (except `transient`), `Name`, `Transform` (identity if missing) and each component
    the world knows. It does not write `World_Transform`: propagation gives it; whoever needs the
    pose earlier composes it with `core.world_of` (the spawn points of `spawn`).
  - Each component is read against its schema: direct copy if the layout matches, migration by
    field name if not; a field the scene does not store takes its default (`NAME_DEFAULT`), like a
    new row.
  - `Report`: `migrated`; `unknown` (tables without a component); `dangling` (references outside
    the document, which stay `NONE`).
  - Children keep the document's order. The rows appear at the next `settle`.
  - With `documents`, each [reference](#scene-references) loads its scene beneath it (`sections`,
    `missing` in the `Report`); `load` and `replace` do it except for a saved game.
- `load(world, app, path|id)` replaces the world with a scene from the assets using `replace`, all
  or nothing: it instantiates in another `World` of the application, a copy of the world cleaned
  (`core.world_clear`: entities, rows and the storages derived from them,
  [classes](../../mirai-core/references/generator.md#attributes)), and only if everything went in
  does it swap its content with the world. It leaves settle and transform propagation done.
  `replace` is also used by loading a save and by the scene a collaboration guest receives.
- `load_untrusted(world, app, path, Untrusted{components, max_entities, max_bytes})` loads, as
  `load`, a level a player saved or downloaded (a path under `host.assets_mount`, or absolute) only
  if it holds what its rules allow: file within `max_bytes`, entities within `max_entities`,
  only the listed components (`Transform` always), values that pass `serial.value_check`, `Entity`
  fields naming entities of the document, `Asset` fields and prefab instances naming assets of the
  registry. Prefab instances are not resolved against their prefabs. A `Scene_Reference` may name
  only a scene the game ships: what hangs from it loads unchecked. `report.refused` says what
  failed and `untrusted_text` how to fix it.
- `spawn(spawner, path_or_id, at)` is the one way to place a copy of a scene while playing and
  returns its root. It places a prefab (`Header_Flag.Prefab`), by its one root; another scene is
  `Not_A_Prefab`, and hangs whole from a `Scene_Reference` instead. One that fails returns `NONE`
  and is the problem `scene.spawn` of its `parent` (or of the world), with the fix. A zero
  rotation is none and a zero scale is 1; its rows wait for the end of the function that spawned
  it. The root receives `Prefab_Instance{prefab}`, the one component that says what prefab an
  entity is of (with `Prefab_Member`, a linked instance; alone, a copy), which a server sends
  ([multiplayer](../../mirai-networking/references/multiplayer.md#what-the-game-declares)).
  The scenes the copy references load with it, under `Id`s made with that of its reference in
  the world; a `transient` copy, which has none, brings every section. A World keeps the form of
  each prefab it spawned (`Prefab_Forms`) until that prefab or one it places changes: spawning it
  again reads no file. The forms are of their World and are not copied with it.
- With a project's assets, `load` and `spawn` instantiate a copy in which outdated prefab instances
  follow their current prefab
  ([resolution](../../mirai-assets/references/scenes.md#resolution-against-the-current-prefab));
  without any, the file as is. With cooked assets (`Assets.indexed`) they load the file, which
  cooking already resolved.
- `capture(world, &scene, types, {root, previous, id, entities, sections})` writes a document
  with the entities that have `Id`, in depth, without what hangs from a reference, which stores its
  scene; with `sections` (a save), everything. With `entities`, only those, as roots, without what
  hangs from them, and their `Entity` fields store the `Id` of an entity left outside: the values
  of some entities, to compare them.
  - From `previous` (the document the world was loaded from) come the order of the roots,
    components of libraries the project does not have and tables that are not components.
  - `transient` fields go as zero; `Entity` ones store the `Id` of their target.
- `save(world, app, path, previous)` captures and writes.
- **Changing scene** is a request: `scene.request(&r, path_or_id)` in
  `Scene_Requests` (`queue`, `keep`). `scene_requests` (`input`, both loops) loads them one at a
  time and pushes a `Scene_Result{scene, path, error}` to the log of `Scene_Results` (`keep`) in
  the frame in which the scene replaces the world; `result_of` looks it up. One
  that fails is also the problem `scene.load` of the world, with the cause and the fix.
  `request_restart(&r)` loads again the scene the world is (`Scene_Root`).
- **Phased load** (`loading.odin`): jobs read and decompress the scene in rounds: each one reads
  what the main thread found in the registry for it (at the start, the scene) and asks for what
  that brings (the scenes of its `With_Document` references and the prefabs of its instances; the
  `Manual` and `Spatial` ones not); the last one instantiates it in a separate `World`, which the
  asset marks do not read meanwhile. Then, jobs (at most the `LOAD_WORKERS_SHARE` part of the
  workers, the rest stays for the frames' work) read and decode the meshes, textures and materials
  it names that are not loaded, and what the other assets it names take (the meshes of a foliage
  source or of a prefab; not those of a scene of several roots, another section), each after
  what it takes, and
  `load_step` hands them to the renderer with the part of the frame the load has
  ([budget](../../mirai-core/references/host.md#loaded-assets)); it also waits for the first
  loads of the `.anim` its World can play, through its prefabs and other assets
  ([content](../../mirai-core/references/host.md#content)). That of a section, in a world
  with `Load_Waits`, then waits for the libraries (`Load_Phase.Waiting`): each frame a library
  names there the assets the load names and it still prepares (`load_wait`, reading them from
  `loads_waiting`), and the load ends once a frame passes without anyone naming theirs.
  `load_step(job, all=true)` does everything in the call. `load_end` passes it what belongs to the
  run of the live world (`core.world_run_copy`) and swaps the two between frames. `Scene_Loading`
  (`keep`) and `Section_Loading` (one entry per section that loads separately) say the phase and
  how far along it is, for a loading screen; meanwhile the world keeps running. Without job
  threads the jobs run where they are requested; `load` and `replace` do everything in the call,
  for whoever needs the scene at once (editor, tests, agents).
- `section_load_begin` / `section_load_end` load a reference's scene separately and join it beneath
  it (`core.world_union`), with its pending references.
  - The first time it runs in a world it requests the scene the player was launched with
    (`app.launch.scene`: `--scene` or `start_scene`; `Scene_Launch` remembers it). If it does not
    load, it prints it and ends the player with `PLAYER_SCENE`.
  - Requests are copied before loading: a load replaces the world and with it the queue's buffer.
- An entity is looked up by its `Id` with `core.entity_of(&es, id)`, up to date from the settle that
  settles what was instantiated
  ([identity](../../mirai-core/references/core.md#persistent-identity)).
- `Error`: `No_Assets`, `Not_Found`, `Invalid`, `Cycle`, `Not_A_Prefab`, `Corrupt`,
  `Duplicate_Id`, `Out_Of_Memory`, `Write_Failed` and, of `load_untrusted`, `Too_Large`,
  `Not_Allowed`, `Out_Of_Range`, `Unknown_Reference`; `error_text`.

### Scene references

Any scene is loaded as the world or referenced as a section; a prefab is also copied by its one
root (an instance with overrides in a document, `spawn` while running).

- `Scene_Reference{scene}` (`reference.odin`) on an entity: the scene's entities hang from it
  without being copied into the document that has the reference. Deleting or turning it off removes
  the entire section; removing the component leaves its entities as its own (dismantling it).
- **Combined ids.** The `Id` in the world of an entity of the section is `id_in(reference, own)`: a
  scene referenced twice does not repeat ids, and each end of a session and each save compute the
  same one.
- What the world uses one at a time (`Sky`, `Sun`) arrives turned off in a section or in a prefab,
  also that of an instance stored in the document: the root's rules.
- **When it loads** (`sections.odin`): `rule` `With_Document` loads with its document; `Manual`,
  when requested; `Spatial`, as the streaming plugin decides. `state` is what was requested:
  `Active`, `Loaded` (loaded and turned off, ready to turn on without a pause: what hangs goes
  under `Disabled` with `Section_Held` and the reference stays on, so that another state can be
  requested of it) or `Unloaded`; `loaded`, what it loaded. `section_request(&r, e, state)` in
  `Section_Requests` requests it and `scene_sections` (`frame`, both loops) fulfills it: it loads
  separately in jobs, up to `SECTION_LOADS` at a time per world (`Section_Loads`, of each `World`),
  and settles nothing while it walks the references. A scene that replaces the world
  (`Scene_Root.changes`) takes the loads in flight with it. What loads requested as `Loaded` is
  joined already turned off. A section that did not load stays in `failed` and is not retried until
  it is requested again; one whose scene contains it is `Cycle`, and its problem names the scenes
  around it (`section_path`). The reference is replicated: with networking the server requests and
  each end loads its own. A `Spatial` one follows `streamed`, what this end's streaming wants,
  which does not travel: `section_state` says what each one has to be. The editor shows a section
  in another way in its view with `Section_Views` (`section_view`), which `scene_sections` reads
  first: it is not an edit, it is not saved, it is not replicated and Play does not copy it.
- **What is unloaded** (`dormant.odin`): while a section is loaded, its record (`Section_Records`)
  knows what changed since it loaded through the stamps of its rows (`core.changes`) and, through
  the shape of each entity (which components it has and which it turned off), which component went
  away or was turned off; turning it off and on is not a change, and a copy of the world copies the
  record with the stamps. On unloading, what was changed and what was added stays turned off where
  it hung (`Dormant`, with `Disabled` and `Section_Held`), or from the reference, where it was, if
  its parent goes away; each entity of its scene that is not there leaves a `Tombstone` with its
  `Id`, and what moves on its own (`Roaming`) hangs from the root. What draws its own far shape (an
  entity with a `@(component,far)`, like a terrain or a foliage) stays on with what hangs from it,
  `Far_Kept`, hung from the reference where it was: the library that draws it keeps of it what its
  far shape asks for according to the sources (the roots of a terrain, the impostors and canopies
  of a foliage), without colliders or the near part; loaded and turned off, the section does not
  turn off the one that hangs from it (it does turn off the one that hangs from something of its
  own, with that). A section that is neither loaded nor loading and does not have those shapes
  (it never loaded, or another scene) reads them from its scene with a load of its own
  (`far_load_begin`, up to `SECTION_FAR_LOADS` at a time): its jobs leave from the scene only
  those entities (`far_keep`), without what hangs from them, where they are in the scene, with
  `Far_Kept`, their assets are warmed like those of any load, and `far_load_end` hangs them from
  the reference in place of the previous ones, unless the section loaded or requests another scene
  meanwhile; `Scene_Reference.far` says which scene they are from. It is the same state an
  unload leaves. A section inside it is unloaded first, and its reference stays while it keeps
  something. On loading again, what is dormant is applied in the separate `World`, before the join:
  each dormant one gives the one arriving with its `Id` what it keeps and what its author turned
  off, each tombstone removes its own, and each stored far shape takes the place of the one
  arriving with its `Id` (which goes away with what hangs from it) and hangs again where that one
  hung; two entities of the world never have the same `Id`. Without a record (a save) everything
  that has an `Id` stays. They are entities: the save stores them and Play and rollback copy them.
  If the reference's scene changed, everything is destroyed.
- **Far shape.** While the section is not loaded and on, an entity with `Section_Proxy` represents
  it next to its reference, under its parent and where it is; the
  [`streaming`](#plugin-streaming) plugin makes it. The editor picks the reference through it.
- `extents` is half the box of the section around its entity: its unbounded volumes apply there
  and, with `streaming`, it is there.
- A save stores what hangs from the references, with `Section_Member` (which the section's scene
  does not store): on loading it, the sections that were loaded stay loaded and their unbounded
  volumes apply again in their box.
- **Persistent root.** A level-based game has in its root scene what lasts the whole save (players,
  state, HUD) and each level is a `Manual` reference: changing level is unloading one and loading
  another, and what is in the root goes into the save and is replicated. Replacing the entire scene
  (from a menu to a game) passes to the new world what has `core.Keep`, with what hangs from it:
  the players' seats carry it.
- A scene that references itself, directly or not, or more than `REFERENCE_DEPTH` levels, is
  `Cycle`; a reference to a scene that is not there is counted in `missing` and stays empty.
- **Between sections** (`unresolved.odin`): an `Entity` field that names something outside its
  document stores the `Id` in the world of its target. If on loading it is not there (its section
  did not load), the field stays `NONE` and waits in `Unresolved_References`; `capture` stores that
  `Id` instead of zero, and `scene_references` (`frame`) resolves it, with a write stamp, when there
  is an entity with that `Id` that is not dormant; `resolved` says which ones it resolved last time,
  so that the editor's undo does not take them for edits. Unloading a section returns there the
  fields of the world that named what it had, and the `Keep` that passes to another scene carries
  its own. A prefab does not store references outside: they stay dangling, as before.
- `loaded` (transient) is the scene from which what hangs was loaded: the editor reloads the
  section when `scene` changes
  ([sections](../../mirai-editor/references/document.md#sections)).

### Sources and residency

`scene_sources` (`sources.odin`) gathers in `Streaming_Sources` the view while it draws, the bodies
the seats drive (on a server, those of each connection) and the entities with `Streaming_Source`,
each also where its motion takes it in `SOURCE_PREFETCH`: that of the view is what moved since the
previous frame, unless it jumped (`View.cut`). Its `revision` grows only when a source moved
`SOURCE_MOVE` or how many there are changed; those beyond `SOURCES_MAX` are the problem
`scene.sources`.

It is the only residency by distance: sections (the `streaming` plugin), terrain chunks and foliage
cells use it. `sources_near` puts the sources in the frame of what is
placed, `box_near` says how many reaches away a box is (the source's `distance` or the one each
library gives), `resident` leaves it resident within one and up to `RESIDENT_KEEP` if it already
was, and `residents_past` leaves, out of a budget, the closest ones.

## Plugin `streaming`

Loading policy of the `Spatial` sections, optional, with the [residency of the
sources](#sources-and-residency). `streaming_sections` (`frame`) loads turned off the section whose
box falls within `load` of a source (or its `distance`) and turns it on within `active`; it turns it
off or unloads it past `RESIDENT_KEEP` times each. It only looks again when the sources moved, the
references changed or the box of one moved. `streaming_crossings` (`game`) takes what moves (with
`Motion` awake and that moved) and leaves the box of its section to the loaded and on section that
contains it, or to the root, where it is, and removes its `Section_Member`: unloading a section
does not take what left, and its scene leaves a tombstone. What has `Roaming` and hangs from the
root, on or not, hangs again from the loaded and on section whose box contains it. It remembers
which section each one is from until the hierarchy changes. Physics accepts that parent change
because it leaves the body where the simulation has it. `navigation` keeps the tiles of a `Spatial`
section that is not on until it returns.

**Far shape (HLOD).** `streaming_far` (`frame`, both loops, after `scene_sections`) shows, while a
section is not loaded and on, the far mesh of its scene next to its reference (`Section_Proxy` and a
transient `Mesh_Renderer`, which follow the reference): it is seen from afar, enters the rays and
keeps covering the sun and the sky.

- The far mesh of a scene is one per application (`Streaming_Far`, `host`), shared by all its
  references. It is made in jobs the first time a reference requests it, in rounds: the main thread
  gives the registry's sources (`assets_source`) that each round asked for (the scene and those it
  references, their meshes and materials, their textures) and the last one builds it with
  `asset.mesh_build_far` and its rays. Up to `FAR_BUILDS` at a time.
- Every on and drawn `Mesh_Renderer` of the scene and of the scenes it references enters, up to
  `REFERENCE_DEPTH`; not what is under `Hidden`, `Drawn_Elsewhere`, `Disabled`, `Rigid_Body` or
  `Character` (what moves) nor skinned meshes. From a `Mask` material the triangles that it covers
  less than its cutoff are left out (the leaves of a card). From a material with a program, whose
  program the CPU does not run, the base color is the texture of the parameter that names it
  (`asset.far_base_parameter`: base color, albedo, diffuse, color).
- The meshes are cut from their DAG at the error one pixel covers at distance `active`
  (`far_error`): from where the far shape starts to be seen the cut is not seen, and the far mesh
  does the rest with its own DAG.
- It carries the compressed blocks of its pages and the renderer pages it like an archive mesh
  ([pages](../../mirai-rendering/references/scene.md#scene-and-instances)): on the GPU is its
  root, the fine pages arrive when the cull asks for them and the far rays trace the root's cut.
  The blocks stay in the renderer; the built geometry and what was read are released in a job on
  publishing it (`host.app_release`).
- It is redone like any cook: it stores each asset it read (and those it asked for without finding)
  with its content hash, and when the registry revision advances it compares; a different one, or
  another `active`, makes it again, and the references show the previous one until the new one is
  there.
- Terrain and foliage do not go into it: they keep their own far shape
  ([what is unloaded](#scene-references)).

## `render`

Components that describe the scene and `render_sync`, which carries it to the renderer.

- **`Hidden`**: neither the entity nor what hangs from it is drawn or gives light; physics, sound
  and gameplay continue. To turn it off entirely, `core.Disabled`
  ([turned off](../../mirai-core/references/core.md#disabled-entities)).
- **`Drawn_Elsewhere`**: its mesh is drawn by another library (the pieces of a broken
  destructible).
- **Lights**: `Sun`, `Point_Light`, `Spot_Light` and `Rect_Light`, with their initial values in
  `SUN_DEFAULT`, `POINT_LIGHT_DEFAULT`, `SPOT_LIGHT_DEFAULT` and `RECT_LIGHT_DEFAULT`. All four
  shine toward -Z of their entity, as a camera looks; their units are those of
  `KHR_lights_punctual` ([units](../../mirai-rendering/references/display.md#units)).
  - `Sun`: `color`, `illuminance` (lux) and `disc` (seen in the sky). It is
    `@(component,single)` ([one at a time](../../mirai-core/references/generator.md#attributes)):
    turning one on turns off the one that was on, and the renderer uses the one that is on if it is
    not hidden. With `height_fade` on it dims according to the height of the main view, from full
    at `start` to `minimum` at `end` and beyond, in steps that only light the scene again when they
    change (`sun_height_factor`): it is an artistic option of a vertical world, not what makes the
    light of each layer correct, which its lights and volumes give. Automatic exposure compensates
    for it; an atmospheric sky, which follows the sun's illuminance, darkens with it.
  - `Point_Light`: `color`, `intensity` (candelas), `range` and `radius`: a sphere of `radius`
    meters times the entity's scale; stretched along an axis it is a capsule along it.
  - `Spot_Light`: that of `Point_Light` and `angle`, the half cone from 1° to 89°; it fades out in
    its last fifth.
  - `Rect_Light`: `color`, `luminance` (nits of its face) and `range`. It is the entity's unit
    square (x by y according to its scale). Its size opens its shadows and widens its glow; a
    larger one gives more light. Inside its lamp it does not shade it. See [local
    lights](../../mirai-rendering/references/lights.md#local-lights).
- **`Light_Emission`**: on the entity of a `Rect_Light` with a mesh, its light takes across its
  width the color of the emission of the material with which the mesh is drawn in `slot` (also the
  one a plugin sets, like the screen of `monitors`), with its texture as on the -Z face of a Cube;
  its luminance remains `luminance`.
- **`Camera`**: `fov`, `near`, `active`, projection. Which camera the game sees is chosen by
  `engine/camera` through the focused seat and its body, and written in the `View_Camera` storage;
  without a choice, the last camera with `active`. There are no priorities. While passing from one
  camera to another, `View_Camera` carries the view's pose (`posed`); `own` and `fade` say which
  body of `View_Bodies` is its own and how much it fades it. `own_hidden` are the layers of that
  body that the camera does not draw, like the head seen from the eyes.
- **`Exposure`**: on a camera's entity, how it exposes its image: `Auto` (light measurement,
  between `min_ev100` and `max_ev100`; `adaptation`, the seconds to 95 % of a light change, or per
  EV with `adaptation_mode` `Speed`) or `Manual` (`aperture`, `shutter`, `iso`), plus
  `compensation` in EV. It replaces entirely the exposure of the `View_Volume` where the camera is
  ([exposure](../../mirai-rendering/references/display.md#exposure)).
- **`Sky`** (`@(component,single)`, `sky.odin`): the sky that is on gives the far light and the
  background. A new scene is born with a `Sky` and a `Sun` entity; without a sky that is on and
  visible there is no sky light and the background is black. See [sky and
  sun](../../mirai-rendering/references/gi.md#sky-and-sun).
  - `luminance` (nits) and `image` (the whole sky, which `luminance` multiplies; the rotation of its
    entity turns it), or `atmosphere`: the air of `air` (Earth by default) lit by the sun that is
    on, which follows its direction and its illuminance and veils the distance.
    `background` and `use_background`: what is seen behind. Exposure is not the sky's but that of
    the `View_Volume` where each view is.
  - **A change on its way** (a day cycle, weather) is state of the component, which the game, an
    animation or a cinematic writes: `from` (what it was) and `fade`, how much of that is still
    seen, from 1 to 0. The renderer draws the blend; it is saved and replicated.
  - **Turning on another sky** is a request: `render.activate(&r, sky, sun, seconds)` in
    `Environment_Requests` (`environment_activate`, `frame`, both loops) turns on the `Sky`, the
    `Sun` or both; with `seconds` the sky arrives from the one that was there (`arrival`, `local`
    fields that are not saved or replicated: each end sees its own). An entity without the
    component is the problem `render.activate`.
  - `sky_active` gives the one that is on; `sky_environment`, what the renderer receives.
- **`View_Volume`** (`view_volume.odin`), a value of [volume](#volume): how views look where it
  applies: its `exposure`, a `tint` that multiplies the image before the display and up to 8 effect
  layers (`layers`), each weighted by its `fade`: the share of the image it leaves as it read it.
  Each view takes it at its camera (`camera_view`, `camera_local_views`; the editor's in
  `render_sync`); a camera with `Exposure` keeps its own. When blending, numbers are interpolated
  and modes and layers pass at half weight; one that adds adds its compensation, multiplies its
  tint and puts its layers after. The layers of the main view are the renderer's;
  each player of a split screen runs those of where they are, in their slot
  (`view_postprocess_sync`, `render.Camera.slot`), and they are given to the renderer only when
  they change. Sky and sun light does not change by volume.
- **`Material_Override`**: entity values for the slots of its mesh (each value and texture carries
  its own), by `base.name_hash` of a name of `MATERIAL_VALUE_NAMES` (`base_color`, `opacity`,
  `metallic`, `roughness`, `emission`, `specular`, `ior`, `transmission`, `alpha_mode`, `coat`,
  `coat_roughness`, `coat_color`, `coat_ior`, `fuzz`, `fuzz_color`, `fuzz_roughness`, `anisotropy`,
  `anisotropy_rotation`, `unlit`, `emission_mode`) or of a non-texture parameter of the program;
  textures by the name of a map of `MATERIAL_MAP_NAMES` or of a texture of the program; and, with
  `own_overlays`, its overlays instead of those of the first slot's material. It is `shared`:
  several game functions animate values of one entity, each setting and dropping only its own names
  with `material_override_value_set` and `material_override_value_drop` instead of writing the
  whole override over what another gave.
- **`Highlight`**: the editor's selection outline; it replaces the entity's `Outline`.
- **`Outline`**: the game's outline, with one of the 15 styles of `Outline_Styles`, a project
  setting (the same in all its scenes) with the color, the fill and what is seen behind another
  surface of each style, and the glow radius. A PostProcess program reads it with `mirai_outline`
  ([outlines](../../mirai-rendering/references/frame-graph.md#outlines)).
- **`Draw_Offset`**: visual correction that the network fades out without touching what is
  simulated.
  **`Drawn_Elsewhere`**: its mesh is drawn by another library (the pieces of a broken
  destructible).

Functions and rules:

- `camera_view` (`late`, game only) puts in `core.View` the camera of `View_Camera`, or otherwise
  the last active one, or `VIEW_DEFAULT`. `view_of_camera` builds a camera's view, with `cut` if it
  changed camera; with a pose, it draws from it without cutting.
- The transform interpolated between `previous` and current is drawn with `Frame_Time.alpha`
  (`drawn_transform`); in the editor and in a newly created world, the current one.
- `render_sync` (`render`, both loops) reads with `core.changes` each table it makes instances
  from, and redoes the scene only on another world (another `core.World_Id`), an entirely replaced
  table or a general asset invalidation. `Render_Sync` is one per application: it reflects the
  renderer's single scene, which another displayed world replaces entirely, and `render_release`
  empties it when the world it shows is released.
  - It keeps no copy of the instances: only what the renderer cannot answer, the entity of each
    one and what it was made from (`drawn`), and the visual instances of the application it was
    last given (`extras`). The instances of the renderer are those of `drawn`, at the same index,
    then those of `extras` (`instance_count`, `instance_object`); what an instance shows and where
    it is are asked of the renderer (`instance_placed`).
  - A mesh that appears adds its instance at the end of the world's and one that goes away leaves
    its place to the last. A row with changed appearance redoes its instance; moving and tinting
    give the renderer the rows written, and it leaves as they are those that say the same.
    Without memory the scene stays empty and is redone in the next frame.
  - A round of derived rows keeps those of the instances that derive theirs (`Drawn.derives`),
    read from the renderer, of the visual instances and of the batches: the others show rows of
    assets, which no round frees.
  - Hiding, showing, changing parent or `Draw_Offset` redoes the instances of the entity and of
    what hangs from it (through `core.Hierarchy`): a hidden instance stays in the scene with
    `hidden`.
  - Replacement, material costs and fallback: [partial
    changes](../../mirai-rendering/references/scene.md#partial-scene-changes).
- `mesh_instance` extracts geometry and appearance with the same algorithm for entities and
  previews; `sphere_desc` and `rect_desc`, an entity's light, for `render_sync` and the `portals`
  plugin.
- `extend.odin` is what a plugin uses to extend the renderer: [extension
  stages](../../mirai-rendering/references/views.md#extension-stages).
- `Graphics_Settings` (machine setting): `graphics_settings_for_device` is a GPU's default and a
  preset sets the quality, but not the `antialiasing` technique
  ([techniques](../../mirai-rendering/references/views.md#antialiasing-techniques)). The Memory
  section (`texture_memory`, `geometry_memory`, in MB) is not part of any preset: at 0 the texture
  pool comes from the device memory and the page pool is the renderer's. `graphics_apply` carries
  it to the renderer when it changes and reloads the textures if their maximum size or the pool
  changes; the page pool is reserved once and its change waits until the renderer starts again
  ([settings](../../mirai-rendering/references/settings.md)).
- `Display_Settings` (machine setting): mode, size and screen of the window the player chose; what
  it leaves at zero is as `project.mirai` says. `display_apply` applies it when it changes and
  only to the player's window (`host.App.game_window`): never to the editor's, where Play also
  runs, nor to one the editor places with `--window`. A screen that does not exist is the problem
  `render.display`.

## `input`

Actions instead of keys. `Input_Map` says which keys, buttons, mouse axes and gamepad controls move
each action and `Actions` stores the state of each one in the tick, both indexed by the value of
`inp.Action`. They are `keep`: loading a scene or a save does not touch them. Which actions exist,
their defaults, `Input_Settings` and the seats: [actions](control.md#actions).

- Action types: `Button`, `Axis`, `Axis2`.
  - `Button`: a key or button, or an axis from a threshold.
  - `Axis`: two keys (negative, positive), a gamepad axis or a mouse axis.
  - `Axis2`: four keys (left, right, down, up), a stick or the mouse movement. Key diagonals keep
    unit length.
- `Action_State`: `down`, `pressed`, `released`, `tapped`, `holding`, `held` (seconds), `value`,
  `vector`. `tap_seconds` and `hold_seconds` come from the map, and each threshold is met at the
  tick nearest to it, so a tap and a hold last the same at any tick rate.
- A rebinding is a change of `Input_Settings`, which the map follows. On a map a tool builds
  (`input_map_make`): `input_map_action(&m, jump, .Button)`,
  `input_map_bind(&m, jump, inp.binding_key(.Space))`, `input_map_unbind`, with the action of the
  world (`jump:=inp.action_of(walk, .Jump)`); `input_map_has` says whether it has an action of a
  type.
- Binding constructors: `binding_key`, `binding_key_axis`, `binding_keys`,
  `binding_mouse_button`, `binding_mouse_axis`, `binding_mouse_delta`, `binding_gamepad_button`,
  `binding_gamepad_axis`, `binding_gamepad_stick`.
- Reading: `down|pressed|released|tapped|holding|value|vector(input, .Jump)` over
  `Input_Of(E)` ([actions](control.md#actions)); `action(actions, a)` gives the full state of an
  action of the world.
- `input_actions_update` (`fixed`, stage `input`) recomputes `Actions` every tick from `core.Input`
  and its previous state, without allocating: a repeated tick gives the same.
- `Frame_Actions.actions` uses the same bindings and evaluator over `core.Frame_Input`.
  - It is updated in `input`, after building the map; it serves cameras and presentation in `late`.
  - Deltas, edges and tap/hold counters last one frame.
  - It is queried with the same functions over `&frame_actions.actions`.
  - Physical movement and gameplay actions read `Actions` in `fixed`.
- `input_map_build` (`input`, stage `begin`) builds the map (`input_map_make`) from the code
  defaults and `Input_Settings` on top, again whenever the setting changes: each entry replaces
  the type, context and bindings of its action; the others stay. An entry the code does not take
  is a world problem that names the action and the fix ([actions](control.md#actions)).
- `Input_Settings` (machine setting): `tap_seconds`, `hold_seconds` and `actions`, keyed entries
  `{action, kind, context, bindings: [{inputs, chord, gamepad, scale, dead_zone}]}` where `action`
  is the name of an action, `context` that of an `inp.Input_Context`
  ([contexts](control.md#contexts)), `inputs` the `Input_Code`s the binding reads, `chord` the keys
  or buttons also held ([chords](control.md#chords)) and `gamepad` 0 for every gamepad or 1 to 4.
  The project's layer and the player's are its layers; `input_settings_put`,
  `input_settings_remove` and `input_settings_find` change and read an entry.
- Those of a seat, with its blocks, are read through [`control`](control.md#actions).

## `audio`

It keeps the voices of the application's mixer equal to the world's `Audio_Source`s, the listener
at the first `Audio_Listener` or, without one, at the `View`, the buses as `Audio_Settings` says,
the reverb of the room where the listener is and what covers each source.

- **Sources.** `Audio_Source.sound` is a `.sound` or a `.sound_set`; there are no hand-made sounds
  in the mixer. With `spatial` it sounds at the entity
  ([positional audio](../../mirai-platform/references/audio.md#positional-audio)), attenuated by
  its curve between `min_distance` and `max_distance`, and with `directivity` louder toward -Z of
  the entity; without it, with its `pan`. `audio_sources` (`late`, after
  `transforms_propagate` and `camera_view`) tunes, starts and stops voices from the source rows
  written since it looked, follows each live voice (its end, its place, what hides it) and writes
  `Audio_Source_State` only when it changes.
  - `pitch` is the speed: it moves the tone with it, like a "slowed" song; with the reverb of its
    bus it gives "slowed + reverb". There is no speed change without a tone change.
  - Volume, pitch, pan and loop are applied to the voice that is sounding; another sound, another
    bus, another curve, another doppler or directivity or a file that was reloaded start it anew.
  - Clearing `playing` or removing the component stops the voice. A sound without `loop` that ends
    leaves `Audio_Source_State.ended`; another value of `plays` starts it again from its start,
    also while it sounds.
  - Doppler: the source's and the listener's velocity come from how much they moved in the frame; a
    `View` with `cut` does not move. It is only sent while there is doppler.
  - With the world's `core.Clock` paused, its voices are paused and the sources are not updated
    until it continues; one-shots are not.
- **One-shots.** `audio.play(sounds, path_or_id, at, bus, volume, pitch)` pushes to
  `Sound_Requests`, from any step and from the interface sounds of `gui` (on `BUS_UI`). Each is
  an `Audio_Source` of `AUDIO_SOURCE_DEFAULT` with those values and starts through the same
  `voice_start` as a source, so the mixer takes the same path for both, without a handle.
  `audio_requests` (`fixed` and `late`, stage `end`) takes the queue: at the end of the tick that
  asked, a tick that runs again (`time.resimulating`) drops what it asks, since it played the first
  time, and the copies of the world for a rollback are made between ticks, after the take; what
  frame steps and the interface push plays at the end of the frame's `late`.
- **Reverb.** The mixer has [only one](../../mirai-platform/references/audio.md#reverb): that of
  the room where the listener is. `Audio_Reverb` is a value of [volume](#volume): without a
  `Volume`, the level's; without any, nothing reverberates. `audio_reverb` (`late`) takes the blend
  at the listener and moves toward it over some `REVERB_FADE` seconds; it only sends while it
  changes. It returns in `Audio_Settings.reverb_bus`.
  - `Audio_Source.reverb` is the part of the source that it sends to the room; a one-shot sends
    none, as `AUDIO_SOURCE_DEFAULT`.
- **Medium.** `Audio_Medium` is what surrounds the listener besides air, like the water they are
  under: a low-pass and a reverb with their weight. A single plugin writes it
  ([water](../../mirai-world/references/water.md#sound)) before `audio_reverb` and
  `audio_buses`, from where the listener is (`listener_position`); at zeros it is air.
  `audio_reverb` mixes its reverb by its weight over that of the room, with the same fade, and
  `audio_buses` gives the master the lower cutoff between that of `Audio_Settings` and that of the
  medium.
- **Occlusion.** A spatial source with `Audio_Occlusion` is heard through what stands between it
  and the listener, as far as it is hidden: the mixer's direct effect blends each band toward what
  the bodies crossed let through (`Audio_Material.transmission`, `AUDIO_MATERIAL_DEFAULT` for a
  body without one), so a hidden source is muffled, not silenced. What collides is told by
  `core.World_Query`, ignoring the source's body and stopping `OCCLUSION_CLEARANCE` before the
  listener, which leaves the player's body out. Without a library that gives the query (physics),
  nothing covers.
  - How hidden: with `radius` 0 one ray; with a radius, the share of `OCCLUSION_SAMPLES` points of
    its sphere that the source reaches and the listener does not see, `OCCLUSION_SAMPLES_PER_FRAME`
    of them retested each frame. A voice that starts tests them all.
  - What gets through: rays from the listener and from the source take turns across up to
    `TRANSMISSION_SURFACES` surfaces, only while it is hidden.
  - `Audio_Source_State.occlusion` follows that share over `fade` seconds.
- **Sets.** A `.sound_set` ([format](../../mirai-assets/references/kinds.md#sound-set)) picks one
  of its sounds each time a voice starts, with `host.content_sound_pick` and the content generator:
  it does not repeat in a rollback because voices are not resimulated.
- **Buses.** `Audio_Bus` is a [named id](../../mirai-core/references/core.md#named-ids): the
  engine declares `master`, `music`, `effects` (that of sources and loose sounds by default),
  `voice` and `ui`, and a game its own below `AUDIO_BUS_CAPACITY`, which is the mixer's capacity. A
  bus is reserved the first time something names it.
  - `Audio_Settings` (project setting) has an entry per bus that does not sound as it arrives: its
    gain in dB, its low-pass, who ducks it, its own reverb over everything it touches, and the bus
    it sends to ([sends](../../mirai-platform/references/audio.md#buses)): one of a lower number,
    or the problem `audio.send` and the master. The gain
    is in dB so that an entry at zeros says "as it arrives": in linear, the master at volume 0
    would be an empty entry. `audio_bus_setting_set` writes or removes the entry and
    `db_volume` converts inside the mixer.
  - `Audio_Volumes` (machine setting) is the volume the player chose per bus, 0 to 1 over the
    game's gain: a slider binds its field and `save` stores it in the player's options.
  - `Audio_Output` (machine setting) is the output the player chose, by its name in
    `platform.audio_device_names`; empty, the system's. `audio_output` moves the mixer to it when
    it changes, without losing its voices, and only if the application has an open output. A name
    the system does not list sounds through the system's and is the problem `audio.output`. Its
    `kind` (speakers by default, or headphones) is given to every mixer, open output or not.
  - `audio_buses` (`late`) compares each bus of the mixer with its entry and its volume and sends
    only what differs; a bus without an entry returns to 0 dB, without filter or ducking. The
    master's mute belongs to the host (the player without focus), not to the settings.
- `Voices` (`host,by_world`, not copied) stores the voices of each world in a `core.Entity_Map` per
  entity: two worlds that run in one frame (a Play and an agent's run) each sound their own without
  cutting the other's. Those of sources that went away or were turned off are stopped from
  `core.changes`, and `audio_release` stops those of the world being released. A source that does
  not sound is a [problem](../../mirai-core/references/core.md#problems) of its entity:
  `audio.sound`, `audio.bus`, `audio.voices` or `audio.memory`.
- `Mixer_Listener` (host) is the mixer's listener, one per application: it is set by the world whose
  listener moved, or the one that runs after another.
- A loose sound is a one-shot of `Sound_Requests` (above). `buses_apply` is what `audio_buses`
  does every frame, for whoever sounds outside the game (the editor), which starts what it plays
  to be heard with `voice_start`.

## `anim`

Animation of transforms and skeletons is the optional `animation` plugin:
`anim "plugins:animation/runtime"`. Contract in the [plugin
reference](../../mirai-animation/references/animation.md).

## `gui`

Game `.ui` interfaces over the UI contexts of each world (`Gui`, `host,by_world`): the window's and
one per local player that has screens or sees a `World_Widget`.

- `UI_Screen`: an interface over the screen; a greater `order` covers a lesser one. `player` `n`
  is the part of local player `n` in split screen (`host.app_player_rect`). With `player` 0 it is
  of whoever its entity is of (`screen_owner`): a seat, the body a seat drives or what hangs from
  them shows in the part of that local player, and not at all for a body nobody drives or one a
  player of another end drives; any other entity shows on the window.
- `World_Widget`: an interface in the world, on the entity.
  - `preview` (true by default): in the editor, while the world is not playing, it is shown as it
    will look, without input or screens, with steps of the editor loop that do not run in a world
    that is playing.
  - `target` `Overlay`: a panel that follows the entity, drawn over the scene. With one player it is
    built in the window's context; with split screen, in that of each local player, placed for
    their camera (a `Billboard` faces that camera and a `Screen` one has its size in the player's
    part) and drawn only in their view. A `Screen` one scales with the screens of its player
    (`UI_Settings.reference` and `UI_Preferences.scale`), so it keeps their size.
  - `target` `Mesh`: the panel is drawn into a renderer texture of `size` by `pixels` texels per
    unit, which the slot `slot` of the material of the entity's mesh shows as base color, lit and
    covered like the scene, or as emission of `emission` nits; what the entity draws (its mesh, or
    the skinned copy from `animation`) uses that copy of its material (`host.Slot_Texture`; the
    standard model: a surface program does not read the map). It is built only once, in the
    window's context, with the ray of the player who has the keyboard, while the camera of some
    local player sees the mesh's box as it was drawn; out of view the texture keeps the last one.
  - Each player's ray leaves their camera: through the pointer while it is seen over their part;
    through the center of their view with the mouse captured, without a keyboard or if they play
    with a gamepad. It reaches a `Mesh` where it touches its triangles as the previous frame drew
    them (posed, with their `Draw_Offset` or carried by the camera), at their first texture
    coordinate (`render.mesh_ray`; without mesh data, through the panel's plane). One with
    `depth_test` does not reach through what the scene drew in front.
  - `Interactive` takes, besides the pointer, the focus, navigation, keys and actions while its
    player points at it and no screen of that player takes the input.
- **Binding.** The `.ui` names what it reads
  ([paths](../../mirai-ui/references/ui.md#data-tree)): each path starts at a component of
  `UI_Screen.entity` (null: its own; in a `World_Widget`, the panel's) or at a storage of the
  world, and an `Entity` field leads to another entity. The interface is built with a copy of the
  bytes it reads, which is redone only when a row's stamp moved. A control bound to a field of a
  storage writes it (`bind_commits`), and so does a `Button` that binds a value, with its
  `choice`; one bound to a component writes the copy, which is seen until a tick runs, and the
  game writes what the event asks for: a component is simulation state, written in a tick.
- **A game shows interfaces only as `.ui`.** The generator refuses a step of the `ui` phase
  outside the engine and the editor parts. What only code can draw is a `Draw` node: the
  procedure the game declares with `@(draw="name")` draws it from the node alone (its rectangle,
  its style and the bytes of the value it binds), when the node is built
  (`source_draw`, [the node](../../mirai-ui/references/ui.md#data-tree)); a name the game lacks is
  the problem `gui.draw`.
- **Modes (`UI_Input`).** `Passive` (a HUD) takes no navigation, keys or actions. Of each player's
  screens, the one with the greatest order that is not `Passive` and is not being hidden takes the
  input. `Modal` also blocks the actions of the seats it covers with `input_block`, releases the
  relative mouse and shows the cursor while it is on top. The block takes them from the game, not
  from the screen: its buttons and `Action_Bar` still read the actions they name past it
  (`seat_action_for`) and the game sees `Clicked`. With `input_context`, the screen that
  takes the input puts those seats in its [context](control.md#contexts) (modal if it is `Modal`,
  instead of the block): its buttons read the actions of that context and the game, what remains.
- A screen that stops being on top remembers its focus and recovers it on returning. One whose
  entity becomes `Hidden` keeps being built until the result says `present=false` (its exit
  animations).
- **Players.** A player's context receives the pointer and the keys only if it has the keyboard
  (`Seats.focus`), and the navigation of its gamepad (with a single player, of all), with the
  buttons as `host.ui_pad_buttons` translates them. Prompts and actions are those of its seat;
  those of the window, those of `Frame_Actions`. What a screen makes float over the surface or the
  safe area floats over its player's part. Each player's camera is that of their view in the last
  split frame (`App.local_cameras`).
- **`UI_Settings`** (project setting): `reference` is the design size in points, which
  `ui.scale_to_fit` brings to the window or the player's part. `languages` are the languages the
  game is in (`Language`, those the fonts have the glyphs of, with their code in
  `LANGUAGE_CODES`; English by default) and `source` the one the interfaces are written in.
  What each text says in them is in the `.strings`
  ([texts](../../mirai-assets/references/kinds.md#texts)). `prompts` picks the prompt
  pack (none: they are drawn). `prompt_images` gives loose entries a texture that wins over that of
  the pack; Project Settings > UI shows them in a table with the entries the game binds.
- **`UI_Preferences`** (machine setting): what the player chose, `language` (the language they
  show) and `scale` (over which it adjusts them). The game's options menu writes it, `save` stores
  it in the player's options and `gui` only reads it.
- **Game source** (`ui.Game_Source` of each context): `family` follows live the player's last used
  device (keyboard and mouse: `Keyboard`; a gamepad, the family SDL recognizes for it: Xbox,
  PlayStation or Nintendo), and a retained screen is redone when the family or the language
  changes; `prompts` comes from the action's bindings in the `Input_Map` (keys by their `core.Key`
  name, mouse or gamepad controls according to the family; four d-pad buttons are `Dpad`);
  `texture` from the assets; `view` draws the camera into a texture of the `Gui` per camera and
  size, every frame it is shown, and releases those nobody showed; `particles` plays a `.particle`
  in the rectangle of a `Particles` node (`UI_Effects`, which the `vfx` plugin draws, and an
  effects view of the renderer `PARTICLE_VIEW_METERS` high, per element and while it is being
  built); `sound` plays the asset. A screen that shows a camera or particles is built every frame:
  it is not drawn again from what it drew. `language` is the language the player chose
  (`ui_language`): the localized texts of the `.ui` show what their keys say in it. A prompt that
  the pack has shows its image (`host.prompts_find`); one it does not have is drawn.
- **Events.** `UI_Events` brings those of `ui.Tree_Event_Kind` (`Clicked`, `Changed`, `Submitted`,
  `Hovered`, `Unhovered`, `Focused`, `Unfocused`, `Dragged`, `Dropped`, `Finished`) and `Back`
  (Escape or East on the top screen with `back`, if the UI did not use them), `Menu` (the action,
  `gui.menu_pressed`), with the entity of
  the screen or the panel, the node's `base.name_hash`, its `rect` (window pixels for a screen,
  panel units for a world panel), `item`, `on`, `value`, `text` (of a field),
  `from`, `from_item` and `from_entity`: in a `Dropped`, the entity of the interface it came from
  (`Context.owner` is the entity while each tree is built). They are those of the last drawn frame,
  a `core.Events` each reader gets once: pushed in the first following tick
  (`gui_events_deliver`, `fixed`, stage `input`), or in the `frame` phase of a frame without ticks
  (the world's time stopped, as under a pause menu; `gui_events_frame`); a tick that a rollback
  repeats receives those it received, from a ring of `Gui` that keeps the last
  `DELIVERED_CAPACITY`. What a widget wrote is seen until its events reached the game. They are read
  with `ui_event`, `clicked`, `clicked_item`, `changed`, `changed_value`, `changed_text`,
  `submitted`, `dropped`, `finished` and `back`: of several of one kind in a frame, all read the
  last, which is what the widget asks for now. Texts are valid as long as the events.
- **Requests (`UI_Requests`).** `gui.play_animation(r, e, node, anim, item)` plays an animation of
  the `.ui` on a node (`ui.tree_play`; its end arrives as `Finished` with the animation in `from`)
  and `gui.focus(r, e, node, item)` moves the focus; they are applied when the interface of `e` is
  built in the frame. `item` counts the copies of a node inside lists; focus only reaches a node of
  a list, not of nested lists.
- **Repeated frames.** A context without changes in its interfaces, without trees that say
  `animating`, without input reaching it (pointer, buttons, keys, wheel, gamepad, text), without
  shown cameras or particles, with the same size, scale, density, atlas, family, view and ray of
  its panels, and in which no `ui` step of the engine or the editor asked for the window's context
  (`gui_context`: the frame counter) in the previous frame, is not built: it delivers
  its converted layer again (the data of a `ui` frame is valid until its next `frame_begin`).
  `Gui.skipped` counts them. In a context that is built, each screen that did not change, does not
  animate, is not hiding and that no input reaches is drawn again without being built
  ([retained subtrees](../../mirai-ui/references/ui.md#retained-subtrees)); `Gui.kept` counts
  them.
- An interface that is not shown is a [problem](../../mirai-core/references/core.md#problems) of
  its entity: `gui.asset` (the `.ui` does not load), `gui.bind` (what is bound does not exist, the
  entity does not have the component or the interface names a field it does not have),
  `gui.action` (the interface names an action the game does not declare: it is shown anyway, as
  without an action, and the `.ui` keeps it in case it returns), `gui.screens` (more than
  `SCREEN_CAPACITY` visible screens: the one with the lowest order is left out), `gui.widgets`
  (`World_Widget`s in view that did not fit: the farthest are left out; `Gui.dropped_widgets`
  counts them), `gui.mesh` (the renderer did not give the texture of a `Mesh`), `gui.events` (more
  than `EVENT_BATCH` events in a frame), `gui.draw` (a `Draw` names a procedure the game does not
  declare), `gui.play` and `gui.request` (a request that was not
  applied); what does not fit in the renderer is `gui.draws` of the world, and what an interface
  nests deeper than a frame holds (`ui.Stats.dropped_nesting`), `gui.nesting`.
- `pointer_consumed`/`keyboard_consumed` say whether the UI had the pointer or the keyboard.
- Flow: `gui_frame_begin` (`ui`, stage `begin`: plan, copies, rays and which contexts are built),
  `gui_widgets` (the first of `intent`), `gui_frame_end` (`end`: passes layers, panels and textures
  to the renderer and applies the cursor and the `Modal` blocks) and `gui_meshes_render`
  (`render`, before `render_sync`).
- Each world has its own contexts, instances and pending events: two worlds built in one frame do
  not mix, and `gui_release` releases those of the world being released.
- `gui.gui_context(gui)` gives a `ui` step of the engine, the editor or the editor part of a
  plugin the window's context between `gui_frame_begin` and `gui_frame_end` (null outside the
  phase; requesting it makes every frame be built). That is why `gui.Gui` is
  `@(storage,host,by_world,shared)`.
- The functions of `gui` and `audio` run only in the game loop.

## `save`

Saves: the `World` written in a slot, a file `saves/<slot>.save` in the project's user folder
(`host.app_user_folder`).

- Requests: `request_save` and `request_checkpoint` (with an optional label),
  `request_autosave`, `request_load`, `request_load_checkpoint`, `request_delete`,
  `request_new_game`, `request_end_game` and `request_label` push into `Save_Requests` and return
  nothing; each gets its `Result`, and what is not valid is also the problem `save.request`.
  - `Invalid_Slot`: the name is not letters, digits, spaces, `-` or `_`, or is a Windows device
    name. `Invalid_Label`: the label does not fit in `LABEL_CAPACITY`.
  - `saves_serve` (`input`, game only) serves them at the start of the next frame with what the
    tick left and leaves a `Result{op, kind, error, slot}` per request in `Save_Results`, which is
    cleared every frame. Requests and results are `keep`: loading does not lose them.
- A slot is a header, the thumbnail as PNG, a scene document (`scene.capture`) and the list of
  borrowed `Id`s. The header says what it is without reading the world: `slots(state, app, out)`
  lists the slots from it (with `all`, also those that do not load, with their `error`),
  `slot_info` reads one's and `slot_thumbnail` only the thumbnail. The editor handles them through
  the API ([saved games](../../mirai-agent-api/references/methods.md#saves)).
  - **Showing the thumbnail in the game.** A `ui` or `frame` function that receives
    `^Save_Thumbnails` (`shared`: the game and `save` write it) calls
    `thumbnail_texture(thumbnails, state.ptr, app, slot)` and writes the `base.Asset_Id` it returns
    in the field the `Image` of its `.ui` is bound to; the UI shows it like any texture
    ([game source](#gui)). The first time it decodes the PNG into a texture of the assets
    (`host.assets_texture_generate`); afterwards it only reads the header and gives the same id
    while the slot is not written again, or a new one in place of the old. A slot without a
    thumbnail gives `{}`.
  - The texture is released with `thumbnail_release` (a menu that closes), when deleting the slot
    with `request_delete`, when requesting it after it was written again and with the world
    (`saves_release`). A world has `THUMBNAIL_TEXTURES` at a time; beyond that, or without room in
    the assets or the renderer, `No_Room`. A PNG that does not decode or is larger than
    `THUMBNAIL_SIDE_MAX` is `Corrupt`; without assets or in a world the application did not make,
    `Unavailable`.
  - **Components are stored** of the entities with `Id`. One without `Id` (a `transient` copy)
    travels with one that `core.id_new` lends it and comes back without it.
  - `transient` fields are not stored, and a component stored with another layout migrates by field
    name.
  - **Storages are not stored**: what a save must keep goes in a component. What is derived (bodies,
    replicas, caches) is redone by the owning library from the components; that is why the bodies'
    velocity is in `core.Motion` and a clip's time in `anim.Animation_Progress`, from which a
    cinematic asks for its shot again.
- **It is written after capturing.** The capture is immediate. With a renderer the slot waits for
  its thumbnail: the player's view (`core.View`) drawn in a texture view of the library, without
  the scene's UI and exposed at once, which returns without waiting for the GPU
  ([texture views](../../mirai-rendering/references/views.md#texture-views)). Then a job halves
  it, makes the PNG and writes the atomic file; the `Result` arrives then.
  - Writes go one at a time and in order: two of one slot end up as the last requested.
  - A slot whose thumbnail does not return within `THUMBNAIL_WAIT` frames is written without it.
    Loading or deleting writes the pending ones first, and a world that goes away (`release`) too.
  - Without a renderer (a dedicated server) and in a world the application did not make (a test),
    without a thumbnail; in the second, immediately.
- **The game** (`Save_Game`, `keep`): the time played (the frames with the game on and the clock
  not paused), its label and whether it is off. The slot stores it and loading it returns it.
  `request_new_game` starts it from zero; `request_end_game` turns it off, like a menu, until
  another one or a load: it does not autosave or count time. It starts on, so a game with a menu
  turns it off when opening it.
- **Autosave** (`Save_Settings`, project setting): rotates between `autosave 1` and
  `autosave <autosave_slots>`, replacing the oldest, by a game interval since the last save, when a
  scene replaces another (`Scene_Root.changes`) and when a `Manual` section is turned on.
  - What the game has at the start is not a change: neither the first scene of the run, nor the
    first section turned on of each scene, nor a slot that is loaded.
  - Never on a client or with the game off; with networking the server does it. Each autosave
    leaves its `Result` with `kind=.Autosave`, also those the game did not request.
- **Checkpoints:** `request_checkpoint` writes the slot `CHECKPOINT` and `request_load_checkpoint`
  loads it.
- Loading replaces the world with `scene.replace`, like a scene: it is left clean
  (`core.world_clear`: derived storages return to their start, also the physics simulation) with
  the slot's entities.
  - Handles change and the in-flight events name entities that are no longer there.
  - A slot that does not load entirely leaves the world as it was (`Failed`).
  - The world's clock returns to the saved tick and seconds.
- A network server saves and loads; what a client has borrowed is stored with the server's last
  state and without `core.Remote` or `core.Pose_Target`, which belong to the session: the capture
  leaves them out (`Capture_Desc.excluded`) without touching their tables. A slot remembers the
  world's scene (`scene.Scene_Root`) and the world is it again on loading: with clients, a [scene
  change](../../mirai-networking/references/multiplayer.md#scene-change).
- Errors: `Unavailable` (saving or loading a slot on a client of a network session, or there is no
  folder), `Not_Found`, `Corrupt`, `Version` (written by another version of the engine), `Failed`,
  `Write_Failed`, `Busy` (also with too many slots to write), `No_Room` (thumbnails as textures).
  `error_text` gives the message. Also `delete_slot`, `slot_path`, `slot_valid`.
- **Player profile** (`profile.save`, in the folder that contains the slots' one): the
  `@(storage,persist)` of all libraries, the progress that is not a save's (achievements,
  unlocks, the last level). It belongs to the player on this machine: `saves_serve` reads it the
  first time a world runs (`Profile_State`) and writes it by itself, also with networking
  (`kept_watch`: the hash of what the file holds, written when it rests after a change, as
  `project.Rest` says, and in `saves_release`).
  - A document with one table per storage (`library/type`); written atomically. A storage stored
    with another layout migrates by field name and one the file does not have keeps its value.
  - A `persist` that is not flat data or has `Entity` fields is not written (`Failed`). A profile
    that is not read is the problem `save.profile` and the progress stays at its initial values.
- **Player options**, kept the same way as the profile: the machine settings of the world and the
  application (`Graphics_Settings`, `Display_Settings`, `Audio_Volumes`, `Audio_Output`,
  `UI_Preferences`, `Input_Settings` with what the player rebound) go to the `settings.mirai` of
  `App.options` (`host.app_options_save`). The player reads them over the project's; without
  `App.options` (the editor) it is `Unavailable`.

## `volume`

`Volume` is the only region of the world: unbounded, a box or a sphere by the entity's scale, or a
plane (everything under the entity, along its up), with `blend` meters of edge where its weight
goes from 1 to 0. What happens in it is another component of the same entity, of the library that
does it.

- **No component carries a shape of its own.** A library that needs a region reads the `Volume`
  of its entity and asks `depth`, `weight`, `holds` (a point) or `overlaps` (a box of the world),
  the one containment and overlap test; `valid` says whether a volume can hold anything. A size, a
  pose or a point that is not a number is outside. Who reads it: the per-zone values below,
  `Fluid`, `Force_Field` and the area requests of
  [physics](../../mirai-physics/references/engine.md#requests), `Strain_Field` of destruct,
  `Environment_Trigger`, the `Nav_Bounds`, `Nav_Area` and `Nav_Obstacle` of
  [navigation](../../mirai-world/references/navigation.md) and `Foliage_Bender`. Each says which
  shapes it takes and reports a problem for another.
- **`Spline`** (`spline.odin`) is the one path, as `Volume` is the one region: points in the frame
  of its entity, each with a width and a height over the ground. What goes along it is another
  component: a `Fluid` makes it a river ([physics](../../mirai-physics/references/physics.md)),
  its `material` a ribbon on the ground ([shapes](../../mirai-world/references/shapes.md#splines)),
  a patrol walks it. Every reader samples it with `spline_sample` (the one sampler,
  `mm.path_sample`) and lays each sample with `spline_lay` on `core.Ground_Queries`, never with a
  copy of its own, and nothing in it names a reader.

The values that change per zone are gravity, wind, reverb, how views look and fog (`Fog_Volume` of
the `fog` plugin):

- **A single algorithm** (`volume.odin`): at a point those that contain it are applied from lowest
  to highest `priority`, and among equals the largest first, over the library's default. Each one
  replaces what is below by its weight or adds (`mode`). A value without `Volume` applies in the
  whole world, replacing, with priority 0.
- `gather` collects in one pass those that contain a point and `combine` applies them, with the
  value of each row given by whoever asks (gravity toward a center depends on the point). `at` is
  both for a value that is its row: what is asked at one point per frame (the game's view, once
  per frame in `render_sync`; the listener).
- What is asked at many points per tick (each body's gravity) keeps an `Index`: the unbounded ones
  in order, the boxes and spheres in a tree and the planes in a list, redone only when a volume, a
  value or a place changes. A point asks the tree for the bounded ones that may contain it;
  without any, it is worth what the library combined of the unbounded ones when redoing it, and
  without bounded ones nobody asks.
- The value and its `Volume` are replicated; `scope` belongs to each end.
- **On the GPU** (`shaders/include/volume.slang`): `ordered` gives the rows in the order in which
  they are applied, which does not depend on the point, and `gpu_volume` their shape;
  `volume_weight` and `volume_mix` are the same weight and the same mix.
- **`Wind`** (`wind.odin`): `speed` toward the front (-Z) of its entity and `gusts` (cycles per
  second). Without any, the air is still. `gpu_wind` gives it to foliage, which mixes it at each
  plant's place, and to particles, which mix it where each one is and approach it as fast as their
  `drag` says, like the gravity of their place. Physics does not read it: bodies have no drag.
- **`Gravity`** (`gravity.odin`): where things fall, in m/s², the same for any mass. `Down` pulls
  toward -Y of its entity (turning it turns gravity); `Center`, toward the entity, like a planet:
  `acceleration` at `radius` (by the scale), with the inverse square of the distance outside and
  linear toward the center inside; with `radius` 0, the same at any distance. Without any,
  `GRAVITY_WORLD` applies. `gravity_of` is the value of a field at a point, the same for the bodies
  of [physics](../../mirai-physics/references/engine.md#gravity) and for the particles of
  [vfx](../../mirai-world/references/vfx.md#game), which do not depend on physics.

## `vfx`

Particles are the [`vfx`](../../mirai-world/references/vfx.md#game) plugin: emitters, `.particle`
effects, instance values, world clocks and requests.
