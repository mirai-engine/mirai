// Shared declarations for every Mirai shader. Layouts are scalar and mirrored
// by render/gpu_types.odin (sizes are asserted there). The constants shared
// with the CPU come generated in shared_constants.slang from their Odin
// declarations (render/abi, asset, rhi): none is defined in a shader source.
#ifndef MIRAI_COMMON_SLANG
#define MIRAI_COMMON_SLANG
// What the extensions of the generation ask of the stages of the engine: empty
// for a generation without them. Frame_Data ends with the nested views
// (MIRAI_FRAME_NESTED) and the fields of the extensions (MIRAI_FRAME_EXTENSIONS)
// only in the stages that read them; the generation decides which
// (cook/shaders/extensions.odin).
#include <extensions.slang>
#include <material_schema.slang>
#include <shared_constants.slang>
#include "origin.slang"

// ---------------------------------------------------------------- binding slots
// SLOT_*: one table for all passes (render/abi). MATERIAL_TEXTURE_SLOT is the
// texture table of the RHI: every material texture, picked by the index a
// material stores. It has no size: it grows with the textures of the scene.
// Its first TEXTURE_TABLE_RESERVED entries hold the tables of the renderer
// (DFG_TEXTURE, AIR_*_TEXTURE).

#define PI 3.14159265358979
#define INV_PI 0.31830988618379
#define FLT_MAX 3.402823e+38
#define INVALID 0xFFFFFFFFu

// ---------------------------------------------------------------- frame constants
#ifdef MIRAI_FRAME_NESTED
// A view drawn inside some pixels of another with the same projection: what a
// camera carried by a rigid transform sees. Its pixels keep their linear depth
// negative, and its index in the alpha of the motion target.
struct Nested_View {
    float4 to_world[3];            // rows: carries the camera of the view, and what it would see, to those of the nested one
    float4 from_world_previous[3]; // rows: the inverse of that transform in the previous frame
    float4 eye;                    // the eye of the nested view, as Frame_Data.eye
    float4 opening;                // the plane its pixels are seen through, in the world of the view; zero: none known
};
#endif

// The air of an atmosphere (render.Gpu_Air), in metres. Its density falls
// with altitude: Rayleigh and Mie by e every scale height, ozone as a tent
// around the middle of its layer.
struct Air_Data {
    float4 rayleigh;       // rgb what a metre of air at the ground scatters, w its scale height
    float4 mie;            // rgb what a metre of haze at the ground scatters, w its scale height
    float4 mie_absorption; // rgb what it absorbs, w the anisotropy of its phase
    float4 ozone;          // rgb what a metre of the middle of the ozone layer absorbs, w that altitude
    float4 planet;         // x the radius of the ground, y that of the top of the air, z the half width of the ozone layer, w the altitude of the eye over the ground
    float4 ground;         // rgb the albedo of the ground of the planet, w the angular radius of the sun, radians
    float4 rows;           // x the row of the sky of the eye in AIR_SKY_TEXTURE, yzw 1 over what crosses the air straight up from the ground
};

