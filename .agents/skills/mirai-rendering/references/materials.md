# Materials and textures

OpenPBR 1.1 model: a metallic-roughness base (that of glTF 2.0) with optional
[layers](#layers-openpbr) (coat, fuzz, specular anisotropy and diffuse transmission) and an unlit
mode.

## Material row

- **One schema.** The values of a material are `asset.Material_Info`; `render.Material_Desc`
  contains it whole and adds what the renderer resolved (textures, program and its parameters).
  The shaders receive indices, modes and defaults from the
  [generated schema](shaders.md#compilation).
- **On the GPU** (`Gpu_Material_Row`), the layer blocks are read only with their `layers` bit.
  `row` is written by the shader with the index through which it read the row; the CPU leaves it
  at zero.
- Textures follow the channels of glTF and its extensions (tangent-space normal with +Y up) and
  each one multiplies the value it accompanies. Row 0 is the default material.
- **Overlays** (`overlay.frag.slang`): layers over an instance's opaque base, with the same
  geometry. Alpha covers with the layer's lit surface and Additive adds its light; Multiply
  filters what is below by the layer's base color without lighting it, so it depends neither on
  light nor on exposure.
- An instance can replace the materials of its mesh with a single one; it also tints the base
  color and adds emission. An object without a material uses the default tinted with its color.

## Evaluation

- The evaluation chooses between common PBR and the Surface program. A Surface replaces the PBR
  values: its standard maps are neither sampled nor loaded; it keeps the normal map
  (`ctx.normal`), its parameter textures and the context of position, UV0/UV1, time and LOD.
- **Vertex color.** Common PBR multiplies its base color by the mesh's; a program does not: it
  reads it as data in `ctx.vertex_color` (white where the mesh has none) and decides
  (`material_vertex_tint`). The instance tint multiplies both, and `uniform_color` replaces only
  the multiplication.
- **Object.** The context carries the instance's transform (pivot, axes with their scale, center
  and radius of its bounds) from `material_context_instance`; a point without an instance
  (preview, studio, extension surfaces) has the world as its object. The axes are perpendicular:
  the return to object space divides by their length (`mirai_object_point`).
- Vertex color and object arrive the same at the G-buffer, the translucent pass, overlays,
  coverage and ray hits (surface, coverage and shadow filters); a batch instance is its own
  object.
- **Wet.** `ctx.wet` (0 dry to 1 soaked) is that of the instance, which an extension gives
  ([`instance_wet_set`](views.md#extension-stages)); 0 without an instance and in batches. The
  engine applies it to every material after evaluating it, program or not (`material_wet_apply`,
  as Lagarde in "Water drop 3b"): what is rough, which is porous, and nonmetallic drinks the water
  and darkens its base color; the water film lowers the roughness toward its own, also partly over
  what does not drink. The normal reflectance stays: the film is thin. It does not touch what has
  transmission (glass, water) or what is unlit. A program reads it only to add (drops, puddles).
- In common PBR, mask coverage reads only opacity and base color.
- The scene caches the opaque instances that require their own F0/F90; G-buffer and lighting use
  stored reflectance only while some of their boxes is in the frustum of the view or of a nested
  view ([G-buffer](frame-graph.md#passes)), and the target is allocated the first time it is
  needed.

## BRDF

- Lambert plus GGX with height-correlated Smith visibility and Schlick Fresnel (`brdf.slang`). The
  distribution computes `1 − (n·h)²` as `|n × h|²`: with the minimum roughness, the rounding of
  `(n·h)²` near 1 leaves the brightness of an area light banded.
- Dielectric `F0` comes from the IOR (or from `specular_ior` in Surface) with its specular color
  and factor; in metals, from the base color. `F90` keeps the specular factor, including zero. IOR
  zero keeps a constant dielectric Fresnel; in the reflectance target, a negative F90 indicates it
  and it is rebuilt with base color and metallic, also in the glass layers.
- The diffuse and the diffuse transmission receive what the base's specular lobe leaves: `1 − max`
  of its directional albedo at the view (`base_diffuse_share`, the albedo scaling of OpenPBR), the
  same for each light and for the environment.
- **DFG table.** The split-sum of the lobe, which `dfg.comp` integrates when the renderer starts
  with the same functions of `brdf.slang` in the first entry of the texture table (`DFG_TEXTURE`).
  With its albedo rough metals recover multiple scattering (Kulla and Conty) in the direct and
  indirect light.
- The roughness does not go below `MIN_ROUGHNESS`, somewhat more for point lights.
- **Units.** The irradiance of a light is stored divided by π, so the specular lobe is multiplied
  by π ([units](display.md#units)). The emission is luminance in nits.

## Layers (OpenPBR)

- **Bits.** `asset.material_layers` gives the layers of a material; unlit excludes the others. The
  row stores them in `layers` and a Surface program adds those its source writes (the fields of
  `Mirai_Surface`, which the catalog lists per program). A layer does not change the scene's light
  mode: it only turns on the [layers target](frame-graph.md) while it is in view.
- **Order and energy.** Fuzz goes over the coat and the coat over the base; each layer reflects
  its lobe and leaves the rest to the one below (albedo scaling), so that each layer takes a
  function of the view alone except the coat's transmission toward the light. The direct light
  (`shading_lobes`) and the indirect (`indirect_compose`) compose the same; `shading_layers`
  prepares the point once for raster, glass (`glass_shading`), ray hits (`surface_shading`), GI and
  the previews studio.
- **Coat:** GGX lobe with its normal, roughness and IOR, which always darkens what is below (there
  is no `coat_darkening`); under it the base reflects with the relative IOR
  (`material_specular`). **Fuzz:** the LTC of Zeltner, Burley and Chiang (2022) with the MaterialX
  adjustments; the passes that filter the light separately count it in the diffuse lobe.
- **Diffuse transmission.** That of OpenPBR on a thin surface and
  `KHR_materials_diffuse_transmission`: the weight takes that part of the diffuse lobe and lets it
  pass, tinted, from the other side, which is lit like a Lambert with an inverted normal
  (`shading_back`, `back_irradiance`). The samples of the direct light store only the front side,
  so the back side of a pixel that transmits is lit by `direct_lighting` in the direct filter
  with its own rays. For the GI it reflects only its diffuse part. It is a sheet without
  volume.
- **Anisotropy.** Anisotropic GGX over the vertex tangent (MikkTSpace) rotated by `rotation` and by
  the map; the environment is read with a normal bent toward the groove (Revie 2011) and the
  traced reflections sample the anisotropic VNDF.
- **Unlit.** The BSDF is zero everywhere (raster, rays, GI, previews): the surface shows its
  emission (in nits or [relative](display.md#exposure-relative-emission)). Base color and opacity
  still decide the coverage.
- **Traced reflection.** The G-buffer marks which lobe the pixel traces (`GBUFFER_TRACE_COAT`): the
  coat's if it reflects at least what the base lets through. The other one reads the probe volume.
- **Cost.** What shows no layers does not compile them: `direct` and `composite` run their
  `unlayered` variant (`MIRAI_GBUFFER_NO_LAYERS`) while no instance with layers is in view, and
  `reflect` its own while none of the scene has them, because its rays shade what they find. Those
  paths evaluate the materials with `MIRAI_MATERIAL_NO_LAYERS`: the layers do not raise the
  registers of a frame that has none. The glass layers have their own layers target and their
  `layers` variant of `glass_layer` while a blend instance of the scene has them.

## Derived graph

`surface_parse` and `surface_graph` (`cook/shaders/surface.odin`, engine-time) read a Surface
program as what each value is made into: the check and `material.program.inspect` use it, and it
is not shown. The source is the only truth; the graph is derived at each revision and never
stored or edited.

- One node per `ctx.*` input, parameter, constant, texture read, write of a variable or of a
  surface field, own call and control; what it does not understand (a `switch`) is a `code` node
  over its lines, with what it reads and writes.
- **Stable ids:** `Program/function/name`, the n-th write with `#n` from the second
  (`Ocean/evaluate/out.base_color#2`); they are resolved to lines at each revision and a line from
  elsewhere does not change them.
- Each node knows what the source says about its value (bound, constant, normalized, from a
  texture, with the tangent) and its type (`Graph_Node.type`); with the contract
  (`mirai_material.slang`), also those of `Mirai_Surface_Context` and `Mirai_Surface`. The check
  rules read it.

## Indirect composition

`indirect_compose(Shading, Indirect)` (`brdf.slang`) is the only formula for the light that
arrives around a point: composite, overlays, glass, glossy hits of the reflections and the
previews studio use it.

- Its inputs (`Indirect`) come from `indirect_lobes` (`scene.slang`), which reads the volume once
  for the requested lobes, and from what the rays traced. The specular uses the DFG table with
  multiple scattering and the specular occlusion of Lagarde and de Rousiers, also over the traced
  reflection.

## Textures

- A `.tex` brings all its levels in their final format; `host` uploads with `texture_add_data`
  those that its [distance](#residency-by-distance) asks for. The chain, its color rules and the
  compression belong to `cook/textures`
  ([imports](../../mirai-imports/references/imports.md#textures-cooktextures)).
- A `.tex` larger than `texture_max_size` (in game and editor, the Textures option of
  `Graphics_Settings`) enters from its first level that fits.
- `texture_add` receives RGBA8 pixels made at runtime, generates its chain on the CPU and uploads
  it uncompressed; `texture_image` replaces the pixels of an image that its owner draws again.
- **Compression.** BC7 for color with and without alpha, BC1 and BC3 for data maps without and
  with alpha, BC5 for normal maps (Z is rebuilt in the shader) and BC6H for HDR; uncompressed,
  RGBA8, RGBA16 (data precision) and RGBA16F (HDR). The renderer uploads the file's format; the
  encoders are in `cook/textures`
  ([imports](../../mirai-imports/references/imports.md#textures-cooktextures)). Without
  `Features.texture_bc` or with `texture_compression` off (`texture_limits`), `host` decodes each
  level to RGBA8, and BC6H to RGBA16F, before uploading it.
- **Arrays and cubes.** A layered `.tex` is uploaded through the same `texture_add_data`, all its
  layers in each level (`Texture_Data.layers`, `cube`), whole and without following the distance.
  It occupies its entry, but the table shows the default white in it: the shaders read the table as
  `Texture2D` and a pass that samples a cube binds the entry's texture. A material, a program
  parameter, a UI, a decal or the sky that name one receive it as `Unsupported`
  (`assets_texture_image`). No pass samples cubes or arrays yet.
- **Pool.** `texture_pool_megabytes` (in game and editor, a part of `Device_Info.memory` or
  `Graphics_Settings.texture_memory`) is the GPU memory for textures, which the
  [residency by distance](#residency-by-distance) distributes, less what the targets of the
  [texture views](views.md#texture-views) hold (`Stats.view_target_bytes`). A texture that does
  not fit whole when added enters without its largest levels; the one that does not follow the
  distance is counted this way in `textures_reduced`.
- Changing the maximum size or the pool does not touch what was already uploaded:
  `host.assets_textures_reload` loads again, from the smallest to the largest, the textures that
  the change reaches: those whose larger side exceeds the smaller of the two sizes, all if the pool
  shrank or the compression changes, and those that left levels out if it grew. `graphics_apply`
  calls it when they change.
- **Filtering.** A common trilinear, repeat and anisotropic sampler. In the G-buffer the level comes
  from the screen derivatives, with bias `log2(render resolution / output resolution)` when TAA
  rescales.
- A scene has at most `texture_capacity` textures: what the texture table grows to, minus the
  `TEXTURE_RESERVED` entries of the DFG and the air at its start; the texture of a handle is in the
  entry `TEXTURE_RESERVED + handle - 1` (`texture_index`)
  ([table](rhi.md#bindings-and-texture-table)).

## Residency by distance

A texture of an asset resides with the levels that the distance of what shows it asks for
(`render/texture_residency.odin`, `host/assets_streaming.odin`). The others (`texture_add`,
`texture_image`, shared, from extensions) keep what they received.

- **Source.** `Texture_Data.source` and `level` say which chain their levels belong to; `host` gives
  that of the `.tex`, which it reads again to give others.
- **What shows it.** The non-hidden instances, their layers and the drawn batches whose material
  rows name it in a map. A texture of a Surface program, whose uv its source decides, asks for all
  its levels while something shows it. One that nothing in the scene shows (particles, UI, sky,
  decals, previews) keeps the levels it has unless the pool asks for them.
- **From where.** The views of the last frame that the window showed (not offscreen frames, except
  those of a capture that waits for its textures, `Frame_Desc.streamed`) and the
  [streaming sources](../../mirai-gameplay/references/libraries.md#sources-and-residency)
  of the drawn world with their advanced point (`texture_sources`), seen as from the perspective
  view of the largest scale.
- **The level.** That of the source whose texel covers a pixel at the nearest point of the box: the
  distance, the pixels of a meter at a meter at the view corner (`texture_viewer`), the uv per meter
  of that mesh entry (`mesh_uv_density`), the largest scale of the instance and the major axis of
  the map transform. It resides `TEXTURE_FILTER_LEVELS` finer, what anisotropic filtering can read,
  between the largest that `texture_max_size` allows and that of side `TEXTURE_TAIL`. With all
  that the image is that of the whole texture.
- **Hysteresis.** It asks for more levels as soon as it needs them and releases one only when its
  distance asks for `TEXTURE_KEEP_LEVELS` less, the proportion of `RESIDENT_KEEP`.
- **Budget.** While what is asked for exceeds the pool (minus what does not follow the distance),
  all take the same fraction of a coarser level, the smallest that fits (`texture_targets`): the
  farthest ends up coarser. Those this holds back are counted in `textures_reduced`; those that do
  not have their levels yet, in `textures_pending`.
- **When.** The estimate runs between frames (`textures_update`) only if a view or a source moved
  `TEXTURE_VIEW_MOVE`, or what the scene shows changed: its instance table, the mesh or the
  materials of an instance, a material, a batch or a texture. An instance that only moves, or is
  hidden or shown, asks again alone when its row goes to the GPU (`textures_touched`): nearer, its
  textures take the finer level at once; `TEXTURE_FAR_STEP` farther than where it last asked, or
  hidden, the scene is estimated again only if a texture was at the level that instance asked.
  A level is never coarser than the estimate of the whole scene gives. `host`
  (`app_textures_stream`, in `app_frame_begin`) reads up to `TEXTURE_READS` at a time in jobs,
  each decoding only the levels it gives (the smallest lie at the start of the `.tex` stream),
  first those that need more levels (those that free memory if the pool is exceeded) and those
  farthest from their levels, and gives them to the renderer with the
  [load budget](../../mirai-core/references/host.md#loaded-assets).
- **Transaction.** `texture_levels_set` creates a texture with the new levels, puts it in the table
  entry and destroys the previous one: the handle and the material rows do not change. A request
  whose texture changed since then (`stamp`) does nothing; a texture whose file is no longer read
  stops following the distance (`texture_stream_stop`).
- `host` gives them with `texture_levels_queue`: their rows are uploaded in the list of the
  following frames, among all of them their share of `UPLOAD_FRAME_BYTES` per frame, which they
  share with the [geometry over several frames](scene.md#geometry-over-several-frames), and up to
  `TEXTURE_UPLOADS` textures at a time; the texture takes its entry between frames once all of
  them were uploaded (`texture_uploads_install`). What the job read stays while
  `texture_upload_pending`; a large level does not stall a frame.
- What a section load brings arrives with the levels of side `TEXTURE_TAIL` and its distance asks
  for the others; the main scene and direct loads arrive whole.
- A texture that a load gives over several frames (`texture_add_over_frames`) enters with its
  levels of side `TEXTURE_TAIL` or less and the larger ones go through the same queue: until all
  were uploaded the small ones are shown, never a half level. Those that the pool has no room for
  stay out beforehand, as in `texture_add_data`.

## Normal maps and specular antialiasing

- **MikkTSpace tangent frame.** The pixel uses the interpolated, unnormalized normal and tangent
  and the bitangent `sign * cross(normal, tangent)`, like the baker that wrote the map
  (`tangent_frame_normal` of `scene.slang`, the same in raster and in ray hits). A mirrored
  instance inverts the sign; the back face inverts the whole frame.
- A mesh generated at runtime can bring its tangents per vertex
  (`Mesh_Generate_Options.tangents`), like the terrain Heightfield.
- The tangents follow the UV that the normal map read on import; the map's transform rotates (and
  can mirror) its green and its red against them, without its scale (`material_map_normal`).
- A normal that ends up facing away from the camera is brought to the silhouette.
- **Specular antialiasing.** The roughness of a pixel grows with the variation of its normal inside
  it (Tokuyoshi and Kaplanyan). The material's before widening is stored in channel B of the motion
  target for the [traced reflections](#traced-reflections).

## Alpha

- **Mask (`mask`).** Alpha = `opacity` times the alpha of the color texture. Below `alpha_cutoff`
  the fragment is discarded and the rays go through the triangle at that point: shadows, bounces
  and reflections see the same holes. Only the instances with some mask or blend material pay for
  that read in the traversal.
- The mips of a masked texture keep the proportion of texels that pass the threshold.
- **Blend (`blend`).** It is drawn over the lit scene. Without transmission it is a layer that
  covers `alpha` of what is behind it: the transparency attenuates its diffuse part, not its
  specular highlight.
- By default it casts no shadow; [`colored_shadows`](lights.md#colored-shadow-filters) filters its
  color in shadows. It does not enter the G-buffer nor appear as a surface in reflections or
  bounces; the sharp reflections see it as a color filter.

## Ray hits

- Probes, reflections and glass read base color, metallic-roughness and emission at the hit; the
  rays that gather light omit the emission of a lamp that contains its light
  ([local lights](lights.md#local-lights)).
- The mip level comes from the ray footprint (ray cones): diffuse rays read coarse levels.
- Hits interpolate normals and tangents to apply normal maps and read what the Surface program
  gives at the hit, which evaluates its stage with explicit LOD
  ([programs](#surface-programs-in-rays-and-raster)).
- **Bounces.** Behind the first hit a surface is diffuse, with its specular reflectance added to
  the albedo. The sharp reflections do see the highlight of what they find, except that of lights
  where they see it edge-on: there the ray footprint covers more relief than a sample samples, and
  that highlight would come out in sparks; that of the probes remains.

## Surface programs in rays and raster

No engine stage evaluates a Surface program except its own, compiled once per program
([programs and stages](shaders.md#programs-and-stages)): editing a program compiles only its
stages.

- **Raster.** A program's pipeline is that of the stage with the program's fragment
  (`program_graphics`, `program_stages.odin`). The cull distributes the visible clusters of
  materials with a program per program (`cull_programs.comp`: count, prefix with the draw
  arguments and distribution, over `include/bins.slang`) and the G-buffer emits one indirect draw
  per program in use and phase. A draw of the clusters of an instance (glass layers and filter,
  translucents, overlays, highlight) is made once per program of its materials, which it names to
  `gbuffer.vert` (`SLOT_DRAW`): the vertex shader collapses the clusters of the others. Thumbnails
  and impostors name the program as the first instance of the draw; the UI splits its triangles
  into ranges by the program of the previews they show, without changing their order.
- **Rays: material points** (`points.odin`, `include/points.slang`). A thread that finds a material
  with a program adds a point (instance, triangle, barycentrics, footprint, program) and a head
  with what it needs to continue, and ends; the threads of a wave that add take consecutive places
  with a single atomic (`points_take`). `points_resolve` counts the points per program, gives them
  their range and distributes them (`points.comp`), and the stage of each program in use
  (`surface_points__<Program>.comp`) writes in each point's record what the program gives there,
  packed. With a single program in the scene its stage traverses the whole window, without
  distributing. The pass continues over the heads (`points_resume`), which can add points for
  another round (`points_rounds`): the rounds go back and forth through the buffer, outside the
  window that the resumption reads. Reflections, the probe volume, the indirect reference, shadows
  and direct light traced with colored shadows, glass, its path from inside and its medium filter
  use points.
- The buffer grows to what a frame asked for (`POINTS_MAX` at most). A point or a head that does
  not fit takes the row of its material at that hit.
- **Coverage in the traversal.** The alpha of a program with coverage decides whether a ray
  continues, so it is evaluated inside the traversal, like an any-hit, from
  `surface_coverage.slang`; nothing is traced again. The stages that trace depend on that compiled
  alpha, not on the rest of the program ([programs and stages](shaders.md#programs-and-stages)).
- **Deferred filters.** A ray that crosses glass with a program does not wait for its filter: it
  takes the [medium filter](#medium-filter) of the instance and adds the crossing as a filter
  point, chained to the others of its owner (a pixel, a probe ray). The program's stage writes in
  a filter point's record the exact filter and not the surface (`point_filter_at`): so it computes
  only what tints and lets pass, and the owner does not rebuild the hit. On resuming, the owner adds
  what the exact filters change from what the means gave, weighted by what each ray carried
  (`filters_weigh`, `filters_correction`). A crossing that does not fit keeps the mean.

### Vertex functions

A Surface program that moves the vertices of what shows it declares
`//! vertex [animated] [reach <metres>|reach <parameter>]` and
`Mirai_Vertex vertex(Mirai_Vertex_Context ctx, Parameters p)` (`mirai_material.slang`), which
gives where a vertex goes, its normal and tangent, in the space of the object
([declaration](shaders.md#programs)). `Pieces` (`shaders/materials/pieces.slang`) is the engine's:
the pieces of a mesh, numbered in UV1, fly in with a turn as its `progress` goes to 1.

- **One geometry for everything** (`displace.odin`). An instance whose materials have such a program
  shows a pose of its own of level 0 of its mesh (`Skin_State.displaced`, current and previous
  vertices, kept by instance identity while it shows the same mesh). The program's stage
  (`surface_vertices__<Program>.comp`) writes it from the rest of the clusters of its materials
  before the Geometry stage, so raster, shadows, reflections and GI (the pose's tree and BLAS,
  refit like a [skin](scene.md#gpu-skinning)), outlines and motion vectors read the same
  vertices. No other pass moves vertices.
- **Only what changed runs.** A pose is written again when the transform of its instance, the
  rows of its materials (parameters, those of a `Material_Override` too) or, if `animated`, the
  time change; otherwise its stage does not run. Its previous vertices are those the frame before
  showed, so the motion of a parameter that moves it is exact. Without `animated`, `ctx.time` is
  0. Instances without such a program pay nothing.
- **Per instance values** come from the parameters of the material of the instance: a game sets
  them on an entity with `Material_Override` (`material_override_value_set`), each entity then
  with rows of its own.
- **Reach.** The box of the instance (culling, the tree of instances, the light it changes) grows
  by `reach`, in the space of the mesh, in each axis: the function keeps every vertex within it
  of its rest. A parameter reach is read from the row of each material.
- **Skins** are moved in place after their skin, the current vertices at the time and transform
  of the frame and the previous ones at those of the frame before, with the parameters of now;
  the skin poses again each frame the program moves it. A deformable an extension writes and the
  instances of batches are drawn as they are.
- Until its stage's pipeline is made the vertices stay where they were (at rest for a new pose),
  as a program draws as its row.

### Program pipelines

- With a window, or with a surface that another process shows (the `--surface` player of a network
  Play, `App_Desc.shown`), the host creates the renderer with `pipeline_thread`
  (`pipeline_thread.odin`): a program's pipeline is requested from the renderer thread the first
  time a draw or a resolve needs it, and a frame does not wait for the driver. Until a frame finds
  it made (`pipelines_install`, at the start), the stage itself draws those materials as their rows
  and their points are read as the row (the record unwritten, `point_record_given`).
- Without either of the two (headless sessions, tests, captures) the pipeline is made where it is
  requested: what a frame draws does not depend on driver time.
- A thumbnail, a material capture or an impostor, which are read right away, wait for the pipeline.
  `capture` and `app_capture_world` draw one more frame if the last one drew a program as
  its row (`renderer_pipelines_pending`, `renderer_pipelines_wait`); the editor images are drawn
  again when pipelines arrive (`renderer_pipelines_made`).
- Extensions ask for a program's with `Stage_Pipeline_Desc.program` or
  `pass_gbuffer_pipeline(..., program)` and receive that of the stage without it until it is made
  ([extensions](views.md#extension-stages)).

### Program limits

- The fog takes the glass's medium filter with a program: a grid cell is a volume, not a ray, and
  one point per fog ray would be millions per frame.
- The particle collisions (`mirai_vfx_trace`, inside a Vfx program, without rounds) see the
  vertex normal with the row's normal map, without the program's.
- Focal tests: `material_program_shows_in_what_a_reflection_finds`,
  `material_program_shows_on_what_the_camera_sees`,
  `material_program_draws_as_its_rows_until_its_pipelines_are_made`,
  `material_textures_color_the_bounced_light`, `glass_tints_the_indirect_light_with_its_mean`,
  `material_program_moves_the_vertices_the_camera_the_rays_and_the_motion_see`,
  `gpu_a_program_moves_a_skin_after_its_skin_now_and_before` and, without GPU,
  `an_instance_whose_program_moves_vertices_shows_a_pose_of_its_own`,
  `gi_reference_gives_the_light_of_a_white_furnace` and, for colors in shadows,
  `material_colored_shadows_filter_textures_and_respect_blockers`.

## LOD

- The levels arrive made: from the importer
  ([levels](../../mirai-imports/references/imports.md#levels-of-detail)) or, for a mesh made at
  runtime, from `host.assets_render_geometry_make` in a job, with the same builder. The renderer
  does not simplify: `mesh_add` registers a single level. A cluster belongs to one slot, so no
  triangle mixes materials.
- Level selection in the culling: [techniques](gi.md#lighting-techniques-and-optimization).

## Material previews and thumbnails

- The material picker draws spheres in the UI pass: their quads carry the material row and
  evaluate the same Surface, maps and BRDF as the scene, with antialiased coverage and without
  offscreen targets.
- Models, objects, prefabs and meshes use `renderer_thumbnail`: an offscreen GPU pass with
  orthographic framing (`thumbnail_view`, a `Camera` like that of a scene). With `fit` the framing
  also encloses a world box: the images of a moving subject share the view.
- Both routes use the analytic studio of `studio.slang`, independent of the scene's lights, probes
  and exposure, and the [previews curve](display.md#display-transform); the programs receive real
  context and parameters. The studio frame carries `FRAME_FLAG_STUDIO` and `studio_emission` takes
  the emission to its scale.
- **Document previews** (`renderer_preview`): the same pass inside the frame, toward a part of a
  square table entry with the shape of whoever shows it. `Preview_View` moves the camera;
  `Preview_Light` chooses the studio or a sun and sky like those of a scene, exposed as by a
  scene's meter.
- They reuse buffers and targets and touch neither scene, camera nor main histories; extraction
  and readback are transactions between frames. `renderer_thumbnail_values` also reads the material
  channels (`Thumbnail_Target`; of a program, what it writes before clamping it) for
  `material.preview.capture`. The [editor](../../mirai-editor/references/panels.md#previews) caches
  the result in an atlas (`renderer_set_thumbnails`).
- **Impostors** (`render/impostor.odin`): `impostor_capture` draws with the same pass (the
  `impostor` variant of `thumbnail.frag`, without light) the frames of a hemi-octahedral grid of
  the scene's meshes, from their CPU copy and with the scene's material table: base color and
  coverage, normal and depth. What is not covered is extended by `impostor_dilate`, on any thread,
  like the levels (`texture_build`, which `texture_add_built` uploads afterwards). The grid and the
  axes of each frame are `impostor_direction` and `impostor_axes`; a shader that draws an impostor
  repeats them ([foliage](../../mirai-world/references/foliage.md#far-impostor-and-crown)).

## Traced reflections

- **Roughness that decides.** Which pixels trace, which share a ray, which see the detail and how
  much they yield to the probe volume is decided by the material's roughness, not the one widened
  by specular antialiasing, which only enlarges the ray footprint and the lobe energy.
- **Sampling.** Each cell takes the direction of its GGX lobe (the VNDF, the tail trimmed) of the
  stratum of its place in a fixed pattern of the screen, the same every frame; below
  `MIRROR_ROUGHNESS` it traces the mirror direction. At a sharp hit (`Reflections.Detailed`), one
  ray to each light up to `reflection_light_budget`; above it, groups of the
  [light tree](lights.md#local-lights). A light the maps of the view hold takes its shadow from
  them and the glass on the way from their tint, without a ray. A rough reflection
  (`Reflections.Traced`) takes the light of what it hits from the probe volume instead of lights
  and shadows.
- **Half resolution.** From `REFLECTION_SHARED_ROUGHNESS` a 2×2 block shares a ray traced from one
  of its pixels, always the same; `reflection_half_resolution` turns it off.
- **Filter.** Only the rays of the frame, so that a reflection never depends on another frame. One
  that is not a mirror is the mean of the cells over a tile of the pattern around the pixel, which
  holds each stratum once; the tile slides with the pixel, and the cells count by how much the
  pixel they were traced from resembles this one, the relief of a surface (waves) less than an
  edge.
- **Transition.** Between half of `reflection_roughness` and that limit, the traced reflection
  yields to that of the probe volume.
- **Detail.** Below `reflection_detail_roughness` the reflection shows the glass that its ray
  crosses (as a color filter) and the specular lobe of the hit; the rougher ones see diffuse hits
  and the [medium filter](#medium-filter) of the glass they cross.

## Glass

`transmission` turns a blend material into glass, with the parameters of
`KHR_materials_transmission`, `KHR_materials_ior` and `KHR_materials_volume` (`render/glass.odin`):

- **Filter.** It does not diffuse: it reflects according to its IOR and lets through the rest of
  the light from behind multiplied by `mix(white, base color, alpha)`.
- **Material layers.** Coat, fuzz, anisotropy, diffuse transmission and unlit are prepared with
  `shading_layers` and composed as over an opaque base (`glass_shading`, `glass_light`). The light
  from behind crosses them once (`shading_through`): the coat leaves to the view what it does not
  reflect, tinted by its color, without the darkening of a base that returns it, and the fuzz what
  it does not take. The layer traces the base's reflection; the coat's comes from the probe volume.
- A transmissive material is drawn as blend even if its mode is `opaque`, with its whole base color
  as a filter; `mask` ignores the transmission.
- **Sheet or solid.** With `thickness` 0 it is a sheet: seen from both sides and it does not bend
  the view.
- With thickness, the mesh is the border of a solid: only its front faces are surfaces; the view
  refracts on entering and leaving. The exit is looked for with a ray inside the mesh, with up to
  three segments with total internal reflection.
- Panel shortcut: if the mesh box (with the instance scale) has one side of no more than 20 % of
  the smaller of the other two and the view enters through a large face, it exits through the
  parallel face at `thickness / cosine of the refracted angle`, in the direction of arrival.
- `attenuation_color` and `attenuation_distance` absorb according to the path (Beer-Lambert), and
  `scatter_color` is the part of what it stops that scatters toward the eye, with the sky light
  that reaches it inside, dimmed by the path from the roof of the solid. Both hold on every path
  through the solid, also from inside and in what is traced.
- An open mesh (without an exit for the inside ray, like the surface of water) follows the
  refracted ray to what it finds, and the solid reaches up to there.
- **From inside.** The camera can be inside a solid: the candidate is the blend instance with a
  solid material (`material_solid`; a sheet without thickness, like a skylight, is not a medium)
  below the roof of whose box (or less than `GLASS_MEDIUM_NEAR` above it), and within its sides, is
  the camera: the one with the smallest box counted up to the camera when it is below it. Below and
  not only inside, because below a sheet open from below (the surface of water) one is inside.
  - Near the roof, above or below it, each pixel decides where its ray starts on the near plane:
    the surface line crosses the lens.
  - In the nearest layer, a back face of the candidate is an exit face (`GBUFFER_GLASS_EXIT`):
    with nothing of the solid in front, it proves the camera is inside. There the view exits
    refracting (from IOR to 1) within the Snell window and the face reflects inward the rest, all
    beyond the critical angle, with its F0 at the outside angle. The internal reflection continues
    through the solid also seeing what is in it (what is in the water) and is absorbed along its
    path; under an open sheet, up to what it finds.
  - The solid absorbs and scatters from the camera to the first layer, or without a layer to the
    opaque scene. For that, a thread per group traces from the camera upward in the candidate:
    inside if the first thing of it that it finds is a back face.
  - All that is a pass of its own (`glass_inside.comp`) after that of the nearest layer, which
    reads the same copy of the scene; it runs only while there is a candidate, and the glass pass
    leaves the exit faces untouched. The exit face does not trace the reflections pass. The layers
    that are not the nearest and what is drawn behind them do not change.
- **Scene behind.** From the exit point the on-screen scene is looked for over the opaque depth; if
  the ray leaves the screen or comes back toward the camera, it is traced in the world and the hit
  is lit like that of a reflection. A rough glass spreads that read over a disc.
- **Layers.** `glass_layers` are the nearest blend surfaces of each pixel that are lit this way,
  once per pixel; each layer reads the scene from a copy. Those behind are drawn forward, back to
  front: they filter, absorb and do not refract, and layers are discarded by depth equality between
  two pipelines with the same vertex shader. Sun and local lights trace their shadow only if they
  would contribute more than a threshold.
- **Reflection.** The first layer uses the reflections pass with its own target, one ray per 2×2
  block at any roughness; where it reflects little of what it sees, the hit and the surfaces
  behind take their light from the probe volume. Inside the solid the camera is in, a reflection
  ends where the solid lets little of its light through.
- **Rays.** A blend-only instance is the class `RAY_GLASS`: the rays that do not see the glass do
  not visit it.
- **No glass in view.** If no blend instance touches the frustum, these passes are not recorded. If
  all are hidden, the layer raster draws nothing and the indirect dispatches have size zero (the
  cull's two-phase occlusion decides).
- The reflection filter discards its history if the passes did not run in the previous frame.
- **Limits.** Glass appears in sharp reflections only as a color filter; behind the layers it does
  not refract; TAA reprojects it with the motion of what is behind it; no caustics or dispersion.
  From inside: a single solid per view (no relative IOR for a glass inside water), what lies
  between two layers inside the solid is not absorbed, and neither shadows nor GI nor particles are
  absorbed in it; the light beams in it are those of
  [`fog`](../../mirai-plugins/references/render-plugins.md#fog).

### Medium filter

The light that crosses glass is paid for with its detail only where it is seen:

- **With detail**, the filter of each texel
  ([colored shadows](lights.md#colored-shadow-filters)): the direct light of the view (its
  samples) and the sharp reflections.
- **With the instance's medium filter**: the rays of the probe volume, the rough reflections, the
  scene that the glass traces behind itself, the shadow rays of what all of them find and the own
  light of the blend surfaces. The sky light enters through a stained-glass window with its color.
- `glass_mean.comp` writes it in `Gpu_Instance.glass`: the filter of each blend face averaged by
  area, evaluating the same material as the visible surface; the faces with a program, from their
  [points](#surface-programs-in-rays-and-raster). It runs in the first view of a frame that
  uploaded the instance table, an instance with blend faces, materials or geometry, before any
  ray, only with `colored_shadows` and glass in the scene.
- In the traversal (`BLEND_MEANS`), a blend-only instance multiplies the ray's filter by its mean
  without reading the triangle; a mixed one reads the triangle's material to know whether it is
  blend. No ray reads textures or evaluates programs for that; glass with a program is corrected
  afterwards by its [deferred filters](#surface-programs-in-rays-and-raster) where the light is
  seen with detail.
- A nearer hit ray also finds the glass beyond its hit if it visits it first: then it traverses
  again up to the hit (`trace_segment`).
- Focal test: `glass_tints_the_indirect_light_with_its_mean`, with each tracer; demo scene:
  `church/church.scene`.
- **Limits.** The medium filter has no drawing nor depends on the direction; a ray that exits
  through an extension's door counts in its first segment also the glass between the door and what
  it would have found without it; the [indirect reference](gi.md#indirect-reference) goes through
  the glass without a filter.

## Limits

No node-based material editing or view (the [graph](#derived-graph) is derived from the code),
virtual textures, subsurface, iridescence, dispersion or OpenPBR transmission outside of glass.

- The [residency by distance](#residency-by-distance) does not see nested views (a portal): what is
  seen through them resides by its distance to the camera. A texture shown by a distant instance
  and something outside the scene (a particle) resides by the instance.

- Of the glass, the layers do not reach the ray filters (colored shadows, medium filter) or the exit
  face seen from inside (`glass_inside.comp`).
