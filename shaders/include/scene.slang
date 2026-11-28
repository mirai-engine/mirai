// Global scene table. Unused declarations are stripped by the optimizer, so
// each pipeline only requires the slots it actually reads.
#ifndef MIRAI_SCENE_SLANG
#define MIRAI_SCENE_SLANG
#include "common.slang"
#include "mirai_material.slang"
#include "batch_instance.slang"
// The Surface program a stage evaluates: none in a stage of the engine (the
// include of the generation), its own in the stages of a program
// (`//! per surface program`), whose include comes first.
#include <surface_programs.slang>

[[vk::binding(SLOT_FRAME, 0)]] ConstantBuffer<Frame_Data> frame : register(MIRAI_REGISTER(b, SLOT_FRAME), space0);

// Whether an instance, by its flags (Instance.meta.w), is of the own body of the view (frame.own).
bool view_owns(uint flags) {
    uint slot = frame.own & 0xffu;
    return slot != 0u && (flags & INSTANCE_FLAG_OWNED) != 0u && ((flags >> INSTANCE_OWNER_SHIFT) & 3u) == slot - 1u;
}

// How much of an instance the view fades out: of its own body, 1 all of it; of another, 0.
float view_body_fade(uint flags) {
    return view_owns(flags) ? float(frame.own >> 16u) / 65535.0 : 0.0;
}

// Whether the view draws what is in these layers (16 bits), of an instance with these flags:
// it draws its layers, and of its own body, not those it leaves out (bits 16-31 of frame.layers).
bool view_draws_layers(uint layers, uint flags) {
    return (layers & frame.layers & 0xffffu) != 0u && !(view_owns(flags) && (layers & (frame.layers >> 16u)) != 0u);
}

// The threshold of a cell of a 4x4, 0 to 1, in an order that keeps the
// cells below any threshold far apart (Bayer): what fades out by `fade`
// leaves out the cells whose threshold is below it.
static const uint FADE_ORDER[16] = {0u, 8u, 2u, 10u, 12u, 4u, 14u, 6u, 3u, 11u, 1u, 9u, 15u, 7u, 13u, 5u};
float fade_threshold(uint2 cell) {
    return (float(FADE_ORDER[(cell.y & 3u) * 4u + (cell.x & 3u)]) + 0.5) / 16.0;
}
// Whether a pixel of what fades out by `fade` (0 to 1) is left out. The
// thresholds move each frame of the view by the bits of its turn reversed
// (van der Corput): from a cut, every 2, 4, 8 or 16 frames give each pixel
// thresholds spaced evenly over the whole range, so the frames the TAA
// blends, from the first ones after a cut to its still history, hold as much
// of the fade at every pixel and no pattern stays.
bool fade_pixel_left(uint2 pixel, float fade) {
    float turn = float(reversebits(frame.frame_index) >> 8u) * (1.0 / 16777216.0);
    return frac(fade_threshold(pixel) + turn) < fade;
}
[[vk::binding(SLOT_LINEAR_SAMPLER, 0)]] SamplerState linear_sampler : register(MIRAI_REGISTER(s, SLOT_LINEAR_SAMPLER), space0);
[[vk::binding(SLOT_POINT_SAMPLER, 0)]] SamplerState point_sampler : register(MIRAI_REGISTER(s, SLOT_POINT_SAMPLER), space0);
[[vk::binding(SLOT_MATERIAL_SAMPLER, 0)]] SamplerState material_sampler : register(MIRAI_REGISTER(s, SLOT_MATERIAL_SAMPLER), space0); // trilinear, anisotropic, repeating
[[vk::binding(MATERIAL_TEXTURE_SLOT, 1)]] Texture2D<float4> material_textures[] : register(MIRAI_REGISTER(t, MATERIAL_TEXTURE_SLOT), space1);
#ifdef INSTANCES_WRITABLE
[[vk::binding(SLOT_INSTANCES, 0)]] RWStructuredBuffer<Instance> instances : register(MIRAI_REGISTER(u, SLOT_INSTANCES), space0);
#else
[[vk::binding(SLOT_INSTANCES, 0)]] StructuredBuffer<Instance> instances : register(MIRAI_REGISTER(t, SLOT_INSTANCES), space0);
#endif
[[vk::binding(SLOT_MESHES, 0)]] StructuredBuffer<Mesh> meshes : register(MIRAI_REGISTER(t, SLOT_MESHES), space0);
// The pools of the geometry (render/gpu_types.odin), read through geometry.slang.
#ifdef VERTICES_WRITABLE
[[vk::binding(SLOT_VERTICES, 0)]] RWStructuredBuffer<uint> vertex_words : register(MIRAI_REGISTER(u, SLOT_VERTICES), space0);
#else
[[vk::binding(SLOT_VERTICES, 0)]] StructuredBuffer<uint> vertex_words : register(MIRAI_REGISTER(t, SLOT_VERTICES), space0);
#endif
[[vk::binding(SLOT_INDICES, 0)]] StructuredBuffer<uint> indices : register(MIRAI_REGISTER(t, SLOT_INDICES), space0);
#include "geometry.slang"
[[vk::binding(SLOT_MATERIALS, 0)]] StructuredBuffer<Material_Row> materials : register(MIRAI_REGISTER(t, SLOT_MATERIALS), space0);
[[vk::binding(SLOT_LIGHTS, 0)]] StructuredBuffer<Light> lights : register(MIRAI_REGISTER(t, SLOT_LIGHTS), space0);
[[vk::binding(SLOT_LIGHT_TREE, 0)]] StructuredBuffer<Light_Node> light_nodes : register(MIRAI_REGISTER(t, SLOT_LIGHT_TREE), space0);
#ifdef PROBES_WRITABLE
[[vk::binding(SLOT_PROBES, 0)]] RWStructuredBuffer<Probe> probes : register(MIRAI_REGISTER(u, SLOT_PROBES), space0);
#else
[[vk::binding(SLOT_PROBES, 0)]] StructuredBuffer<Probe> probes : register(MIRAI_REGISTER(t, SLOT_PROBES), space0);
#endif
[[vk::binding(SLOT_IRRADIANCE, 0)]] Texture2D<float4> irradiance_atlas : register(MIRAI_REGISTER(t, SLOT_IRRADIANCE), space0);
[[vk::binding(SLOT_DISTANCE, 0)]] Texture2D<float4> distance_atlas : register(MIRAI_REGISTER(t, SLOT_DISTANCE), space0);
[[vk::binding(SLOT_SURFACE, 0)]] Texture2D<float4> surface_specular : register(MIRAI_REGISTER(t, SLOT_SURFACE), space0);
// The views target of the view while it has nested views (FRAME_FLAG_NESTED):
// 1 + the nested view of each pixel, 0 for the view itself (pixel_view).
[[vk::binding(SLOT_VIEWS, 0)]] [[vk::image_format("r8ui")]] Texture2D<uint> pixel_views : register(MIRAI_REGISTER(t, SLOT_VIEWS), space0);
#include "brdf.slang"
#include "air.slang"

// F0 and the encoded F90 of a G-buffer pixel. Most scenes hold only the
// default dielectric, whose reflectance its albedo (a = metallic) gives by
// itself; the G-buffer keeps what each pixel evaluated (`stored`) while some
// surface departs from it: specular maps and factors, another IOR, a program.
float4 pixel_reflectance(int2 p, float4 albedo, bool stored) {
    if (stored) return surface_specular.Load(int3(p, 0));
    return float4(specular_f0(albedo.rgb, albedo.a), 1.0);
}

// ---------------------------------------------------------------- the view
// The ray of the pixel at uv, for any projection: where it is at linear depth
// 0, and what a unit of linear depth moves a point along it (not a unit vector).
float3 view_origin(float2 uv) { return frame.eye_origin.xyz + frame.eye_du.xyz * uv.x + frame.eye_dv.xyz * uv.y; }
float3 view_ray(float2 uv) { return frame.ray_origin.xyz + frame.ray_du.xyz * uv.x + frame.ray_dv.xyz * uv.y; }
// A point of the view itself from its linear depth (G-buffer R32F), and the
// direction the eye sees it in. For a pixel that may be of a nested view, pixel_at.
float3 position_from_depth(float2 uv, float linear_depth) { return view_origin(uv) + view_ray(uv) * linear_depth; }
float3 view_direction(float2 uv) { return normalize(view_ray(uv)); }
float view_depth(float3 world) { return dot(frame.depth_plane.xyz, world) + frame.depth_plane.w; }
// The unit vector from a point towards the eye, and how far the eye is from it.
float3 to_eye(float3 world) { return normalize(frame.eye.xyz - world * frame.eye.w); }
float eye_distance(float3 world) { return frame.eye.w > 0.5 ? length(frame.eye.xyz - world) : view_depth(world); }
// The clip position of a place for the camera of the view, jittered, without
// the jitter, and for the camera of the frame before: the matrices take it
// from the eye, so a place near the eye keeps what f32 holds of it however far
// from the origin the view is.
float4 view_clip(float3 world) { return mul(frame.view_proj, float4(world - frame.camera_position.xyz, 1.0)); }
float4 view_clip_unjittered(float3 world) { return mul(frame.view_proj_unjittered, float4(world - frame.camera_position.xyz, 1.0)); }
float4 view_clip_previous(float3 world) { return mul(frame.prev_view_proj, float4(world - frame.prev_eye.xyz, 1.0)); }
// How far a ray goes before it leaves the box of what rays meet
// (frame.scene_box), a little past it: all a ray that looks for the scene
// alone needs, as one towards the sun. 0 for one that does not cross it.
float scene_reach(float3 origin, float3 direction) {
    float3 low = frame.scene_box[0].xyz, high = frame.scene_box[1].xyz;
    if (any(low > high)) return 0.0;
    float3 inverse = 1.0 / select(abs(direction) < float3(1e-12), float3(1e-12), direction);
    float3 a = (low - origin) * inverse, b = (high - origin) * inverse;
    float3 far = max(a, b), near = min(a, b);
    float leave = min(far.x, min(far.y, far.z));
    return leave >= max(max(near.x, max(near.y, near.z)), 0.0) ? leave * 1.001 + 0.01 : 0.0;
}

// How far a shadow ray goes toward the sun: none (no traversal) while it casts no shadows.
float sun_reach(float3 origin, float3 direction) {
    return frame.sun_direction.w >= SUN_UNSHADOWED ? 0.0 : scene_reach(origin, direction);
}
float2 project_uv(float3 world) {
    float4 clip = view_clip(world);
    float2 ndc = clip.xy / clip.w;
    return float2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
}

// A pixel of the G-buffer in the world: where it is, the direction the eye
// that drew it sees it in and how far from that eye. pixel_at
// (pixel.slang) finds it.
struct Pixel {
    float3 position;
    float3 view;     // unit, from the eye towards the pixel
    float distance;  // from the eye, along view
};

// The levels of the image of the sky left out of what a ray that gathers
// reads: it takes the sky from a few texels across, without the noise of its detail.
static const float SKY_GATHER_LEVELS = 5.0;

// Render units per nit (Scene.light_scale).
float light_scale() { return frame.sky_color.w; }

// A luminance in nits in render units: emission enters the light of the frame here.
float3 render_units(float3 nits) { return nits * light_scale(); }

// A direction of the world as one of the sky, which turns with its entity.
float3 sky_direction(float3 dir) {
    float3 u = -frame.sky_orientation.xyz;
    return dir + 2.0 * cross(u, cross(u, dir) + frame.sky_orientation.w * dir);
}

// An image of the sky (map as Frame.sky_map) at a level of its mip chain,
// times its luminance. The image has the whole turn across and the zenith at
// its top, twice as wide as tall; its rows do not wrap: the top one is not
// next to the bottom one, though the sampler repeats. A read keeps to the
// middle of the top and bottom rows of the coarser level it blends, which at
// the levels of an irradiance are a few rows in all.
float3 sky_image(float4 map, float3 color, float3 dir, float level) {
    float edge = 0.5 / exp2(max(map.z - 1.0 - ceil(level), 0.0));
    float2 uv = float2(atan2(dir.z, dir.x) / (2.0 * PI) + 0.5, clamp(acos(clamp(dir.y, -1.0, 1.0)) / PI, edge, 1.0 - edge));
    return color * material_textures[mirai_nonuniform(uint(map.x))].SampleLevel(material_sampler, uv, level).rgb;
}

// Without an image, a gradient: the horizon slightly brighter, the ground darker.
float3 sky_gradient(float3 color, float3 dir) {
    float up = clamp(dir.y * 0.5 + 0.5, 0.0, 1.0);
    return lerp(color * 0.35, color, smoothstep(0.2, 0.8, up));
}

// The light of the sun at a place: above the air of an atmosphere, what of
// it crosses the air to the altitude of the place.
float3 sun_light(float3 position) {
    if (frame.sky_map.y < 0.5) return frame.sun_color.rgb;
    float r = max(air_eye_radius(frame.air) + position.y - frame.camera_position.y, frame.air.planet.x + AIR_GROUND_MARGIN);
    return frame.sun_color.rgb * air_sun(frame.air, r, frame.sun_direction.y);
}

// What the sun sends from a surface towards its eye with nothing in its way, share of
// it (the light a pass takes of the sun); a surface without a normal takes it whole.
float3 sun_radiance(Shading s, float share = 1.0) {
    if (frame.sun_direction.w < 0.5 || !(share > 0.0)) return float3(0.0);
    float cosine = dot(s.normal, s.normal) > 0.5 ? dot(s.normal, frame.sun_direction.xyz) : 1.0;
    if (cosine <= 0.0) return float3(0.0);
    return sun_light(s.position) * (cosine * share) * shading_response(s, frame.sun_direction.xyz);
}

// The illuminance of the sun above the air, render units: sun_color is the
// light that reaches the ground with the sun overhead unless the sky on is
// the atmosphere (a change from one).
float3 sun_above_air() { return frame.sun_color.rgb * PI * (frame.sky_map.y > 0.5 ? float3(1.0) : frame.air.rows.yzw); }