struct Frame_Data {
    float4x4 view;                 // it and the view_proj ones take a point from the eye: camera_position, prev_eye for prev_view_proj (view_clip of scene.slang)
    float4x4 proj;
    float4x4 view_proj;
    float4x4 inv_view_proj;
    float4x4 prev_view_proj;       // previous frame, without jitter
    float4x4 view_proj_unjittered; // current frame without the TAA sub-pixel jitter
    float4 camera_position;   // xyz, w = near plane
    float4 camera_forward;    // xyz, w = far plane
    float4 sun_direction;     // xyz towards the sun, w = 0 no sun, 1 active, SUN_UNSHADOWED active and no ray goes to it
    float4 sun_color;         // rgb its illuminance over pi, render units (above the air of an atmosphere: sun_light), w = the angular radius of its disc in the sky; 0: it is not seen
    float4 sky_color;         // rgb the luminance of the sky, render units, w = the light scale: render units per nit
    float4 background;        // rgb luminance shown where no geometry is visible, render units, w = 1 to use it instead of the sky
    float4 frustum[6];        // world planes (xyz normal, w distance), inside when dot >= 0
    float4 volume_cascades[VOLUME_CASCADES_MAX]; // xyz the place of the probe at the lowest corner of each cascade, relative to the origin, w its spacing
    uint4 volume_counts;    // xyz probes of a cascade along each axis, w cascades
    uint4 volume_atlas;     // x = probes per atlas row, y = irradiance tile, z = distance tile, w = 1 when the volume holds light
    float2 resolution;
    float2 inv_resolution;
    uint frame_index;
    uint light_nodes;       // of the light tree; 0: no local light
    uint instance_count;
    uint debug_view;
    float gi_strength;
    float exposure;         // the scene-linear value of one render unit, as a frame before exposed the view
    uint own;               // bits 0-7: 1 + the local slot whose body (INSTANCE_FLAG_OWNED) is the view's own, 0: none; bits 16-31: how much of it the view fades out, unorm
    uint flags;             // FRAME_FLAG_*
    uint4 shadowless_lights; // x the root of the tree of the local lights that cast no shadows (render/light_tree.odin), 0: none; y the node after it; zw 0
    float4 jitter;            // xy current TAA jitter in render pixels, zw previous
    float4 texturing;         // x = mip bias of rasterized material textures, y = roughness below which reflections are traced (0: none are), z = first box of a glass instance listed after the TLAS nodes, w = how many
    float4 time; // current, previous simulation time in seconds
    // The ray of the pixel at uv: a point at linear depth d along it is
    // (eye_origin + eye_du * uv.x + eye_dv * uv.y) + d * (ray_origin + ray_du * uv.x + ray_dv * uv.y),
    // whatever the projection.
    float4 eye_origin;
    float4 eye_du;
    float4 eye_dv;
    float4 ray_origin;
    float4 ray_du;
    float4 ray_dv;
    float4 eye;              // the eye as a point (xyz, 1), or the direction towards it (xyz, 0) for a parallel projection
    float4 depth_plane;      // the linear depth of a world point: dot(xyz, point) + w
    float4 prev_depth_plane; // the same for the previous camera
    float4 prev_eye;         // xyz the eye of the previous camera, which prev_view_proj takes points from
    float4 clip_plane;       // world plane nothing is drawn behind; zero for none
    float2 footprint;        // x width of a pixel at depth 0, y what it grows by per unit of depth
    uint layers;             // the instances the view draws: those whose layers share a bit with these
    uint view_index;         // of the nested view these constants draw; 0 for the view itself
    float4 sky_map;          // x = the image of the sky in the texture table, y = 1 for an atmosphere lit by the sun, z = its last level, w = 1 with an image
    float4 sky_orientation;  // the turn of the sky, a quaternion (xyz, w): a direction of the world is one of the sky by its inverse
    float4 sky_from;         // a change of the sky on its way: rgb the luminance it changes from (render units), a how much of it still shows
    float4 sky_from_map;     // the image it changes from, as sky_map
    float4 tint;             // rgb what the image is multiplied by before the display
    Air_Data air;            // the air of an atmosphere (sky_map.y), with sun_color the light of the sun above it
    int4 origin;             // xyz what every place of the frame is relative to (render/origin.odin), in steps of ORIGIN_STEP: what it adds to a place, origin.slang
    float4 scene_box[2];     // xyz the lowest corner of what rays meet, relative to the origin, then the highest; low above high: nothing (scene_reach)
    int4 volume_cells[VOLUME_CASCADES_MAX]; // xyz the cell of the world of the probe at the lowest corner of each cascade
    float4 volume_center;    // xyz where the cascades centre, relative to the origin, which moves on smoothly as they step a cell at a time
    float4 detail_eye;       // where the levels of detail are chosen from (xyz) and its near plane (w): the eye of the view, or that of render.Frame_Detail
    float4 detail_footprint; // xy the footprint of a pixel of that eye, as footprint; zw 0
    float4 cut;              // x the error in pixels the cut of the levels of the meshes allows (Settings.lod_error_pixels); 0 draws level 0. y the pixels across below which an instance of a batch is not rasterized (Settings.batch_min_pixels); 0 draws every one
    uint4 batches;           // the batches drawn (scene.slang): x their instance slots, y the first word of their group table in the u32 pool, z how many, w how many rays meet
    uint4 moved;             // what casts shadows and changed since the frame before (occluder_changed of trace.slang): x the boxes of moved_boxes, y the lights of moved_lights, z MOVED_* bits
    float4 moved_boxes[OCCLUDER_CHANGES_MAX * 2]; // low (w: the instance, as bits; OCCLUDERS_MANY: several), then high, relative to the origin
    uint4 moved_lights[LIGHT_MOVES_MAX / 4];
    uint4 sun_maps;          // x the maps of the shadows of the sun the view drew this frame, the nearest cascade first (sun_shadow_seen of shadow_maps.slang), 0: none; y where the rows of the maps start in their buffer; z the side of their atlas, texels, while the view drew maps, else 0; w 1 while they keep the tint of glass
    uint4 sun_map_rows[SUN_MAP_ROWS];
#ifdef MIRAI_FRAME_NESTED
    Nested_View nested[NESTED_VIEW_CAPACITY]; // nested[i - 1] for the pixels whose view index is i
#endif
#ifdef MIRAI_FRAME_EXTENSIONS
    MIRAI_FRAME_EXTENSIONS
#endif
};

