# Hierarchy, prefabs and spawning

A prefab is a `.prefab` asset ([assets](../assets.md)). Code names it by its path in the assets,
as the file is spelled (`"pets/Dog.prefab"`); a field of data (`Spawn_Point.prefab`) holds its
`base.Asset_Id`. Every prefab of the project ships, whether a scene names it or not.

## Spawn and forget

```odin
import "mirai:engine/scene"

@(step="fixed")
game_burst :: proc(impacts:core.Read(Impact),spawner:scene.Spawner) {
    for row in 0..<core.count(impacts) {
        at:=core.at(impacts,row).point
        scene.spawn(spawner,"arena/Burst.prefab",{position=at},transient=true)
    }
}
```

The third argument is the `core.Transform{position, rotation, scale}` of the root; a zero rotation
is none and a zero scale is 1. `parent=` hangs the root under an entity. `transient=true`: no `Id`
of its own, for effects and projectiles. The path or the `base.Asset_Id` of a prefab both work.
A spawn that fails returns `core.NONE` and is the problem `scene.spawn` of the parent or of the
world.

## Keep the root

`scene.spawn` gives the root, to give the new entity components:

```odin
@(step="fixed",server)
game_dogs :: proc(spawner:scene.Spawner,owners:core.Read(Owner)) {
    for row in 0..<core.count(owners) {
        dog:=scene.spawn(spawner,"pets/Dog.prefab",{position=core.at(owners,row).home})
        if dog!=core.NONE {
            core.commands_add(spawner.commands,dog,Follow{leader=core.entity_at(owners,row)})
        }
    }
}
```

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
// hierarchy:core.Ref(core.Hierarchy)
for c:=core.first_child(hierarchy,e);c!=core.NONE;c=core.next_sibling(hierarchy,c) {...}
```

- Whole subtree, parents before children:
  `for at:=root;at!=core.NONE;at=core.subtree_next(hierarchy,root,at) {...}`.
- Destroy an entity and what hangs from it: `core.destroy_tree(es,hierarchy,e)` with
  `es:^core.Entities`.
- Upward: `core.ancestor_with(parents,table,e)` and `core.is_under(parents,e,ancestor)`, with
  `parents:core.Read(core.Parent)`.

## Pitfalls that fail silently

- The `Hierarchy` shows a `Parent` only after the function that wrote it ends.