// The light of the air in a direction of the world, seen from the eye of the
// frame (air_sky); without a sun, none.
float3 sky_atmosphere(float3 dir) {
    if (frame.sun_direction.w < 0.5) return float3(0.0);
    return air_sky(frame.air, dir, frame.sun_direction.xyz) * sun_above_air();
}

// Directions about a normal whose mean is what the hemisphere gives a white
// Lambert surface: concentric rings of equal share of the cosine, always the same ones.
#define SKY_IRRADIANCE_DIRECTIONS 8u

// What the light of the air gives a surface with that normal, as the
// luminance of the white Lambert surface it lights.
float3 sky_atmosphere_irradiance(float3 normal) {
    if (frame.sun_direction.w < 0.5) return float3(0.0);
    float3 across, up;
    make_basis(normal, across, up);
    float3 sum = float3(0.0);
    for (uint i = 0u; i < SKY_IRRADIANCE_DIRECTIONS; i++) {
        float radius = sqrt((float(i) + 0.5) / float(SKY_IRRADIANCE_DIRECTIONS));
        float angle = float(i) * 2.39996323;
        float2 disc = radius * float2(cos(angle), sin(angle));
        float3 dir = normalize(across * disc.x + up * disc.y + normal * sqrt(saturate(1.0 - dot(disc, disc))));
        sum += air_sky(frame.air, dir, frame.sun_direction.xyz);
    }
    return sum / float(SKY_IRRADIANCE_DIRECTIONS) * sun_above_air();
}

// One look of the sky: its atmosphere in the direction of the world (what it
// gives a surface of that normal, for an irradiance: below_last not
// negative), or in the direction of the sky its image at the level that
// spread picks (or below_last levels under its last one), or its gradient.
float3 sky_look(float4 map, float3 color, float3 world_dir, float3 dir, float spread, float below_last) {
    if (map.y > 0.5) return below_last >= 0.0 ? sky_atmosphere_irradiance(world_dir) : sky_atmosphere(world_dir);
    if (map.w < 0.5) return sky_gradient(color, dir);
    float level = below_last >= 0.0 ? max(map.z - below_last, 0.0) : saturate(spread) * max(map.z - SKY_GATHER_LEVELS, 0.0);
    return sky_image(map, color, dir, level);
}

// The sky now in a direction of the world, mixed with the one it changes
// from while a change is on its way.
float3 sky_mixed(float3 dir, float spread, float below_last) {
    float3 d = sky_direction(dir);
    float3 now = sky_look(frame.sky_map, frame.sky_color.rgb, dir, d, spread, below_last);
    if (frame.sky_from.w <= 0.0) return now;
    float3 was = sky_look(frame.sky_from_map, frame.sky_from.rgb, dir, d, spread, below_last);
    return lerp(now, was, frame.sky_from.w);
}

// The light of the sky from a direction. `spread` is how much of the sky the
// ray stands for: 0 a pixel that looks at it, 1 a ray that gathers light.
float3 sky_radiance(float3 dir, float spread = 1.0) {
    return sky_mixed(dir, spread, -1.0);
}

// What the sky gives a surface with that normal, as the luminance of the
// white Lambert surface it lights: the gradient at the normal, the image
// read from a level a few texels across, about what a hemisphere gathers, or
// the hemisphere of the air.
float3 sky_irradiance(float3 normal) {
    return sky_mixed(normal, 1.0, 2.0);
}

// No pixel of the sun is brighter than this many times its light: the disc is
// a few pixels wide, and what filters the image has to hold it.
static const float SUN_DISC_MAX = 400.0;

// The sky as the eye sees it: with the disc of the sun and the glow around
// it. Rays that gather light take sky_radiance: the sun reaches what they hit
// as the light it is.
float3 sky_seen(float3 dir) {
    float3 sky = sky_radiance(dir, 0.0);
    float radius = frame.sun_color.w;
    if (frame.sun_direction.w < 0.5 || radius <= 0.0) return sky;
    float angle = acos(clamp(dot(dir, frame.sun_direction.xyz), -1.0, 1.0));
    if (angle > 0.5) return sky;
    // The disc sends the light of the sun: what reaches a surface over the solid angle it comes from.
    float disc = min(1.0 / (PI * radius * radius), SUN_DISC_MAX) * smoothstep(radius, radius * 0.8, angle);
    float glow = 2.0 * exp(-angle / (3.0 * radius)) + 0.2 * exp(-angle / 0.07);
    return sky + sun_light(frame.camera_position.xyz) * (disc + glow);
}

// The background in a direction of the world: its image (Frame.background_map),
// turned as the sky, at the level spread picks, times its color; or its color.
float3 background_look(float3 dir, float spread) {
    float4 map = frame.background_map;
    if (map.w < 0.5) return frame.background.rgb;
    return sky_image(map, frame.background.rgb, sky_direction(dir), saturate(spread) * max(map.z - SKY_GATHER_LEVELS, 0.0));
}

// What the eye sees past the scene: the background when the frame shows one,
// else the sky with the sun.
float3 sky_shown(float3 dir) {
    return frame.background.w > 0.5 ? background_look(dir, 0.0) : sky_seen(dir);
}

// What a reflection of that roughness (spread) sees of the sky: the sky as
// what gathers light sees it (sky_radiance), never its detail; where the frame
// shows the background there, a mirror sees it as a camera would, and a
// rougher lobe less of it, none when fully rough.
float3 sky_reflected(float3 dir, float spread) {
    float3 light = sky_radiance(dir);
    return frame.background_map.y > 0.5 ? lerp(background_look(dir, spread), light, saturate(spread)) : light;
}

// ---------------------------------------------------------------- instances of batches
// Below frame.instance_count an instance index names an instance of the
// scene; from it on, an instance of a batch (render/batch.odin): its slot
// among those of the batches drawn, BATCH_GROUP slots a group. The group
// table, a word per group in the u32 pool from frame.batches.y, names the
// batch of each group, whose row follows the instances in the instance table.
// A row keeps in its transforms, which none of its instances has, where they
// are and how they are drawn. An instance is BATCH_WORDS words of the pool:
// its position, its rotation (quat_pack of std/math, 10 bits) and its scale
// along x, y and z, half floats; a batch with colors has a word more of
// each in the pool (render.batch_color).

bool instance_batched(uint index) { return index >= frame.instance_count; }
uint batch_of(uint index) { return indices[frame.batches.y + (index - frame.instance_count) / BATCH_GROUP]; }
Instance batch_row(uint batch) { return instances[frame.instance_count + batch]; }
uint batch_records(Instance row) { return asuint(row.world[0].x); }  // the first word of its instances in the pool
// Its instances: of one the GPU fills (render.batch_reserve), those its
// Instances stage wrote in the view, whose count is the word before them, up
// to its room.
uint batch_count(Instance row) {
    uint filled = asuint(row.world_inv[2].z);
    return filled != 0u ? min(indices[filled - 1u], asuint(row.world[0].y)) : asuint(row.world[0].y);
}
uint batch_first(Instance row) { return asuint(row.world[0].z); }    // the slot of its first instance
uint batch_tree(Instance row) { return asuint(row.world[0].w); }     // the root of the tree of its instances in the BLAS nodes
uint batch_order(Instance row) { return asuint(row.world[1].x); }    // the instances of the leaves of that tree, in the pool
float batch_fade(Instance row) { return row.world[1].y; }            // metres from the eye where it starts to fade out
float batch_cull(Instance row) { return row.world[1].z; }            // metres from the eye where it is gone; 0: never
float batch_sway(Instance row) { return row.world[1].w; }            // metres of the space of its mesh the hook sways a point in its wind at most; 0: it casts at rest
uint batch_visible(Instance row) { return asuint(row.world[2].x); }  // its first entry of the visible list
uint batch_levels(Instance row) { return asuint(row.world[2].y); }   // of detail of its mesh, a draw record and a visible list each
uint batch_draw(Instance row) { return asuint(row.world[2].z); }     // its first draw record after those of the instances
uint batch_classes(Instance row) { return asuint(row.world[2].w); }  // of rays that meet it (RAY_* of trace.slang)
float4 batch_vertex(Instance row) { return row.world_inv[0]; }       // what the vertex hook of the generation reads of it
float3 batch_anchor(Instance row) { return row.world_inv[1].xyz; }   // what its instances in the pool, its tree and its box are relative to, relative to the origin
float batch_reach(Instance row) { return row.world_inv[1].w; }       // metres the vertex hook moves a point of its instances at most
uint batch_colors(Instance row) { return asuint(row.world_inv[2].x); } // 1 + the word of the color of its first instance in the pool; 0: none
float batch_swayed(Instance row) { return row.world_inv[2].y; }      // metres of the world its largest instance sways as its wind blows now (render.batch_swayed)
// Its world_inv[2].z: of one the GPU fills, the first word of its instances, past its count; 0 otherwise.
// Its prev_world: the basis its instances take (batch_basis_placement), zero without one.

// The transform of the instance of a batch whose words start at `words`,
// moved by the anchor of its batch, and its inverse.
void batch_placement(uint words, float3 anchor, out float4 world[3], out float4 inverse[3]) {
    float3 p = asfloat(uint3(indices[words], indices[words + 1u], indices[words + 2u])) + anchor;
    batch_instance_placement(p, indices[words + 3u], uint2(indices[words + 4u], indices[words + 5u]), world, inverse);
}

// The box in the world of a box of its own space under a transform.
void box_transformed(float4 world[3], float3 bounds_min, float3 bounds_max, out float3 low, out float3 high) {
    float3 center = transform_point(world, (bounds_min + bounds_max) * 0.5);
    float3 half_size = (bounds_max - bounds_min) * 0.5;
    float3 extent = float3(dot(abs(world[0].xyz), half_size), dot(abs(world[1].xyz), half_size), dot(abs(world[2].xyz), half_size));
    low = center - extent;
    high = center + extent;
}

// The box in the world of a mesh under a transform.
void transformed_bounds(float4 world[3], Mesh mesh, out float3 low, out float3 high) {
    box_transformed(world, mesh.bounds_min.xyz, mesh.bounds_max.xyz, low, high);
}

// The meta.x of the instance an index names, its mesh and the cut rays trace
// it with, without placing an instance of a batch.
uint scene_mesh_word(uint index) {
    return instance_batched(index) ? batch_row(batch_of(index)).meta.x : instances[index].meta.x;
}

// The instance an index names, of the scene or of a batch: that of a batch
// is the row of its batch with its own transforms and box, at rest, and its
// own tint and wetness when its batch has colors.
Instance scene_instance(uint index) {
    if (!instance_batched(index)) return instances[index];
    Instance inst = batch_row(batch_of(index));
    uint k = index - frame.instance_count - batch_first(inst);
    uint colors = batch_colors(inst);
    if (colors != 0u) {
        uint c = indices[colors - 1u + k];
        inst.tint.rgb *= float3(float(c & 255u), float((c >> 8u) & 255u), float((c >> 16u) & 255u)) / 255.0;
        inst.wet = float(c >> 24u) / 255.0;
    }
    float4 basis[3] = inst.prev_world;
    batch_placement(batch_records(inst) + k * BATCH_WORDS, batch_anchor(inst), inst.world, inst.world_inv);
    batch_basis_placement(float3(inst.world[0].w, inst.world[1].w, inst.world[2].w), basis, inst.world, inst.world_inv);
    inst.prev_world = inst.world;
    float3 low, high;
    transformed_bounds(inst.world, meshes[instance_mesh(inst)], low, high);
    inst.bounds_min.xyz = low;
    inst.bounds_max.xyz = high;
    return inst;
}

// How much of what has that box fades out between `fade` and `cull` metres
// from the eye (cull 0: never): 1 where it is gone.
float box_faded(float3 low, float3 high, float fade, float cull) {
    if (cull <= 0.0) return 0.0;
    float3 eye = frame.camera_position.xyz;
    float start = min(fade, cull);
    return saturate((length(eye - clamp(eye, low, high)) - start) / max(cull - start, 1e-4));
}

// How much of an instance of a batch with that box its size on the screen
// fades out: 1 where the diagonal of its box spans frame.cut.y pixels or
// fewer, 0 from twice that, between them the pattern of the fade.
float box_small_faded(float3 low, float3 high) {
    float least = frame.cut.y;
    if (least <= 0.0) return 0.0;
    float3 eye = frame.detail_eye.xyz;
    float distance = max(length(eye - clamp(eye, low, high)), frame.detail_eye.w);
    float pixels = length(high - low) / max(frame.detail_footprint.x + frame.detail_footprint.y * distance, 1e-9);
    return saturate((2.0 * least - pixels) / least);
}

// How much of an instance of a batch with that box the raster fades out: 1 at
// its cull distance, or as small on the screen as Settings.batch_min_pixels,
// where it is no longer drawn. Rays meet it all the same.
float batch_faded(Instance row, float3 low, float3 high) {
    return max(box_faded(low, high, batch_fade(row), batch_cull(row)), box_small_faded(low, high));
}

// ---------------------------------------------------------------- materials

// A material evaluated at one point of a surface.
struct Material_Sample {
    float3 base_color;
    float alpha;
    float metallic;
    float roughness;
    float occlusion;
    float3 emission;
    bool emission_relative;  // the emission is the exposed value (EMISSION_RELATIVE), not nits
    float3 f0;
    float f90;
    Material_Layers layers;
};

// The row of the instances whose slots an instance of the scene or of a
// batch takes: its own, or that of its batch.
uint instance_row(uint index) { return instance_batched(index) ? frame.instance_count + batch_of(index) : index; }

// The slots are read from the row of the instances (instance_row), not from
// the copy inst: an array of a copy indexed by a value is local memory once
// for every place this is inlined.
uint material_of(uint row, Instance inst, uint vertex_material) {
    uint slot = vertex_material >> 24;
    if (slot > 0u && slot <= 32u) {
        uint given = instances[row].slot_materials[slot - 1u];
        if (given != 0u) return given - 1u;
    }
    return inst.meta.y != INVALID ? inst.meta.y : (vertex_material & 0xffffffu);
}

Material material_row(uint row) {
    Material m = materials[row].shared;
    m.row = row;
    return m;
}

