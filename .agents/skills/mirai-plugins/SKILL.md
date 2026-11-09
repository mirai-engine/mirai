---
name: mirai-plugins
description: Write and maintain Mirai plugins (runtime and editor parts) and the first-party
  plugins, such as the `behavior` AI (minds, smart objects, perception, influence). Use when
  creating or changing a plugin, splitting its responsibilities, or integrating it with the
  project world.
---

# Mirai plugins

A plugin is a folder with libraries: the game's (`runtime/`) and, if it wants its own tools, an
editor package (`editor/`). There is no plugin registry: the generator
([core](../mirai-core/SKILL.md)) reads the attributes of its packages and joins them to the
project world. Layout, manifests and build:
[projects](../mirai-projects/references/projects.md). Editor and its extensions:
[the editor skill](../mirai-editor/SKILL.md).

## Map

- Shape, parts, dependencies, build and list of first-party plugins:
  [shape](references/plugins.md#shape),
  [what each part does](references/plugins.md#what-each-part-does),
  [dependencies and compatibility](references/plugins.md#dependencies-and-compatibility),
  [first-party plugins](references/plugins.md#first-party-plugins) and
  [changing a plugin](references/plugins.md#changing-a-plugin)
- Plugins from other repositories (`mirai plugin`, `cook/install`, companions, the
  `mirai-engine/mirai-plugins` catalog):
  [git plugins](references/plugins.md#git-plugins-and-catalog); publishing one in the catalog:
  [workflow](#publish-a-plugin-in-the-catalog)
- `paint` (vertex color brush, `paint.*`): [plugins.md#paint](references/plugins.md#paint)
- `physics_placement` (`placement.drop`):
  [plugins.md#physics-placement](references/plugins.md#physics-placement)
- `previews` (animation documents, animation and skeleton thumbnails; `animation.capture`):
  [animation document](references/previews.md#animation-document),
  [thumbnails](references/previews.md#animation-thumbnails),
  [capture](references/previews.md#animation-capture) and
  [sound documents](references/previews.md#sound-documents)
- `vfx` (particles: `.particle` format, emitters and clocks, GPU pools and passes, Vfx programs
  with surfaces, bones, channels and grids, stages and neighbors, volumes, events to the game):
  [format](references/vfx.md#format), [game](references/vfx.md#game),
  [surfaces, bones and resources](references/vfx.md#surfaces-bones-and-resources),
  [grids and stages](references/vfx.md#grids-and-stages),
  [world textures](references/vfx.md#world-textures), [grid states](references/vfx.md#grid-states),
  [volumes](references/vfx.md#volumes), [channels](references/vfx.md#channels),
  [data channels](references/vfx.md#data-channels), [UI effects](references/vfx.md#ui-effects),
  [reports](references/vfx.md#reports),
  [GPU pools and emitters](references/vfx.md#pools-and-emitters),
  [births and steps](references/vfx.md#births-and-steps),
  [Vfx programs](references/vfx.md#vfx-programs), [passes](references/vfx.md#passes) and
  [particle lights](references/vfx.md#particle-lights)
- `fluids` (plane fluids on a `vfx` grid) is not part of the engine: it is installed from the
  catalog (<https://github.com/tomaszbk/mirai-fluids>); how `water` takes its waves:
  [what physics shows](references/water.md#what-physics-shows).
- `imprint` (snow, mud and sand that keep footprints and furrows: height clipmap on a `vfx` grid,
  stamps, displacement of the ground meshes as seen by rays):
  [the field](references/imprint.md#the-field), [stamps](references/imprint.md#stamps),
  [what is drawn](references/imprint.md#what-is-drawn) and [scene](references/imprint.md#scene)
- `water` (the `Fluid_Volume`s drawn as water: glass surface, `fog` medium, caustics, foam,
  splashes and wakes from physics): [appearance](references/water.md#appearance),
  [what physics shows](references/water.md#what-physics-shows),
  [sound](references/water.md#sound), [scene](references/water.md#scene) and
  [limits](references/water.md#limits)
- `vfx` in the editor (GPU effect preview, effects document, `Particle_Emitter` section,
  thumbnails, Particles card, `particle.*` methods):
  [Particle_Emitter section](references/vfx-editor.md#particle_emitter-section),
  [effect preview](references/vfx-editor.md#effect-preview),
  [particle document](references/vfx-editor.md#particle-document) and
  [thumbnails](references/vfx-editor.md#thumbnails)
- `terrain` (format, chunks, material layers, levels of detail, holes, tool, in-game editing,
  residency): [source and chunks](references/terrain.md#entity-source-and-chunks),
  [volume with heightfield](references/terrain.md#joining-a-volume-with-a-heightfield),
  [format](references/terrain.md#canonical-format),
  [geometry and collision](references/terrain.md#geometry-and-collision),
  [materials and layers](references/terrain.md#materials-and-layers),
  [mesh authoring](references/terrain.md#mesh-authoring), [tool](references/terrain.md#tool),
  [API](references/terrain.md#api),
  [editing during Play](references/terrain.md#editing-during-play),
  [publishing and residency](references/terrain.md#jobs-publishing-and-residency) and
  [open worlds](references/terrain.md#limits-in-open-worlds)
  - Network edits and the `terrain_multiplayer` bridge: [network](references/terrain.md#network)
  - Material under the surface of a Volume (strata, veins, `terrain.interior`):
    [interior](references/terrain.md#volume-interior)
  - What digging removes (`Terrain_Digs`), the `terrain_vfx` dust and the `terrain_debris` pieces
    and drops: [what digging leaves](references/terrain.md#what-digging-leaves)
  - Quadtree, far nodes, coarse grid and piece budget:
    [quadtree](references/terrain.md#quadtree-and-nodes)
- `foliage` (`.foliage`, cells, generator, overrides and orphans, ground and its `foliage_terrain`
  bridge, per-cell batches, types from prefabs, octahedral impostors and canopy in rays, wind by
  variants and by hook, bending by `Foliage_Bender`, collision by resident cells, brush and
  instance selection): [source](references/foliage.md#entity-and-source),
  [format](references/foliage.md#format), [cells](references/foliage.md#layers-of-a-cell),
  [ground](references/foliage.md#ground), [drawing](references/foliage.md#drawing),
  [impostor and crown](references/foliage.md#far-impostor-and-crown),
  [wind](references/foliage.md#wind), [collision](references/foliage.md#collision),
  [removed in play](references/foliage.md#instances-removed-in-play) and
  [tool](references/foliage.md#tool)
- `navigation` (automatic navmesh per agent class, areas, obstacles, manual and generated links,
  agents, link crossing, crowd, air and water volumes, `.navmesh`, `nav.*`):
  [meshes](references/navigation.md#meshes),
  [air and water volumes](references/navigation.md#air-and-water-volumes),
  [links](references/navigation.md#links), [agents](references/navigation.md#agents),
  [baking](references/navigation.md#baking) and
  [editor and API](references/navigation.md#editor-and-api)
  - Tiles per section, stitching, baking of each section and coarse graph:
    [sections](references/navigation.md#sections); agents that keep going far from the players
    (`scene.Roaming`, `Nav_Far`): [the far field](references/navigation.md#the-far-field)
- `behavior` (minds by name, enemies with minds, perception, smart objects, place queries,
  influence maps, `behavior.*`): [minds](references/behavior.md#minds),
  [enemies with minds](references/behavior.md#enemies-with-minds),
  [smart objects](references/behavior.md#smart-objects),
  [influence maps](references/behavior.md#influence-maps),
  [perception](references/behavior.md#perception), [places](references/behavior.md#places) and
  [API](references/behavior.md#api)
- `navigation_terrain` (automatic bridge: where the terrain collision is not loaded, for the
  navmesh): [navigation.md](references/navigation.md#meshes)
- `animation_physics` (automatic bridge: the mode, velocity and request of each `Character` feed
  the motion matching of its `Animation`):
  [locomotion](../mirai-animation/references/animation.md#locomotion-by-motion-matching)
- `unreal` and its `unreal_*` bridges (import Unreal packages and maps in the editor) are not part
  of the engine: they are installed from the catalog (`mirai plugin add unreal`); code and
  documentation in <https://github.com/tomaszbk/mirai-unreal>
- `streaming` (loading of `Spatial` sections by proximity and what crosses sections):
  [libraries](../mirai-gameplay/references/libraries.md#plugin-streaming)
- `shapes` (editable outlines and solids of brush entities saved as source, stamps and vertex
  edits, bevels of the rims of an outline, the derived child with mesh and collider, static or
  dynamic; the Shapes tool and `shapes.*`):
  [source and derived](references/shapes.md#source-and-derived),
  [static and dynamic](references/shapes.md#static-and-dynamic),
  [editing](references/shapes.md#editing) and [Shapes tool](references/shapes.md#shapes-tool)
- `physics_cache` (portable recording, `Geometry_Playback`):
  [recording](references/physics-cache.md#recording),
  [relation with animation](references/physics-cache.md#relation-with-animation) and
  [playback](references/physics-cache.md#playback)
- `physics_fields` (force and strain regions): [component](references/physics-fields.md#component),
  [fixed step](references/physics-fields.md#fixed-step) and
  [selection preview](references/physics-fields.md#selection-preview)
- `ragdoll` (components and `ragdoll.setup`): [components](references/ragdoll.md#components),
  [setup by API](references/ragdoll.md#setup-by-api),
  [state and errors](references/ragdoll.md#state-and-errors) and
  [order and memory](references/ragdoll.md#order-and-memory)
- `ui_inspector` (`.ui` document, paths and the `ui.*` API):
  [document](references/ui-inspector.md#document), [paths](references/ui-inspector.md#paths),
  [API](references/ui-inspector.md#api) and
  [document bar](references/ui-inspector.md#document-bar)
- `playtest` (what an agent or a bot plays with: `play.observe`, the monitors of `play.qa.*` and
  `play.explore`): [plugins.md](references/plugins.md#first-party-plugins)
- `profiler` and `tracy` (development: captures panel and Tracy client in Odin):
  [profiler in the editor](references/profiling.md#profiler-editor) and
  [Tracy at runtime](references/profiling.md#tracy-runtime)
- `decals`, `deform`, `monitors`, `portals`, `mirror`, `fog`, `fsr`, `lens` and plugins that
  extend the renderer: [decals](references/render-plugins.md#decals),
  [deform](references/render-plugins.md#deform), [monitors](references/render-plugins.md#monitors),
  [portals](references/render-plugins.md#portals), [mirror](references/render-plugins.md#mirror),
  [fog](references/render-plugins.md#fog), [fsr](references/render-plugins.md#fsr) and [renderer
  extensions](../mirai-rendering/references/views.md#extension-stages)
- `prompts_kenney` (Kenney prompt pack and how it is regenerated):
  [plugins.md](references/plugins.md#first-party-plugins)
- `abilities` (attacks, combos, dashes and reactions as rows of game data: sheets with timeline
  windows, cancel rules, statuses, attributes and effects; `abilities.*`):
  [abilities skill](../mirai-abilities/SKILL.md)
- `animation` (clips, graphs, rigs, morphs, actions, authoring and its API):
  [animation skill](../mirai-animation/SKILL.md)
- `lens` (depth of field, motion blur, bloom, vignette, distortion and aberration; settings per
  camera and per volume, consistent with exposure): [lens](references/render-plugins.md#lens)

## Workflow

1. Create the manifest and the folders according to
   [project manifests](../mirai-projects/references/projects.md#manifests).
2. `runtime/` is a library like `game/`: `@(component)` components, `@(storage)` storages and
   `@(step=...)` functions over `core`, `host` and the `engine/*` libraries. It is the only part
   of the plugin that reaches the game. Import paths:
   [what each part does](references/plugins.md#what-each-part-does).
3. `editor/` is a library with the same attributes, but its types and functions live in `Editor`
   and run in the editor loop. It can import its own `runtime/` for the layout of its components.
4. Enable it in `plugins` of `project.mirai`; its dependencies are enabled automatically and come
   earlier in the order.
5. Generate the world and build and run the project that enables the plugin
   ([verification](#verification)).

### Publish a plugin in the catalog

1. The plugin lives in its own public git repository: `plugin.mirai` at the root, a license file
   and, if it has bridges with other plugins, each one in `plugins/<name>/` as a companion
   ([git plugins](references/plugins.md#git-plugins-and-catalog)). It ships its data and its
   licenses inside.
2. `mirai plugin check <folder>` validates it as the installation will, and
   `mirai plugin add <url> --ref <commit>` in a test project installs it; then
   `mirai build editor` of that project builds it.
3. A PR to <https://github.com/mirai-engine/mirai-plugins> adds only `plugins/<name>.json` with
   the description, the URL and the reviewed commit (the catalog README has the format) and, if
   it has an icon, `plugins/<name>.png`, the same one that the `icon` of its manifest names. CI
   runs `uv run scripts/validate.py`: the file, the fields, that the repository at that commit is
   the plugin of that name with its license file, and that no name, not even a companion's, is
   repeated in the catalog. The license lives only in the plugin repository.
4. A new version is another PR that changes only `commit`: projects that installed it from the
   catalog update to that commit and to none that was not reviewed.

## Invariants

- The exclusion of the editor part is checked in the
  [project verification](../mirai-projects/SKILL.md#verification).
- A plugin library is the only writer of its own data. To move something owned by another
  library, send a request (`core.place`, `phys.set_velocity`, `destruct.damage`); if it owns a
  shared row it declares `locks`.
- Two types with the same name in different packages are legal (the world field carries the
  package in front), but the names of functions and of types used in scenes must be unambiguous:
  prefix with the plugin.
- Authoring geometry preview: immutable generated meshes and visual instances, with the same
  constructor as execution; it keeps identity and revision and frees the previous version after
  generating the new one. Confirming the source is a transaction, and what can be undone stays in
  a component or revisioned source. Runtime can publish resident chunks without a file and save
  on explicit request. Lifetimes: [terrain](references/terrain.md),
  [host](../mirai-core/references/host.md) and [preview](../mirai-editor/references/extensions.md).
- When changing a first-party plugin, update the demo project if it uses it.
- The authoring and control API expresses intent with names and defaults. Resolve handles and
  indices inside the plugin, separate influence goals from activation, and publish solver details
  only through optional inspection (example: [animation](../mirai-animation/SKILL.md)).
- AI over the network: the minds decide on the server.
- Navigation: automatic navmesh by tiles from the collision.
- Far-away simulation: automatic coarse simulation through the portal graph.
- Water: Gerstner waves.

## Verification

- Types: `mirai check plugins/<n>/runtime` and `plugins/<n>/editor` of those affected. Editor
  parts need `-collection:plugins=<root>/plugins`.
- World: `mirai generate <project that enables the plugin>`, and build and run that project.
- Tests: `mirai test plugins/<n>/runtime` or `.../editor` with the cases of the Verification
  section of the area's reference (see Map); `--release` only if a failure may depend on optimization.
- GPU: terrain uses `-define:TERRAIN_GPU=true`; skinning and render plugins, graphics validation.
- Discovery, order or validation of manifests:
  [project verification](../mirai-projects/SKILL.md#verification). Editor tools:
  [mirai-editor](../mirai-editor/SKILL.md#verification).
- Before declaring a method available, generate and build the demo editor and check it with
  `engine.describe`.
- Direct gestures (clicks on surfaces, drags) are tested by the user; the rest, by API and
  captures.
