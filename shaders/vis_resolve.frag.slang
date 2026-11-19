#include "native.slang"
//! per surface program opaque
// The material of each pixel of the visibility target (visibility.slang),
// once: a draw of each Surface program covers the view at the depth its
// pixels were classified at (vis_resolve.vert, vis_classify.frag), so only
// they run it. The triangle a pixel shows is built again with the function of
// the raster (gbuffer_build.slang), its barycentrics at the pixel and at the
// next pixels along x and y give the inputs and their exact screen gradients,
// and the targets are those gbuffer_output.slang writes.
//
// A pixel of the quad that is not of this program (a helper) is given the
// triangle of a neighbor, at its own place, for the derivatives of the
// shading normal (specular antialiasing). A program that takes derivatives
// across the quad itself (mirai_program_derivatives: of its own uv, sampled
// by a plain uv, or ddx) gets them as the raster would: where the triangles
// of a quad do not continue one another (a silhouette, a seam of the uv) the
// quad evaluates again with the triangle of each of its pixels in all four.
// One that carries its derivatives (mirai_dual.slang), and the rows, which
// take the exact gradients of their uv, evaluate once.
//
// plain: without the reflectance target; layers: with the reflectance and the
// layers targets (as gbuffer.frag). nested: the pixels of a nested view.
//! variant plain MIRAI_GBUFFER_PLAIN=1
//! variant layers MIRAI_GBUFFER_LAYERS=1
//! constant nested MIRAI_NESTED_PIXELS
#ifndef MIRAI_GBUFFER_LAYERS
// Without the layers target no instance with layers is in sight.
#define MIRAI_MATERIAL_NO_LAYERS true
#endif
#define MIRAI_TEXTURE_FEEDBACK
#define MATERIAL_GRADIENTS
#define MIRAI_BATCHES
#include "gbuffer_output.slang"
#include "visibility.slang"

// The visible clusters (cull_bins.comp).
[[vk::binding(SLOT_PASS0, 0)]] StructuredBuffer<Visible_Cluster> visible : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<uint> visibility : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
#include "cull_stats.slang"
[[vk::binding(SLOT_PASS2, 0)]] RWStructuredBuffer<Stats_Block> resolve_stats : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);
#include <extension_vertex.slang>
#ifdef MIRAI_HOOK_VERTEX
// What the vertex hook moves the instance of each visible cluster by (cull_bins.comp).
[[vk::binding(SLOT_PASS4, 0)]] StructuredBuffer<float4> visible_moved : register(MIRAI_REGISTER(t, SLOT_PASS4), space0);
#endif
#include "gbuffer_build.slang"

// A corner of the triangle a pixel shows, as the raster placed it, with what
// it gives a point of the triangle.
struct Resolve_Corner {
    float4 position; // jittered clip
    float3 world;
    float3 before;   // in the world, in the frame before
    float3 normal;   // a unit, in the world
    float4 tangent;
    float2 uv, uv1;
    float4 color;    // of the vertex, with the colors of the instance
    uint2 surface;   // of a far mesh (Mesh_Point.surface)
};

Resolve_Corner resolve_corner(Instance inst, Mesh mesh, Cluster c, Cluster_Block b, Gbuffer_Cluster k, uint corner) {
    Gbuffer_Corner p = gbuffer_corner_place(inst, mesh, c, b, k, corner);
    Resolve_Corner r;
    r.position = view_clip(p.world);
    r.world = p.world;
    r.before = gbuffer_corner_world_previous(inst, mesh, c, b, k, p);
    r.normal = transform_normal(inst.world_inv, p.v.normal);
    r.tangent = instance_tangent(inst, p.v.tangent);
    r.uv = p.v.uv;
    r.uv1 = p.v.uv1;
    r.color = p.v.color;
    r.surface = p.v.surface;
    return r;
}

// A triangle as the raster placed it: its corners, and what they share.
struct Resolve_Triangle {
    Resolve_Corner a, b, c;
    float3 tint;     // of the base color: the instance's, and the color of the vertices where it tints the row
    bool tinted;
    float3 emission;
    uint surface;
    uint flags;
    uint material;
    uint instance;
};