bool material_has(uint texture_index) { return texture_index != INVALID; }

// What an instance gives over the rows of its materials
// (render.Instance_Material_Values): `block` is Instance.material_values. A
// stage that draws no instance of a scene (MIRAI_NO_INSTANCES: the previews)
// reads none, and does not bind the pool they are in.
// Those the instance at an index gives; INVALID (a surface an extension
// draws) gives none.
uint material_values_of(uint instance_index) {
#ifdef MIRAI_NO_INSTANCES
    return 0u;
#else
    return instance_index == INVALID ? 0u : scene_instance(instance_index).material_values;
#endif
}
// Where the words of row `row` as an instance shows it start in the pool: 0
// for a row it shows as the table holds it. The CPU makes them whole when
// the instance is given what it gives (render.instance_material_values_give).
uint material_given(uint block, uint row) {
#ifndef MIRAI_NO_INSTANCES
    if (block != 0u) {
        uint rows = min(indices[block - 1u], INSTANCE_VALUES_MAX);
        for (uint i = 0u; i < rows; i++) {
            uint at = block - 1u + INSTANCE_VALUES_HEADER + i * INSTANCE_ROW_WORDS;
            if (indices[at] == row) return at + 1u;
        }
    }
#endif
    return 0u;
}
// The N words of the pool from `at`, as a T: a stage loads those it reads.
T material_words<T, let N : int>(uint at) {
    uint words[N];
    [ForceUnroll] for (int k = 0; k < N; k++) {
#ifdef MIRAI_NO_INSTANCES
        words[k] = 0u;
#else
        words[k] = indices[at + uint(k)];
#endif
    }
    return reinterpret<T>(words);
}
// How much an instance fades out by what it gives its rows (block:
// Instance.material_values), 0 none to 1 all: its blended rows by their
// opacity, the others by pixels (instance_fade).
float material_values_fade(uint block) {
#ifdef MIRAI_NO_INSTANCES
    return 0.0;
#else
    return block != 0u ? asfloat(indices[block]) : 0.0;
#endif
}
// A row as an instance shows it: its own of it, and the fade of a blended one.
Material material_row(uint row, uint block) {
    uint at = material_given(block, row);
    Material m;
    if (at == 0u) m = material_row(row);
    else m = material_words<Material, MATERIAL_WORDS>(at);
    m.row = row;
    if (material_apart(m)) m.opacity *= 1.0 - material_values_fade(block);
    return m;
}
// The parameters the program of a row reads at a point of an instance: those
// of the row, or the instance's own of it.
void material_parameters(uint row, uint block, out float4 parameters[16]) {
    uint at = material_given(block, row);
    if (at == 0u) parameters = materials[row].custom_params;
    else parameters = material_words<float4[16], PROGRAM_PARAMETER_BYTES / 4>(at + MATERIAL_WORDS + MATERIAL_BLOCK_WORDS);
}
#ifdef MIRAI_TEXTURE_FEEDBACK
// The finest level a stage that shades surfaces samples of each texture, for
// its residency (render/texture_residency.odin): the first word says how
// many textures it may write, then one per texture past the reserved entries
// of the table. Any pass, in any order: an atomic minimum.
[[vk::binding(TEXTURE_FEEDBACK_SLOT, 0)]] RWStructuredBuffer<uint> texture_feedback_words : register(MIRAI_REGISTER(u, TEXTURE_FEEDBACK_SLOT), space0);
#endif

// While true, samples record nothing: a pixel of a quad that evaluates its
// material for the derivatives of another (vis_resolve.frag).
static bool texture_feedback_quiet = false;
// Whether this is a helper of a quad of a fragment stage, which runs only for
// the derivatives of the others: what it does to memory is dropped.
bool texture_feedback_helper() {
    __stage_switch {
    case fragment: return IsHelperLane();
    default: return false;
    }
}
#ifndef MIRAI_TEXTURE_FEEDBACK_QUIET
#define MIRAI_TEXTURE_FEEDBACK_QUIET false
#endif
// Whether what this invocation samples is recorded: never in a pipeline made
// without the recording (a constant), nor by a helper or while quiet.
bool texture_feedback_on() {
#ifdef MIRAI_TEXTURE_FEEDBACK
    return !MIRAI_TEXTURE_FEEDBACK_QUIET && !texture_feedback_quiet && !texture_feedback_helper();
#else
    return false;
#endif
}
// That a texture was sampled at `level`: log2 of the texels across its width
// a sample spans at the level it reads, less log2 of that width, which no
// level held changes; -FLT_MAX for every level. The lanes of a wave that
// sample one texture write once, the finest level of them.
void texture_feedback(uint texture_index, float level) {
#ifdef MIRAI_TEXTURE_FEEDBACK
    if (!texture_feedback_on()) return;
    uint entry = texture_index - TEXTURE_TABLE_RESERVED;
    if (entry >= texture_feedback_words[0] || isnan(level)) return;
    uint code = uint(clamp(floor((level - TEXTURE_FEEDBACK_LOW) * TEXTURE_FEEDBACK_STEPS), 0.0, float(TEXTURE_FEEDBACK_CODES - 1u)));
    for (;;) {
        uint first = WaveReadLaneFirst(entry);
        if (first != entry) continue;
        uint least = WaveActiveMin(code);
        uint at = TEXTURE_FEEDBACK_FIRST + entry;
        if (WaveIsFirstLane() && least < texture_feedback_words[at]) InterlockedMin(texture_feedback_words[at], least);
        return;
    }
#endif
}

// Ray hits have no screen-space derivatives: `lod` is the level of a texture
// of one texel, which the size of the texture then shifts (see hit_lod).
float4 material_texel_at(uint texture_index, float2 uv, float lod) {
    float2 size = float2(texture_size(material_textures[mirai_nonuniform(texture_index)], 0));
    texture_feedback(texture_index, lod + 0.5 * log2(size.y / size.x));
    return material_textures[mirai_nonuniform(texture_index)].SampleLevel(material_sampler, uv, lod + 0.5 * log2(size.x * size.y));
}
#ifdef MATERIAL_GRADIENTS
// A surface resolved from the visibility target (vis_resolve.frag) is a
// triangle rebuilt at a pixel: the exact screen gradients of its inputs are
// set before its material runs, per uv set (xy along x, zw along y), and of
// its place and its interpolated normal (along x, then along y). steady:
// along each axis, the neighbor of the quad continues its surface, so a
// difference across the quad is a derivative there.
static float4 material_uv_gradients[2];
static float3 material_world_gradients[2];
static float3 material_normal_gradients[2];
static bool2 material_steady;
#endif
// That a sample of a rasterized surface reads where uv changes by dx and dy
// (uv units) along the pixel: the level anisotropic filtering reads, over the
// shorter axis of the footprint or the longer one over its samples, each axis
// the shortest a device may take of it (the larger of its two steps in texels).
void material_texel_feedback(uint texture_index, float2 dx, float2 dy, float lod) {
#ifdef MIRAI_TEXTURE_FEEDBACK
    if (!texture_feedback_on()) return;
    float2 size = float2(texture_size(material_textures[mirai_nonuniform(texture_index)], 0));
    float2 x = abs(dx * size), y = abs(dy * size);
    float across = max(x.x, x.y), down = max(y.x, y.y);
    float longer = max(across, down);
    // Where the uv do not change no level is asked.
    if (longer > 0.0) texture_feedback(texture_index, log2(max(min(across, down), longer / MATERIAL_ANISOTROPY)) + lod - log2(size.x));
#endif
}
// Rasterized surfaces (MATERIAL_RASTER, fragment shaders only) filter with the
// screen-space derivatives of uv, and `lod` is a bias.
float4 material_texel(uint texture_index, float2 uv, float lod) {
#ifdef MATERIAL_RASTER
    material_texel_feedback(texture_index, ddx(uv), ddy(uv), lod);
    return material_textures[mirai_nonuniform(texture_index)].SampleBias(material_sampler, uv, lod);
#else
    return material_texel_at(texture_index, uv, lod);
#endif
}

