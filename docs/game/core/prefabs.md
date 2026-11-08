# Hierarchy, prefabs and spawning

A prefab is a `.prefab` asset ([assets](../assets.md)). Code names it by its path in the assets,
as the file is spelled (`"prefabs/Dog.prefab"`); a field of data (`Spawn_Point.prefab`) holds its
`base.Asset_Id`. Every prefab of the project ships, whether a scene names it or not.

## Spawn and forget

```odin
import "mirai:engine/scene"

@(step="fixed")
game_burst :: proc(impacts:core.Read(Impact),spawns:^scene.Spawns) {
    for row in 0..<core.count(impacts) {
        at:=core.at(impacts,row).point
        scene.request_spawn(spawns,"prefabs/Burst.prefab",{position=at},transient=true)
    }
}
```

The third argument is the `core.Transform{position, rotation, scale}` of the root; a zero rotation
is none and a zero scale is 1. `parent=` hangs the root under an entity. `transient=true`: no `Id`
of its own, for effects and projectiles. A spawn that fails is the problem `scene.spawn` of the
parent or of the world.

## Spawn and keep the root

To give the new entity components, receive a `scene.Spawner`:

```odin
@(step="fixed",server)
game_dogs :: proc(spawner:scene.Spawner,owners:core.Read(Owner)) {
    for row in 0..<core.count(owners) {
        dog:=scene.spawn(spawner,"prefabs/Dog.prefab",{position=core.at(owners,row).home})
        if dog!=core.NONE {
            core.commands_add(spawner.commands,dog,Follow{leader=core.entity_at(owners,row)})
        }
    }
}
```

- `scene.spawn` returns `core.NONE` when it fails, and that is the problem `scene.spawn`.
- The rows appear when the function ends. `core.commands_add` gives only a component the root
  lacks; for one the prefab already has, `core.commands_added(spawner.commands,e,Follow)` returns
  the row to finish. Put a component in the prefab when it is always there.
- Create without a prefab: `core.commands_create(commands)`, then `commands_add` (or
  `commands_add_default`, the row of the component at its default) for
  `core.Transform`, `core.Parent{entity=parent}` and the rest.
- Players' bodies are not spawned by code: a `Spawn_Point` and `Spawn_Settings`
  ([character](../character.md)).

## Hierarchy

`core.Transform` is local to the `core.Parent`; `core.World_Transform` (`position`, `rotation`)
is the result, read with `core.Read(core.World_Transform)`. Never keep your own child list.

```odin
@(step="fixed")
game_glow :: proc(hierarchy:core.Ref(core.Hierarchy),names:core.Read(core.Name),
                  lamps:core.Read(Lamp),tints:^core.Table(render.Tint)) {
    for row in 0..<core.count(lamps) {
        lamp:=core.entity_at(lamps,row)
        for c:=core.first_child(hierarchy,lamp);c!=core.NONE;c=core.next_sibling(hierarchy,c) {
            if core.name_get(names,c)!="Globe" {continue}
            if tint:=core.get(tints,c);tint!=nil {tint.emission=core.at(lamps,row).glow}
        }
    }
}
```

- Whole subtree, parents before children:
  `for at:=root;at!=core.NONE;at=core.subtree_next(hierarchy,root,at) {...}`.
- Destroy an entity and what hangs from it: `core.destroy_tree(es,hierarchy,e)` with
  `es:^core.Entities`.
- Upward: `core.ancestor_with(parents,table,e)` and `core.is_under(parents,e,ancestor)`, with
  `parents:core.Read(core.Parent)`.

## Pitfalls that fail silently

- `scene.Spawns` gives no handle: the root exists next tick. Use `scene.spawn` to keep it.
- The `Hierarchy` shows a `Parent` only after the function that wrote it ends.
- A path is the file's, spelled the same, with its capitals and spaces.
- A spawned entity does not exist in this function's tables: do not `core.get` it in the same
  function that spawned it.
