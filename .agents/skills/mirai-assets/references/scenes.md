# Scene

Tables (`asset/scene.odin`): `entities` (id, parent, sibling order and name), one per component
type with the component's name, `scene` (`Scene_Info`), those of instances if there are prefabs,
`off`. The other tables are kept as they are.

- `entities`: columns `id` (`Entity_Id`, the key), `parent` (`Entity_Id`, 0 without a parent),
  `order` (`u32`, order among siblings) and `name` (`[64]u8`, text).
- One table per component type, with the component's name (`name_hash` identifies it): column
  `entity` (`u32`, row of `entities`, increasing) and column `value` (the data; size zero for a
  tag). With the same layout it is loaded by block copy.
- `scene` (`Scene_Info`: the id counter) and, if it places prefabs, the two component tables of
  its instances and `overrides`.
- `off`, if some component is turned off by itself: a `Component_Off {entity, component}` (the
  entity's Id and the component's `name_hash`) for each one. Without the table, everything is on;
  turning off a whole entity is its `Disabled` component.
- What governs a whole scene (its sky, its sun, its rules) are components of its entities. A
  one-row table (`Single`) with a single `value` column is a scene setting from an earlier version
  of the format: nothing reads it and saving the document discards it (`scene_lone_value`).
- The other tables are kept as they are.

`asset.Scene` is the editable document, independent of the data world:

- `Scene.stamp` is the hash of the content of the file it was read from or last written to (0:
  none).
- If the file stores a component with another layout, `scene_get` migrates on reading and
  `scene_set` writes in the file's layout.
- Removing a component or an entity forgets that it was off; `engine/scene` loads the off ones off
  and saves them as they are in the world.
- `scene_view` is the copy-free read for loading: it validates rows in range and ordered;
  `scene_view_check` also checks unique ids, existing parents and no cycles.

## Prefab