float2 material_map_uv(Material_Map_Transform transform, float2 uv0, float2 uv1) {
    float2 uv = transform.uv_set == 1u ? uv1 : uv0;
    return float2(dot(transform.linear.xy, uv), dot(transform.linear.zw, uv)) + transform.offset;
}
float2 material_map_uv(Material m, uint map, float2 uv0, float2 uv1) { return material_map_uv(materials[m.row].map_transforms[map], uv0, uv1); }
float4 material_map_texel(Material m, uint map, uint texture_index, float2 uv0, float2 uv1, float2 lod, bool ray) {
    Material_Map_Transform transform = materials[m.row].map_transforms[map];
    float2 uv = material_map_uv(transform, uv0, uv1);
    float level = transform.uv_set == 1u ? lod.y : lod.x;
    if (ray) level += transform.ray_lod;
#ifdef MATERIAL_GRADIENTS
    if (!ray) {
        // The gradients of its uv set, through the linear part of its transform, `level` a bias.
        float4 g = material_uv_gradients[transform.uv_set == 1u ? 1 : 0];
        float2 dx = float2(dot(transform.linear.xy, g.xy), dot(transform.linear.zw, g.xy));
        float2 dy = float2(dot(transform.linear.xy, g.zw), dot(transform.linear.zw, g.zw));
        material_texel_feedback(texture_index, dx, dy, level);
        float scale = exp2(level);
        return material_textures[mirai_nonuniform(texture_index)].SampleGrad(material_sampler, uv, dx * scale, dy * scale);
    }
#endif
    return ray ? material_texel_at(texture_index, uv, level) : material_texel(texture_index, uv, level);
}
// A direction of the tangent space of a map (xy, along its texture), in the
// axes of the mesh UVs the tangents of the surface follow (u, and v
// upwards): the transform of the map turns, and may mirror, the texture
// against them. A slope turns with the transpose of the transform; its
// scale is taken out, so a map that tiles more does not get steeper.
float2 material_map_axes(Material m, uint map, float2 xy) {
    float4 l = materials[m.row].map_transforms[map].linear;
    return float2(l.x * xy.x - l.z * xy.y, l.w * xy.y - l.y * xy.x) * rsqrt(max(abs(l.x * l.w - l.y * l.z), 1e-12));
}
// The tangent-space normal a normal map gives, scaled.
float3 material_map_normal(Material m, uint map, float scale, float2 uv0, float2 uv1, float2 lod, bool ray) {
    float2 xy = material_map_texel(m, map, m.textures[map], uv0, uv1, lod, ray).xy * 2.0 - 1.0;
    float z = sqrt(max(1.0 - dot(xy, xy), 0.0));
    return float3(material_map_axes(m, map, xy) * scale, z);
}
float3 material_map_normal(Material m, float2 uv0, float2 uv1, float2 lod, bool ray) {
    return material_map_normal(m, MATERIAL_MAP_NORMAL, m.normal_scale, uv0, uv1, lod, ray);
}
// A tangent-space normal in the MikkTSpace frame of a surface (mikktspace.h):
// the interpolated normal and tangent as they come, not normalized, and the
// bitangent sign * cross(normal, tangent). It is the frame the bakers of
// normal maps write in: any other shows their seams.
float3 tangent_frame_normal(float3 normal, float4 tangent, float3 tangent_normal) {
    float3 bitangent = tangent.w * cross(normal, tangent.xyz);
    return normalize(tangent_normal.x * tangent.xyz + tangent_normal.y * bitangent + tangent_normal.z * normal);
}
// Whether the transform of an instance turns the winding of its triangles around.
bool instance_mirrored(Instance inst) { return dot(inst.world[0].xyz, cross(inst.world[1].xyz, inst.world[2].xyz)) < 0.0; }
// Whether the view turns the winding of what it draws around: the nested view of a mirror.
bool view_mirrored() { return dot(frame.view[0].xyz, cross(frame.view[1].xyz, frame.view[2].xyz)) < 0.0; }
// A tangent of an instance in the world: a unit direction along its surface,
// as long as the normal it is interpolated with (MikkTSpace), and the side
// its bitangent is on, which a reflection turns around.
// mirrored: instance_mirrored of the instance.
float4 instance_tangent(Instance inst, bool mirrored, float4 tangent) {
    return float4(normalize(transform_vector(inst.world, tangent.xyz)), mirrored ? -tangent.w : tangent.w);
}
// The tangent of a point of a triangle a ray hit: those of its corners interpolated at w, in the world.
float4 hit_tangent(Instance inst, float3 w, Mesh_Triangle t) {
    float3 along = t.a.tangent.xyz * w.x + t.b.tangent.xyz * w.y + t.c.tangent.xyz * w.z;
    return instance_tangent(inst, instance_mirrored(inst), float4(along, t.a.tangent.w));
}
// The normal the normal map of a material gives where a ray hit a triangle.
float3 material_ray_normal(Material m, Instance inst, float3 normal, float3 w, Mesh_Triangle t, float2 uv, float2 uv1, float2 lod) {
    if (!material_has(m.textures[MATERIAL_MAP_NORMAL])) return normal;
    return tangent_frame_normal(normal, hit_tangent(inst, w, t), material_map_normal(m, uv, uv1, lod, true));
}
// Sampling follows the evaluated surface's explicit context, including a
// ray hit reconstructed inside a fragment shader. A sample of a program
// reports the level it reads, from its uv and its bias or gradients, as a
// map does; one that names a level, or asks for the size, keeps every level
// of the texture: the levels it names count from the largest one held.
float4 mirai_sample_texture_at(uint index, float2 uv, float lod, bool ray) {
    if (!material_has(index)) return float4(1.0);
#ifdef MATERIAL_RASTER
    if (!ray) return material_texel(index, uv, lod);
#endif
    return material_texel_at(index, uv, lod);
}
Mirai_Surface mirai_surface_default(Mirai_Surface_Context ctx) {
    Mirai_Surface s;
    s.base_color = MATERIAL_DEFAULT_BASE_COLOR; s.alpha = MATERIAL_DEFAULT_OPACITY; s.normal = ctx.normal;
    s.metallic = MATERIAL_DEFAULT_METALLIC; s.roughness = MATERIAL_DEFAULT_ROUGHNESS; s.occlusion = 1.0;
    s.emission = MATERIAL_DEFAULT_EMISSION; s.specular_color = MATERIAL_DEFAULT_SPECULAR_COLOR;
    s.specular_factor = MATERIAL_DEFAULT_SPECULAR_FACTOR; s.specular_ior = MATERIAL_DEFAULT_IOR;
    s.coat_weight = 0.0; s.coat_roughness = MATERIAL_DEFAULT_COAT_ROUGHNESS; s.coat_color = MATERIAL_DEFAULT_COAT_COLOR;
    s.coat_ior = MATERIAL_DEFAULT_COAT_IOR; s.coat_normal = ctx.vertex_normal;
    s.fuzz_weight = 0.0; s.fuzz_color = MATERIAL_DEFAULT_FUZZ_COLOR; s.fuzz_roughness = MATERIAL_DEFAULT_FUZZ_ROUGHNESS;
    s.diffuse_transmission_weight = 0.0; s.diffuse_transmission_color = MATERIAL_DEFAULT_DIFFUSE_TRANSMISSION_COLOR;
    s.subsurface_weight = 0.0; s.subsurface_color = MATERIAL_DEFAULT_SUBSURFACE_COLOR; s.subsurface_radius = MATERIAL_DEFAULT_SUBSURFACE_RADIUS;
    s.stylized = false; s.stylized_softness = MATERIAL_DEFAULT_STYLIZED_SOFTNESS; s.stylized_shade = MATERIAL_DEFAULT_STYLIZED_SHADE;
    s.specular_anisotropy = 0.0; s.specular_tangent = ctx.tangent.xyz; s.unlit = false;
    return s;
}
float4 mirai_sample_texture(Mirai_Surface_Context ctx, uint index, float2 uv, float lod) {
    return mirai_sample_texture_at(index, uv, lod, ctx.ray);
}
float4 mirai_sample_texture(Mirai_PostProcess_Context ctx, uint index, float2 uv, float lod) {
    return mirai_sample_texture_at(index, uv, lod, false);
}
float4 mirai_sample_texture_level(uint index, float2 uv, float level) {
    if (!material_has(index)) return float4(1);
    texture_feedback(index, -FLT_MAX);
    return material_textures[mirai_nonuniform(index)].SampleLevel(material_sampler, uv, level);
}
float4 mirai_sample_texture_grad(uint index, float2 uv, float2 dx, float2 dy) {
    if (!material_has(index)) return float4(1);
#ifdef MIRAI_TEXTURE_FEEDBACK
    // As material_texel: the level anisotropic filtering reads of these gradients.
    if (texture_feedback_on()) {
        float2 size = float2(texture_size(material_textures[mirai_nonuniform(index)], 0));
        float2 across2 = abs(dx * size), down2 = abs(dy * size);
        float across = max(across2.x, across2.y), down = max(down2.x, down2.y);
        float longer = max(across, down);
        if (longer > 0.0) texture_feedback(index, log2(max(min(across, down), longer / MATERIAL_ANISOTROPY)) - log2(size.x));
    }
#endif
    return material_textures[mirai_nonuniform(index)].SampleGrad(material_sampler, uv, dx, dy);
}
// A uv set at a point with its derivatives: of the triangle where the
// visibility target is resolved (MATERIAL_GRADIENTS), across the quad in
// another raster stage; in a ray, the width of its footprint in uv, which
// `lod` (ctx.lod or ctx.lod1) is the level of.
Mirai_Dual2 material_uv_dual(Mirai_Surface_Context ctx, float2 uv, float lod, int set) {
    if (ctx.ray) {
        float width = exp2(lod);
        return mirai_dual(uv, float2(width, 0.0), float2(0.0, width));
    }
#ifdef MATERIAL_GRADIENTS
    float4 g = material_uv_gradients[set];
    return mirai_dual(uv, g.xy, g.zw);
#elif defined(MATERIAL_RASTER)
    return mirai_dual(uv, ddx(uv), ddy(uv));
#else
    return mirai_dual(uv);
#endif
}
Mirai_Dual2 mirai_uv0(Mirai_Surface_Context ctx) { return material_uv_dual(ctx, ctx.uv0, ctx.lod, 0); }
Mirai_Dual2 mirai_uv1(Mirai_Surface_Context ctx) { return material_uv_dual(ctx, ctx.uv1, ctx.lod1, 1); }
Mirai_Dual3 mirai_vertex_normal(Mirai_Surface_Context ctx) {
    if (ctx.ray) return mirai_dual(ctx.vertex_normal);
#ifdef MATERIAL_GRADIENTS
    return mirai_dual(ctx.vertex_normal, material_normal_gradients[0], material_normal_gradients[1]);
#elif defined(MATERIAL_RASTER)
    return mirai_dual(ctx.vertex_normal, ddx(ctx.vertex_normal), ddy(ctx.vertex_normal));
#else
    return mirai_dual(ctx.vertex_normal);
#endif
}
float4 mirai_sample_texture(Mirai_Surface_Context ctx, uint index, Mirai_Dual2 uv) {
    if (!material_has(index)) return float4(1.0);
    // A ray reads the level of the widest footprint, as material_texel_at takes it.
    if (ctx.ray) return material_texel_at(index, uv.value, log2(max(max(length(uv.dx), length(uv.dy)), 1e-30)));
    // A raster lod is the bias of the view.
    float scale = exp2(ctx.lod);
    return mirai_sample_texture_grad(index, uv.value, uv.dx * scale, uv.dy * scale);
}
float4 mirai_load_texture(uint index, int2 texel) {
    if (!material_has(index)) return float4(1);
    return material_textures[mirai_nonuniform(index)].Load(int3(texel, 0));
}
float2 mirai_texture_size(uint index) {
    if (!material_has(index)) return float2(1);
    texture_feedback(index, -FLT_MAX);
    return float2(texture_size(material_textures[mirai_nonuniform(index)], 0));
}
// The table of the chunks (render/ground.odin) names the texture of the chunk
// of the place: its samples are the centers of its texels, so the read stays
// in the chunk and meets its neighbor's at the edge they share. The texels
// hold their color times what they cover.
float4 mirai_ground_color(Mirai_Surface_Context ctx, float3 world_position, float4 fallback) {
    if (frame.ground_table == 0u) return fallback;
    float2 at = (world_position.xz - frame.ground.xy) * frame.ground.z;
    int2 chunk = int2(floor(at));
    if (any(chunk < 0) || any(chunk >= int(GROUND_TABLE))) return fallback;
    float4 entry = material_textures[mirai_nonuniform(frame.ground_table)].Load(int3(chunk, 0));
    uint index = uint(round(entry.r * 255.0)) | (uint(round(entry.g * 255.0)) << 8u);
    if (index == 0u) return fallback;
    float span = float(GROUND_TEXELS - 1u) / float(GROUND_TEXELS);
    float2 uv = (at - float2(chunk)) * span + 0.5 / float(GROUND_TEXELS);
    float widen = frame.ground.z * span;
    float4 color = material_textures[mirai_nonuniform(index)].SampleGrad(linear_sampler, uv, ctx.position_dx.xz * widen, ctx.position_dy.xz * widen);
    return float4(fallback.rgb * (1.0 - color.a) + color.rgb, color.a + fallback.a * (1.0 - color.a));
}
float4 mirai_sample_texture_projected(Mirai_Surface_Context ctx, uint index, float3 u, float3 v, float metres) {
    float scale = 1.0 / max(metres, 1e-6);
    // On the grid of the world: what the origin adds to the turns of the texture.
    float2 shift = float2(origin_phase(ctx.origin, u * scale), origin_phase(ctx.origin, v * scale));
    float2 uv = shift + float2(dot(ctx.world_position, u), dot(ctx.world_position, v)) * scale;
    // A raster lod is the bias of the frame.
    float widen = ctx.ray ? scale : scale * exp2(ctx.lod);
    float2 dx = float2(dot(ctx.position_dx, u), dot(ctx.position_dx, v)) * widen;
    float2 dy = float2(dot(ctx.position_dy, u), dot(ctx.position_dy, v)) * widen;
    return mirai_sample_texture_grad(index, uv, dx, dy);
}
float4 material_base_color(Material m, float2 uv0, float2 uv1, float2 lod, float3 tint, bool ray) {
    float4 base = float4(m.base_color * tint, m.opacity);
    if (material_has(m.textures[MATERIAL_MAP_BASE_COLOR])) base *= material_map_texel(m, MATERIAL_MAP_BASE_COLOR, m.textures[MATERIAL_MAP_BASE_COLOR], uv0, uv1, lod, ray);
    return base;
}

// The coverage of a masked material at a point: its opacity times the alpha
// of its mask map, which the row holds as the base color map when the
// material has no mask of its own. No program runs: visibility, the shadow
// maps and rays cut by it alike. A stage that has only the uv the map reads
// (mask_uv_set) gives it as both.
float material_mask(Material m, float2 uv0, float2 uv1, float2 lod, bool ray) {
    float alpha = m.opacity;
    uint texture_index = m.textures[MATERIAL_MAP_MASK];
    if (material_has(texture_index)) alpha *= material_map_texel(m, MATERIAL_MAP_MASK, texture_index, uv0, uv1, lod, ray).a;
    return alpha;
}
// The uv set the mask map of a material row reads.
uint mask_uv_set(uint row) { return materials[row].map_transforms[MATERIAL_MAP_MASK].uv_set; }

// The layers a pass shades of those a material holds: all of them, or the
// unlit bit alone in a pass that only sees surfaces without layers
// (MIRAI_MATERIAL_NO_LAYERS: true, or a constant of the stage).
uint material_layers_allowed(uint layers) {
#ifdef MIRAI_MATERIAL_NO_LAYERS
    if (MIRAI_MATERIAL_NO_LAYERS) return layers & MATERIAL_LAYER_UNLIT;
#endif
    return layers;
}
// A subsurface takes the place of a diffuse transmission, as a solid that of
// a thin surface; neither is held with a weight of 0.
void material_layers_settle(inout Material_Layers l) {
    if (!(l.subsurface > 0.0)) l.bits &= ~MATERIAL_LAYER_SUBSURFACE;
    if ((l.bits & MATERIAL_LAYER_SUBSURFACE) == 0u) return;
    l.bits &= ~MATERIAL_LAYER_DIFFUSE_TRANSMISSION;
    l.diffuse_transmission = 0.0;
}
// Whether a material reads the tangent of its surface: by its normal map, the
// normal map of its coat, an anisotropic lobe or a program.
bool material_tangents(Material m) {
    uint layers = material_layers_allowed(m.layers);
    return m.program_id != 0u || material_has(m.textures[MATERIAL_MAP_NORMAL]) || (layers & MATERIAL_LAYER_ANISOTROPY) != 0u
        || ((layers & MATERIAL_LAYER_COAT) != 0u && material_has(m.textures[MATERIAL_MAP_COAT_NORMAL]));
}
// The layers a material holds at a point (MATERIAL_LAYER_* of its row): the
// blocks of the row, under the values of the instance, by their maps. The coat follows the surface under the
// normal map of the base, or its own map; the tangent of an anisotropic lobe
// is that of the surface turned by its rotation and its map, across the
// shading normal.
Material_Layers material_layers(Material m, Mirai_Surface_Context ctx) {
    Material_Layers l = material_layers_none();
    uint bits = material_layers_allowed(m.layers);
    l.bits = bits;
    if (bits == 0u || (bits & MATERIAL_LAYER_UNLIT) != 0u) return l;
    float2 lod = float2(ctx.lod, ctx.lod1);
    uint given = material_given(ctx.material_values, m.row);
    Material_Blocks blocks;
    if (given == 0u) blocks = materials[m.row].blocks;
    else blocks = material_words<Material_Blocks, MATERIAL_BLOCK_WORDS>(given + MATERIAL_WORDS);
    Material_Coat coat = blocks.coat;
    Material_Fuzz fuzz = blocks.fuzz;
    Material_Diffuse_Transmission transmission = blocks.diffuse_transmission;
    Material_Anisotropy anisotropy = blocks.anisotropy;
    Material_Subsurface subsurface = blocks.subsurface;
    if ((bits & MATERIAL_LAYER_STYLIZED) != 0u) {
        l.stylized_softness = blocks.stylized.softness;
        l.stylized_shade = blocks.stylized.shade;
        return l;
    }
    if ((bits & MATERIAL_LAYER_COAT) != 0u) {
        l.coat = coat.weight;
        l.coat_roughness = coat.roughness;
        if (material_has(m.textures[MATERIAL_MAP_COAT])) l.coat *= material_map_texel(m, MATERIAL_MAP_COAT, m.textures[MATERIAL_MAP_COAT], ctx.uv0, ctx.uv1, lod, ctx.ray).r;
        if (material_has(m.textures[MATERIAL_MAP_COAT_ROUGHNESS])) l.coat_roughness *= material_map_texel(m, MATERIAL_MAP_COAT_ROUGHNESS, m.textures[MATERIAL_MAP_COAT_ROUGHNESS], ctx.uv0, ctx.uv1, lod, ctx.ray).g;
        l.coat_ior = coat.ior;
        l.coat_color = coat.color;
        l.coat_normal = ctx.vertex_normal;
        if (material_has(m.textures[MATERIAL_MAP_COAT_NORMAL])) {
            float3 mapped = tangent_frame_normal(ctx.vertex_normal, ctx.tangent, material_map_normal(m, MATERIAL_MAP_COAT_NORMAL, coat.normal_scale, ctx.uv0, ctx.uv1, lod, ctx.ray));
            l.coat_normal = dot(mapped, ctx.normal) > 0.0 ? mapped : ctx.vertex_normal;
        }
    }
    if ((bits & MATERIAL_LAYER_FUZZ) != 0u) {
        l.fuzz = fuzz.weight;
        l.fuzz_color = fuzz.color;
        l.fuzz_roughness = fuzz.roughness;
        if (material_has(m.textures[MATERIAL_MAP_FUZZ_COLOR])) l.fuzz_color *= material_map_texel(m, MATERIAL_MAP_FUZZ_COLOR, m.textures[MATERIAL_MAP_FUZZ_COLOR], ctx.uv0, ctx.uv1, lod, ctx.ray).rgb;
        if (material_has(m.textures[MATERIAL_MAP_FUZZ_ROUGHNESS])) l.fuzz_roughness *= material_map_texel(m, MATERIAL_MAP_FUZZ_ROUGHNESS, m.textures[MATERIAL_MAP_FUZZ_ROUGHNESS], ctx.uv0, ctx.uv1, lod, ctx.ray).a;
    }
    if ((bits & MATERIAL_LAYER_DIFFUSE_TRANSMISSION) != 0u) {
        l.diffuse_transmission = transmission.weight;
        l.diffuse_transmission_color = transmission.color;
        if (material_has(m.textures[MATERIAL_MAP_DIFFUSE_TRANSMISSION])) l.diffuse_transmission *= material_map_texel(m, MATERIAL_MAP_DIFFUSE_TRANSMISSION, m.textures[MATERIAL_MAP_DIFFUSE_TRANSMISSION], ctx.uv0, ctx.uv1, lod, ctx.ray).a;
        if (material_has(m.textures[MATERIAL_MAP_DIFFUSE_TRANSMISSION_COLOR])) l.diffuse_transmission_color *= material_map_texel(m, MATERIAL_MAP_DIFFUSE_TRANSMISSION_COLOR, m.textures[MATERIAL_MAP_DIFFUSE_TRANSMISSION_COLOR], ctx.uv0, ctx.uv1, lod, ctx.ray).rgb;
    }
    if ((bits & MATERIAL_LAYER_SUBSURFACE) != 0u) {
        l.subsurface = subsurface.weight;
        l.subsurface_color = subsurface.color;
        l.subsurface_radius = subsurface.radius;
        if (material_has(m.textures[MATERIAL_MAP_SUBSURFACE])) l.subsurface *= material_map_texel(m, MATERIAL_MAP_SUBSURFACE, m.textures[MATERIAL_MAP_SUBSURFACE], ctx.uv0, ctx.uv1, lod, ctx.ray).a;
        if (material_has(m.textures[MATERIAL_MAP_SUBSURFACE_RADIUS])) l.subsurface_radius *= material_map_texel(m, MATERIAL_MAP_SUBSURFACE_RADIUS, m.textures[MATERIAL_MAP_SUBSURFACE_RADIUS], ctx.uv0, ctx.uv1, lod, ctx.ray).r;
    }
    material_layers_settle(l);
    if ((bits & MATERIAL_LAYER_ANISOTROPY) != 0u) {
        float2 direction = float2(1.0, 0.0);
        l.anisotropy = anisotropy.amount;
        if (material_has(m.textures[MATERIAL_MAP_ANISOTROPY])) {
            float3 texel = material_map_texel(m, MATERIAL_MAP_ANISOTROPY, m.textures[MATERIAL_MAP_ANISOTROPY], ctx.uv0, ctx.uv1, lod, ctx.ray).rgb;
            float2 along = texel.rg * 2.0 - 1.0;
            if (dot(along, along) > 1e-8) direction = normalize(material_map_axes(m, MATERIAL_MAP_ANISOTROPY, along));
            l.anisotropy *= texel.b;
        }
        float2 r = anisotropy.rotation;
        direction = float2(r.x * direction.x - r.y * direction.y, r.y * direction.x + r.x * direction.y);
        float3 bitangent = ctx.tangent.w * cross(ctx.vertex_normal, ctx.tangent.xyz);
        l.tangent = direction.x * ctx.tangent.xyz + direction.y * bitangent;
    }
    return l;
}