Resolve_Triangle resolve_triangle(uint id) {
    uint e = visibility_entry(id);
    Visible_Cluster entry = visible[e];
    Instance inst = scene_instance(entry.instance);
    Mesh mesh = meshes[instance_mesh(inst)];
    Cluster cluster = cluster_at(entry.cluster);
    Cluster_Block block = visible_block(mesh, cluster, entry);
    Gbuffer_Cluster k = gbuffer_cluster_of(entry.instance, inst, mesh, entry.material, entry.along);
#ifdef MIRAI_HOOK_VERTEX
    if (instance_batched(entry.instance)) gbuffer_cluster_moved(k, visible_moved[e * 2u], visible_moved[e * 2u + 1u]);
#endif
    uint corner = visibility_triangle(id) * 3u;
    Resolve_Triangle t;
    t.a = resolve_corner(inst, mesh, cluster, block, k, corner);
    t.b = resolve_corner(inst, mesh, cluster, block, k, corner + 1u);
    t.c = resolve_corner(inst, mesh, cluster, block, k, corner + 2u);
    t.tint = inst.tint.rgb;
    t.tinted = k.tinted;
    // A far mesh: its emission joins that of the instance, and its roughness
    // and metallic replace those of its material, as its first corner says.
    t.emission = inst.emission.rgb + ((t.a.surface.x & MESH_SURFACE_SET) != 0u ? surface_emission(t.a.surface.y) : float3(0.0));
    t.surface = t.a.surface.x;
    t.flags = k.flags;
    t.material = k.material;
    t.instance = entry.instance;
    return t;
}

// The barycentrics of the point of a triangle a pixel center shows, from the
// clip positions of its corners as the raster had them: the weights whose sum
// of the corners projects to the pixel, which hold for corners behind the eye
// too (homogeneous rasterization, Olano and Greer 1997), and for a pixel off
// the triangle, along its plane.
float3 resolve_barycentrics(float4 a, float4 b, float4 c, float2 pixel) {
    float3 p = float3(pixel.x * frame.inv_resolution.x * 2.0 - 1.0, 1.0 - pixel.y * frame.inv_resolution.y * 2.0, 1.0);
    float3 ra = float3(a.x, a.y, a.w), rb = float3(b.x, b.y, b.w), rc = float3(c.x, c.y, c.w);
    float3 w = float3(dot(cross(rb, rc), p), dot(cross(rc, ra), p), dot(cross(ra, rb), p));
    float sum = w.x + w.y + w.z;
    return abs(sum) > 1e-30 ? w / sum : float3(1.0, 0.0, 0.0);
}

float2 resolve_mix(float2 a, float2 b, float2 c, float3 w) { return a * w.x + b * w.y + c * w.z; }
float3 resolve_mix(float3 a, float3 b, float3 c, float3 w) { return a * w.x + b * w.y + c * w.z; }
float4 resolve_mix(float4 a, float4 b, float4 c, float3 w) { return a * w.x + b * w.y + c * w.z; }

// A point of a triangle at a pixel, with the screen gradients of its inputs.
struct Resolve_Point {
    Raster_Input input;
    float4 uv_gradients;  // of uv0: xy along x, zw along y
    float4 uv1_gradients;
    float3 world_dx, world_dy;
    float3 normal_dx, normal_dy; // of the interpolated normal, normalized
};

