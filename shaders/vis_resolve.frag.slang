#include "native.slang"
//! atomics 64
// The material of each pixel of the visibility buffer (visibility.slang),
// once: the triangle its word names is built again with gbuffer.vert's own
// function, its barycentrics at the pixel and at the next pixels along x and
// y give the attributes and their screen gradients (no quad of the pass
// shares a triangle), and the targets are those gbuffer.frag writes. Drawn
// with a greater-or-equal depth test against the depth vis_depth.frag gave,
// so a nearer surface of a forward draw stays.
//! variant plain MIRAI_GBUFFER_PLAIN=1
//! variant layers MIRAI_GBUFFER_LAYERS=1
#ifndef MIRAI_GBUFFER_LAYERS
// Without the layers target no instance with layers is in sight.
#define MIRAI_MATERIAL_NO_LAYERS true
#endif
#define MIRAI_TEXTURE_FEEDBACK
#define MATERIAL_GRADIENTS
#define MIRAI_BATCHES
#define MIRAI_GBUFFER_DEPTH
#include "gbuffer_output.slang"
#include "visibility.slang"

[[vk::binding(SLOT_PASS0, 0)]] StructuredBuffer<uint2> visible : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] StructuredBuffer<uint64_t> visibility : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
#include <extension_vertex.slang>
#include "gbuffer_build.slang"

// The barycentrics of the point of a triangle that a pixel center shows,
// from the clip positions of its corners as the raster had them: the weights
// whose sum of the corners projects to the pixel, which hold for corners
// behind the eye too (homogeneous rasterization, Olano and Greer 1997).
float3 resolve_barycentrics(float4 a, float4 b, float4 c, float2 pixel) {
    float2 ndc = float2(pixel.x * frame.inv_resolution.x * 2.0 - 1.0, 1.0 - pixel.y * frame.inv_resolution.y * 2.0);
    float3 p = float3(ndc, 1.0);
    float3 ra = float3(a.x, a.y, a.w), rb = float3(b.x, b.y, b.w), rc = float3(c.x, c.y, c.w);
    // The rows of the inverse of the matrix whose columns are the corners, up to its determinant.
    float3 w = float3(dot(cross(rb, rc), p), dot(cross(rc, ra), p), dot(cross(ra, rb), p));
    float sum = w.x + w.y + w.z;
    return abs(sum) > 1e-20 ? w / sum : float3(1.0, 0.0, 0.0);
}

float2 resolve_mix(float2 a, float2 b, float2 c, float3 w) { return a * w.x + b * w.y + c * w.z; }
float3 resolve_mix(float3 a, float3 b, float3 c, float3 w) { return a * w.x + b * w.y + c * w.z; }
float4 resolve_mix(float4 a, float4 b, float4 c, float3 w) { return a * w.x + b * w.y + c * w.z; }

[shader("fragment")]
Stage_Output main(float4 pixel : SV_Position) {
    uint64_t word = visibility[visibility_pixel(uint2(pixel.xy))];
    if (word == 0ull) discard;
    uint entry = visibility_entry_of(word);
    uint2 listed = visible[visibility_visible(entry)];
    uint index = listed.x;
    Instance inst = scene_instance(index);
    Mesh mesh = meshes[instance_mesh(inst)];
    Cluster cluster = cluster_at(listed.y);
    uint corner = visibility_triangle(entry) * 3u;
    Gbuffer_Vertex a = gbuffer_vertex_build(index, inst, mesh, cluster, corner);
    Gbuffer_Vertex b = gbuffer_vertex_build(index, inst, mesh, cluster, corner + 1u);
    Gbuffer_Vertex c = gbuffer_vertex_build(index, inst, mesh, cluster, corner + 2u);
    float3 w = resolve_barycentrics(a.position, b.position, c.position, pixel.xy);
    float3 wx = resolve_barycentrics(a.position, b.position, c.position, pixel.xy + float2(1.0, 0.0));
    float3 wy = resolve_barycentrics(a.position, b.position, c.position, pixel.xy + float2(0.0, 1.0));

    Raster_Input input;
    input.in_normal = resolve_mix(a.out_normal, b.out_normal, c.out_normal, w);
    input.in_color = resolve_mix(a.out_color, b.out_color, c.out_color, w);
    input.in_emission = a.out_emission;
    input.in_clip = resolve_mix(a.out_clip, b.out_clip, c.out_clip, w);
    input.in_prev_clip = resolve_mix(a.out_prev_clip, b.out_prev_clip, c.out_prev_clip, w);
    input.in_world = resolve_mix(a.out_world, b.out_world, c.out_world, w);
    input.in_flags = a.out_flags;
    input.in_uv = resolve_mix(a.out_uv, b.out_uv, c.out_uv, w);
    input.in_material = a.out_material;
    input.in_instance = a.out_instance;
    input.in_uv1 = resolve_mix(a.out_uv1, b.out_uv1, c.out_uv1, w);
    input.in_tangent = resolve_mix(a.out_tangent, b.out_tangent, c.out_tangent, w);
    input.in_surface = a.out_surface;
    input.in_vertex_color = resolve_mix(a.out_vertex_color, b.out_vertex_color, c.out_vertex_color, w);

    float2 uv_x = resolve_mix(a.out_uv, b.out_uv, c.out_uv, wx), uv_y = resolve_mix(a.out_uv, b.out_uv, c.out_uv, wy);
    float2 uv1_x = resolve_mix(a.out_uv1, b.out_uv1, c.out_uv1, wx), uv1_y = resolve_mix(a.out_uv1, b.out_uv1, c.out_uv1, wy);
    material_uv_gradients[0] = float4(uv_x - input.in_uv, uv_y - input.in_uv);
    material_uv_gradients[1] = float4(uv1_x - input.in_uv1, uv1_y - input.in_uv1);
    material_world_gradients[0] = resolve_mix(a.out_world, b.out_world, c.out_world, wx) - input.in_world;
    material_world_gradients[1] = resolve_mix(a.out_world, b.out_world, c.out_world, wy) - input.in_world;
    float3 n = normalize(input.in_normal);
    material_normal_gradients[0] = normalize(resolve_mix(a.out_normal, b.out_normal, c.out_normal, wx)) - n;
    material_normal_gradients[1] = normalize(resolve_mix(a.out_normal, b.out_normal, c.out_normal, wy)) - n;

    // The raster tested what fades and the holes of a masked material: the
    // pixel shows this surface even where its alpha here would say otherwise.
    Fragment f = fragment_evaluate(input);
    Stage_Output output = gbuffer_output(input, f);
    output.depth = visibility_depth(word);
    return output;
}