// The specular reflectance of a sample (OpenPBR): the dielectric F0 of its
// IOR, specular color and factor, and the base color of a metal. Under a
// coat the base meets the coat instead of the air, so its IOR is relative to
// the coat where the coat covers it, and the coat roughens it. A stylized
// point has no specular lobe and reflects its base color whole: it is no metal.
void material_specular(inout Material_Sample s, float3 color, float ior, float factor) {
    if ((s.layers.bits & MATERIAL_LAYER_STYLIZED) != 0u) s.metallic = 0.0;
    float eta = ior;
    if (s.layers.coat > 0.0) {
        eta = lerp(ior, ior / max(s.layers.coat_ior, 1.0), saturate(s.layers.coat));
        float base = s.roughness * s.roughness, coat = s.layers.coat_roughness * s.layers.coat_roughness;
        s.roughness = lerp(s.roughness, min(1.0, sqrt(sqrt(base * base + 2.0 * coat * coat))), saturate(s.layers.coat));
    }
    float ratio = (max(eta, 1.0) - 1.0) / (max(eta, 1.0) + 1.0);
    float3 f0 = saturate(color * (ratio * ratio)) * saturate(factor);
    s.f0 = lerp(f0, saturate(s.base_color), s.metallic);
    s.f90 = lerp(saturate(factor), 1.0, s.metallic);
}
// The standard model of a row at a point, its maps read: what the engine
// makes a sample from (material_evaluate), and what a program builds on
// (mirai_surface_standard). layers: those of the row there.
Mirai_Surface material_standard(Material m, Mirai_Surface_Context ctx, float3 tint, out Material_Layers layers) {
    Mirai_Surface s = mirai_surface_default(ctx);
    float2 uv0 = ctx.uv0, uv1 = ctx.uv1, lod = float2(ctx.lod, ctx.lod1);
    bool ray = ctx.ray;
    float4 base = material_base_color(m, uv0, uv1, lod, tint, ray);
    s.base_color = base.rgb;
    s.alpha = base.a;
    s.roughness = m.roughness;
    s.metallic = m.metallic;
    s.occlusion = 1.0;
    float3 orm = float3(1.0);
    if (material_has(m.textures[MATERIAL_MAP_METALLIC_ROUGHNESS])) {
        orm = material_map_texel(m, MATERIAL_MAP_METALLIC_ROUGHNESS, m.textures[MATERIAL_MAP_METALLIC_ROUGHNESS], uv0, uv1, lod, ray).rgb;
        s.roughness *= orm.g;
        s.metallic *= orm.b;
    }
    if (m.textures[MATERIAL_MAP_OCCLUSION] == MATERIAL_OCCLUSION_PACKED) {
        s.occlusion = lerp(1.0, orm.r, m.occlusion_strength);
    } else if (material_has(m.textures[MATERIAL_MAP_OCCLUSION])) {
        float occlusion = material_map_texel(m, MATERIAL_MAP_OCCLUSION, m.textures[MATERIAL_MAP_OCCLUSION], uv0, uv1, lod, ray).r;
        s.occlusion = lerp(1.0, occlusion, m.occlusion_strength);
    }
    s.roughness = clamp(s.roughness, MIN_ROUGHNESS, 1.0);
    s.metallic = saturate(s.metallic);
    s.emission = m.emission;
    if (material_has(m.textures[MATERIAL_MAP_EMISSION])) s.emission *= material_map_texel(m, MATERIAL_MAP_EMISSION, m.textures[MATERIAL_MAP_EMISSION], uv0, uv1, lod, ray).rgb;
    layers = material_layers(m, ctx);
    s.specular_color = m.specular_color;
    s.specular_factor = m.specular_factor;
    if (material_has(m.textures[MATERIAL_MAP_SPECULAR])) s.specular_factor *= material_map_texel(m, MATERIAL_MAP_SPECULAR, m.textures[MATERIAL_MAP_SPECULAR], uv0, uv1, lod, ray).a;
    if (material_has(m.textures[MATERIAL_MAP_SPECULAR_COLOR])) s.specular_color *= material_map_texel(m, MATERIAL_MAP_SPECULAR_COLOR, m.textures[MATERIAL_MAP_SPECULAR_COLOR], uv0, uv1, lod, ray).rgb;
    s.specular_ior = m.ior;
    // The layers the row holds there, as a program gives them.
    s.unlit = (layers.bits & MATERIAL_LAYER_UNLIT) != 0u;
    if ((layers.bits & MATERIAL_LAYER_STYLIZED) != 0u) {
        s.stylized = true; s.stylized_softness = layers.stylized_softness; s.stylized_shade = layers.stylized_shade;
    }
    if ((layers.bits & MATERIAL_LAYER_COAT) != 0u) {
        s.coat_weight = layers.coat; s.coat_roughness = layers.coat_roughness; s.coat_color = layers.coat_color; s.coat_ior = layers.coat_ior; s.coat_normal = layers.coat_normal;
    }
    if ((layers.bits & MATERIAL_LAYER_FUZZ) != 0u) {
        s.fuzz_weight = layers.fuzz; s.fuzz_color = layers.fuzz_color; s.fuzz_roughness = layers.fuzz_roughness;
    }
    if ((layers.bits & MATERIAL_LAYER_ANISOTROPY) != 0u) {
        s.specular_anisotropy = layers.anisotropy; s.specular_tangent = layers.tangent;
    }
    if ((layers.bits & MATERIAL_LAYER_DIFFUSE_TRANSMISSION) != 0u) {
        s.diffuse_transmission_weight = layers.diffuse_transmission; s.diffuse_transmission_color = layers.diffuse_transmission_color;
    }
    if ((layers.bits & MATERIAL_LAYER_SUBSURFACE) != 0u) {
        s.subsurface_weight = layers.subsurface; s.subsurface_color = layers.subsurface_color; s.subsurface_radius = layers.subsurface_radius;
    }
    return s;
}
Material_Sample material_evaluate(Material m, Mirai_Surface_Context ctx, float3 tint, float3 added_emission) {
    Material_Sample s;
    Material_Layers layers;
    Mirai_Surface standard = material_standard(m, ctx, tint, layers);
    s.base_color = standard.base_color;
    s.alpha = standard.alpha;
    s.roughness = standard.roughness;
    s.metallic = standard.metallic;
    s.occlusion = standard.occlusion;
    s.emission = standard.emission + added_emission;
    s.layers = layers;
    material_specular(s, standard.specular_color, m.ior, standard.specular_factor);
    return s;
}
Mirai_Surface mirai_surface_standard(Mirai_Surface_Context ctx) {
    if (ctx.material == INVALID) return mirai_surface_default(ctx);
    Material_Layers layers;
    return material_standard(material_row(ctx.material, ctx.material_values), ctx, float3(1.0), layers);
}
// The context of a point for its material. vertex_normal: the interpolated
// normal of the surface, facing like `normal`; tangent: its MikkTSpace
// tangent in the world, w the side of its bitangent.
Mirai_Surface_Context material_context(float3 position, float3 normal, float3 vertex_normal, float4 tangent, float2 uv0, float2 uv1, float2 lod, bool ray) {
    Mirai_Surface_Context ctx;
    ctx.world_position = position; ctx.view_direction = to_eye(position); ctx.origin = frame.origin.xyz; ctx.normal = normal; ctx.vertex_normal = vertex_normal; ctx.tangent = tangent; ctx.uv0 = uv0; ctx.uv1 = uv1;
    ctx.time = frame.time.x; ctx.previous_time = frame.time.y; ctx.lod = lod.x; ctx.lod1 = lod.y; ctx.ray = ray;
    ctx.position_dx = float3(0.0); ctx.position_dy = float3(0.0);
    ctx.vertex_color = float4(1.0);
    ctx.object_position = float3(0.0); ctx.object_x = float3(1.0, 0.0, 0.0); ctx.object_y = float3(0.0, 1.0, 0.0); ctx.object_z = float3(0.0, 0.0, 1.0);
    ctx.object_center = float3(0.0); ctx.object_radius = 0.0; ctx.object_low = float3(0.0); ctx.object_high = float3(0.0); ctx.wet = 0.0;
    ctx.material_values = 0u; ctx.material = INVALID;
    ctx.particle_data[0] = float4(0.0); ctx.particle_data[1] = float4(0.0); ctx.particle_data[2] = float4(0.0); ctx.particle_data[3] = float4(0.0); ctx.particle_given = 0u; ctx.particle_random = 0.0; ctx.particle_radius = 0.0;
    ctx.particle_color = float4(1.0); ctx.particle_life = 0.0; ctx.particle_frame = 0.0;
    float4 clip = view_clip(position);
    float2 ndc = clip.xy / max(clip.w, 1e-6);
    ctx.screen = float2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5); ctx.screen_size = frame.resolution;
    ctx.depth = view_depth(position); ctx.scene_depth = frame.camera_forward.w;
    return ctx;
}
// The context of a point of an instance, whose mesh has that color there.
Mirai_Surface_Context material_context_instance(Mirai_Surface_Context ctx, Instance inst, float4 vertex_color) {
    ctx.vertex_color = vertex_color;
    ctx.object_position = float3(inst.world[0].w, inst.world[1].w, inst.world[2].w);
    ctx.object_x = float3(inst.world[0].x, inst.world[1].x, inst.world[2].x);
    ctx.object_y = float3(inst.world[0].y, inst.world[1].y, inst.world[2].y);
    ctx.object_z = float3(inst.world[0].z, inst.world[1].z, inst.world[2].z);
    Mesh mesh = meshes[instance_mesh(inst)];
    float3 half_size = (mesh.bounds_max.xyz - mesh.bounds_min.xyz) * 0.5;
    ctx.object_center = transform_point(inst.world, (mesh.bounds_min.xyz + mesh.bounds_max.xyz) * 0.5);
    ctx.object_radius = length(float3(length(ctx.object_x) * half_size.x, length(ctx.object_y) * half_size.y, length(ctx.object_z) * half_size.z));
    ctx.object_low = mesh.bounds_min.xyz; ctx.object_high = mesh.bounds_max.xyz;
    ctx.wet = saturate(inst.wet);
    ctx.material_values = inst.material_values;
    return ctx;
}
// The same for an instance an index names; INVALID (a surface an extension
// draws) has none.
Mirai_Surface_Context material_context_instance(Mirai_Surface_Context ctx, uint instance_index, float4 vertex_color) {
    if (instance_index == INVALID) {
        ctx.vertex_color = vertex_color;
        return ctx;
    }
    return material_context_instance(ctx, scene_instance(instance_index), vertex_color);
}
// The footprint of a ray hit `width` world units wide, across its normal.
Mirai_Surface_Context material_context_cone(Mirai_Surface_Context ctx, float width) {
    float3 tangent, bitangent;
    make_basis(ctx.vertex_normal, tangent, bitangent);
    ctx.position_dx = tangent * width; ctx.position_dy = bitangent * width;
    return ctx;
}
// A context without a tangent frame of its own: for coverage, and for points
// whose layers do not matter.
Mirai_Surface_Context material_context(float3 position, float3 normal, float2 uv0, float2 uv1, float2 lod, bool ray) {
    float3 tangent, bitangent;
    make_basis(normal, tangent, bitangent);
    return material_context(position, normal, normal, float4(tangent, 1.0), uv0, uv1, lod, ray);
}
// What a material with a program gives from what its program gave at a point.
void material_program_apply(Material m, Mirai_Surface result, float3 tint, float3 added_emission, out Material_Sample values, inout float3 normal) {
    values = (Material_Sample)0;
    values.base_color = result.base_color * tint; values.alpha = result.alpha;
    values.metallic = saturate(result.metallic); values.roughness = clamp(result.roughness, MIN_ROUGHNESS, 1.0);
    values.occlusion = saturate(result.occlusion); values.emission = result.emission + added_emission;
    normal = normalize(result.normal);
    // The layers a program gives, where the row says it may give them.
    Material_Layers l = material_layers_none();
    l.bits = result.unlit ? MATERIAL_LAYER_UNLIT : 0u;
    if (!result.unlit && result.stylized && (m.layers & MATERIAL_LAYER_STYLIZED) != 0u) {
        l.bits = MATERIAL_LAYER_STYLIZED;
        l.stylized_softness = saturate(result.stylized_softness);
        l.stylized_shade = saturate(result.stylized_shade);
    } else if (!result.unlit) {
        l.coat = saturate(result.coat_weight); l.coat_roughness = saturate(result.coat_roughness); l.coat_color = saturate(result.coat_color);
        l.coat_ior = max(result.coat_ior, 1.0); l.coat_normal = normalize(result.coat_normal);
        l.fuzz = saturate(result.fuzz_weight); l.fuzz_color = saturate(result.fuzz_color); l.fuzz_roughness = saturate(result.fuzz_roughness);
        l.anisotropy = saturate(result.specular_anisotropy); l.tangent = result.specular_tangent;
        l.diffuse_transmission = saturate(result.diffuse_transmission_weight); l.diffuse_transmission_color = saturate(result.diffuse_transmission_color);
        l.subsurface = saturate(result.subsurface_weight); l.subsurface_color = saturate(result.subsurface_color);
        l.subsurface_radius = clamp(result.subsurface_radius, 0.0, MATERIAL_SUBSURFACE_RADIUS_MAX);
        l.bits = (l.coat > 0.0 ? MATERIAL_LAYER_COAT : 0u) | (l.fuzz > 0.0 ? MATERIAL_LAYER_FUZZ : 0u) | (l.anisotropy > 0.0 ? MATERIAL_LAYER_ANISOTROPY : 0u)
            | (l.diffuse_transmission > 0.0 ? MATERIAL_LAYER_DIFFUSE_TRANSMISSION : 0u) | (l.subsurface > 0.0 ? MATERIAL_LAYER_SUBSURFACE : 0u);
    }
    l.bits &= material_layers_allowed(m.layers);
    material_layers_settle(l);
    if ((l.bits & MATERIAL_LAYER_COAT) == 0u) l.coat = 0.0;
    if ((l.bits & MATERIAL_LAYER_FUZZ) == 0u) l.fuzz = 0.0;
    if ((l.bits & MATERIAL_LAYER_ANISOTROPY) == 0u) l.anisotropy = 0.0;
    if ((l.bits & MATERIAL_LAYER_DIFFUSE_TRANSMISSION) == 0u) l.diffuse_transmission = 0.0;
    if ((l.bits & MATERIAL_LAYER_SUBSURFACE) == 0u) l.subsurface = 0.0;
    values.layers = l;
    material_specular(values, result.specular_color, max(result.specular_ior, 1.0), result.specular_factor);
}
// The program of a material at a point; false without one, or in a stage that
// runs none (it includes the empty surface_programs.slang).
bool material_program(Material m, Mirai_Surface_Context ctx, float3 tint, float3 added_emission, out Material_Sample values, inout float3 normal) {
    values = (Material_Sample)0;
    if (m.program_id == 0u) return false;
    ctx.material = m.row;
    Mirai_Surface result = mirai_surface_default(ctx);
    float4 parameters[16];
    material_parameters(m.row, ctx.material_values, parameters);
    if (!mirai_evaluate_program(m.program_id, parameters, ctx, result)) return false;
    material_program_apply(m, result, tint, added_emission, values, normal);
    return true;
}