// ---------------------------------------------------------------- scene data
// A whole vertex, which thumbnails and previews upload for themselves. The
// scene keeps its vertices in clusters, read by geometry.slang alone.
struct Vertex {
    float3 position;
    uint normal;       // octahedral snorm16x2
    float2 uv;           // origin at the top left of the image, v downwards
    uint color;        // rgba8 unorm: rgb multiplies the base color
    uint material;     // row of the material table
    float2 uv1;
    uint tangent;      // pack_tangent: MikkTSpace, with the sign of its bitangent
};
// A vertex of the geometry of a thumbnail, with the emission of its instance.
struct Thumbnail_Vertex { Vertex vertex; float3 emission; };
// A vertex of UI geometry in points, 40 bytes written by the engine.
struct Ui_Vertex { float3 position; float4 color; uint material; float2 uv; };
// The parameters of a post-process effect. exposed: before the tonemap the
// effect sees the image exposed, scene-linear values where middle gray is
// 0.18, whatever the light of the scene.
// outlined: the outline mask holds this frame (mirai_outline).
struct Post_Parameters { uint program; uint exposed; uint outlined; float fade; float4 values[16]; };

// Up to 128 triangles of one slot of a mesh, with their vertices
// (asset.Cluster): in the index pool, CLUSTER_WORDS each, read by geometry.slang.
struct Cluster {
    int3 position;       // its lowest corner, in steps of the position grid of its mesh
    uint vertex_first;   // its first vertex, of those of the mesh
    int2 uv;             // the lowest uv of its vertices, in steps of the uv grid
    int2 uv1;
    uint triangle_first; // its first word of triangles, from those of the mesh
    uint counts;         // vertices - 1 (bits 0-7), triangles (8-15), slot (16-20), CLUSTER_CONE, cutoff of the cone (24-31, snorm8)
    uint size_xy;        // the size of its box in steps: x (0-15), y (16-31)
    uint size_z_cone;    // z (0-15), the axis of its cone, octahedral snorm8 (16-31)
    float4 lod;          // the sphere its error is seen from, in the space of the mesh
    float error;
    float4 parent;       // the sphere of the clusters that replace it
    float parent_error;  // their error; FLT_MAX: nothing replaces it
    uint page;           // the page of its mesh that holds it
    uint child_page;     // the page of the group it was simplified from; INVALID at level 0
};
// A vertex of a skinned or deformed mesh where it is now (render.Gpu_Posed_Vertex).
struct Posed_Vertex { float3 position; uint normal; uint tangent; };

