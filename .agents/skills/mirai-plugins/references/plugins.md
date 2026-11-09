# Plugins

## Shape

```text
plugins/<name>/
  plugin.mirai     manifest
  runtime/         game library: components, storages and world functions; each
                   subfolder with sources is another package of the same library
  editor/          editor package: tools, panels and editor-only data
  shaders/         Slang Surface and PostProcess programs; stages and hooks of a render extension
  assets/          assets that the plugin code refers to
  plugins/         only in a project plugin: its companions, plugins with the same shape
```

Location, validation, discovery and order of plugins:
[the project package](../../mirai-projects/references/projects.md#the-project-package). The
generator uses that order when sorting the functions of one stage
([order](../../mirai-core/references/generator.md#order)): `after` and `before` name only
functions of dependencies, so between plugins that do not depend on each other the stage orders
them.

## What each part does

- **`runtime/`** (`plugins:<n>/runtime` in the engine, `project:plugins/<n>/runtime` in a project)
  goes to `World` and `Shared`, in game and editor, with what the plugin adds to the world.
- **`editor/`** (`plugins:<n>/editor` or `project:plugins/<n>/editor`) goes to `Editor`, editor
  only, with the default `editor` loop; it can import its `runtime/` and `mirai:editor`.
- **`shaders/`** is not imported: it feeds the project's shader generation (`//! mirai surface
  Name` or `postprocess`, with a unique name across engine, project and plugins) and the stages,
  hooks and constants of a [render plugin](render-plugins.md).
- **`assets/`** is mounted under `plugins/<n>/`; everything it has is a cook root, because its code
  refers to it and no scene names it.

Rules:

- A plugin component is one more component: it appears in `World_Info`, in scenes by name and in
  what `save` stores. A scene that uses it needs the plugin enabled; otherwise
  `scene.instantiate` counts the table as `unknown` and `scene.capture` keeps it from the previous
  document.
- An editor package cannot ask for the `game` loop or receive editor types in a `fixed` function:
  the generator rejects it. What lasts between editing and Play lives in `World` components.
- Each part of an active engine plugin is compiled once into its own library
  ([plugin libraries](../../mirai-projects/references/projects.md#plugin-libraries)): a game
  change does not recompile the plugins, and a change in a plugin recompiles that library (and the
  ones that depend on its declarations) and restarts the editor. Project plugins are compiled with
  the project library, and the shipped game compiles all of them from their sources.
- Each library has its own type table: the engine does not find with `type_info_of` the `typeid`
  of a type that a plugin declares. A `typeid` crosses libraries to be compared; what the engine
  walks by reflection (rows, values, schemas) it receives as `^runtime.Type_Info`
  (`editor.Held_Values.info`, `World_Info`). Tests compile plugin and engine into one binary and
  do not see this: it shows in the project's editor.
- A `development` plugin (manifest) enters the editor and the player, never a shipped game: that
  game's world is generated without it and a game that reaches it does not compile.

## Dependencies and compatibility

- Manifest fields and their errors:
  [manifests](../../mirai-projects/references/projects.md#manifests).
- A plugin that only joins two others is `automatic`: it is enabled by itself when its
  dependencies are there, and neither of the two knows the other.
- A plugin imports only its `dependencies` and theirs: the generator rejects any other import and
  names the dependency to declare. Those that use physics name `physics`, and those that damage
  destructibles also `destruct`.
- Its tests also import its `test_dependencies`, which are never enabled with it (`multiplayer`
  tests the network with `physics` bodies); `mirai test` rejects any other import before
  compiling.
- An incompatible engine change raises the version and updates the range of the first-party
  plugins in the same task.

## Git plugins and catalog

A plugin from another repository is a `plugins/` folder of the project like any other (it is
imported as `project:plugins/<name>/...` and compiles with the project), but it is a git checkout
at the commit that `sources` of `project.mirai` names. A repository is a plugin; the plugins that
go with it (its automatic bridges with other plugins) are its **companions**, in
`plugins/<companion>/` inside its folder, a single level: discovery adds them after the plugin,
they are imported from its folder (`project:plugins/<plugin>/plugins/<companion>/...`) and are
installed, updated and removed with it, with no source of their own. A plugin that depends on
another imports it as `plugins:<n>/...` if it is an engine plugin and as
`project:plugins/<n>/...` if it is a project plugin. `cook/install` handles it; the CLI is
`mirai plugin` and in the editor, the Plugins category of the settings and the new project
dialog.

- Installing clones aside, checks that it is a plugin (`plugin_check`: valid manifest, folders of
  its parts, no links, an `engine` range that includes this engine, the same in each companion)
  and that no name, its own or a companion's, is held by the engine or another plugin of the
  project; only then does it move it to `plugins/<name>`, add the source, enable it and ignore it
  in the project's `.gitignore`. If the project does not open with it, it leaves everything as it
  was. Installing never runs plugin code.
- Updating and removing refuse if the checkout has changes of its own; removing also refuses if an
  active plugin that is not its companion depends on it. An update that does not pass
  `plugin_check` goes back to the previous commit.
- One installed from the catalog (`catalog` in its source) updates only to the commit that the
  catalog lists, when a PR to the catalog moves it and not when its repository advances, and never
  goes back: if it arrived with `--ref` at a descendant of that commit, it stays. Without a
  readable catalog, or if the catalog no longer lists it or lists it with another `url`, the
  update fails. The editor shows "Update available" only when the catalog lists another commit.
  One added by address goes to the default branch of its remote.
- The commit in `sources` rules: `sync` clones or moves each checkout to it (a fresh clone of the
  project, a pull that changed a commit). `sync_needed` decides it without running git, and the
  `tools/mirai` build (`build`, `edit`, `play`), the editor Build and the launcher call it before
  opening a project.
- git runs without a terminal (`GIT_TERMINAL_PROMPT=0`): a private repository uses the credentials
  of the machine's helper.
- The editor and the launcher run the steps in a thread of their own (`job_start`); a change
  compiles the project again.
- What the plugin needs (data, weights, licenses) comes in its repository: installing downloads
  nothing else.

The **catalog** is the `project.CATALOG_URL` repository with one file per plugin,
`plugins/<name>.json` (`project.Catalog_File`; the name is the file's): each plugin with the
commit that was reviewed, which is the one installed, never HEAD. The engine reads the format;
what validates it on each PR is the catalog's CI
([publishing](../SKILL.md#publish-a-plugin-in-the-catalog)). One is added or moved with a PR that
touches only its file, so two PRs never collide; an invalid file leaves the catalog unread and the
error names the plugin. The machine keeps a checkout of the catalog in its machine folder
(`project.machine_folder`). Next to the file, `plugins/<name>.png` (optional,
`project.catalog_icon`) is the icon with which the editor shows it before installing it; once
installed, the `icon` of its `plugin.mirai` applies
([manifests](../../mirai-projects/references/projects.md#manifests)).

## First-party plugins

Engine plugins; each `plugin.mirai` says its parts and `demo/project.mirai` says which ones the
demo enables. How an `editor/` adds steps, panels and tools:
[editor extensions](../../mirai-editor/references/extensions.md).

- **`physics`**: the solver as its own package (`runtime/sim`) and its integration with the world;
  the editor gets its collision rows, its API, Simulate with bodies and the Collision modes
  ([physics](../../mirai-physics/SKILL.md)).
- **`destruct`**: destructibles, fracture and pieces
  ([destruction](../../mirai-physics/references/engine-destruct.md)).
- **`shapes`** (`Runtime` and `Editor`; depends on `physics`): editable outlines and solids of
  brush entities whose source is saved and whose mesh and collider are derived on a child
  ([shapes](shapes.md)).
- **`multiplayer`**: the game network, without physics, and the editor's networked Play
  ([multiplayer](../../mirai-networking/references/multiplayer.md)).
- **Automatic bridges**: `destruct_multiplayer` (replicated fractures), `foliage_terrain` (the
  [foliage ground](foliage.md#ground) from the terrains), `foliage_multiplayer` (the replicated
  [removed instances](foliage.md#instances-removed-in-play)), `terrain_multiplayer` (the
  [terrain edits](terrain.md#network) over the network), `terrain_vfx` (the
  [dust of what is dug](terrain.md#what-digging-leaves)) and `spawn_physics` (the body that the
  [editor's Play puts at a place](../../mirai-gameplay/references/control.md#spawn-points)
  resting on what is below it). `terrain_debris` is not automatic: a project asks for its pieces
  and drops. The ground of
  [grounding](../../mirai-animation/references/animation-grounding.md) and the arm of the cameras
  need no bridge: they use `core.World_Queries`, which `physics` provides.
- **`navigation`** (`Runtime`, `Editor`; depends on `physics`): automatic navmesh from static
  collision, per agent class and by tiles that rebuild themselves, areas, obstacles, manual and
  generated links, agents that write their `Move_Input` and cross links, the scene's `.navmesh`
  and the `nav.*` methods. Contract in [navigation](navigation.md).
- **`behavior`** (`Runtime`, `Editor`; depends on `physics` and `navigation`): minds that the game
  runs by name in its functions, perception with memory, smart objects, place queries, influence
  maps and the `behavior.*` methods. Contract in [behavior](behavior.md).
- **`abilities`** (`Runtime`, `Editor`; depends on `physics` and `animation`): abilities as
  `Ability` and `Ability_Kit` rows of game data, the `Ability_User` that runs them, effects and
  the `abilities.*` methods. Contract in [abilities](../../mirai-abilities/SKILL.md).
- **`spawn`** (`Runtime`, `Editor`): spawn points and bodies for the players, which it destroys
  with their seat; the Spawn card of Create
  ([spawn points](../../mirai-gameplay/references/control.md#spawn-points)).
- **`cinematics`**: timelines, shots, tracks and viewers
  ([cinematics](../../mirai-gameplay/references/cinematics.md)).

- **`paint`** (`Runtime`, `Editor`)
  - Game: `Painted{source, shape}` stores what the entity showed before its first stroke. Its
    `Mesh_Renderer` points to a painted copy (own mesh that differs only in the vertex colors).
  - Editor: vertex color brush that writes painted copies of a mesh. The copy is a file of the
    stroke step (`editor.file_write`): it stays unsaved in the registry's memory until Save, undo
    and cancel remove it, and the next stroke reads it through `host.assets_file`. It paints the
    decoded level 0 of the clusters and stores it with `asset.mesh_build` in one level: the copy
    does not keep the coarser levels of the source.
    Test: `painted_copies_stay_in_memory_until_saved_and_go_with_undo_and_cancel`. API:
    [Paint](#paint).
- **`terrain`** (`Runtime`, `Editor`, `Shaders`, `Assets`)
  - Game: `Terrain{source, revision, solid}` and `terrain_update`. Heightfield, Mesh or Volume
    sources, derived chunks and immutable geometry replaced by region, material layers, levels of
    detail and holes. Contract in [terrain](terrain.md).
  - Editor: creation, sculpting, layer and hole painting with local preview, cancellation and
    undo. `terrain_slope.slang` paints by slope; `terrain_layers.slang` blends the layers through
    `assets/terrain_layers.mat`.
- **`foliage`** (`Runtime`, `Editor`, `Shaders`; depends on `physics`; not enabled in the demo):
  foliage of a scene in cells, with no entity per instance, drawn with instance batches, with one
  static body per cell and over a ground that another library writes. Editor: brush to paint and
  erase and selection of an instance with the gizmo. Contract in [foliage](foliage.md).
- **`previews`** (`Editor`)
  - Animation [documents](previews.md), with their clips on rigid objects or compact skeletons.
  - GPU skinning isolated from the world and its histories; what they edit is a step of the
    document.
- **`animation`** (`Runtime`, `Editor`)
  - Game: clips, blend spaces, graphs with optional states, layers, dense poses, GPU skinning,
    root motion and constraints. Contract in
    [animation](../../mirai-animation/references/animation.md).
  - Editor: per-instance inspector and
    [authoring by API](../../mirai-animation/references/animation-authoring.md) of clips, curves,
    skeletons, sockets and profiles, with preview and goal control. The dedicated visual window
    is pending.
- **`physics_placement`** (`Editor`): places a chosen mesh under the cursor with a temporary
  physics simulation; confirms creation and poses in a single undo; `placement.drop` does it by
  API. See [Physics placement](#physics-placement).
- **`ragdoll`** (`Runtime`, `Editor`): [ragdolls](ragdoll.md) with bodies bound to bones, free
  simulation, animated kinematics and physical animation motors; `ragdoll.setup` builds them from
  the skeleton's body.
- **`physics_fields`** (`Runtime`, `Editor`)
  - [Persistent fields](physics-fields.md) of sphere, box or plane with radial or directional
    force, curve with range, noise and independent strain.
  - Editor: volume and direction arrows when selecting a field in Edit or Simulate/pause.
- **`ui_inspector`** (`Editor`): [document](ui-inspector.md) that shows a `.ui` as the game builds
  it and edits its nodes, layout, bindings and styles.
- **`prompts_kenney`** (`Assets`): the Kenney prompt pack (CC0) for keyboard and mouse, Xbox and
  PlayStation, enabled in the demo.
  - `source/` holds the PNGs of the `Double` variant of the package and `kenney.prompts.json`,
    which gives an image to each `core.Key`, to the mouse buttons and movement and to the faces,
    shoulders, triggers, sticks and their press, d-pad and its directions, Start and Back of each
    gamepad (the colored buttons on the faces).
  - `assets/` holds `kenney.prompts` and its atlases, imported with
    `mirai import plugins/prompts_kenney/source/kenney.prompts.json --out
    plugins/prompts_kenney/assets --root plugins/prompts_kenney`
    ([prompts](../../mirai-imports/references/imports.md#prompts)).
- **`playtest`** (`Editor`, development): `play.observe`, the monitors of `play.qa.*` with their
  repros and the bot of `play.explore`, over the ticks the API runs
  ([`Run_Provider`](../../mirai-editor/references/extensions.md#runs-the-api-drives)). The game
  template enables it; none of its tools are listed by MCP by default, which the playtester
  agent reaches through `call`.
- **`profiler`** (`Editor`, development) and **`tracy`** (`Runtime`, development): captures panel
  of `profile.*` and Tracy GUI client. See [profiling](profiling.md).
- **`vfx`** (`Runtime`, `Editor`, `Shaders`; depends on `physics`, whose gravity its particles
  take): GPU [particles](vfx.md), their `.particle` format, the inspector and document of an
  effect and the `particle.*` methods.
- **`fluids`** is not part of the engine: the plugin lives in
  <https://github.com/tomaszbk/mirai-fluids>, with its `water_fluids` bridge, and is installed
  from the catalog.
- **`imprint`** (`Runtime`, `Shaders`; depends on `vfx` and `physics`): snow, mud and sand
  [footprints](imprint.md) in a height clipmap on a `vfx` grid, with the ground meshes displaced
  on the GPU for the raster and the rays.
- **`decals`, `deform`, `monitors`, `portals`, `mirror`, `fog`**
  - Parts: `Runtime`; `Shaders` except `monitors`; `Editor` except `deform`.
  - Renderer extensions: decals on the G-buffer, meshes deformed on the GPU with their own
    equations, screens that show cameras, portals, flat mirrors and volumetric fog. Contract in
    [render plugins](render-plugins.md).
  - Editor: Decal, Screen, Portal, Mirror and Fog cards of Create, with their icon and what they
    show when selected.
- **`lens`** (`Runtime`, `Shaders`): what a lens does to the resolved image (depth of field,
  motion blur, bloom, vignette, distortion and chromatic aberration), per camera and per volume.
  Contract in [render plugins](render-plugins.md#lens).

## Paint

Vertex color brush (shortcut **B**, code in `paint_editor.odin` and `canvas.odin`).

- `Painted` stores what the entity showed before its first stroke and its `Mesh_Renderer` points
  to a painted copy, which is a file of the stroke step (`editor.file_write`): it stays in memory
  until Save, undo and cancel remove it, and the next stroke reads it through `host.assets_file`.
- A stroke stamps the brush by distance in the world onto the vertices, with a soft falloff up to
  the radius, and each vertex keeps the maximum of its stamps: passing twice in one stroke paints
  once.
- `paint.stroke` and `paint.clear` are the brush and **Clear paint** by API
  ([methods](../../mirai-agent-api/references/methods.md#painting-and-placement)): they load, stamp
  and write the copy with the same procedures as the tool, on an entity by id and without
  touching its state or the user's current stroke. The whole stroke is one undo step.

## Physics placement

Editor tool (place icon, shortcut **P**, code in `placement.odin`) that drops meshes under the
cursor with a temporary physics simulation and confirms creation and poses in a single undo.
`placement.drop`
([methods](../../mirai-agent-api/references/methods.md#painting-and-placement)) does the same within
one call: it opens the preview, drops each mesh in order, advances the physics until rest or its
cap and confirms, or cancels on an error; it never leaves the preview open.

- The panel uses the Mesh row of Details (`editor.geometry_choice`, the
  [geometry selector](../../mirai-editor/references/extensions.md#a-panel)) and needs no selected
  entity. **Speed**, **Drop height** and **Scale** set the frequency, the drop height and the
  uniform scale, and change within the same preview.
- The mesh, its box, the footprint and the drop height under the cursor are instances and lines
  of the frame, with no entities or undo. Preview and creation use the same pose, also with a
  non-centered origin; the bounds are measured again only when the geometry or the asset revision
  changes.
- The left button drops a mesh and, held, keeps going according to Speed; releasing it stops the
  creations and the physics continues. A confirmation admits `PLACEMENT_CAPACITY` meshes.

The drop:

- Clones the world and advances only the [physics](../../mirai-physics/references/engine.md), at a
  fixed step and with a cap on steps per frame: no gameplay, player input or network. Each drop is
  added to the same clone without restarting the previous ones.
- The environment stays fixed. The created meshes are dynamic bodies with their box as the
  collision approximation, also if they are curved or concave. The environment's characters are
  their static capsule, destructibles without a collider are their outer mesh, and other surfaces
  need a collider; joints do not act.
- When the bodies sleep, advancing stops; `PLACEMENT_TICKS` after the last drop it pauses to
  confirm or cancel, and another drop resumes it.

Transaction:

- The poses are shown inside a
  [temporary tool transaction](../../mirai-editor/references/extensions.md). **Confirm** keeps
  entities and poses as one undo step; **Cancel** or Escape restores entities, poses and
  selection. Changing tool, starting Play or replacing the document cancels.
- The clone's auxiliary colliders and bodies never enter the document. The `Physics_Placement`
  storage owns the clone and frees it on finishing or when the editor is destroyed.

## Changing a plugin

- Each plugin defines how it publishes its authoring changes: file and reload, or immutable
  generated resources. The component stores the identity and revision of its source.
- Derived fields carry `transient`; those that must not travel over the network, `local`.
- Test with `generate` of the demo, `check` of each part and a run with the editor or the game.
- `paint/editor`: unsaved copies that go with undo and cancel, and stroke and clear by API
  (`painted_copies_stay_in_memory_until_saved_and_go_with_undo_and_cancel`,
  `paint_api_strokes_along_points_and_clears_as_steps_of_undo`). The stroke with the pointer is
  verified by the user.
- `physics_placement/editor`: drop and stacking without gameplay, a single undo/redo,
  cancellation, tool removal, selection preservation, atomic rejection of invalid geometry and
  the drop by API without an open preview
  (`placement_api_drops_settle_and_confirm_within_the_call`). Capture the mesh and its footprint
  under the cursor without modifying entities or history; the click on surfaces and its controls
  are verified by the user.
