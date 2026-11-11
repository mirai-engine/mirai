---
name: mirai-world
description: Mirai world content plugins - `terrain` (heightfield and volume terrain, chunks,
  material layers, digging, dust, the ground contract, with the `terrain_debris` pieces), `foliage`
  (cells, impostors, wind, collision, ground), `water` (waves, caustics, foam, wakes), `imprint`
  (footprints in snow, mud and sand), `vfx` (GPU particles, `.particle` effects, births by channel,
  grids and volumes), `navigation` (automatic navmesh, links, agents), `behavior` (AI minds, smart
  objects, perception, influence maps) and `shapes` (editable solids of a polygon and brush
  entities, and splines of roads, paths and rivers). Use when sculpting or painting terrain,
  scattering vegetation, making water, snow or particles, making enemies and NPCs walk and decide,
  or changing any of those plugins.
---

# Mirai world

The plugins that fill a scene: the ground, what grows on it, water and effects, and the agents that
walk and think in it. They are ordinary plugins, with a `runtime/` and an `editor/` part and the
rules of [the plugin system](../mirai-plugins/SKILL.md). Layout, manifests and build:
[projects](../mirai-projects/references/projects.md). What a game writes against them:
[gameplay](../mirai-gameplay/SKILL.md).

## Map

- `vfx` (particles: `.particle` format, emitters and clocks, GPU pools and passes, Vfx programs
  with surfaces, bones, channels and grids, stages, volumes, events to the game):
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
- `vfx` in the editor (GPU effect preview, effects document, `Particle_Emitter` section,
  thumbnails, Particles card, `particle.*` methods):
  [Particle_Emitter section](references/vfx-editor.md#particle_emitter-section),
  [effect preview](references/vfx-editor.md#effect-preview),
  [particle document](references/vfx-editor.md#particle-document) and
  [thumbnails](references/vfx-editor.md#thumbnails)
- `fluids` (plane fluids on a `vfx` grid) is not part of the engine: it is installed from the
  catalog (<https://github.com/tomaszbk/mirai-fluids>); how `water` takes its waves:
  [what physics shows](references/water.md#what-physics-shows).
- `imprint` (snow, mud and sand that keep footprints and furrows: height clipmap on a `vfx` grid,
  stamps, displacement of the ground meshes as seen by rays):
  [the field](references/imprint.md#the-field), [stamps](references/imprint.md#stamps),
  [what is drawn](references/imprint.md#what-is-drawn) and [scene](references/imprint.md#scene)
- `water` (the `Fluid`s drawn as water: glass surface, `fog` medium, caustics, foam,
  splashes and wakes from physics): [appearance](references/water.md#appearance),
  [what physics shows](references/water.md#what-physics-shows),
  [sound](references/water.md#sound), [scene](references/water.md#scene) and
  [limits](references/water.md#limits)
- `terrain` (format, chunks, material layers, levels of detail, holes, tool, in-game editing,
  residency): [source and chunks](references/terrain.md#entity-source-and-chunks),
  [volume with heightfield](references/terrain.md#joining-a-volume-with-a-heightfield),
  [format](references/terrain.md#canonical-format),
  [geometry and collision](references/terrain.md#geometry-and-collision),
  [materials and layers](references/terrain.md#materials-and-layers),
  [tool](references/terrain.md#tool), [API](references/terrain.md#api),
  [editing during Play](references/terrain.md#editing-during-play),
  [publishing and residency](references/terrain.md#jobs-publishing-and-residency) and
  [open worlds](references/terrain.md#limits-in-open-worlds)
  - Network edits and the `terrain_multiplayer` bridge: [network](references/terrain.md#network)
  - Material under the surface of a Volume (strata, veins, `terrain.interior`):
    [interior](references/terrain.md#volume-interior)
  - What digging removes (`Terrain_Digs`), the dust and the `terrain_debris` pieces and drops:
    [what digging leaves](references/terrain.md#what-digging-leaves)
  - The ground it gives `core.Ground_Queries` (foliage, navigation):
    [ground](references/terrain.md#ground)
  - Quadtree of a Heightfield and octree of a Volume, far nodes, coarse grid and piece budget:
    [tree](references/terrain.md#tree-and-nodes)
- `foliage` (`.foliage`, cells, generator, overrides and orphans, ground read from
  `core.Ground_Queries`, per-cell batches, types from prefabs, octahedral impostors and canopy in
  rays, wind by variants and by hook, bending by `Foliage_Bender`, collision by resident cells,
  brush and instance selection): [source](references/foliage.md#entity-and-source),
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
- The library under navigation and minds (A*, tiled navmesh, avoidance, the `Mind` loop and its
  actions): [minds](../mirai-std/references/ai.md#decisions-minds-mindodin) and
  [navigation](../mirai-std/references/ai.md#navigation) of `std/ai`
- `shapes` (editable solids of a polygon and brush entities saved as source, stamps and vertex
  edits, bevels of the rims of a polygon, the derived child with mesh and collider, static or
  dynamic; the ribbons of roads along a `volume.Spline` with a material; the
  Shapes tool and `shapes.*`):
  [source and derived](references/shapes.md#source-and-derived),
  [static and dynamic](references/shapes.md#static-and-dynamic),
  [splines](references/shapes.md#splines),
  [editing](references/shapes.md#editing) and [Shapes tool](references/shapes.md#shapes-tool)
- Using them from a game (volumes, mining and dig-and-break games, the demo):
  [gameplay](../mirai-gameplay/SKILL.md)

## Workflow

1. Open only the sections the Map names for the plugin.
2. Enable the plugin in `plugins` of `project.mirai`; its dependencies are enabled automatically and
   come earlier in the order.
3. Change its `runtime/` and `editor/` parts as
   [the plugin system](../mirai-plugins/SKILL.md#workflow) says, and update the demo project if it
   uses the plugin.
4. Generate the world and build and run the project that enables it ([verification](#verification)).

## Invariants

- The invariants of every plugin (single writer of its data, names prefixed with the plugin, an
  API that expresses intent) are in [the plugin system](../mirai-plugins/SKILL.md#invariants).
- Authoring geometry preview: immutable generated meshes and visual instances, with the same
  constructor as execution; it keeps identity and revision and frees the previous version after
  generating the new one. Confirming the source is a transaction, and what can be undone stays in
  a component or revisioned source. Runtime can publish resident chunks without a file and save
  on explicit request. Lifetimes: [terrain](references/terrain.md),
  [host](../mirai-core/references/host.md) and [preview](../mirai-editor/references/extensions.md).
- Terrain: two representations, Heightfield and Volume, and no third; a brush is an intent
  (`Brush_Kind`) that both take, and what is wrong with it is an error that says the fix.
- Content plugins meet each other through the `core` contracts, never through a bridge plugin:
  the ground (`core.Ground_Queries`, which terrain gives) and births of effects (`core.Births`,
  which vfx takes).
- AI over the network: the minds decide on the server.
- Navigation: automatic navmesh by tiles from the collision.
- Far-away simulation: automatic coarse simulation through the portal graph.
- Water: Gerstner waves.

## Verification

- Types: `mirai check plugins/<n>/runtime` and `plugins/<n>/editor` of those affected. Editor
  parts need `-collection:plugins=<root>/plugins`.
- World: `mirai generate <project that enables the plugin>`, and build and run that project.
- Tests: `mirai test plugins/<n>/runtime` or `.../editor` with the cases of the Verification
  section of the plugin's reference: [terrain](references/terrain.md#verification),
  [foliage](references/foliage.md#verification),
  [navigation](references/navigation.md#verification),
  [behavior](references/behavior.md#verification), [vfx](references/vfx.md#verification),
  [vfx in the editor](references/vfx-editor.md#verification),
  [water](references/water.md#verification), [imprint](references/imprint.md#verification) and
  [shapes](references/shapes.md#verification); `--release` only if a failure may depend on
  optimization.
- GPU: terrain uses `-define:TERRAIN_GPU=true`; the plugins that draw with shaders of their own,
  graphics validation.
- Before declaring a method available, generate and build the demo editor and check it with
  `engine.describe`. Discovery, order or validation of manifests:
  [project verification](../mirai-projects/SKILL.md#verification). Editor tools:
  [mirai-editor](../mirai-editor/SKILL.md#verification).
- Direct gestures (clicks on surfaces, drags, brushes) are tested by the user; the rest, by API and
  captures.