struct Instance {
    float4 world[3];      // rows of the object-to-world 3x4 matrix
    float4 world_inv[3];  // rows of the world-to-object 3x4 matrix
    float4 prev_world[3];
    uint4 meta;         // x mesh (bits 0-23) and the cut rays trace it with (24-25), y material in place of the slots' (INVALID: theirs), z object id, w flags
    float4 bounds_min;    // world space AABB
    float4 bounds_max;
    float4 tint;          // rgb multiplies the base color
    float4 emission;      // rgb radiance added to the material's
    float4 glass;         // rgb: what a crossing of one of its blended faces leaves of light, the mean over them (glass_mean.comp writes it after every upload); a: their area
    uint slot_materials[32]; // row+1 by source slot; zero inherits
    float wet;            // 0 dry to 1 soaked (render.scene_set_instance_wet)
    uint reserved[3];
};
uint instance_mesh(Instance inst) { return inst.meta.x & INSTANCE_MESH_MASK; }
uint instance_ray_cut(Instance inst) { return (inst.meta.x >> INSTANCE_RAY_SHIFT) & 3u; }

// A cut of a mesh rays trace (render.Gpu_Mesh_Ray): the root of its tree and
// its first triangle by software, the table of the primitives of its BLAS
// with hardware, and its error.
struct Mesh_Ray { uint bvh_root; uint triangle_offset; uint table_word; float error; };
struct Mesh {
    uint cluster_word;   // its first cluster in the index pool
    uint cluster_count;
    uint level_word;     // its levels in the index pool: first cluster, count, error, parent error
    uint level_count;
    uint page_word;      // its page table in the index pool (geometry.slang, page_at)
    uint page_count;
    uint vertex_count;
    uint slot_word;      // the material word of each slot in the index pool
    uint posed_word;     // INVALID: as its clusters
    uint previous_word;
    uint part_word;      // posed with its part collapsed, then where that was; INVALID: none
    uint part_layers;    // of its part: a view that does not draw them draws those vertices
    uint flags;          // MESH_FLAG_*
    uint slab_axes;      // bit per object axis across which every vertex lies on a face of the box
    float position_step; // of the grids of its clusters
    float uv_step;
    float uv1_step;
    float lod_reach;     // how far a sphere of its levels reaches past its box
    uint bounds_word;    // of a pose: the box and the cone of the normals of each cluster it poses, as posed now (geometry.slang, posed_bounds); INVALID: none
    uint pad0;
    float4 bounds_min;   // object space
    float4 bounds_max;
    Mesh_Ray rays[MESH_RAY_LEVELS];
};

// The maps of a material (MATERIAL_MAP_* of the schema, asset.Material_Maps
// says what each one holds) are the index of its texture and of its
// transform. A texture is an index into the texture table, INVALID for none;
// each one multiplies the value it belongs to.
// The occlusion texture of a material whose occlusion is the red of its
// metallic-roughness texture, placed the same way: one sample serves both.
#define MATERIAL_OCCLUSION_PACKED 0xFFFFFFFEu

// Where a map reads its texture: uv' = linear * uv + offset, the transform of
// the material and the scale, rotation and offset of the map composed once on
// the CPU. ray_lod is the level a ray adds for what that transform shrinks.
struct Material_Map_Transform {
    float4 linear;  // xy and zw: the rows of the 2x2 matrix
    float2 offset;
    uint uv_set;
    float ray_lod;
};

