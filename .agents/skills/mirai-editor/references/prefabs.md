# Linked prefabs

Code: `prefabs.odin`, `api_prefab.odin`.

- A prefab is a scene with exactly one root
  ([what makes one](../../mirai-assets/references/scenes.md#prefab)): the same `.scene` file as any
  other, which the registry knows as a prefab from its header. The editor tells them apart by that
  alone: `shown_kind` gives `SHOWN_PREFAB` for it, which is the color, icon and filter of the
  content browser, what a field of prefabs lists (a name with `prefab`, or the tag `kind=prefab`)
  and what a drag carries; `asset.list` says `prefab` of each scene. It is no second kind: a scene
  saved with another number of roots is shown as a scene from then on.
- An **instance** is a subtree of the document linked to a prefab; its entities (the **members**)
  have the effective values in the `World`. A scene with several roots is not instantiated
  (`Not_One_Root`, with the fix): it hangs from a `Scene_Reference`.
- An instance is two components of its entities
  ([format](../../mirai-assets/references/scenes.md#prefab-instances)): `scene.Prefab_Instance` on
  its root (the prefab and its stamp when the instance was last brought up to date with it) and
  `scene.Prefab_Member` on every entity it placed, the root among them (the root and the entity of
  the prefab it stands for). They are rows like any other: the history, a shared session, the
  recovery log, a Play copy and a save carry them with no code of their own. Both are hidden from
  the inspector and from the documents of `scene.write` and `mirai scene`, which name the prefab.
- The instance of an entity is a table lookup (`prefab_link_of`); its members are found by walking
  the subtree of its root (`prefab_members`), which the [member lock](#hierarchy-of-an-instance)
  guarantees.

## Operations

An operation works on **one instance**: it captures the entities under its root as a document
(`prefab_work_begin`), changes it with the `asset` procedures and writes it back onto the same
entities (`prefab_work_put`, with `scene.update`), inside **one** gesture whose step holds the rows
that changed. Entities outside the instance are not touched and the members that stay keep their
handles. All require `Edit`.

- A prefab file an operation writes (Create, Create variant, Apply) stays **unsaved** in the memory
  of the registry, as any asset an edit changes, and is part of the step: undo and redo give its
  bytes back ([files in the history](document.md#edits-and-undo)). Save writes it. A step that
  wrote a prefab file undoes only in order.
- A prefab, and the scene opened as the document, are read through the registry, as is what the
  prefab names: an unsaved one looks as in the scene.
- A prefab is read with its own instances up to date with their prefabs (`prefab_scene_load`, by
  the [resolver](../../mirai-assets/references/scenes.md#resolution-against-the-current-prefab)):
  what is applied, the base and what `prefab.inspect` shows start from it. Its components take the
  layout the program gives them, and a field its file does not keep takes what loading gives it
  (the component's default): such a field is not an override until the instance changes it, and
  every file an apply writes keeps every field of the components.
- Opening a document brings its stale instances up to date before the `World` takes them
  (`scene_load_file`): no step holds that, and the document is not dirty.

Procedures, with their action and API method:

- `prefab_create` (`Prefab_Create`, `prefab.create`) makes the subtree a new prefab in `assets/`,
  without overwriting, and links it as the first instance; the root stays at the origin, without
  rotation and with its scale. The instances inside the subtree become the prefab's own: the
  document keeps only the new one. `prefab_create_entities` (from Details, Edit or the Scene menu)
  reduces the selection to its roots and, with several, creates a group that keeps their world
  poses; grouping, link and file are one step. The action creates `<name of the active entity>`
  beside the scene and is disabled if one of the roots is an internal member of an instance.
- `prefab_instantiate` (drag to the viewport, placement from Assets, `prefab.instantiate`) places
  an instance with new ids and returns the root. `scene.write` places the prefab a new entity
  names with it too, `joined` to the gesture of the write, whose step holds the instance.
- `prefab_apply` (`Prefab_Apply`, `prefab.apply`) writes the entity's overrides into its prefab,
  ends them and updates all instances: first the added entities (they pass to the prefab with what
  hangs from them and remain as members), then values and components. The prefabs that place the
  one that changed, found through the dependencies of the registry, are brought up to date and
  written too, unsaved. With `target` `Base` (`Prefab_Apply_Base`) it continues to the base of a
  [variant](#variants).
- `prefab_variant_create` (`prefab.variant.create`, Create variant in the menu of a prefab in
  Assets) writes a [variant](#variants).
- `prefab_revert` (`Prefab_Revert`, `prefab.revert`) forgets the overrides and gives back what the
  prefab has; what was added is deleted.
- `prefab_unlink` (`Prefab_Unlink`, `prefab.unlink`): the members become ordinary entities, and the
  instances its prefab places are given back as instances of the document; with `recursive`, those
  are unlinked too.
- `prefab_refresh` (`prefab.refresh`) updates the instances of a prefab, or of all, with its file,
  as one step. The editor runs it on showing a document that has stale instances; a scene loaded by
  the game is resolved by itself
  ([loading](../../mirai-gameplay/references/libraries.md#scene)).
- `paths` are comma-separated names (`name`, `Component`, `Component.field` or `child`); without
  them, all the entity's overrides. The entity of apply and revert is a member or an added entity
  (its `child` override); `all_members` is for root actions. Apply and Revert require a member with
  overrides or an added entity; Unlink, an entity of an instance.

Details:

- Create prefab for an unlinked or multiple selection.
- The linked root shows colored icon and name; double click on the icon opens its prefab. The
  header has four compact actions: Save variant, Apply changes, Unlink and Revert all. Save variant
  asks for a name and saves the instance, with what it changes, as a new variant of its prefab
  beside it (Create prefab on the linked root), which becomes its prefab. Apply changes and Revert
  all process all the members in one transaction and keep the root's placement. The root of a
  variant's instance adds Apply to base and, below the header, "Variant of" with the base's name.
- A member shows its icon in the prefab's color and Revert entity changes, which restores only that
  entity; Go to root, in the Hierarchy card, selects the root.
- No override counter. The name of each action appears on hover, also when disabled.

Instance selection (viewport, Scene and Find): from outside the instance, a click on a member
selects the root and the double click, the member; if any selected entity already belongs to that
instance, a click chooses the member.

## Prefab document

- Double click in Assets or on an instance's icon opens it in a tab (`file_open_path`); the scene
  and its changes stay in its own. It is edited with the common tools, saved to the same `.scene`
  keeping identity, has its own history and closing asks about the changes.
- A tab is a prefab's when its file had one root as the tab opened it (`Document.prefab`), and
  stays so while it lives: it opens beside the scene instead of taking its tab, with the prefab
  icon, the variants and the preview sunlight.
- It is a scene as any other: it takes a second root, sections and Play. No rule keeps its one
  root; saved with several while other files place it, the editor says that it is no prefab until
  it has one again, and its instances stay as they are.
- Preview sunlight is a preview sun active on opening, with a neutral environment and grid: it only
  changes the renderer, never entities, assets, bounds, selection or history, and on returning to
  the scene its lighting is restored. It is the studio light (`studio_lighting`), which a scene
  turns on as an option of its viewport ([studio light](panels.md#studio-light)).

## Overrides

- An override is what an instance has different from its **base**: the prefab as the instance was
  last updated. Its types are `field` (`Component.field` or `name`), `added`, `removed`, `turned`
  and `child` (an entity added under a member).
- Overrides are **not kept** in the editor: they are derived by comparing the members with the
  base (`asset.scene_overrides_derive`) when something asks: the actions and `prefab.inspect` of
  the selected instance (`prefab_overrides_of`, derived again when the history, the bases or the
  edits of other editors moved), Apply, Revert, Refresh and Save, which writes them into the file
  for the load that finds the prefab changed.
- The bases are kept by prefab and stamp (`Prefabs.bases`) while an instance of the `World` or a
  step of the history is at that stamp. An instance whose base this editor does not hold and whose
  file is another by now (the rows of another editor arrived before the file, a file changed
  outside) reads as stale and derives nothing; refreshing it keeps everything it has that the
  prefab does not give.
- A member turned off is an `added` of `Disabled`: so an instance leaves out a part of its prefab
  without deleting it.
- The `Transform` of an instance's root is its placement: it is never an override and is kept on
  applying, reverting or updating. The children's transforms are compared.
- A **stale** instance (`stale`) is not at the stamp its prefab gives now
  ([as resolved](../../mirai-assets/references/scenes.md#resolution-against-the-current-prefab),
  asked of the files once for each state of the registry: `prefab_stamp`): its file changed, or
  the file of a prefab it places did. `prefab.refresh` brings it up to date, the members follow
  the prefab except in their overrides, and nothing is stale after it, whether or not the prefabs
  that place the one that changed were saved again.
- A node the prefab no longer has is deleted in each instance on updating it, even if it has
  overrides, with the entities added under it; what other entities pointed to, to it or to what
  hung from it, ends up pointing to none.
- A prefab whose file is missing counts as `missing` and its instance stays as it was, with the
  overrides its file stored.
- The revert arrows are in [inspector](inspector.md#reversion-and-review).

## Hierarchy of an instance

- Anything created, placed, pasted or moved under an entity of an instance stays as an added
  entity. A copy of a member whose root was not copied with it is one too; a copy of a root is
  another instance.
- A member that is not the root (`prefab_member_locked`) keeps the place the prefab gives it: it is
  not deleted, does not change parent, nor is it the root of a new prefab. It is turned off to
  leave it out of the instance and is duplicated (the copy is an added entity). Deleting a
  selection leaves it with a notice; by API, `scene.delete` and the `parent` of `scene.set` fail
  with a message that says what to do. To change its place, edit the prefab or unlink the instance.
- The root moves, deletes and duplicates as an instance.

## Nested prefabs

- A document holds only the instances it placed. The entities of an instance a prefab places are
  members of the outer instance; that inner instance lives in the file of the prefab, and is read
  from it through the `source` of each member: when Unlink gives it back, and for the `links` of
  `prefab.inspect` (`prefab_chain`), which name the instance that placed an entity and then each
  one inside it that the entity is of. The inspector shows the instance of the document: a crate
  inside a placed shelf is a member of the shelf.
- `prefab_apply` propagates outward: it updates and writes, unsaved, the prefabs that place the one
  that changed.
- A prefab that contains the open document cannot be placed (`Cycle`).

## Variants

A variant is a common prefab whose root is the root of an instance of another prefab, its
**base**: with no new format or fields, it is a prefab that places another at its root.

- `asset.prefab_variant_base` recognizes it by its root; `prefab.inspect` with `path` or `asset`
  gives its `base` and the chain of bases. A variant of a variant is the same one level further
  out.
- What the variant changes from its base are the overrides of that instance: when the base changes,
  the resolver brings it up to date on reading the variant and the variant keeps its own.
- Creating a variant writes a prefab with an instance of the base at the origin, without overrides,
  unsaved and as an undo step; it places nothing in the document. From Assets it is called
  `<base>_variant`, beside the base, numbered if it exists.
- In an instance of a variant, Apply writes into the variant, the nearest prefab. Apply to base
  writes first into the variant and then passes to the base the overrides of the variant's root
  instance that the selection changed, with the same procedure; the variant keeps its other
  overrides and the base propagates to all its variants. What the instance changed of an entity the
  variant added stays in the variant. `target` `Base` on something that is not a variant fails with
  `Not_Variant`.
- In a variant's document, its root is an instance of the base: double click on its icon opens the
  base and Apply changes writes into it.
- A prefab document's bar has a menu with its family (the first base and its variants, each under
  its own) that opens the chosen one, and Create variant, which asks for a name, writes a variant
  of the open prefab beside it and opens it.

## Errors

- If the migration of a component cannot be prepared, the inspector does not publish an incomplete
  default; Apply rejects before writing the prefab and the document's capture rejects saving.
  Without memory the migration gives `Out_Of_Memory`; with an invalid schema, `Rejected`.
- The errors are `Prefab_Error`. By API, those of an entity, path, id or instance that do not exist
  (`Unknown_Entity`, `No_Id`, `Not_Found`, `Unknown_Path`, `Not_Instance`), a scene without
  exactly one root named as a prefab (`Not_One_Root`) and the apply to the base of something that
  is not a variant (`Not_Variant`) are `INVALID_PARAMS`, and the rest,
  `SERVER_ERROR` ([API](../../mirai-agent-api/references/methods.md#prefabs)).
