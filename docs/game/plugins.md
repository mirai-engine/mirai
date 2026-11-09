---
name: plugins
description: Write a plugin in a game project (runtime and editor parts, plugin.mirai manifest).
  Use for plugins/, dependencies, Create cards, bridges, development tools, plugins from git.
---

# Writing a plugin in a project

A plugin is a folder `plugins/<name>/` with libraries joined to the project world like `game/`;
use one for a reusable feature with its own data and editor tools, otherwise `game/`.

## Map

- New plugin, manifest, turning it on, components and requests: [recipe 1](#1-runtime-part).
- Own editor entries (Create cards, tools, panels, inspector):
  [editor-part.md](plugins/editor-part.md).
- Bridge between two plugins, tool for making the game, engine range: [recipe 2](#2-manifest-flags).
- From git or the catalog: `mirai plugin add <url|name>`, `list`, `catalog`, `update`, `remove`.
  What a plugin offers: its public package and `mirai rpc --project . describe <plugin>`.
- Replicated data: [networking](networking.md). Assets:
  [assets](assets.md).

Layout: `plugin.mirai`, `runtime/`, `editor/`, `shaders/`, `assets/`; a part exists only if
`parts` names it (`Runtime`, `Editor`, `Shaders`, `Assets`) and its folder exists. Each subfolder
with `.odin` sources (not `_test.odin`) is another package. `assets/` mounts under
`plugins/<name>/` and all of it ships.

## 1. Runtime part
`plugins/heal/plugin.mirai`, then add `"heal"` to `plugins` in `project.mirai`:
```json
{"name": "heal", "version": "0.1.0", "dependencies": [], "parts": ["Runtime"]}
```

`plugins/heal/runtime/heal.odin` is `package heal`: the plugin owns its data and takes
[requests](core/wiring.md#request-ask-the-library-that-owns-the-data), here a `Heal_Requests` queue
storage and a proc `heal`.

The game does `import heal "project:plugins/heal/runtime"` and, in a `@(step="fixed")` taking
`^heal.Heal_Requests`, calls `heal.heal(requests, target, 25)`. Components show in the inspector
and scenes by reflection. Check: `mirai generate`, `mirai check plugins/heal/runtime`.

## 2. Manifest flags

- `"automatic": true`: needs `dependencies`; active when all are, no project names it.
- `"development": true`: only in the editor and Play; a shipped game using it fails to build.
- `"engine": {"min": "0.1", "max": "0.1"}`: engine versions it works with; an empty end is open.

## Pitfalls

- A plugin not in `plugins` is inactive; its components in a scene are skipped without failing.
- A plugin imports only itself, its `dependencies` and theirs; others are rejected.
- A component declared in `editor/` lives in the editor world and is gone in Play.
- A library step runs in the `game` loop; `loops="game editor"` adds the editor.