// The values of a material that shading holds by value (render.Gpu_Material).
struct Material {
    float3 base_color;          // linear
    float opacity;
    float3 emission;            // by emission_mode: luminance in nits, or the exposed value
    float normal_scale;
    float roughness;
    float metallic;
    float occlusion_strength;
    float alpha_cutoff;
    float3 specular_color;      // multiplies the dielectric F0 of its IOR
    float specular_factor;
    float transmission;         // share of the light that goes through instead of being diffused
    float ior;                  // 0: a constant Fresnel
    float thickness;            // 0: a sheet
    float attenuation_distance; // 0: the solid absorbs nothing
    float3 attenuation_color;   // what a solid leaves of white light that crosses attenuation_distance of it
    uint alpha_mode;            // ALPHA_*
    uint layers;                // MATERIAL_LAYER_* bits: which blocks of the row it reads
    uint emission_mode;         // EMISSION_*
    uint program_id;            // Surface program that replaces the values above; 0 for none
    uint textures[MATERIAL_MAPS];
    uint row;                   // of the material table, where the rest of it follows
};
// A row of the material table. Shading code holds its Material by value; where
// a map is placed and what a program reads are fetched from the row at the
// point that uses them, so a surface without maps or program reads neither.
// The blocks of a row read only when the bit of their layer is set.
struct Material_Coat { float3 color; float weight; float roughness; float ior; float normal_scale; };
struct Material_Fuzz { float3 color; float weight; float roughness; };
struct Material_Anisotropy { float amount; float2 rotation; }; // rotation: cosine and sine
struct Material_Diffuse_Transmission { float3 color; float weight; };
struct Material_Volume { float3 scatter; float pad; }; // what a solid scatters of what it stops
struct Material_Row {
    Material shared;
    Material_Coat coat;
    Material_Fuzz fuzz;
    Material_Anisotropy anisotropy;
    Material_Diffuse_Transmission diffuse_transmission;
    Material_Volume volume;
    Material_Map_Transform map_transforms[MATERIAL_MAPS];
    float4 custom_params[16];
};

// What the vertex shader tells the fragment shaders of an instance.
#define RASTER_HIGHLIGHT_MASK 31u // outline level
#define RASTER_FLAG_MIRRORED 32u  // its transform turns the winding of its triangles around
#define RASTER_FLAG_FADING 64u    // what fades out by the unorm16 of bits 16-31: the body the view fades out (view_body_fade), or an instance of a batch near its cull distance
#define RASTER_FADE_SHIFT 16u

struct Light {
    float4 position_range;   // xyz, w range
    float4 color_intensity;  // rgb color, w intensity
    float4 direction_cone;   // spot: xyz direction, w cos(half-angle); a rectangle: xyz the side it lights, w LIGHT_RECT; w LIGHT_POINT for the others
    float4 size;             // x the radius of the sphere, or of the capsule, metres; y half the segment of a capsule along axis, or half the width of a rectangle; z half its height; w the material row whose emission a rectangle shows, as uint bits (0: none)
    float4 axis;             // xyz along the segment of a capsule, or the width of a rectangle
};

// A node of the tree of the local lights (render/light_tree.odin): a leaf is
// a light, a group stands for the lights under it as one sphere of light.
// The first child of a group follows it.
struct Light_Node {
    float4 center_radius; // xyz the center of its lights, weighed by how bright each is; w the radius of the sphere around it that holds them
    float4 power_reach;   // rgb the sum of their colors times their intensities; w how far from the center the farthest of them reaches
    float4 cone;          // xyz the axis of the directions they face; w the half-angle around it that holds those directions, radians; PI: any
    float emission;       // the half-angle beyond the directions they face that their light goes, radians: a spot its cone, a rectangle a quarter turn
    float range;          // of a group, the mean of their ranges weighed by how bright each is
    float spread;         // root of the mean square of how far their light lies from the center, their sizes included
    uint child;           // a leaf: its light; a group: its second child
    uint flags;           // LIGHT_NODE_*, and the number of its lights
};