// A wet surface (Lagarde, "Water drop 3b - Physically based wet surfaces"):
// what is rough, and so porous, and not metal drinks the water and darkens;
// the film of water over it smooths it, which also covers WET_FILM_COVER of a
// surface that drinks none. Its reflectance at normal incidence stays: the
// film is thin. Glass, what light crosses and what is unlit stay as they are.
#define WET_DARKEST 0.2        // of the base color of a porous dielectric soaked
#define WET_FILM_ROUGHNESS 0.05
#define WET_FILM_COVER 0.3
void surface_wet(inout float3 base_color, inout float roughness, float metallic, float wet) {
    if (!(wet > 0.0)) return;
    float porosity = saturate((roughness - 0.5) / 0.4);
    float factor = lerp(1.0, WET_DARKEST, (1.0 - metallic) * porosity);
    base_color *= lerp(1.0, factor, wet);
    float film = wet * max(0.5 * (1.0 - factor), WET_FILM_COVER);
    roughness = clamp(lerp(roughness, min(roughness, WET_FILM_ROUGHNESS), film), MIN_ROUGHNESS, 1.0);
}
void material_wet_apply(inout Material_Sample s, Material m, float wet) {
    if (m.transmission > 0.0 || (s.layers.bits & MATERIAL_LAYER_UNLIT) != 0u) return;
    surface_wet(s.base_color, s.roughness, s.metallic, wet);
}

// A Surface program replaces the shared PBR values. Resolve it before sampling
// the shared maps; the normal supplied by the caller remains its input.
Material_Sample material_sample_finish(Material_Sample values, Material m, Mirai_Surface_Context ctx) {
    material_wet_apply(values, m, ctx.wet);
    // A masked material covers by its mask map, whatever its program or standard model give. A
    // surface resolved from the visibility target (MATERIAL_GRADIENTS) was cut by it there
    // (vis_raster.frag), and nothing reads its alpha.
#ifndef MATERIAL_GRADIENTS
    if (m.alpha_mode == ALPHA_MASK) values.alpha = material_mask(m, ctx.uv0, ctx.uv1, float2(ctx.lod, ctx.lod1), ctx.ray);
#endif
    // The emission of the instance takes the mode of the material's.
    values.emission_relative = m.emission_mode == EMISSION_RELATIVE;
    return values;
}
Material_Sample material_sample(Material m, Mirai_Surface_Context ctx, float3 tint, float3 added_emission, inout float3 normal) {
    Material_Sample values;
    if (!material_program(m, ctx, tint, added_emission, values, normal)) values = material_evaluate(m, ctx, tint, added_emission);
    return material_sample_finish(values, m, ctx);
}
// The same where the program's stage gave what the program gives (given).
Material_Sample material_sample_given(Material m, Mirai_Surface_Context ctx, float3 tint, float3 added_emission, inout float3 normal, bool given, Mirai_Surface program) {
    if (!given) return material_sample(m, ctx, tint, added_emission, normal);
    Material_Sample values;
    material_program_apply(m, program, tint, added_emission, values, normal);
    return material_sample_finish(values, m, ctx);
}

// The emission of a far mesh at a vertex (Mesh_Point.surface.y): nits, as
// rgb9e5 (math.rgb9e5_pack).
float3 surface_emission(uint packed) {
    float scale = exp2(float(int(packed >> 27u) - 24));
    return float3(float(packed & 511u), float((packed >> 9u) & 511u), float((packed >> 18u) & 511u)) * scale;
}
// The roughness and metallic a far mesh gives a point (Mesh_Point.surface.x)
// in place of those of its material, and the specular that follows them.
void material_surface_apply(inout Material_Sample s, Material m, uint surface) {
    if ((surface & MESH_SURFACE_SET) == 0u) return;
    s.roughness = clamp(float(surface & 0xffu) / 255.0, MIN_ROUGHNESS, 1.0);
    s.metallic = float((surface >> 8u) & 0xffu) / 255.0;
    material_specular(s, m.specular_color, m.ior, m.specular_factor);
}

// The emission of a sample in render units: nits by the light scale, or the
// exposed value it asks for over the exposure the view had (one frame late,
// as frame.exposure is).
float3 emission_render_units(float3 emission, bool relative) {
    return relative ? emission / max(frame.exposure, 1e-30) : render_units(emission);
}

// The emission a ray hit shows. A relative emitter lights nothing, so the
// rays that gather light find none; the passes whose rays the camera looks
// along (reflections, what glass shows behind it) define
// MIRAI_HITS_SHOW_RELATIVE_EMISSION and see it.
float3 hit_emission(Material_Sample m) {
#ifdef MIRAI_HITS_SHOW_RELATIVE_EMISSION
    return emission_render_units(sample_emission(m, 1.0), m.emission_relative);
#else
    return m.emission_relative ? float3(0.0) : render_units(sample_emission(m, 1.0));
#endif
}

// The alpha of a blended surface: its opacity, or what its program gives
// from the same context; the other maps have no effect on it.
float material_alpha(Material m, Mirai_Surface_Context ctx, float3 tint, float3 added_emission) {
    float3 normal = ctx.normal;
    Material_Sample values;
    if (material_program(m, ctx, tint, added_emission, values, normal)) return values.alpha;
    return material_base_color(m, ctx.uv0, ctx.uv1, float2(ctx.lod, ctx.lod1), tint, ctx.ray).a;
}

// Whether a point of a material with this alpha is there at all, for the
// G-buffer and for rays: a masked one has holes and a blended one lets both
// through (it is drawn on its own, and casts no shadow).
bool material_covers(Material m, float alpha) {
    uint mode = m.alpha_mode;
    return mode == ALPHA_OPAQUE || (mode == ALPHA_MASK && alpha >= m.alpha_cutoff);
}

// A blended material with transmission and thickness is the boundary of a
// solid: its front faces are where light enters it.

bool material_solid(Material m) { return m.transmission > 0.0 && m.thickness > 0.0; }

// What a blended surface lets through of the light that reaches it from
// behind where it covers: its transmission of what it does not reflect, by
// its base color, under what the layers of its material leave
// (shading_through). Without transmission it is a coat that hides it. Where
// it does not cover (alpha) there is no surface and the light goes on whole.
float3 surface_through(Material m, float3 base_color, float3 reflectance, float3 layers = float3(1.0)) {
    return m.transmission * (1.0 - reflectance) * layers * base_color;
}

// What a solid leaves of the light that crosses `path` of it.
float3 material_absorption(Material m, float path) {
    return m.attenuation_distance > 0.0 ? pow(max(m.attenuation_color, float3(1e-4)), float3(path / m.attenuation_distance)) : float3(1.0);
}

// How far into a solid of the material its clearest color still lets
// SOLID_CLEAR of the light through: what lies farther in does not show.
#define SOLID_CLEAR 0.002
// How far into a solid of the material its clearest color lets `share` of the light through.
float material_reach(Material m, float share) {
    float clearest = max(m.attenuation_color.r, max(m.attenuation_color.g, m.attenuation_color.b));
    if (!(m.attenuation_distance > 0.0) || clearest >= 0.999) return FLT_MAX;
    return m.attenuation_distance * log(share) / log(max(clearest, 1e-4));
}

float material_clear_reach(Material m) {
    float clearest = max(m.attenuation_color.r, max(m.attenuation_color.g, m.attenuation_color.b));
    if (!(m.attenuation_distance > 0.0) || clearest >= 0.999) return FLT_MAX;
    return m.attenuation_distance * log(SOLID_CLEAR) / log(max(clearest, 1e-4));
}

// Surface attributes at a ray hit.
struct Surface {
    float3 position;
    float3 normal;           // interpolated shading normal
    float3 geometric_normal; // from the triangle winding (robust for front/back tests)
    float3 albedo;           // reflectance as a diffuse reflector (bounce_albedo)
    float3 emission;
    float3 base_color;       // with metallic and roughness, the surface as a glossy one
    float metallic;
    float roughness;
    float3 f0;
    float f90;
    Material_Layers layers;
};

// What a point reflects as a diffuse reflector, for the bounces behind the
// first hit: its base with its specular lobe folded into its albedo (seen
// face on, bounce_albedo) under its layers, as the layers take their share
// of light from everywhere.
float3 sample_albedo(Material_Sample m, float3 normal) {
    float3 base = min(diffuse_reflectance(m.base_color, m.metallic) * diffuse_remaining(m.f0) + m.f0, float3(1.0));
    if (m.layers.bits == 0u) return base;
    Shading s = shading_surface(float3(0.0), normal, normal, m.base_color, m.metallic, m.roughness, m.f0, m.f90);
    shading_layers(s, m.layers, m.metallic);
    if ((s.layers & MATERIAL_LAYER_UNLIT) != 0u) return float3(0.0);
    // A stylized point reflects its diffuse light alone, by its shade.
    if ((s.layers & MATERIAL_LAYER_STYLIZED) != 0u) return s.diffuse * s.shade;
    // What a thin base lets through leaves on the other side: it reflects the rest.
    if ((s.layers & MATERIAL_LAYER_DIFFUSE_TRANSMISSION) != 0u) base = min(s.diffuse * diffuse_remaining(m.f0) + m.f0, float3(1.0));
    if (s.coat > 0.0) base = base * ((1.0 - s.coat) + s.below_coat * s.coat_through) + coat_reflectance(s);
    if (s.fuzz > 0.0) base = base * (1.0 - s.fuzz) + s.fuzz_color;
    return min(base, float3(1.0));
}