Resolve_Point resolve_point(Resolve_Triangle t, float2 pixel) {
    float4 a = t.a.position, b = t.b.position, c = t.c.position;
    float3 w = resolve_barycentrics(a, b, c, pixel);
    float3 wx = resolve_barycentrics(a, b, c, pixel + float2(1.0, 0.0));
    float3 wy = resolve_barycentrics(a, b, c, pixel + float2(0.0, 1.0));
    Resolve_Point s;
    s.input.in_normal = resolve_mix(t.a.normal, t.b.normal, t.c.normal, w);
    s.input.in_vertex_color = resolve_mix(t.a.color, t.b.color, t.c.color, w);
    s.input.in_color = (t.tinted ? s.input.in_vertex_color.rgb : float3(1.0)) * t.tint;
    s.input.in_emission = t.emission;
    s.input.in_surface = t.surface;
    s.input.in_world = resolve_mix(t.a.world, t.b.world, t.c.world, w);
    // What is linear in the triangle is taken to the clip spaces once.
    s.input.in_clip = view_clip_unjittered(s.input.in_world);
    s.input.in_prev_clip = view_clip_previous(resolve_mix(t.a.before, t.b.before, t.c.before, w));
    s.input.in_flags = t.flags;
    s.input.in_uv = resolve_mix(t.a.uv, t.b.uv, t.c.uv, w);
    s.input.in_material = t.material;
    s.input.in_instance = t.instance;
    s.input.in_uv1 = resolve_mix(t.a.uv1, t.b.uv1, t.c.uv1, w);
    s.input.in_tangent = resolve_mix(t.a.tangent, t.b.tangent, t.c.tangent, w);
    // Counter-clockwise on the screen is the front, as the raster takes it;
    // the sign of the homogeneous determinant holds behind the eye too.
    float3 ra = float3(a.x, a.y, a.w), rb = float3(b.x, b.y, b.w), rc = float3(c.x, c.y, c.w);
    s.input = raster_facing(s.input, dot(ra, cross(rb, rc)) > 0.0);
    s.uv_gradients = float4(resolve_mix(t.a.uv, t.b.uv, t.c.uv, wx) - s.input.in_uv, resolve_mix(t.a.uv, t.b.uv, t.c.uv, wy) - s.input.in_uv);
    s.uv1_gradients = float4(resolve_mix(t.a.uv1, t.b.uv1, t.c.uv1, wx) - s.input.in_uv1, resolve_mix(t.a.uv1, t.b.uv1, t.c.uv1, wy) - s.input.in_uv1);
    s.world_dx = resolve_mix(t.a.world, t.b.world, t.c.world, wx) - s.input.in_world;
    s.world_dy = resolve_mix(t.a.world, t.b.world, t.c.world, wy) - s.input.in_world;
    float3 n = normalize(s.input.in_normal);
    s.normal_dx = normalize(resolve_mix(t.a.normal, t.b.normal, t.c.normal, wx)) - n;
    s.normal_dy = normalize(resolve_mix(t.a.normal, t.b.normal, t.c.normal, wy)) - n;
    return s;
}

// Whether the point a neighbor of the quad shows, `step` pixels along an
// axis, continues the surface of this one (of the same material): its place and uv are where the
// plane of this triangle puts them, but for what the bend of a smooth surface
// moves in a pixel. False across a silhouette or a seam of the uv.
bool resolve_continues(Resolve_Point s, float step, float3 world_d, float2 uv_d, float2 uv1_d, float3 world, float2 uv, float2 uv1) {
    float3 off_world = world - (s.input.in_world + world_d * step);
    float2 off_uv = uv - (s.input.in_uv + uv_d * step), off_uv1 = uv1 - (s.input.in_uv1 + uv1_d * step);
    return length(off_world) <= 0.5 * length(world_d) + 1e-6 * abs(fragment_depth(s.input))
        && length(off_uv) <= 0.5 * length(uv_d) + 1e-7 && length(off_uv1) <= 0.5 * length(uv1_d) + 1e-7;
}

// Counts what the resolve shades (Stats_Block.resolved): the pixels, and of
// each quad, by its first pixel that is not a helper, its helpers and whether
// it evaluates again; one atomic of each per wave.
void resolve_count(bool helper, uint2 odd, bool again) {
    uint live = helper ? 0u : 1u;
    uint lives = QuadReadLaneAt(live, 0u) | (QuadReadLaneAt(live, 1u) << 1u) | (QuadReadLaneAt(live, 2u) << 2u) | (QuadReadLaneAt(live, 3u) << 3u);
    if (helper) return;
    bool first = firstbitlow(lives) == odd.y * 2u + odd.x;
    uint3 counted = WaveActiveSum(uint3(1u, first ? 4u - countbits(lives) : 0u, first && again ? 1u : 0u));
    if (WaveIsFirstLane()) {
        InterlockedAdd(resolve_stats[0].resolved[0], counted.x);
        if (counted.y != 0u) InterlockedAdd(resolve_stats[0].resolved[1], counted.y);
        if (counted.z != 0u) InterlockedAdd(resolve_stats[0].resolved[2], counted.z);
    }
}

