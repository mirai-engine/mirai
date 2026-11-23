# Asset types in detail

Each kind lives in `asset/<type>.odin` with `*_document`/`*_save`, `*_view`, and `*_check` (also
run by `mirai asset verify`). Non-obvious contracts per kind:

## Fracture

Defined by `destruct` (`plugins/destruct/runtime/fracture_asset.odin`); runtime model in
[destruction](../../mirai-physics/references/destruction.md).

- `Fracture_Info.source_mesh` optionally links intact mesh (0 = independent). Pieces are closed
  meshes with local indices covering geometry exactly once; connection strength 0 inherits
  component strength; every cluster needs pieces.
- `fracture_document` bakes 1 convex hull per cluster; `fracture_source_check` validates authored
  source without hulls. `Fracture_Builder` authors pieces/levels/proximity connections (area and
  strength are authored inputs).
- `fracture_geometry` converts validated source for runtime/cook; non-uniform scale multiplies
  areas by the largest two-axis product.

## Mesh

- **Clusters**: `Cluster` holds <= `CLUSTER_TRIANGLES` triangles of 1 slot (`u8` indices).
  `Cluster_Vertex` (16 B) quantizes pos/uv on whole-mesh power-of-two grids (`position_step`,
  `uv_step`, `uv1_step`) from cluster min corner (crack-free across seams), oct normal,
  `math.tangent_angle_pack`; `uv1`/`color` streams gated by `Has_Uv1`/`Has_Colors`. Finite check
  (`vertices_finite`) rejects NaN/Inf.
- **Pages**: `Mesh_Page` packs whole DAG groups of 1 level (<= `MESH_PAGE_WORDS`, contiguous
  finest->coarsest). `mesh_page_layout` matches GPU words; `mesh_page_decode` decodes bit-exact
  with zero allocs (`MESH_PAGE_SCRATCH_BYTES`). `page_data` codes each page
  (`asset/mesh_page_code.odin`, `coded_bytes` 0 = raw; `Codecs.None` still codes if valid). Pages
  from `root_page` stay resident (`MESH_ROOT_WORDS`; skin/morphs/islands/`Levels` are all root).
  `mesh_pages_pack` writes `page_data`.