// The emission of a sample seen at cosine `mu` of its coat (OpenPBR): the
// coat filters what the base emits where it covers it.
float3 sample_emission(Material_Sample m, float mu) {
    if (m.layers.coat <= 0.0 || (m.layers.bits & MATERIAL_LAYER_COAT) == 0u) return m.emission;
    return m.emission * lerp(float3(1.0), coat_transmission(saturate(m.layers.coat_color), saturate(mu), max(m.layers.coat_ior, 1.0 + 1e-3)), saturate(m.layers.coat));
}

// The point of a ray hit as the lights see it, from `view`, with `normal`
// turned to the side the view is on: the layers of its material turn with it.
Shading surface_shading(Surface s, float3 normal, float3 view) {
    Shading point = shading_surface(s.position, normal, view, s.base_color, s.metallic, s.roughness, s.f0, s.f90);
    Material_Layers layers = s.layers;
    if (dot(normal, s.normal) < 0.0) layers.coat_normal = -layers.coat_normal;
    shading_layers(point, layers, s.metallic);
    return point;
}

// What a hit that lets light through sends towards its viewer of the light
// of its other side, as a diffuse reflector facing it; zero for the others.
float3 surface_transmit(Surface s) {
    if ((s.layers.bits & MATERIAL_LAYER_DIFFUSE_TRANSMISSION) == 0u) return float3(0.0);
    return surface_shading(s, s.normal, s.normal).transmit;
}

// Texture level for a ray hit, before the size of the texture: a footprint
// `footprint` world units wide covers footprint^2 * (uv area / world area) of
// the uv square (ray cones, Akenine-Moller et al. 2021).
float hit_lod(float3 world_edge1, float3 world_edge2, float2 uv_edge1, float2 uv_edge2, float footprint) {
    float world_area = length(cross(world_edge1, world_edge2));
    float uv_area = abs(uv_edge1.x * uv_edge2.y - uv_edge1.y * uv_edge2.x);
    return 0.5 * log2(max(uv_area, 1e-12) / max(world_area, 1e-12)) + log2(max(footprint, 1e-6));
}


// What multiplies the base color of a material at a vertex of that color: the
// color, but for a program, which reads it in its context.
float3 material_vertex_tint(Material m, float3 vertex_color) {
    return m.program_id != 0u ? float3(1.0) : vertex_color;
}
// The same color override applies to raster, ray hits and the filters of glass.
float3 instance_color(Instance inst, Material m, float3 vertex_color) {
    return ((inst.meta.w & INSTANCE_FLAG_UNIFORM_COLOR) != 0u ? float3(1.0) : material_vertex_tint(m, vertex_color)) * inst.tint.rgb;
}

Surface surface_from_triangle(uint instance_index, uint primitive, float2 bary, float footprint);

// The face of a triangle of an instance in world axes, outward as its vertices wind (not unit), and the row
// of its material. primitive: its cluster and its triangle (geometry.slang).
float3 triangle_face(uint instance_index, uint primitive, out uint material) {
    Instance inst = scene_instance(instance_index);
    float3 a, b, c;
    uint word;
    mesh_triangle_positions(meshes[instance_mesh(inst)], primitive, a, b, c, word);
    material = material_of(instance_row(instance_index), inst, word);
    return transform_normal(inst.world_inv, cross(b - a, c - a));
}

// A shading normal n of a face where a ray hit it, turned against the ray.
float3 hit_normal_turned(float3 face, float3 n, float3 direction) {
    // A shading normal that leans to the other side of the face would bend the ray back in.
    if (dot(n, direction) * dot(face, direction) <= 0.0) n = face;
    return dot(n, direction) > 0.0 ? -n : n;
}
// The shading normal of a triangle where a ray hit it, turned against the
// ray, and whether the material there is blended. A material with a program
// gives the normal of its row here: the stage of its program gives its own.
float3 hit_normal(uint instance_index, uint primitive, float2 bary, float3 direction, out bool blended) {
    uint material;
    float3 face = triangle_face(instance_index, primitive, material);
    blended = material_apart(material_row(material, material_values_of(instance_index)));
    return hit_normal_turned(face, surface_from_triangle(instance_index, primitive, bary, 1e-4).normal, direction);
}

// footprint: width in world units of what the ray gathers at the hit. Wide
// rays read coarse texture levels, which also keeps their noise low.
// The point of a triangle a ray met, as its material reads it.
struct Hit_Point {
    Instance inst;
    Material m;
    float3 position;
    float3 normal;           // the input normal of the material: the interpolated one under its normal map
    float3 geometric_normal; // from the triangle winding (robust for front/back tests)
    float4 color;            // of the vertices
    uint2 surface;           // of a far mesh (Mesh_Point.surface), the same in the three vertices
    Mirai_Surface_Context ctx;
};

Hit_Point hit_point(uint instance_index, uint primitive, float2 bary, float footprint) {
    Hit_Point h;
    h.inst = scene_instance(instance_index);
    Mesh_Triangle tri = mesh_triangle(h.inst, meshes[instance_mesh(h.inst)], primitive);
    float3 w = float3(1.0 - bary.x - bary.y, bary.x, bary.y);
    float3 local = tri.a.position * w.x + tri.b.position * w.y + tri.c.position * w.z;
    float3 n = tri.a.normal * w.x + tri.b.normal * w.y + tri.c.normal * w.z;
    h.color = tri.a.color * w.x + tri.b.color * w.y + tri.c.color * w.z;
    h.position = transform_point(h.inst.world, local);
    float3 vertex_normal = transform_normal(h.inst.world_inv, n);
    h.normal = vertex_normal;
    float3 edge1 = tri.b.position - tri.a.position;
    float3 edge2 = tri.c.position - tri.a.position;
    float3 face = cross(edge1, edge2);
    h.geometric_normal = dot(face, face) > 1e-20 ? transform_normal(h.inst.world_inv, face) : h.normal;
    h.m = material_row(material_of(instance_row(instance_index), h.inst, tri.material), h.inst.material_values);
    float3 world_edge1 = transform_vector(h.inst.world, edge1);
    float3 world_edge2 = transform_vector(h.inst.world, edge2);
    float2 lod = float2(hit_lod(world_edge1, world_edge2, tri.b.uv - tri.a.uv, tri.c.uv - tri.a.uv, footprint), hit_lod(world_edge1, world_edge2, tri.b.uv1 - tri.a.uv1, tri.c.uv1 - tri.a.uv1, footprint));
    float2 uv = tri.a.uv * w.x + tri.b.uv * w.y + tri.c.uv * w.z;
    float2 uv1 = tri.a.uv1 * w.x + tri.b.uv1 * w.y + tri.c.uv1 * w.z;
    // Shared PBR diffuse hits average their normal map away. A Surface program
    // still receives its mapped input normal, as coverage does on every ray.
#ifdef MIRAI_DIFFUSE_HITS
    if (h.m.program_id != 0u)
#endif
        h.normal = material_ray_normal(h.m, h.inst, h.normal, w, tri, uv, uv1, lod);
    h.surface = tri.a.surface.xy;
    h.ctx = material_context_cone(material_context_instance(material_context(h.position, h.normal, vertex_normal, hit_tangent(h.inst, w, tri), uv, uv1, lod, true), h.inst, h.color), footprint);
    return h;
}

// What the program of the material at a hit gives there: only a stage of that
// program runs it (surface_points.comp).
Mirai_Surface hit_program(Hit_Point h) {
    Mirai_Surface_Context ctx = h.ctx;
    ctx.material = h.m.row;
    Mirai_Surface result = mirai_surface_default(ctx);
    float4 parameters[16];
    material_parameters(h.m.row, ctx.material_values, parameters);
    mirai_evaluate_program(h.m.program_id, parameters, ctx, result);
    return result;
}

// given: the stage of the program of the material wrote what it gives at the
// point (points.slang); otherwise the material is evaluated here.
Surface surface_from_hit(Hit_Point h, bool given, Mirai_Surface program) {
    Surface s;
    s.position = h.position;
    s.normal = h.normal;
    s.geometric_normal = h.geometric_normal;
    // A far mesh keeps its surface in its vertices, the same in the three of a triangle.
    float3 added_emission = h.inst.emission.rgb + ((h.surface.x & MESH_SURFACE_SET) != 0u ? surface_emission(h.surface.y) : float3(0.0));
    Material m = h.m;
    Material_Sample material = material_sample_given(m, h.ctx, instance_color(h.inst, m, h.color.rgb), added_emission, s.normal, given, program);
    material_surface_apply(material, m, h.surface.x);
    s.albedo = sample_albedo(material, s.normal);
    s.emission = hit_emission(material);
    s.layers = material.layers;
    s.base_color = material.base_color;
    s.metallic = material.metallic;
    s.roughness = material.roughness;
    s.f0 = material.f0;
    s.f90 = material.f90;
    return s;
}
// What a decal writes (DECAL_WRITE_*): those of its row, or those a decal
// writes by default where an instance shows a row of another mode as one.
uint material_decal_writes(Material m) {
    uint writes = (materials[m.row].volume.flags >> MATERIAL_DECAL_SHIFT) & DECAL_WRITES_ALL;
    return writes != 0u ? writes : DECAL_WRITES_DEFAULT;
}
// Whether what a material gives a point changes with nothing that says so:
// its program reads the time. A pass that keeps what a ray found does not keep it.
bool material_changing(Material m) { return m.program_id != 0u && (materials[m.row].volume.flags & MATERIAL_PROGRAM_CHANGING) != 0u; }
Surface surface_from_triangle(uint instance_index, uint primitive, float2 bary, float footprint) {
    return surface_from_hit(hit_point(instance_index, primitive, bary, footprint), false, (Mirai_Surface)0);
}

// ---------------------------------------------------------------- probe volume
// Cascades of probes centered on volume_center (render/ddgi.odin): cascade c has
// volume_counts.xyz probes along each axis, volume_cascades[c].w metres apart,
// the probe of its lowest corner at volume_cascades[c].xyz, relative to the
// origin, in the cell volume_cells[c] of the grid of the world. A cell of the
// world keeps its slot while the cascade scrolls: along an axis, the slot of
// cell k is k modulo the count. A probe holds the light of the cell it was
// last traced for (Probe.cell); a slot whose probe was traced for another
// cell holds nothing yet.
uint probe_cascades() { return frame.volume_counts.w; }
float probe_spacing(uint cascade) { return frame.volume_cascades[cascade].w; }
uint probe_cascade_size() { return frame.volume_counts.x * frame.volume_counts.y * frame.volume_counts.z; }
int3 probe_corner_cell(uint cascade) { return frame.volume_cells[cascade].xyz; }
// Where the probe of a cell of the world is, relative to the origin.
float3 probe_cell_position(uint cascade, int3 cell) {
    return frame.volume_cascades[cascade].xyz + float3(cell - probe_corner_cell(cascade)) * probe_spacing(cascade);
}
uint probe_slot(uint cascade, int3 cell) {
    int3 counts = int3(frame.volume_counts.xyz);
    int3 wrapped = ((cell % counts) + counts) % counts;
    return cascade * probe_cascade_size() + uint(wrapped.x + counts.x * (wrapped.y + counts.y * wrapped.z));
}
// The cell of the world a slot stands for in this frame.
int3 probe_slot_cell(uint index, out uint cascade) {
    int3 counts = int3(frame.volume_counts.xyz);
    cascade = index / probe_cascade_size();
    uint local = index % probe_cascade_size();
    int3 wrapped = int3(int(local % uint(counts.x)), int((local / uint(counts.x)) % uint(counts.y)), int(local / uint(counts.x * counts.y)));
    int3 corner = probe_corner_cell(cascade);
    int3 from = ((corner % counts) + counts) % counts;
    return corner + ((wrapped - from) % counts + counts) % counts;
}
// Whether a probe holds the light of the cell its slot stands for.
bool probe_holds(Probe probe, int3 cell) { return all(probe.cell.xyz == cell) && (probe.cell.w & PROBE_VALID) != 0; }
// Where the probe of a slot traces from: its cell, moved out of geometry when
// it was traced for that cell before.
float3 probe_world_position(uint index) {
    uint cascade;
    int3 cell = probe_slot_cell(index, cascade);
    Probe probe = probes[index];
    float3 offset = all(probe.cell.xyz == cell) ? probe.offset.xyz : float3(0.0);
    return probe_cell_position(cascade, cell) + offset;
}
// The tile of a probe in the atlases, in tiles.
float2 probe_atlas_tile(uint index) {
    uint per_row = frame.volume_atlas.x;
    return float2(float(index % per_row), float(index / per_row));
}
// A direction as the [0,1] square the tiles map their interior to.
float2 probe_atlas_direction(float3 dir) { return oct_encode(normalize(dir)) * 0.5 + 0.5; }
// Atlas texel of an octahedral direction inside a probe tile (with 1 texel border).
float2 probe_atlas_texel(float2 tile_position, float2 oct, uint tile, float2 atlas_size) {
    float2 tile_origin = tile_position * float(tile);
    float2 texel = tile_origin + 1.0 + oct * float(tile - 2u);       // interior
    return texel / atlas_size;
}
float2 probe_atlas_uv(uint index, float3 dir, uint tile, float2 atlas_size) {
    return probe_atlas_texel(probe_atlas_tile(index), probe_atlas_direction(dir), tile, atlas_size);
}

// Distances are stored divided by this limit so the second moment fits in
// half floats at any spacing.
float probe_distance_limit(uint cascade) { return 1.5 * probe_spacing(cascade); }