struct Bvh_Node {
    float3 bounds_min;
    uint left_first;   // inner: left child (right = left + 1); leaf: first item
    float3 bounds_max;
    uint count;        // 0 for inner nodes
};

struct Bvh_Triangle {
    float3 v0;
    uint primitive; // index within the mesh (integer, never float bits)
    float4 e1;
    float4 e2;
};

// Probe.cell.w flags: traced for its cell and seeing out of geometry; inside
// geometry; chosen to be traced this frame (ddgi_select.comp, until ddgi_relocate.comp).
#define PROBE_VALID 1
#define PROBE_BURIED 2
#define PROBE_CHOSEN 4
struct Probe {
    float4 offset; // xyz from the center of its cell, metres; w how near it is to the change that keeps it awake, 0 to 1 (ddgi_touch.comp)
    int4 cell;     // xyz the cell of the world it was last traced for, w PROBE_* flags
    uint4 frames;  // x when it was last traced, y last used by a pixel, z last reached by a change
};

// ---------------------------------------------------------------- helpers
float3 transform_point(float4 m[3], float3 p) {
    return float3(dot(m[0].xyz, p) + m[0].w, dot(m[1].xyz, p) + m[1].w, dot(m[2].xyz, p) + m[2].w);
}
float3 transform_vector(float4 m[3], float3 v) {
    return float3(dot(m[0].xyz, v), dot(m[1].xyz, v), dot(m[2].xyz, v));
}
// Normals use the inverse transpose: n_world = transpose(inv) * n.
float3 transform_normal(float4 inv[3], float3 n) {
    return normalize(inv[0].xyz * n.x + inv[1].xyz * n.y + inv[2].xyz * n.z);
}

// The solid angle of a convex polygon seen from a point, each direction
// weighed by its cosine to normal, of the part above the horizon of normal:
// pi when it covers that whole side. The integral along the edges of that
// part (Arvo 1995). Corners relative to the point, in order around it.
float polygon_projected_angle<let N : int>(float3 corners[N], float3 normal) {
    float3 polygon[N + 1];
    uint count = 0u;
    for (uint i = 0u; i < uint(N); i++) {
        float3 a = corners[i];
        float3 b = corners[i + 1u < uint(N) ? i + 1u : 0u];
        float above_a = dot(normal, a);
        float above_b = dot(normal, b);
        if (above_a >= 0.0) { polygon[count] = a; count++; }
        if ((above_a >= 0.0) != (above_b >= 0.0)) { polygon[count] = a + (b - a) * (above_a / (above_a - above_b)); count++; }
    }
    if (count < 3u) return 0.0;
    float sum = 0.0;
    for (uint i = 0u; i < count; i++) {
        float3 a = normalize(polygon[i]);
        float3 b = normalize(polygon[i + 1u < count ? i + 1u : 0u]);
        float3 edge = cross(a, b);
        float sine = length(edge);
        if (sine > 1e-7) sum += dot(normal, edge) * (atan2(sine, dot(a, b)) / sine);
    }
    return abs(sum) * 0.5;
}

