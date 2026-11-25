# Import: current behavior

All packages are *engine-time*: `cook/import` (core: `Imported_Model`, `Reader`, source space, PBR
conversions, writer, settings, images/sounds/fonts/strings/prompts), format packages
`cook/import/{obj,gltf,usd,fbx}` (each exports `FORMAT`, zero cross-format deps),
`cook/import/sources` (`FORMATS`, `source_kind`, `import_source`, store [library](#library), used
by `editor/import.odin` and `mirai-import`), and `cook/textures`.

## API

- `sources.import_source` imports a model (assets + prefab if nodes exist), image (`.tex`), sound,
  font or prompt pack; package in store retains settings/ids across reimports.
- `sources.source_kind` sniffs first bytes (TGA by extension, prompts by `.prompts.json`).
- `importer.import_model` parses into an arena-backed `Imported_Model`; `importer.import_write`
  writes assets (`Import_Report`); `prefab.model_import` adds `cook/prefab.model_prefab`.
- `Outputs` (`output_root`/`part`/`model`/`input`/`written`, `outputs_end`) handles multi-asset
  whole-source imports, deduplicating shared parts by `(kind, name)` and hashing all `output_input`
  files before the first cached output.
- `Error` is `{code, message}` (`temp_allocator`). `Import_Options` carries settings,
  `ignore_stored`, `store` (required), `manifest`, `documents`, `root`, `registry`, `rebuild`,
  caches and `worker`. Also exposes `mesh_levels` and `pbr.odin` conversions.

## Formats

`importer.Format` declares `extensions` (fixed array), `version` (bumps rebuild key), default
`space`, output `folder` (default stem), and `sniff` (`SNIFF_BYTES` -> `Content`, `No`,
`Extension`). `format_find` prefers `Content` matches over `Extension` matches.

### The reader

`Reader` accumulates into the model arena, rejects unsafe paths, reports `fail`/`warn`, and builds
meshes via `Mesh_Builder` (`Corner` defaults missing UV to 0 and `uv1` to `uv`). `builder_morph`
records sparse engine-space deltas (unsharing flat deformed faces; computing MikkTSpace tangent
deltas at weight 1). `source_space(r, space)` sets file space before the first triangle.

### Source space

`Source_Space{meters_per_unit, axes, v_origin}` maps source axes to engine `+X/+Y/+Z` (negative
determinant = mirror; `ENGINE_SPACE` is meters, `{X,Y,Z}`, V from top; `GLTF_SPACE` uses
`FACING_PLUS_Z`). Import bakes once so assets hold meters and engine axes with no negative scales:
- **Corners:** transforms position/normal/UV (`1-v` on `Bottom`), flips winding and bitangent sign
  on mirror, generates MikkTSpace tangents (`geom.corner_tangents`) per normal-map UV (splitting
  vertices when needed).
- **Space bake (`space_bake`):** conjugates node/bone TRS (`C T C⁻¹`), inverse binds, clip keys,
  light sizes/frames (lights shine `-Z`), and material UV transforms (`Bottom`). Identity space is
  a no-op.

### Front

All models face `-Z`. `Import_Settings.front` rotates about `+Y` after parsing (`model_front`,
`space_turn`) without re-reading. `Auto` rotates purely-skinned rigs using confident `body_detect`
(mixed static+skinned levels stay untouched; unrotated rigs warn because `.skeleton` stores no
forward).

### Adding a format

1. Add `cook/import/<format>` importing only `mirai:cook/import` (or put in a plugin).
2. Export `FORMAT :: importer.Format{...}` (`version = 0`) plus optional `format(&options)`.
3. Populate `Reader` in source space (meshes, `.mat` values, images with `green_down` for DX
   normals, parents before children).
4. Register in `sources.FORMATS` and `ENGINE_PACKAGES` (`cook/build/engine.odin`).
5. Add format tests (`importer.import_model`) and fuzz fixtures in `cook/import/sources`.

### Plugin formats

Plugin editor packages provide
([extensions](../../mirai-editor/references/extensions.md#importers-of-a-plugin)):
- `Import_Format_Provider{format}`: extra `importer.Format` with `prepare`/`release` options,
  sharing standard cache/documents. `mirai import` loads the project's editor library (building if
  stale) when needed (`editor.import_library`).
- `Import_Source_Provider{source}`: claims files via `claims(path, head)` before formats and emits
  whole scenes/assets via `Outputs`. `importer.build_key` hashes `name`, `version` and plugin code.
  Example: external `unreal` catalog plugin.

## Import cache

Each asset's `Import_Info` records source name, index, size/hash of decoded input,
`importer_version` (`IMPORTER_VERSION` + `Format.version`) and `settings_hash` (mesh: levels/front/
rig/`MESH_CACHE_VERSION`; texture: `Build_Options`/`BUILD_VERSION`/encoder; sound: `Stream`;
materials/skeletons/clips: 0). Changing texture settings preserves cached meshes and vice versa.
`import_write` reuses unchanged mesh/texture objects (`Written.kept`) from current or prior builds
when version, `owner` and `Import_Info` match (Fast textures upgrade once Final exists in cache).
Cheap documents (materials/skeletons/clips/prefabs) always rewrite; `--rebuild` bypasses reuse.

## Identity and reimport

Imports ingest sources as store [packages](../../mirai-assets/references/formats.md#packages). The
package manifest holds `origin`, content `identity` (source/input bytes, settings, whole-source
plugin code), settings, inputs and asset entries `(kind, name, index -> id, owner, deps)`. First
ingest assigns random ids; reimports reuse ids via `Import_Options.manifest` or `origins` ref
(unreadable manifest fails explicitly). Objects are written uncompressed (`Codecs.None`) to store
builds under `imports/<key>` (Final), `imports-fast/<key>` (Fast) and `builds/<build_select>`:
- **Cached outputs (`asset.import_cached`):** meshes, textures, sounds, fonts (never user-edited;
  mounted from packages).
- **Documents:** materials, prefabs, skeletons, clips, texts, prompts (build stores baseline;
  `documents_follow` writes/updates project files found by id in `cook/import/documents.odin`).
- **Root & parts:** root is prefab/texture/sound without `owner`. Renamed source parts become new
  assets; removed parts warn and leave existing project documents intact. Imports never mutate
  another source's package or documents.

### Changed documents

Project pins record each written document's `content_hash` (`asset.Package_Written`; `asset.detach`
and materials excluded). `Import_Options.changed` controls conflicts: `Refuse` (default ->
`Error_Code.Changed`), `Discard` (`--discard-changes` / `discard_changes`, still keeping manual
skeleton body/sockets and clip roots), or `Keep` (used by refresh/add: keeps user edits, warns,
still writes build objects).

### Parts

`cook/import/parts.odin` sets `owner` to the model prefab when an output belongs solely to it:
meshes/skeletons always; clips/unused textures never. Under `Parts.Auto`, a material is a part iff
it has textures, serves one mesh, UVs stay in `0..1` (`PARTS_UV_SLACK`) without spanning edge-to-
edge, leaves `PARTS_MIN_UNUSED` grid cells empty, and its texture does not tile (`PARTS_SEAM_STEPS`
/ `PARTS_EDGE_CONTENT`). Textures used exclusively by part materials become parts. `owner` persists
across reimports (`asset.detach` clears it) unless overridden by `--parts auto|all|none`.

## Library

`cook/import/sources/library.odin` manages machine-wide store packages and project `packages.mirai`:
- `ingest(origin, options, settings)`: ingests into `packages/<id>` and `origins/<origin_name>`,
  serialized by per-origin `<store>/locks/`. No-ops if identity and readable build already match.
- `project_add` / `project_ingest`: pins package(s) in `packages.mirai` (atomic under project write
  lock) and follows documents into `folder` (prefab generation needs source + editor game types).
- `project_refresh`: resolves every pinned package to a readable build from local `imports` /
  `imports-fast` (with `fast_textures`), optional `cache.Source` (`--from`), or local re-ingest
  (finalizing Fast builds from texture cache when `--final` is required). Deduplicates pins sharing
  one origin; never deletes missing sources; tracks file size/mtime in `Source_Hashes` (re-ingest
  USD stages after editing sublayers).
- CLI: `mirai import <file> [--project P] [--folder F] [--final] [--release] [--from S]` and
  `mirai import --refresh <root>`. Project builds auto-refresh packages (`build.job_imports`).

```bash
mirai import assets/hero.glb --project demo --front auto
mirai import assets/walk.glb --project demo --skeleton <skeleton_id>
mirai import --refresh demo --final --release
```

## In parallel

`model_cook` runs `mesh_cook` and `texture_cook` in parallel via `Import_Options.worker`
(`jobs.Worker_Ref`), while ids, files and parts run deterministically on one thread. Fast->Final
finalization bounds in-flight textures to worker count. `--profile` / `asset.import {profile:true}`
reports per-zone timings (`importer.profile_totals`). Refreshes share one `Import_Options.registry`.

### Texture cache

`cook/textures/cache.odin` caches encoded textures in store `cache-textures` (`cook/cache`) keyed
by `textures.cache_key_build` (source bytes/texels + `settings_hash`) or `cache_key_blocks` (for
RGBA8 cooking). Shared across projects/worktrees; `cache.lookup` batches remote `cache.Source`
fetches before jobs run. `fast_textures` prefers an existing Final cache hit, else writes Fast and
caches lossless texels under the Final key for later finalization. `--rebuild` bypasses reads.

### Mesh cache

`mesh_cook` caches simplified levels/clusters/colliders in store `cache-meshes` keyed by
`mesh_content_hash` + `mesh_build_hash` + `MESH_CACHE_VERSION` (without materials/id). Skips
simplification and DAG construction on cache hit; `--rebuild` bypasses reads.

## Settings of a source

`Import_Settings` (zero = defaults; `IMPORT_USAGE`): only non-default fields persist in the package
manifest and override CLI options unless `ignore_stored` is set (invalid fields -> `Malformed`):
- `image` (`Normal_Green_Down` flips green); `alpha_coverage` preserves mip alpha coverage.
- `rdo_lambda` (0 = default, negative via `--rdo-lambda 0` = lowest error).
- `front` (`auto|negative_z|z|x|negative_x`); affects mesh hash.
- `rig` (`Humanoid` or Mesh2Motion animal; `rig_crotch`/`rig_neck` override humanoid fit).
- `skeleton` (`--skeleton <id>`): imports `.anim` only, bound to an existing skeleton (no meshes/
  materials/prefab).
- `sound` (`--sound smallest|lossless|file`): `Smallest` (default) keeps a short Ogg's file where
  smaller than its samples coded, `File` every file as it is ([sounds](#sounds)).

### Root scale

`model_scales` (`cook/import/scale.odin`), with no setting, after the space (whose
`meters_per_unit` already turned the declared unit into meters): the positive uniform scale of a
root node and of each node that is the only child of one of those that draws nothing (the groups an
exporter adds to change units) goes down the hierarchy into every mesh one node alone draws
(vertices, bounds, morph deltas, colliders; LODs and outlines are built after). The nodes above
take 1 and their children the scale and offset they lost, so world transforms stay exact. It is
never moved under a root that holds a skin or a node a clip moves, and a mesh other nodes also draw
keeps it on its nodes; scales of nodes below the root are their own (a level's props). A
non-skinned mesh still drawn at a factor of `UNIT_FACTORS` (10ⁿ, inches, feet) warns once, naming
why it was not baked.

## The imported model

`Imported_Model` is engine-agnostic plain data: rigid meshes in node space, skinned meshes in bind
space, parents before children in engine space, only referenced materials (deduped as `name (n)`).
Clip-only / skin-only files are valid models.

## What is written

Outputs go to store builds; documents write flat files in the target folder (existing ids followed
in place) with `Cooked` flag, `Import_Info`, BC textures and compressed mesh/texture streams.
Materials preserve user overrides via `asset.material_follow` (`imported` vs `material` layers,
program params, `overlays`, `hidden`); skeletons preserve manual body/sockets; clips preserve
manual roots. Broken model images warn; broken loose images fail. `mirai import` builds engine
first (stderr) and prints asset report (stdout; exit 0 ok, 1 fail, 2 usage).

## Template rigs (`cook/rig`)

Non-`Source` `rig` replaces source skins/skeletons (`cook/import/rig.odin`) with CC0 Mesh2Motion
rigs (`Humanoid`, `Fox`, `Horse`, `Bird`, `Dragon`, `Kaiju`, `Shark`, `Snake`, `Spider`; generated
by `scripts/gen_rig_templates.py` from `fetch_mesh2motion.py`). Humanoid fits horizontal slices
(floor/crotch/neck/top, mirrored; warns if `rig_crotch`/`rig_neck` needed); animals deform template
surface to mesh (`register.odin`). Rejects nodes with mesh + children or shared multi-node meshes.

## Levels of detail

`lods=Auto` builds a cluster DAG (`asset.mesh_build_dag`, `geom.cluster_dag_build`) for static
meshes and discrete `Levels` (up to `LOD_MAX`, `geom.cluster_levels_build`) for skinned meshes
(`lods=None` keeps level 0 only):
- Each level targets `LOD_SHARE` triangles via `geom.simplify` (`LOD_WEIGHTS`, locked borders),
  relaxing normal seams (`Permissive`), then non-material seams (`Error_Clamped`) if reduction
  stalls past `LOD_KEEP`; stops past mesh radius error or below `LOD_MIN_TRIANGLES`.
- **Foliage pruning:** submeshes with >= `ISLANDS_MIN` small islands (<= `ISLAND_MAX_TRIANGLES`)
  bucket by radius octave and prune via `geom.islands_reduce` instead of quadric collapse.
- `Mesh_Lod.error` stores max geometric/attribute/island error in object units for renderer
  `lod_error_pixels` selection.

### Masked cards

`cook/import/cutout.odin`, `outline.odin` (always active, no toggle): cuts small `Mask` islands
into conservative opaque outlines (supports skinned/morph meshes by interpolating corner weights).
Clean leaves (`<= OUTLINE_TRIANGLES`, `<= 1/OUTLINE_COVERAGE` area, error `<= CUTOUT_LEAF_ERROR`)
become two-sided opaque geometry (`<name> outline` material slot if mixed, with `alpha_fill`
bleeding base color into transparent texels); complex clusters keep alpha-tested tight convex
hulls (<= 8 corners). Empty cards drop.

## Collision

Import stores only source-authored `asset.Collider` rows (never auto-generates; prefabs add `Auto`
`Collider` only when present):
- Naming conventions (all formats): `UCX_` (hulls per piece), `UBX_` (box), `USP_` (sphere),
  `UCP_` (capsule), `-colonly`/`-convcolonly` (collision-only), `-col`/`-convcol` (drawn+collider).
- glTF: `KHR_physics_rigid_bodies` / `KHR_implicit_shapes` and `OMI_physics_body`/`shape`.
- USD: `PhysicsCollisionAPI` (`Mesh` approximation, `Cube`/`Sphere`/`Capsule`/`Cylinder`/`Cone`).
- Plugins: fill `Imported_Mesh.collision` directly (e.g. Unreal `BodySetup`).

## Textures (`cook/textures`)

`source_decode` (`vendor:stb/image`) decodes `.hdr` (`RGBA32F`), 16-bit PNG (`RGBA16`) and other
formats (`RGBA8`; no EXR). `build` generates full per-layer mip chains (linear-light color,
renormalized normals with optional `green_down` flip, direct HDR average, optional `channels`
swizzle/invert, bisected `alpha_coverage` preservation; rejects sides > `asset.TEXTURE_MAX_SIZE`).
- Formats (`stored_format`): `BC5` normals, `BC6H` opaque non-negative HDR (else `RGBA16F`), `BC7`
  color/alpha-data, `BC1` opaque data (or uncompressed `RGBA8`/`RGBA16`/`RGBA16F` when requested).
- Slang compute encoder runs on a shared headless GPU context (Fast skips RDO; Final enables
  `rdo_lambda`). Non-BC GPUs decode on load in `host`. Bump `BUILD_VERSION` on output changes.

### Heightmaps (`cook/textures/heightmap.odin`)

`heightmap_decode` reads 8/16-bit images linearly into `[0,1]` (no sRGB, mips or alpha); rejects
HDR and PNM before decoding.

## OBJ

Meters, `+Y` up, V from bottom; splits meshes by `o`/`g`, triangulates polygons via `std/geom`,
assigns slots per `usemtl`. Reads MTL `Kd` (0.8 default), `Ke`, `Pr`/`Pm`/`Ns`, `d`/`Tr` (`blend`
or glass transmission `1-d` with `Ni`), `map_Kd`, `map_Ke`, `norm`/`bump` (`-bm`); skips `map_Pr`/
`map_Pm`.

## glTF and GLB

Uses cgltf (default scene, TRS/decomposed matrix, `NORMAL`/`TANGENT`/`TEXCOORD_0..1`/`COLOR_0`,
`EXT_meshopt_compression` for attributes/`QUATERNION`/`EXPONENTIAL`).
- Materials: metallic-roughness, relative emission, `alphaMode`, `doubleSided`,
  `KHR_texture_transform`, transmission/ior/volume/specular/clearcoat/diffuse-transmission/unlit;
  converts specular-glossiness, `ior=0`, sheen -> LTC fuzz, anisotropy -> OpenPBR.
- Lights: `KHR_lights_punctual` (`Sun`, `Point_Light`, `Spot_Light` with `innerConeAngle` as
  its `inner` share of the outer cone; missing range -> 0.5 lux).
- Rejects Draco, compressed indices/normals/`OCTAHEDRAL`, GPU instancing, points/lines, shear,
  zero scale, missing `TEXCOORD`; skips cameras.

### Skinned meshes

Each skinned node writes a unique mesh (`JOINTS_0..1`/`WEIGHTS_0..1`, up to 8 influences, quantized
to sum 255 via `asset.skin_weights_quantize`, affine invertible inverse binds). One `.skeleton` per
skin (bones are not prefab entities); auto-detects body map (preserving manual body/sockets on
reimport) and sets `Animation_Root` to moving pelvis parent (preserving manual root).

### glTF clip markers

`extras.markers` (`[{"name":"foot_l","time":0.27}]`) imports as sorted clip markers (rejects empty
name or negative/non-finite time).

### glTF morph targets

Stored in `morphs`/`morph_deltas` (up to `asset.MESH_MAX_MORPHS`; uniform across primitives;
`POSITION`/`NORMAL`/`TANGENT`). `node.weights` differing from mesh defaults store in
`Morph_Weights` (capped at `asset.MORPH_WEIGHTS`).

### glTF clips

Tracks target escaped name paths (`%25`, `%2F`) with `name_hash` (duplicate sibling names fail;
unnamed nodes become `Skeleton`/`Mesh`/`Node`). Preserves `STEP`/`LINEAR`/`CUBICSPLINE` (Hermite);
`weights` becomes `<path>/@morph/<target>` Float tracks. Rejects duplicate channels, matrix-animated
nodes, null quaternions and non-increasing/non-finite times.

## USD

Flattens crate/composition via `usdcat --flatten --skipSourceFileComment` (bare non-composed USDA
works without it; otherwise `Tool` error). Reads polygonal `subdivisionScheme="none"` meshes
(`primvars:normals`, `st`/`st1`, `displayColor`), `metersPerUnit` (0.01 default), `upAxis`, xform
ops, `UsdPreviewSurface` + `UsdUVTexture` + `UsdTransform2d`, and UsdLux lights (`SphereLight`,
`RectLight`, `DiskLight`, `Spot_Light` cone, `DistantLight`). Rejects subdivision, instancers,
curves, NURBS, time samples, specular workflow, multi-`UsdTransform2d`, shear, USDZ.

## FBX

FBX 7+ binary/ASCII via [ufbx](../../../../third_party/ufbx/UPSTREAM.md) (FBX 6 rejected).
Declares `GlobalSettings` units/axes, strips namespaces when unique, bakes Maya `Rrs` segment scale
compensate (zero animated parent scale rejected), bakes `Geometric*` transforms, keeps top 8 skin
influences per vertex, imports blend shapes, converts ufbx PBR shaders (assembling single-channel
roughness/metalness into `.Metallic_Roughness`), samples Euler stacks at scene FPS with linear
reduction, maps `DeformPercent` to `@morph` and animated custom numeric properties to Float curves.
Rejects NURBS, multi-skin meshes, non-root skin bones; warns on lights/cameras/curves.

## Sounds

`cook/import/sound.odin` decodes WAV/Ogg (1-2 ch; >2 -> `Unsupported`) via `audio.decode`:
resamples coded clips to `audio.MIXER_RATE` (Kaiser-windowed sinc), stores `< SOUND_STREAM_SECONDS`
as `Lossless` 16-bit and longer clips with `Stream` (keeping Ogg/non-16-bit WAV intact). By
default (`Smallest`) a short Ogg keeps its file, at its own rate, where it is smaller than `MLPC`
(most are 2-4x smaller; a click with silence codes smaller): the mixer decodes it whole on load,
so a start decodes nothing, at 4 bytes per sample in memory. `.Lossless` always codes, `.File`
keeps every file; the coding is in the settings hash.
Verifies Ogg page CRCs before stb_vorbis (`Malformed` if no intact pages).

## Fonts

`cook/import/font.odin` validates TrueType/OpenType (`ui.font_init`) and stores compressed bytes as
`<name>.font`. Rejects TTC (suggests `fonttools ttLib -y 0`) and WOFF; FreeType errors ->
`Malformed`.

## Prompts

`cook/import/prompts.odin` imports prompt folders (`prompts_names.odin` picks simplest filename
variant) or `<name>.prompts.json` manifests into power-of-two sRGB atlases owned by `.prompts`:

```json
{"entries": [
  {"family": "Xbox", "input": "South", "image": "xbox/xbox_button_color_a.png"},
  {"family": "Keyboard", "input": "Key", "key": "Space", "image": "keys/keyboard_space.png"}
]}
```

## What it does not do

Does not write scenes (whole-source plugins do), USD blend shapes/cameras/USDZ, or compile OpenUSD.
`cook/prefab.model_prefab` builds prefabs via `author.scene_file_bytes` keeping rigid
`Animation_Target.path`, `Mesh_Renderer`, `Pose_Source.rig`, `Bone_Attachment` (`bone.<hash>`
sockets), `Animation`, and `Hidden` (omitting bone entities and unavailable plugin components).
