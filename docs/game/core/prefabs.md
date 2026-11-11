# Hierarchy, prefabs and spawning

A prefab is a `.scene` asset ([assets](../assets.md)) whose kind is Prefab, with exactly one root
entity, placed as a copy of what hangs from that root. Its kind is chosen when it is made (Create
> Prefab, File > New prefab, a prefab made of a selection, `scene.new` with `kind`, `kind` in a
document of `scene.write` or `mirai scene write`) and changed the same way; a prefab opens in the
studio light, so a door needs no sun of its own. Code names it by its path in the
assets, as the file is spelled (`"pets/Dog.scene"`); a field of data (`Spawn_Point.prefab`) holds
its `base.Asset_Id`. Every scene of the project ships, whether another names it or not.

- A scene that is not a prefab is not spawned, whatever its roots: it hangs whole under an entity
  with `scene.Scene_Reference` (a section, loaded with its scene or asked with
  `scene.section_request`). A prefab can hang as a section too.
- A scene a prefab references loads with each copy of it.

## Spawn and forget

```odin
import "mirai:engine/scene"

@(step="fixed")
game_burst :: proc(impacts:^core.Table(Impact,.Read),spawner:scene.Spawner) {
    for row in 0..<core.count(impacts) {
        at:=core.at(impacts,row).point
        scene.spawn(spawner,"arena/Burst.scene",{position=at},transient=true)
    }
}
```

The third argument is the `core.Transform{position, rotation, scale}` of the root; a zero rotation
is none and a zero scale is 1. `parent=` hangs the root under an entity. `transient=true`: no `Id`
of its own, for effects and projectiles. The path or the `base.Asset_Id` of a prefab both work.
A spawn that fails (no such scene, or one that is not a prefab) returns `core.NONE` and is the
problem `scene.spawn` of the parent or of the world, which says what to change. The root of a copy
has `scene.Prefab_Instance`, whose `prefab` is the scene it came from.

A spawn never waits for a file. A prefab the scene names in a field (a `Spawn_Point`'s prefab) is
read with the scene, and its spawn is whole at once. One that is not loaded yet is read in the
background: the root comes at once with its transform, parent and `scene.Prefab_Pending`, and
nothing else, and takes the rest of the prefab a few frames later. What the game gives the root
meanwhile stays, and wins over the prefab's value.

## Keep the root

`scene.spawn` gives the root, to give the new entity components:

```odin
@(step="fixed",server)
game_dogs :: proc(spawner:scene.Spawner,owners:^core.Table(Owner,.Read)) {
    for row in 0..<core.count(owners) {
        dog:=scene.spawn(spawner,"pets/Dog.scene",{position=core.at(owners,row).home})
        if dog!=core.NONE {
            core.commands_add(spawner.commands,dog,Follow{leader=core.entity_at(owners,row)})
        }
    }
}
```

- The rows appear when the function ends. `core.commands_add` gives only a component the root
  lacks; for one the prefab already has, `core.commands_added(spawner.commands,e,Follow)` returns
  the row to finish, or nil for a root that waits for its prefab, to which `commands_add` gives
  it. Put a component in the prefab when it is always there.
- Create without a prefab: `core.commands_create(commands)`, then `commands_add` (or
  `commands_add_default`, the row of the component at its default) for
  `core.Transform`, `core.Parent{entity=parent}` and the rest.

## At spawn points

A `spawn.Spawn_Point` (plugin `spawn`) is a place of the scene where its `prefab` appears. With
`players` on it is one of the players': a player's body appears at the point asked for, or else at
the next one of the players' in turn, of the prefab asked for, or else the point's, or else
`Spawn_Settings.prefab`. While such a prefab is named, each seat gets its body there with no code
([character](../character.md)). With `players` off only the game spawns there, so the point of an
enemy never gives a player its body:

```odin
import spawn "plugins:spawn/runtime"

// An enemy every 10 s, at most 3 alive: Enemy is a component its prefab carries.
@(storage)
Enemy_Clock :: struct {next:u64}

@(step="fixed",server)
enemies_appear :: proc(enemies:^core.Table(Enemy,.Read),requests:^spawn.Spawn_Requests,
    clock:^Enemy_Clock,time:core.Time) {
    if core.count(enemies)>=3 || !core.due(time,clock.next) {return}
    spawn.spawn(requests,core.NONE) // at the next point without players, of its prefab
    clock.next=core.deadline(time,10)
}
```

- `spawn.spawn(requests,core.NONE,path,point)` names a prefab or a point; without them the points
  without players are taken in turn. The copy has its own `core.Id`, so the API names it.
- A client cannot spawn: the server does, and the copy reaches the clients when its prefab
  carries `multiplayer.Replicate`.

## Hierarchy

`core.Transform` is local to the `core.Parent`; `core.World_Transform` (`position`, `rotation`)
is the result, read with `^core.Table(core.World_Transform,.Read)`. Never keep your own child list.

```odin
// hierarchy:core.Ref(core.Hierarchy)
for c:=core.first_child(hierarchy,e);c!=core.NONE;c=core.next_sibling(hierarchy,c) {...}
```

- Whole subtree, parents before children:
  `for at:=root;at!=core.NONE;at=core.subtree_next(hierarchy,root,at) {...}`.
- Destroy an entity and what hangs from it: `core.destroy_tree(commands.entities,hierarchy,e)`
  with `commands:core.Commands`.
- Upward: `core.ancestor_with(parents,table,e)` and `core.is_under(parents,e,ancestor)`, with
  `parents:^core.Table(core.Parent,.Read)`.

## Pitfalls that fail silently

- The `Hierarchy` shows a `Parent` only after the function that wrote it ends.