float2 oct_wrap(float2 v) { return (1.0 - abs(v.yx)) * float2(v.x >= 0.0 ? 1.0 : -1.0, v.y >= 0.0 ? 1.0 : -1.0); }
float2 oct_encode(float3 n) {
    n /= (abs(n.x) + abs(n.y) + abs(n.z));
    float2 p = n.z >= 0.0 ? n.xy : oct_wrap(n.xy);
    return p;
}
float3 oct_decode(float2 p) {
    float3 n = float3(p, 1.0 - abs(p.x) - abs(p.y));
    if (n.z < 0.0) n.xy = oct_wrap(n.xy);
    return normalize(n);
}
float3 unpack_normal(uint packed) { return oct_decode(unpackSnorm2x16(packed)); }
// The tangent of a vertex (std/math tangent_pack): xyz along u, w the sign of
// its bitangent, sign * cross(normal, tangent).
float4 unpack_tangent(uint packed) {
    float2 p = float2(float(int(packed & 0x7FFFu) - 16384), float(int((packed >> 15u) & 0x7FFFu) - 16384)) / 16383.0;
    return float4(oct_decode(p), (packed & (1u << 30u)) != 0u ? -1.0 : 1.0);
}
uint pack_tangent(float3 tangent, float sign) {
    int2 q = int2(round(clamp(oct_encode(tangent), -1.0, 1.0) * 16383.0)) + 16384;
    return uint(q.x) | (uint(q.y) << 15u) | (sign < 0.0 ? (1u << 30u) : 0u);
}
float4 unpack_rgba8(uint packed) { return unpackUnorm4x8(packed); }
// The tangent of a vertex of a cluster about its packed normal: its angle in
// bits 0-14 and the sign of its bitangent in bit 15 (std/math
// tangent_angle_pack). The axis the angle turns from is decided on the
// integers of the normal, as the CPU decides it.
float4 unpack_tangent_angle(uint normal_packed, uint angle) {
    int x = max(int(normal_packed << 16u) >> 16, -32767);
    int y = max(int(normal_packed) >> 16, -32767);
    int z = 32767 - abs(x) - abs(y);
    if (z < 0) {
        int folded = (32767 - abs(y)) * (x >= 0 ? 1 : -1);
        y = (32767 - abs(x)) * (y >= 0 ? 1 : -1);
        x = folded;
    }
    uint least = abs(y) < abs(x) ? 1u : 0u;
    if (abs(z) < abs(least == 0u ? x : y)) least = 2u;
    float3 n = unpack_normal(normal_packed);
    float3 along = normalize(cross(float3(least == 0u ? 1.0 : 0.0, least == 1u ? 1.0 : 0.0, least == 2u ? 1.0 : 0.0), n));
    float3 across = cross(n, along);
    float turn = float(angle & 0x7fffu) * (2.0 * PI / 32768.0);
    return float4(along * cos(turn) + across * sin(turn), (angle & 0x8000u) != 0u ? -1.0 : 1.0);
}

float luminance(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

// The bits of the half float nearest a value, from those of its float, for a
// buffer the renderer copies into a texture of half floats: f32tof16 would
// need 16-bit types the device may lack. Beyond the largest half it gives
// that, below the smallest one and for NaN zero, of its sign.
uint half_bits(float value) {
    uint sign = (asuint(value) >> 16u) & 0x8000u;
    if (value != value) return sign;
    uint bits = asuint(min(abs(value), 65504.0));
    int exponent = int(bits >> 23) - 112;
    if (exponent <= -10) return sign;
    if (exponent <= 0) {
        // A subnormal half: the mantissa with its leading one, shifted down.
        uint mantissa = (bits & 0x7FFFFFu) | 0x800000u;
        uint shift = uint(14 - exponent);
        return sign | ((mantissa >> shift) + ((mantissa >> (shift - 1u)) & 1u));
    }
    return sign | min(((uint(exponent) << 10) | ((bits >> 13) & 0x3FFu)) + ((bits >> 12) & 1u), 0x7BFFu);
}
uint2 half_bits(float4 value) {
    return uint2(half_bits(value.x) | (half_bits(value.y) << 16u), half_bits(value.z) | (half_bits(value.w) << 16u));
}
// The value of the bits of a half float, without 16-bit types.
float half_value(uint bits) {
    uint sign = (bits & 0x8000u) << 16u;
    uint exponent = (bits >> 10u) & 0x1Fu;
    uint mantissa = bits & 0x3FFu;
    if (exponent == 0u) return asfloat(sign | asuint(float(mantissa) * 5.9604645e-8));
    if (exponent == 31u) return asfloat(sign | 0x7F800000u | (mantissa << 13u));
    return asfloat(sign | ((exponent + 112u) << 23u) | (mantissa << 13u));
}
// Luma and two chroma axes, where a box around colors keeps their hue.
float3 to_ycocg(float3 c) { return float3(dot(c, float3(0.25, 0.5, 0.25)), dot(c, float3(0.5, 0.0, -0.5)), dot(c, float3(-0.25, 0.5, -0.25))); }
float3 from_ycocg(float3 c) { return float3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z); }