// The first nonzero value of the four pixels of a quad, the same in all four.
uint quad_first(uint value) {
    uint l0 = QuadReadLaneAt(value, 0u), l1 = QuadReadLaneAt(value, 1u), l2 = QuadReadLaneAt(value, 2u), l3 = QuadReadLaneAt(value, 3u);
    return l0 != 0u ? l0 : l1 != 0u ? l1 : l2 != 0u ? l2 : l3;
}

Stage_Output resolve_shade(Resolve_Point s, bool2 steady) {
    material_uv_gradients[0] = s.uv_gradients;
    material_uv_gradients[1] = s.uv1_gradients;
    material_world_gradients[0] = s.world_dx;
    material_world_gradients[1] = s.world_dy;
    material_normal_gradients[0] = s.normal_dx;
    material_normal_gradients[1] = s.normal_dy;
    material_steady = steady;
    Fragment f = fragment_evaluate(s.input);
    Stage_Output output = gbuffer_output(s.input, f);
    if (MIRAI_NESTED_PIXELS) output = gbuffer_output_nested(output);
    return output;
}

// The tests of the program depth run before the fragment: a pixel of
// another program fails them, and is a helper of its quad.
[shader("fragment")]
[earlydepthstencil]
Stage_Output main(float4 pixel : SV_Position) {
    // A helper is a pixel of the quad that is not of this program: it gives
    // the others its derivatives and writes nothing, nor reports what it samples.
    bool helper = IsHelperLane();
    uint own = helper ? 0u : visibility.Load(int3(int2(pixel.xy), 0));
    uint across_x = QuadReadAcrossX(own), across_y = QuadReadAcrossY(own), across_d = QuadReadAcrossDiagonal(own);
    uint id = own != 0u ? own : across_x != 0u ? across_x : across_y != 0u ? across_y : across_d;
    // No pixel of the quad shows a triangle of this program (the same in all
    // four): nothing is built, nor read through an id that names none.
    if (id == 0u) return (Stage_Output)0;
    Resolve_Point s = resolve_point(resolve_triangle(id), pixel.xy);

    // What each neighbor shows, against what this triangle says it shows.
    uint2 odd = uint2(pixel.xy) & 1u;
    float2 step = float2(odd.x == 0u ? 1.0 : -1.0, odd.y == 0u ? 1.0 : -1.0);
    float3 world = s.input.in_world;
    float2 uv = s.input.in_uv, uv1 = s.input.in_uv1;
    uint material = s.input.in_material;
    bool2 steady;
    steady.x = QuadReadAcrossX(material) == material && resolve_continues(s, step.x, s.world_dx, s.uv_gradients.xy, s.uv1_gradients.xy, QuadReadAcrossX(world), QuadReadAcrossX(uv), QuadReadAcrossX(uv1));
    steady.y = QuadReadAcrossY(material) == material && resolve_continues(s, step.y, s.world_dy, s.uv_gradients.zw, s.uv1_gradients.zw, QuadReadAcrossY(world), QuadReadAcrossY(uv), QuadReadAcrossY(uv1));
    uint broken = all(steady) ? 0u : 1u;
    broken |= QuadReadAcrossX(broken) | QuadReadAcrossY(broken) | QuadReadAcrossDiagonal(broken);

    bool again = broken != 0u && mirai_program_derivatives;
    resolve_count(helper, odd, again);
    // Once, or, where the quad evaluates again, once a triangle of its pixels,
    // each pixel keeping the round of its own: the material is inlined once.
    Stage_Output output = (Stage_Output)0;
    uint pending = own, built = id;
    texture_feedback_quiet = helper;
    for (uint round = 0u; round < 4u; round++) {
        uint leader = id;
        if (again) {
            leader = quad_first(pending);
            if (leader == 0u) break;
            texture_feedback_quiet = pending != leader;
            // A triangle already built is not built again.
            if (leader != built) {
                s = resolve_point(resolve_triangle(leader), pixel.xy);
                built = leader;
            }
            steady = bool2(true, true);
        }
        Stage_Output shaded = resolve_shade(s, steady);
        if (!again) return shaded;
        if (pending == leader) {
            output = shaded;
            pending = 0u;
        }
    }
    texture_feedback_quiet = false;
    return output;
}