A prefab is a scene with **exactly one root**: no kind, extension or table of its own. The same
file is loaded whole, hangs under a `Scene_Reference` as a section, or is placed as a copy: a
linked instance in a document, or a spawned copy in a running world
([running scenes](../../mirai-gameplay/references/libraries.md#scene)). Only a copy needs the one
root, which is what it is placed by.

- `Header_Flag.One_Root` in the header of the file says it. `document_write` derives it from the
  `parent` column of the entities on every write, whoever writes (a `Scene`, `mirai asset set`,
  `pack`, a merge), and `scene_view` fails with `Corrupt` on a header that disagrees with its
  entities: the flag cannot differ from the document.
- `registry_prefab(file)` answers from the header the registry read, for a file on disk and for one
  held in memory alike, so a browser tells a prefab from a scene without opening files;
  `asset_prefab(a)` asks an open asset, `scene_roots` and `prefab_root` a `Scene`.
- A scene that gains a second root is no prefab from its next write: a resolver takes it as a
  missing prefab and its instances stay as they are, until it has one root again.

## Prefab instances

The document stores each entity with its effective values, so a scene loads without its prefabs.
An instance (`asset/prefab.odin`) is two components of its entities, saved and merged as any
other: `Prefab_Instance` on its root (the prefab, and the `stamp` of that prefab as it was last
updated against it, [as resolved](#resolution-against-the-current-prefab); 0: unknown) and
`Prefab_Member` on every entity
it placed, the root among them (the root, and `source`, the entity of the prefab it stands for).
What it fixed on its own are its `Override`s, a table of the file.

- `asset.Prefab_Instance` and `asset.Prefab_Member` are declared once, as `@(component)`s of
  `asset`, which the world generator reads beside `core` and `engine`: a document and a world hold
  the same two types (`scene.Prefab_Instance` and `scene.Prefab_Member` are their names in
  `engine/scene`). `source` is a plain number: an `Entity_Id` field would be taken for a reference
  into this document and remapped or emptied with it.
- The root of a copy spawned while the world runs has `Prefab_Instance` too, with stamp 0 and no
  `Prefab_Member`: it says what prefab the entity is of and is linked to nothing. No document holds
  it (`scene.capture` leaves out a `Prefab_Instance` whose entity is not a member of itself), and a
  saved game holds no instances at all.

- `scene_instantiate` copies the prefab's entities with new ids, points their internal references
  to the copies and empties those that pointed outside.
- An override fixes something of a member; the fixed value is the one the entity has in its table.
  `Field` fixes the part of the component that the path names (`""` is all; fixing a part replaces
  the overrides of what it contains); `Added` and `Removed`, its presence; `Turned`, whether it is
  off. `component` 0 with path `"name"` is the entity's name.
- `Child` (`component` 0, no path) is an entity the instance put under a member, with what hangs
  from it; it is not a member, and the instances placed among them belong to the document. It is
  the only hierarchy change of an instance: a member neither changes place nor is missing, and is
  turned off with `Disabled` (an `Added`) to leave it out.
- `scene_instance_update`: the members follow the prefab (additions, removals, parent, order, name
  and components) except what an override names, and the `stamp` becomes the prefab's. The parent,
  the order and the root's placement (`INSTANCE_PLACEMENT`) belong to the instance; a member whose
  origin is no longer in the prefab is removed with what the instance added under it.
  - Marking compares leaf by leaf with the base (`value_leaves`, `overrides_mark`) and following
    copies what is marked onto the new base (`override_keep`), in `asset/overrides.odin`; the
    layers of an [imported material](kinds.md#what-was-imported-and-what-was-changed) use the same
    functions.
- A document holds the instances it placed, not those its prefabs place: the entities of a prefab
  inside a prefab are members of the outer instance, and what the outer prefab fixed of them is in
  its own file. `scene_instance_unlink` with the prefab gives them back as instances of the
  document, each member by its `source`, with the overrides the prefab held of them.
- A member a prefab gains gets an Id made of the Id of the root and its `source`: the same in
  every load, cook and editor that updates the instance.
- `scene_overrides_derive` finds the overrides of the instances of a document by comparing their
  members with a base, and `scene_overrides_apply` writes some into a prefab. A file keeps the
  overrides for the load that finds the prefab changed; the editor derives them when it saves
  ([overrides](../../mirai-editor/references/prefabs.md#overrides)).
- The editor's Apply and Revert of an added entity: `scene_child_apply` writes it into the prefab
  with what hangs from it (instances placed among them included) and makes it a member;
  `scene_child_revert` deletes it with what hangs from it.

## Resolution against the current prefab

The stamp of a prefab is its content hash **as resolved**: the hash of its file while nothing it
places is stale, and otherwise the hash of the file a save of it resolved would write. An instance
is stale when its `stamp` is not that one. Every end computes the same stamp from the same files,
so an instance brought up to date is up to date for the editor, the cook and a load alike, whether
or not its prefab was saved again, and saving that prefab as it resolves gives the same stamp.

- `Prefab_Resolver` reads each prefab once through `Prefab_Files`, which opens them for as long as
  needed: `Registry_Prefabs` reads them from a registry; `engine/scene`, from `host`'s cache.
- `resolver_check` looks only at the `Prefab_Instance` table of a prefab whose instances are up to
  date (`Current`); one that places a stale instance (`Stale`) is resolved then, and its stamp is
  that of what it resolves to. `Checking` is a prefab that contains itself. An instance of a
  missing prefab, or of a scene that no longer has one root, stays as it is.
- `scene_resolve` updates each stale instance of a document and gives it the stamp of its prefab
  as resolved: resolved again with the same files, nothing is stale.
- It is used by `engine/scene` on loading
  ([running scenes](../../mirai-gameplay/references/libraries.md#scene)), cooking
  ([cooking](../../mirai-projects/references/build.md#asset-cooking)) and the editor on
  reading a prefab ([prefabs](../../mirai-editor/references/prefabs.md)).