// Histories never recover from NaN/Inf, so values entering them are guarded.
float3 finite_or_zero(float3 v) { return (any(isnan(v)) || any(isinf(v))) ? float3(0.0) : v; }

// The irradiance atlases of the probe volume and the radiance of its rays
// hold the light raised to 1/PROBE_LIGHT_GAMMA, as RTXGI: in half floats, the
// light of a room hundreds of times dimmer than the strongest light of the
// scene (whose light scale it is) stays out of the denormals, where it faded.
#define PROBE_LIGHT_GAMMA 5.0
float3 probe_light_encode(float3 light) { return pow(max(light, float3(0.0)), float3(1.0 / PROBE_LIGHT_GAMMA)); }
float3 probe_light_decode(float3 stored) { return pow(max(stored, float3(0.0)), float3(PROBE_LIGHT_GAMMA)); }
// The square root of the irradiance a stored value stands for, which a read blends.
float3 probe_light_root(float3 stored) { return pow(max(stored, float3(0.0)), float3(0.5 * PROBE_LIGHT_GAMMA)); }

// Integer hash (PCG) and uniform random numbers in [0,1).
uint hash_u32(uint v) {
    uint state = v * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}
float random01(inout uint seed) {
    seed = hash_u32(seed);
    return float(seed >> 8) * (1.0 / 16777216.0);
}
uint seed_for(uint2 pixel, uint frame, uint salt) {
    return hash_u32(pixel.x * 1973u + pixel.y * 9277u + frame * 26699u + salt * 104729u);
}

// A point of the unit square for each frame that, over the frames, fills the
// square evenly: what a filter accumulates over time comes out far steadier
// than with independent random numbers. Every place starts the sequence at a
// point of its own. Neither step is close to a multiple of 1/4, so a pixel
// that takes its turn one frame in four still gets an even share.
float2 sequence_point(uint2 place, uint salt, uint frame) {
    uint start = hash_u32(place.x * 1973u + place.y * 9277u + salt * 104729u);
    float2 offset = float2(float(start >> 8), float(hash_u32(start) >> 8)) * (1.0 / 16777216.0);
    return frac(offset + float(frame & 4095u) * float2(0.6180339887, 0.4142135624));
}

void make_basis(float3 n, out float3 t, out float3 b) {
    // Duff et al. branchless orthonormal basis.
    float s = n.z >= 0.0 ? 1.0 : -1.0;
    float a = -1.0 / (s + n.z);
    float c = n.x * n.y * a;
    t = float3(1.0 + s * n.x * n.x * a, s * c, -s * n.x);
    b = float3(c, s + n.y * n.y * a, -n.y);
}

// Cosine-weighted hemisphere sample; the pdf cos/pi cancels a Lambert BRDF.
float3 sample_cosine(float3 n, float2 u) {
    float r = sqrt(u.x);
    float phi = 2.0 * PI * u.y;
    float3 t, b;
    make_basis(n, t, b);
    return normalize(t * (r * cos(phi)) + b * (r * sin(phi)) + n * sqrt(max(1.0 - u.x, 0.0)));
}

// Uniformly distributed directions on the sphere (spherical Fibonacci).
float3 spherical_fibonacci(float index, float count) {
    const float golden = 1.6180339887;
    float phi = 2.0 * PI * frac(index * (golden - 1.0));
    float cos_theta = 1.0 - (2.0 * index + 1.0) / count;
    float sin_theta = sqrt(clamp(1.0 - cos_theta * cos_theta, 0.0, 1.0));
    return float3(cos(phi) * sin_theta, sin(phi) * sin_theta, cos_theta);
}

#endif
