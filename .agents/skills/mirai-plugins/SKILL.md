---
name: mirai-plugins
description: The Mirai plugin system - manifests (`plugin.mirai`), the runtime and editor parts,
  dependencies and order, plugins from git and the catalog (`cook/install`, `mirai plugin`) - and
  the tool, physics add-on and renderer plugins `paint`, `physics_cache`, `ragdoll`, `playtest`,
  `previews`, `profiler`, `tracy`, `ui_inspector`, `prompts_kenney`, `decals`, `deform`,
  `monitors`, `portals`, `mirror`, `fog`, `fsr` and `lens`.
  Use when creating, changing, splitting, installing or publishing a plugin, when a plugin must
  extend the engine or integrate with the project world, or when working on one of those plugins.
  The plugins of terrain, vegetation, water, particles, navigation and AI are in `mirai-world`.
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
- World content (`terrain`, `foliage`, `water`, `imprint`, `vfx`, `navigation`, `behavior`,
  `shapes` and their bridges): [mirai-world](../mirai-world/SKILL.md)
- `paint` (vertex color brush, `paint.*`): [plugins.md#paint](references/plugins.md#paint)
- `previews` (animation documents, animation and skeleton thumbnails; `animation.capture`):
  [animation document](references/previews.md#animation-document),
  [thumbnails](references/previews.md#animation-thumbnails),
  [capture](references/previews.md#animation-capture) and
  [sound documents](references/previews.md#sound-documents)
- `animation_physics` (automatic bridge: the mode, velocity and request of each `Character` feed
  the motion matching of its `Animation`):
  [locomotion](../mirai-animation/references/animation.md#locomotion-by-motion-matching)
- `unreal` and its `unreal_*` bridges (import Unreal packages and maps in the editor) are not part
  of the engine: they are installed from the catalog (`mirai plugin add unreal`); code and
  documentation in <https://github.com/tomaszbk/mirai-unreal>
- `streaming` (loading of `Spatial` sections by proximity and what crosses sections):
  [libraries](../mirai-gameplay/references/libraries.md#plugin-streaming)
- `physics_cache` (portable recording, `Geometry_Playback`):
  [recording](references/physics-cache.md#recording),
  [relation with animation](references/physics-cache.md#relation-with-animation) and
  [playback](references/physics-cache.md#playback)
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
- `animation` (clips, motion matching, rigs, morphs, actions, authoring and its API):
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
- When changing a first-party plugin, update the demo project if it uses it.
- The authoring and control API expresses intent with names and defaults. Resolve handles and
  indices inside the plugin, separate influence goals from activation, and publish solver details
  only through optional inspection (example: [animation](../mirai-animation/SKILL.md)).

## Verification

- Types: `mirai check plugins/<n>/runtime` and `plugins/<n>/editor` of those affected. Editor
  parts need `-collection:plugins=<root>/plugins`.
- World: `mirai generate <project that enables the plugin>`, and build and run that project.
- Tests: `mirai test plugins/<n>/runtime` or `.../editor` with the cases of the Verification
  section of the area's reference (see Map); `--release` only if a failure may depend on
  optimization.
- GPU: skinning and render plugins, graphics validation.
- Discovery, order or validation of manifests:
  [project verification](../mirai-projects/SKILL.md#verification). Editor tools:
  [mirai-editor](../mirai-editor/SKILL.md#verification).
- Before declaring a method available, generate and build the demo editor and check it with
  `engine.describe`.
- Direct gestures (clicks on surfaces, drags) are tested by the user; the rest, by API and
  captures.