// Under the tiles of the irradiance, the atlas keeps of each probe a tile of
// the light around a narrow lobe of each direction, with about a texel a ray:
// the power of the cosine its rays are weighed by there, as wide as a texel,
// and the roughness of the specular lobe that is as wide. A smoother lobe
// reads it as it is, the most the rays of a probe tell apart; a rougher one
// goes to the irradiance as it widens.
#define PROBE_GLOSS_POWER 48.0
#define PROBE_GLOSS_ROUGHNESS 0.45
// The row of texels the tiles of the narrow lobes start at, and the first
// texel of that of a probe from its tile of the irradiance (probe_atlas_tile):
// they keep its row and column.
uint probe_gloss_under() {
    uint per_row = max(frame.volume_atlas.x, 1u);
    return (probe_cascade_size() * probe_cascades() + per_row - 1u) / per_row * frame.volume_atlas.y;
}
float2 probe_gloss_origin(float2 tile, uint under) { return tile * float(PROBE_GLOSS_TILE) + float2(0.0, float(under)); }

// The directions one read of the probe volume gives the light around, at
// most: those of the diffuse lobe, the specular lobe and the coat of a point.
#define PROBE_READS 3
#define PROBE_DIFFUSE 0
#define PROBE_SPECULAR 1
#define PROBE_COAT 2

// What a read of the probe volume gives the light around: at[d] for each bit
// d of `wants`. The probes around a point and their weights depend only on the
// point, so each direction costs only its irradiance.
// rough[d]: the roughness of the lobe around at[d], for the lobes other than the diffuse; 1, the irradiance.
struct Probe_Directions {
    float3 at[PROBE_READS];
    float rough[PROBE_READS];
    uint wants;
};
Probe_Directions probe_directions(float3 direction) {
    Probe_Directions directions;
    [ForceUnroll]
    for (int d = 0; d < PROBE_READS; d++) {
        directions.at[d] = direction;
        directions.rough[d] = 1.0;
    }
    directions.wants = 1u;
    return directions;
}
bool probe_wants(Probe_Directions directions, int d) { return (directions.wants & (1u << uint(d))) != 0u; }

// What the probes of a cascade around a point give around each direction it
// wants (w: the share of it that comes from the sky, blended as it is),
// where they see it, and its weight: zero where none of them holds
// light. The weights are those of DDGI (wrapped cosine, Chebyshev visibility,
// small weights crushed); the irradiance blends as its square root, so that a
// bright probe does not stain dark neighbors, and the point moves off its
// surface and towards the eye by a share of the spacing that shrinks as the
// eye, or the origin of the ray that found the point, comes closer than a
// cell (`viewer_distance`): moved farther, it would pass the surface the ray
// left. Where the probes that see the point in the open (its distance within
// their mean, up to PROBE_SEEN_MARGIN spacings) hold enough of the weight of
// the grid, the others count only as much as they see it: at the edge of a
// wall thinner than the spacing, a probe moved to its other side looks past
// the edge, the variance of its distances swells, and Chebyshev left it
// weight enough to bring in the light beyond. The share goes smoothly with
// the distances and the place in the cell, so the light has no seam where a
// probe stops seeing the point.
#define PROBE_SEEN_MARGIN 0.1
#define PROBE_SEEN_GAIN 4.0
#define PROBE_HIDDEN_SHARE 0.055
float probe_cascade_read(uint cascade, float3 position, float3 normal, float3 view_dir, float viewer_distance, Probe_Directions directions, bool surface, out float4 light[PROBE_READS]) {
    float spacing = probe_spacing(cascade);
    float limit = probe_distance_limit(cascade);
    float toward_eye = lerp(0.0, 0.8, saturate(viewer_distance / spacing));
    float3 biased = position + (normal * 0.2 + view_dir * toward_eye) * (0.6 * spacing);
    int3 counts = int3(frame.volume_counts.xyz);
    float3 rel = (biased - frame.volume_cascades[cascade].xyz) / spacing;
    int3 base = clamp(int3(floor(rel)), int3(0), max(counts - 2, int3(0)));
    float3 alpha = clamp(rel - float3(base), 0.0, 1.0);
    int3 first = probe_corner_cell(cascade) + base;
    // The slots of the 8 probes step from that of the first, as probe_slot wraps them.
    int3 first_slot = ((first % counts) + counts) % counts;
    uint cascade_slot = cascade * probe_cascade_size();
    float2 irr_size = float2(texture_size(irradiance_atlas, 0));
    float2 dist_size = float2(texture_size(distance_atlas, 0));
    float2 toward[PROBE_READS];
    float gloss[PROBE_READS];
    uint gloss_under = probe_gloss_under();
    float4 sum[PROBE_READS];
    [ForceUnroll]
    for (int d = 0; d < PROBE_READS; d++) {
        toward[d] = probe_wants(directions, d) ? probe_atlas_direction(directions.at[d]) : float2(0.0);
        gloss[d] = saturate((1.0 - directions.rough[d]) / (1.0 - PROBE_GLOSS_ROUGHNESS));
        sum[d] = float4(0.0);
        light[d] = float4(0.0);
    }
    float weight_sum = 0.0;
    // The same weighed by how much each probe sees the point, and the share
    // of the trilinear weight of those that see it.
    float4 seen_sum[PROBE_READS];
    [ForceUnroll]
    for (int d = 0; d < PROBE_READS; d++) seen_sum[d] = float4(0.0);
    float seen_weight = 0.0;
    float seen_share = 0.0;
    uint held = 0u;
    [unroll]
    for (int i = 0; i < 8; i++) {
        int3 offset = int3(i & 1, (i >> 1) & 1, (i >> 2) & 1);
        int3 cell = first + offset;
        int3 slot = first_slot + offset;
        slot = select(slot == counts, int3(0), slot);
        uint index = cascade_slot + uint(slot.x + counts.x * (slot.y + counts.y * slot.z));
        Probe probe = probes[index];
        if (!probe_holds(probe, cell)) continue;
        float3 probe_pos = probe_cell_position(cascade, cell) + probe.offset.xyz;
        // A probe behind the plane of a surface sees the other side of what the
        // surface is part of: through a wall thinner than the spacing, its light
        // leaks. 5 cm, in metres: the most a probe stays behind the plane it lights.
        if (surface && dot(probe_pos - position, normal) < -0.05) continue;
        float2 tile = probe_atlas_tile(index);
        held++;
        float3 to_probe = normalize(probe_pos - position);
        float3 tri = lerp(1.0 - alpha, alpha, float3(offset));
        float weight = 1.0;
        float facing = (dot(to_probe, normal) + 1.0) * 0.5;
        weight *= facing * facing + 0.2;
        float3 probe_to_point = biased - probe_pos;
        float distance_to_probe = length(probe_to_point);
        float2 moments = distance_atlas.SampleLevel(linear_sampler, probe_atlas_texel(tile, probe_atlas_direction(probe_to_point), frame.volume_atlas.z, dist_size), 0.0).rg * float2(limit, limit * limit);
        float mean = moments.x;
        float variance = abs(mean * mean - moments.y);
        float chebyshev = 1.0;
        if (distance_to_probe > mean) {
            float d = distance_to_probe - mean;
            chebyshev = variance / (variance + d * d);
            chebyshev = max(chebyshev * chebyshev * chebyshev, 0.0);
        }
        weight *= chebyshev;
        weight = max(0.000001, weight);
        const float crush = 0.2;
        if (weight < crush) weight *= weight * weight / (crush * crush);
        float trilinear = tri.x * tri.y * tri.z;
        weight *= trilinear;
        float sees = saturate(1.0 - max(distance_to_probe - mean, 0.0) / (PROBE_SEEN_MARGIN * spacing));
        [ForceUnroll]
        for (int d = 0; d < PROBE_READS; d++) {
            if (!probe_wants(directions, d)) continue;
            float4 stored = gloss[d] < 1.0 ? irradiance_atlas.SampleLevel(linear_sampler, probe_atlas_texel(tile, toward[d], frame.volume_atlas.y, irr_size), 0.0) : float4(0.0);
            float4 root = float4(probe_light_root(stored.rgb), stored.a);
            // The diffuse lobe is the irradiance: it pays nothing of the narrow ones.
            [branch]
            if (d != PROBE_DIFFUSE && gloss[d] > 0.0) {
                float4 narrow = irradiance_atlas.SampleLevel(linear_sampler, (probe_gloss_origin(tile, gloss_under) + 1.0 + toward[d] * float(PROBE_GLOSS_TILE - 2u)) / irr_size, 0.0);
                root = lerp(root, float4(probe_light_root(narrow.rgb), narrow.a), gloss[d]);
            }
            root *= weight;
            sum[d] += root;
            seen_sum[d] += root * sees;
        }
        weight_sum += weight;
        seen_weight += weight * sees;
        seen_share += trilinear * sees;
    }
    // Where every probe sees the point hidden, their tiny weights still share
    // out their light: the point is not left to the next cascade or the sky.
    if (held == 0u || weight_sum <= 0.0) return 0.0;
    float open = saturate(PROBE_SEEN_GAIN * seen_share);
    float total = lerp(weight_sum, seen_weight, open);
    float shown = PROBE_HIDDEN_SHARE > 0.0 ? saturate(seen_share / PROBE_HIDDEN_SHARE) : 1.0;
    [ForceUnroll]
    for (int d = 0; d < PROBE_READS; d++) {
        float4 root = lerp(sum[d], seen_sum[d], open) / total;
        light[d] = float4(root.rgb * root.rgb, root.a) * shown;
    }
    return 1.0;
}

// What the probe volume gives a point around each direction it wants, and
// how much of it the volume holds: the finest cascade whose probes surround
// it, blending into the next one over the last cells before its edge, and the
// next one where none of its probes holds light yet; 0 where none holds any
// and -1 beyond the cascades.
float probe_volume_read(float3 position, float3 normal, float3 view_dir, float viewer_distance, Probe_Directions directions, bool surface, out float4 light[PROBE_READS]) {
    [ForceUnroll]
    for (int d = 0; d < PROBE_READS; d++) light[d] = float4(0.0);
    float3 counts = float3(frame.volume_counts.xyz);
    uint cascades = probe_cascades();
    uint cascade = cascades;
    float edge = 0.0;
    for (uint c = 0u; c < cascades; c++) {
        float spacing = probe_spacing(c);
        float3 rel = (position - frame.volume_cascades[c].xyz) / spacing;
        float3 inside = min(rel, counts - 1.0 - rel);
        if (min(inside.x, min(inside.y, inside.z)) < 0.5) continue;
        // The blend into the next cascade goes by the centre of the cascades, which
        // moves on smoothly: by the cascade, which steps a cell at a time, it jumped
        // at every step. Not by the eye, which the cascades may not centre on.
        float3 from_center = (counts - 1.0) * 0.5 - abs(position - frame.volume_center.xyz) / spacing;
        edge = min(from_center.x, min(from_center.y, from_center.z));
        cascade = c;
        break;
    }
    if (cascade == cascades) return -1.0;
    bool next = cascade + 1u < cascades;
    // Whole by an edge of 1.5 cells: the cascade still holds the point there, as it is up to a
    // cell off the centre. Over as wide a band as leaves the 3 cells below and above the centre
    // whole in the cascade (the floor under an eye there), and at least half a cell.
    float band = max(0.5, (counts.y - 1.0) * 0.5 - 4.5);
    float blend = next ? saturate((1.5 + band - edge) / band) : 0.0;
    float held = 0.0;
    // The finest cascade, then the next one where it blends or holds nothing.
    [loop]
    for (uint k = 0u; k < 2u; k++) {
        float4 read[PROBE_READS];
        float a = probe_cascade_read(cascade + k, position, normal, view_dir, viewer_distance, directions, surface, read);
        if (k == 0u || held == 0.0) {
            held = a;
            light = read;
            if (k == 0u && next && (blend > 0.0 || a == 0.0)) continue;
            break;
        }
        if (a > 0.0) {
            [ForceUnroll]
            for (int d = 0; d < PROBE_READS; d++) light[d] = lerp(light[d], read[d], blend);
        }
    }
    return held;
}

// How much of the light around a point is the sky's alone: 0 inside the
// cascades and without a volume, 1 beyond them, and between over the last
// cells of the last one, by the centre of the cascades as one blends into the
// next. Along an axis with too few cells to keep any of them whole that way,
// by the cells of the cascade themselves: the cascade holds the point up to
// its last one.
float probe_volume_beyond(float3 position) {
    uint cascades = probe_cascades();
    if (cascades == 0u) return 0.0;
    float3 counts = float3(frame.volume_counts.xyz);
    float spacing = probe_spacing(cascades - 1u);
    float3 rel = (position - frame.volume_cascades[cascades - 1u].xyz) / spacing;
    float3 inside = min(rel, counts - 1.0 - rel) - 0.5;
    if (min(inside.x, min(inside.y, inside.z)) < 0.0) return 1.0;
    float3 half = (counts - 1.0) * 0.5;
    float band = max(0.5, half.y - 4.5);
    float3 from_center = half - abs(position - frame.volume_center.xyz) / spacing - 1.5;
    float3 left = select(half >= 1.5 + 2.0 * band, from_center, inside);
    return saturate(1.0 - min(left.x, min(left.y, left.z)) / band);
}

// Irradiance (in Lambert-normalized radiance units) arriving around each
// direction a surface point wants, from the probe volume, or zero when no
// cache exists (callers add their own ambient floor) or no probe holds light
// yet; beyond the cascades, the sky's, which the last one blends into. w is
// the share of it that comes from the sky. The normal places the lookup and weights the probes; the
// directions are what the irradiance is read for.
// `view_dir` points towards the eye or the origin of the ray that found the
// point, `viewer_distance` away; below 0, the eye of the view.
// The share of it that comes through a gate of an extension is that of the
// place beyond the gate, so the light of a point at a gate is the same on both
// of its sides.
void probe_volume_light(float3 position, float3 normal, float3 view_dir, float viewer_distance, Probe_Directions directions, bool surface, out float4 light[PROBE_READS]) {
    float beyond = probe_volume_read(position, normal, view_dir, viewer_distance, directions, surface, light) >= 0.0 ? probe_volume_beyond(position) : 1.0;
    if (beyond <= 0.0) return;
    [ForceUnroll]
    for (int d = 0; d < PROBE_READS; d++) {
        if (probe_wants(directions, d)) light[d] = lerp(light[d], float4(sky_irradiance(directions.at[d]), 1.0), beyond);
    }
}

#endif
