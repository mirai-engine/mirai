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
- **`cook/`** runs only while a game is cooked: a package built apart, into a library the cook
  loads, that gives the `codec.Cook_Api` of a compression plugin through `codec.COOK_SYMBOL`. It
  goes by the C convention and is never imported from `runtime/`.
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
  names the dependency to declare. Those that use physics name `physics`, which is also what
  breaks things; only what works on `Destructible` entities names `destruct`.
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
- **`locomotion`** (`Runtime`, `Editor`; depends on `physics`): walking, jumping, flying and
  swimming of a `Character` by its `Walk`, `Fly` or `Swim`, the layered moves and the seat that
  drives it; it tells the editor's bots how fast a body walks
  ([locomotion](../../mirai-physics/references/engine.md#locomotion)).
- **`destruct`**: destructibles, fracture and pieces
  ([destruction](../../mirai-physics/references/engine-destruct.md)).
- **`shapes`** (`Runtime` and `Editor`; depends on `physics`): editable outlines and solids of
  brush entities whose source is saved and whose mesh and collider are derived on a child
  ([shapes](../../mirai-world/references/shapes.md)).
- **`multiplayer`**: the game network, without physics, and the editor's networked Play
  ([multiplayer](../../mirai-networking/references/multiplayer.md)).
- **Automatic bridges**: `destruct_multiplayer` (replicated fractures), `physics_cache_destruct`
  (the [recording of destructibles](physics-cache.md#recording)), `terrain_multiplayer` (the
  [terrain edits](../../mirai-world/references/terrain.md#network) over the network) and
  `spawn_physics` (the body
  that the [editor's Play puts at a place](../../mirai-gameplay/references/control.md#spawn-points)
  resting on what is below it). `terrain_debris` is not automatic: a project asks for its pieces and
  drops. What two plugins share through a `core` contract needs no bridge: the ground of
  [grounding](../../mirai-animation/references/animation-grounding.md) and the arm of the cameras
  use `core.World_Queries`, which `physics` provides; foliage and navigation read the ground of
  `core.Ground_Queries`, which `terrain` provides; births of effects go through `core.Births`,
  which `vfx` takes; and a component declared `replicated="object"` (removed foliage) is
  replicated by `multiplayer` without a bridge ([core](../../mirai-core/references/core.md#ground)).
- **`navigation`** (`Runtime`, `Editor`; depends on `physics` and `locomotion`): automatic
  navmesh from static collision, per agent class and by tiles that rebuild themselves, areas,
  obstacles, manual and generated links, agents that write their `Move_Input` and cross links, the
  scene's `.navmesh` and the `nav.*` methods. Contract in
  [navigation](../../mirai-world/references/navigation.md).
- **`behavior`** (`Runtime`, `Editor`; depends on `physics`, `locomotion` and `navigation`):
  minds that the game runs by name in its functions, perception with memory, smart objects, place
  queries, influence maps and the `behavior.*` methods. Contract in
  [behavior](../../mirai-world/references/behavior.md).
- **`abilities`** (`Runtime`, `Editor`; depends on `physics`, `locomotion` and `animation`):
  abilities as `Ability` and `Ability_Kit` rows of game data, the `Ability_User` that runs them,
  effects and the `abilities.*` methods. Contract in [abilities](../../mirai-abilities/SKILL.md).
- **`spawn`** (`Runtime`, `Editor`): spawn points and bodies for the players, which it destroys
  with their seat; the Spawn card of Create
  ([spawn points](../../mirai-gameplay/references/control.md#spawn-points)).
- **`cinematics`** (depends on `animation`): the shots and the actions the markers of a clip stage
  ([cinematics](../../mirai-gameplay/references/cinematics.md)).

- **`paint`** (`Runtime`, `Editor`)
  - Game: `Painted{colors}` names a `.paint`, the colors of the entity over the shared mesh its
    `Mesh_Renderer` shows: one per vertex by index in the mesh (cluster order, every level), with
    the position of each and the content hash of the mesh file painted on. The runtime gives them
    to the instance through `engine/render` (`colors_load`, `instance_colors_set`); the mesh and
    its levels stay shared and untouched. Colors of another number of vertices than the mesh has
    are not shown and reported as `paint.mismatch`.
  - Editor: vertex color brush that writes a `.paint` per stroke. API: [Paint](#paint).
- **`terrain`** (`Runtime`, `Editor`, `Shaders`, `Assets`)
  - Game: `Terrain{source, revision, solid}` and `terrain_update`. Heightfield or Volume
    sources, derived chunks and immutable geometry replaced by region, material layers, levels of
    detail and holes. Contract in [terrain](../../mirai-world/references/terrain.md).
  - Editor: creation, sculpting, layer and hole painting with local preview, cancellation and
    undo. `terrain_slope.slang` paints by slope; `terrain_layers.slang` blends the layers through
    `assets/terrain_layers.mat`.
- **`foliage`** (`Runtime`, `Editor`, `Shaders`; depends on `physics`; not enabled in the demo):
  foliage of a scene in cells, with no entity per instance, drawn with instance batches, with one
  static body per cell and over a ground that another library writes. Editor: brush to paint and
  erase and selection of an instance with the gizmo. Contract in
  [foliage](../../mirai-world/references/foliage.md).
- **`previews`** (`Editor`)
  - Animation [documents](previews.md), with their clips on rigid objects or compact skeletons.
  - GPU skinning isolated from the world and its histories; what they edit is a step of the
    document.
- **`animation`** (`Runtime`, `Editor`)
  - Game: clips, the one `.character` set (motion matching, layers and actions), dense poses, GPU
    skinning, root motion and constraints. Contract in
    [animation](../../mirai-animation/references/animation.md).
  - Editor: per-instance inspector and
    [authoring by API](../../mirai-animation/references/animation-authoring.md) of clips, curves,
    skeletons, sockets and profiles, with preview and goal control. The dedicated visual window
    is pending.
- **`ragdoll`** (`Runtime`, `Editor`): [ragdolls](ragdoll.md) with bodies bound to bones, free
  simulation, animated kinematics and physical animation motors; `ragdoll.setup` builds them from
  the skeleton's body.
- **`ui_inspector`** (`Editor`): [document](ui-inspector.md) that shows a `.ui` as the game builds
  it and edits its nodes, layout, bindings and styles.
- **`prompts_kenney`** (`Assets`): the Kenney prompt pack (CC0) for keyboard and mouse, Xbox and
  PlayStation, enabled in the demo.
  - `assets/` holds the PNGs of the `Double` variant of the package and `kenney.prompts.json`,
    which gives an image to each `core.Key`, to the mouse buttons and movement and to the faces,
    shoulders, triggers, sticks and their press, d-pad and its directions, Start and Back of each
    gamepad (the colored buttons on the faces), and beside it `kenney.prompts`, imported with
    `mirai import plugins/prompts_kenney/assets/kenney.prompts.json`; its atlases are of the
    imported folder of the plugin ([prompts](../../mirai-imports/references/imports.md#prompts)).
- **`playtest`** (`Editor`, development): `play.observe`, the monitors of `play.qa.*` with their
  repros and the bot of `play.explore`, over the ticks the API runs
  ([`Run_Provider`](../../mirai-editor/references/extensions.md#runs-the-api-drives)). The bot
  only picks where to go: the drive of the editor walks it there. Whether a body is stuck is
  measured once (`stuck_watch`), for the monitors, `play.observe` and the bot. The game
  template enables it; none of its tools are listed by MCP by default, which the playtester
  agent reaches through `call`.
- **`profiler`** (`Editor`, development) and **`tracy`** (`Runtime`, development): captures panel
  of `profile.*` and Tracy GUI client. See [profiling](profiling.md).
- **`vfx`** (`Runtime`, `Editor`, `Shaders`; no dependencies: its particles take the gravity and
  wind of the `engine/volume` volumes): GPU [particles](../../mirai-world/references/vfx.md), their
  `.particle` format, the inspector and document of an effect and the `particle.*` methods.
- **`fluids`** is not part of the engine: the plugin lives in
  <https://github.com/tomaszbk/mirai-fluids>, with its `water_fluids` bridge, and is installed
  from the catalog.
- **`imprint`** (`Runtime`, `Shaders`; depends on `vfx` and `physics`): snow, mud and sand
  [footprints](../../mirai-world/references/imprint.md) in a height clipmap on a `vfx` grid, with
  the ground meshes displaced on the GPU for the raster and the rays.
- **`decals`, `deform`, `monitors`, `portals`, `fog`**
  - Parts: `Runtime`; `Shaders` except `monitors`; `Editor` except `deform`.
  - Renderer extensions: decals on the G-buffer, meshes deformed on the GPU with their own
    equations, screens that show cameras, portals and flat mirrors, and volumetric fog. Contract in
    [render plugins](render-plugins.md).
  - Editor: Decal, Screen, Portal, Mirror and Fog cards of Create, with their icon and what they
    show when selected.
- **`lens`** (`Runtime`, `Shaders`): what a lens does to the resolved image (depth of field,
  motion blur, bloom, vignette, distortion and chromatic aberration), per camera and per volume.
  Contract in [render plugins](render-plugins.md#lens).

## Paint

Vertex color brush (shortcut **B**, code in `paint_editor.odin` and `canvas.odin`).

- A stroke paints every vertex of every level of the mesh and writes the colors of the entity as
  a `.paint`, a file of the stroke step (`editor.file_write`) that `Painted` names: the flush
  writes it when the step ends, undo and cancel remove it, and the next stroke reads it through
  `host.assets_file`. Another entity of the same mesh keeps its own colors.
- A `.paint` whose mesh file changed (imported again) follows it: `paint_fit` gives each vertex
  the color of the nearest painted position and writes it, as a step.
- A stroke stamps the brush by distance in the world onto the vertices, with a soft falloff up to
  the radius, and each vertex keeps the maximum of its stamps: passing twice in one stroke paints
  once.
- `paint.stroke` and `paint.clear` are the brush and **Clear paint** by API
  ([methods](../../mirai-agent-api/references/methods.md#painting-and-shapes)): they load, stamp
  and write the colors with the same procedures as the tool, on an entity by id and without
  touching its state or the user's current stroke. The whole stroke is one undo step.

## Changing a plugin

- Each plugin defines how it publishes its authoring changes: file and reload, or immutable
  generated resources. The component stores the identity and revision of its source.
- Derived fields carry `transient`; those that must not travel over the network, `local`.
- Test with `generate` of the demo, `check` of each part and a run with the editor or the game.
- `paint/editor`: colors written at the flush that go with undo and cancel, every level painted, and
  stroke and clear by API (`painted_colors_reach_the_disk_at_the_flush_and_go_with_undo_and_cancel`,
  `a_stroke_paints_every_level_of_a_mesh_two_entities_share`,
  `paint_api_strokes_along_points_and_clears_as_steps_of_undo`,
  `paint_follows_its_mesh_imported_again_with_its_vertices_in_another_order`); drawn at every level,
  per instance: `gpu_instances_of_one_mesh_draw_their_own_colors_at_every_level` (`render`). The
  stroke with the pointer is verified by the user.