- **Builders & LOD**: `mesh_build` takes `Mesh_Source` (`Vertex` with MikkTSpace tangent + slot
  index) and indices; `mesh_level_decode` unpacks a level; `mesh_tangents` runs
  `geom.corner_tangents`. `Mesh_Level` DAG replaces by `error`/`parent_error` spheres (`Levels` =
  whole-mesh levels; [LOD](../../mirai-imports/references/imports.md#levels-of-detail));
  `ray_errors` cuts DAG for tracing.
- **Collision**: `colliders` hold authored shapes
  ([collision](../../mirai-imports/references/imports.md#collision)). Cooked `piece_points` /
  `piece_sizes` come from [cooking](../../mirai-projects/references/build.md#asset-cooking);
  `mesh_collision_pieces` uses them or caches `geom.mesh_decompose` in `project.COLLISION_CACHE`
  (shipped builds never decompose).
- **Morphs & skin**: `asset/morph.odin` stores quantized `Morph_Cluster_Delta` (`morph_step`,
  `MORPH_NORMAL_STEP`, `MORPH_TANGENT_STEP`), applied pre-skin via `Morph_Weights`. Skinned meshes
  link `Mesh_Info.skeleton`, `joints` inverse-binds, 8 weights summing to 255
  (`skin_weights_quantize`); palette:
  `inverse(mesh_world)*rig_world*bone_model_pose*inverse_bind`. `MESH_VERSION` mismatch requires
  reimport ([versions](formats.md#versions)).
- `mesh_view` unpacks all pages into `Mesh_Geometry`; `mesh_check_indices` validates all indices,
  weights, deltas, and colliders.

```odin
desc := asset.Mesh_Desc{id = id}
if asset.mesh_build(source, indices, nil, &desc.geometry, context.temp_allocator) {
    err := asset.mesh_save(out_path, &types, desc)
    _ = err
}
```

## Skeleton

Reusable bone hierarchy (no per-bone ECS entities): unique bone paths, parent before child, valid
TRS, unique socket names on valid bones. Optional `body` + `body_parts` store
[body map](../../mirai-std/references/anim-body.md) (`skeleton_body_detect`). Cross-validate
mesh joints via `mesh_skeleton_check`.

## Texture

- **Formats**: `RGBA8`, `BC1`, `BC5`, `BC7` (8-bit); `RGBA16` (16-bit linear); `RGBA16F`, `BC6H`
  (unsigned HDR, no alpha). `Srgb` applies sRGB curve on `RGBA8`/`BC1`/`BC7`, linear elsewhere.
  GPU encoding: [texture cooking](../../mirai-imports/references/imports.md#textures-cooktextures).
- **Mips & streaming**: `texels` stores smallest mip first (Store splits on mip boundaries).
  `texture_open` reads metadata, `texture_decode` decodes `[from, before)`, `texture_view` decodes
  all, `texture_mip` slices a decoded mip.
- **Field planes**: non-`Fast` block formats may split each mip into field planes (BC6H/BC7
  mode-grouped; `Texture_Mip.size` includes mode table). `Codecs.None` keeps planes; compressed
  picks smaller. `texture_decode(..., keep_fields=true)` passes planes directly to renderer.
- **Layers & CPU decode**: `layers` (default 1; `Cube` = 6 faces `+X,-X,+Y,-Y,+Z,-Z`, square;
  `texture_layer`). CPU helpers in `asset/texture_blocks.odin`: `texture_level_rgba8` (BC5 fills
  blue Z), `texture_level_rgba16f`, `texture_level_linear`, `texture_bc6h_block_decode` (reserved
  modes -> black).

```odin
a: asset.Asset
if asset.asset_load(&a, tex_path) == .None {
    defer asset.asset_close(&a)
    if view, err := asset.texture_open(&a, &types); err == .None {
        if asset.texture_decode(&a, &types, &view, from=0, before=2) == .None {
            mip0 := asset.texture_mip(view, 0)
            _ = mip0
        }
    }
}
```

## Material

OpenPBR model (`material_layers`, `unlit` excludes layers, `emission_mode` `Physical` nits vs
`Relative`; [model](../../mirai-rendering/references/materials.md#layers-openpbr)). Empty `program`
= standard model; `parameters`, `overlays`, `hidden`; `two_sided` (default false); per-map
`Material_Map` UV transform; `ior >= 1`. `material_view` validates ranges including `imported` and
`imported_parameters`.

### What was imported and what was changed

Imported materials store `imported` (last import) beside `material` (current); without `imported`
the material is its own base. Uses `asset/overrides.odin` (`value_leaves`, `overrides_mark`,
`override_keep`, shared with [prefab overrides](scenes.md#prefab-instances)).

- **Overrides**: leaf-by-leaf diff (`material_overrides`), no stored list; reverting to imported
  value clears the override.
- `material_follow(types, view, new_imported)` keeps overrides on reimport;
  `material_revert(types, view, paths)` restores named paths (empty = all; bad path -> `.Invalid`).
- `material_parameters_follow` follows `imported_parameters` by name, dropping removed source
  params while keeping user-added params, `overlays`, and `hidden`.

```odin
if view, err := asset.material_view(&a, &types); err == .None {
    merged := asset.material_follow(&types, view, fresh_imported)
    reverted, bad_path, rev_err := asset.material_revert(&types, view, {"roughness"})
    _ = merged; _ = reverted; _ = bad_path; _ = rev_err
}
```

## Animation

`asset/animation.odin`: project `.anim` keeps editable keys; cooked `.anim` keeps
`anim.library_compress` streams ([storage](../../mirai-std/references/anim-storage.md)).

- Track `target` is textual (escaped nominal paths for glTF, names for authored). Looping is not
  stored. `Animation_Clip.root` holds root options; `Animation_Clip.skeleton` supplies rest pose
  for compression.
- `animation_document` validates `ANIMATION_MAX_*`, names, key order, finiteness. `Cubic_Spline`
  uses explicit tangents (Hermite); `Cubic` uses squad for rotations.
- `animation_clips_add` populates `anim.Library` atomically (returns 0 on fail; `base.name_hash`,
  marker `id` = row). `animation_compress` compresses with `Skeleton_Open`
  (`skeleton_open_registry` / host) and `animation_parents`. `animation_cooked_document` writes
  cooked; `animation_descs` rejects cooked. `.character` and API authoring live in
  [animation](../../mirai-animation/references/animation.md) (atomic publish, outside scene undo).

## Sound

`asset/sound.odin`: `Lossless` (16-bit `audio.lossless_encode` in raw `lossless` bulk, zero-copy)
or `File` (WAV/OGG in `file` bulk; an Ogg without `Stream` is decoded whole when it loads).
`Stream` decodes while playing; without it, mixer keeps it in memory
([audio](../../mirai-platform/references/audio.md#sounds),
[imports](../../mirai-imports/references/imports.md#sounds)).

## Sound set

`asset/sound_set.odin`: weighted `.sound` refs (dependencies; weight 0 = 1, empty ignored), each
with `gain` and `pitch` over the drawn volume/pitch (0 = 1) and a `delay` (s, up to
`SOUND_SET_DELAY_MAX`) used when `all` plays every entry as one layered cue; volume/pitch ranges,
`hearing` for `audio.play`
([audio](../../mirai-gameplay/references/libraries.md#audio)). Validated by `sound_set_problem`;
edited via `sound_set.set` or
[previews](../../mirai-plugins/references/previews.md#sound-documents).

## Interface

`.ui` stores [`ui.Tree_Data`](../../mirai-ui/references/ui.md#data-tree) tables (`UI_TABLE_*`) and
bulk `text` (`ui.Tree_String`); image/font/`widget` `.ui` refs are dependencies
(`host.ui_tree_imports`, `ui.tree_link`, `style_infos.from`).

- `asset/ui.odin` + `std/ui_format` keep `asset` independent of `ui`; `host.ui_tree_document` /
  `ui_tree_save` / `ui_tree_view` reject invalid trees (`.Invalid`). `asset.ui_check` matches
  `ui.tree_load` (`host.ui_check_refuses_what_tree_load_refuses_case_by_case`).
- Edit values via `mirai asset set hud.ui 'nodes[6].layout.gap=8'`, structure/texts via `mirai ui`
  or `ui.*`.

## Font

`asset/font.odin`: bulk `file` holds raw TTF/OTF; 1 font per file (`font_check` rejects `ttcf` and
web fonts). Loaded bytes stay resident while shown
([content](../../mirai-core/references/host.md#content),
[imports](../../mirai-imports/references/imports.md#fonts)).

## Texts

`asset/strings.odin`: sole localization store (`Localized` `.ui` nodes, `core.Text`, `core.text`).
`entries` map `(key, lang)` to UTF-8 slices in bulk `text`.

- `host.app_texts` merges all `.strings` into `base.Texts` (`base.text`; duplicate keys use first
  file by path, flagged by `mirai texts missing` along with glyphs missing from `ui.FONT_RANGES`).
- Languages are data-driven; fallback strips region at last `-`, then falls back to the file's
  first language (`UI_Settings.source`).
- Authoring: `cook/author/texts.odin` (`texts_key`), RFC 4180 CSV (`cook/import/strings.odin`),
  `mirai texts`, `texts.*` ([texts](../../../../docs/game/ui/texts.md)).

## Records

`asset/records.odin`: typed [game data](../../mirai-core/references/core.md#game-data) tables.
`records` names the row struct (`declares=true` includes `columns` `Records_Column` + `defaults`
and generates the struct; `false` shares another file's type). `rows` stores 53-bit random `id`
(`core.Record`), unique ASCII `name`, and `value` in file schema. Validated by
`records_columns_problem` and `records_problem` (`records_view`/`records_document`).

## Prompts

`asset/prompts.odin`: maps `(family, input)` (`ui.Prompt_Family`/`ui.Prompt_Input`, compile-time
count assert in `host`) to texture rects (textures are deps). `key` holds `core.Key` (`Keyboard`
family covers keys and mouse). See [imports](../../mirai-imports/references/imports.md#prompts).
