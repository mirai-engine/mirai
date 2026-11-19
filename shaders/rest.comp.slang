#include "native.slang"
// Where the vertex hook moved the point of each pixel of the view from where
// it rests (the rest target of gbuffer.slang), after the resolve, while a
// batch gives the hook values: the triangle of a pixel of a batch is built
// again with the function of the raster (gbuffer_build.slang), with what the
// cull computed of the hook (cull_bins.comp) and without it, and taken at the
// barycentrics of the pixel center. Every other pixel moved nothing.
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1
#define MIRAI_BATCHES
#define GBUFFER_REST_OUT SLOT_PASS3
#include "gbuffer.slang"
#include "visibility.slang"

// The visible clusters (cull_bins.comp).
[[vk::binding(SLOT_PASS0, 0)]] StructuredBuffer<Visible_Cluster> visible : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<uint> visibility : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS2), space0);
#include <extension_vertex.slang>
#ifdef MIRAI_HOOK_VERTEX
[[vk::binding(SLOT_PASS4, 0)]] StructuredBuffer<float4> visible_moved : register(MIRAI_REGISTER(t, SLOT_PASS4), space0);
#endif
#include "gbuffer_build.slang"

// The weights of the corners of a triangle at a pixel center, from their clip
// positions (as resolve_barycentrics of vis_resolve.frag).
float3 rest_barycentrics(float4 a, float4 b, float4 c, float2 pixel) {
    float3 p = float3(pixel.x * frame.inv_resolution.x * 2.0 - 1.0, 1.0 - pixel.y * frame.inv_resolution.y * 2.0, 1.0);
    float3 ra = float3(a.x, a.y, a.w), rb = float3(b.x, b.y, b.w), rc = float3(c.x, c.y, c.w);
    float3 w = float3(dot(cross(rb, rc), p), dot(cross(rc, ra), p), dot(cross(ra, rb), p));
    float sum = w.x + w.y + w.z;
    return abs(sum) > 1e-30 ? w / sum : float3(1.0, 0.0, 0.0);
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    int2 p = int2(id.xy);
    if (any(p >= int2(frame.resolution))) return;
    float depth = g_depth.Load(int3(p, 0)).r;
    float3 moved = float3(0.0);
    uint own = visibility.Load(int3(p, 0));
    if (own != 0u) {
        uint e = visibility_entry(own);
        Visible_Cluster entry = visible[e];
        if (instance_batched(entry.instance)) {
            Instance inst = scene_instance(entry.instance);
            Mesh mesh = meshes[instance_mesh(inst)];
            Cluster cluster = cluster_at(entry.cluster);
            Cluster_Block block = visible_block(mesh, cluster, entry);
            Gbuffer_Cluster k = gbuffer_cluster_of(entry.instance, inst, mesh, entry.material, entry.along);
#ifdef MIRAI_HOOK_VERTEX
            k.moved = visible_moved[e * 2u];
#endif
            uint corner = visibility_triangle(own) * 3u;
            Gbuffer_Corner a = gbuffer_corner_place(inst, mesh, cluster, block, k, corner);
            Gbuffer_Corner b = gbuffer_corner_place(inst, mesh, cluster, block, k, corner + 1u);
            Gbuffer_Corner c = gbuffer_corner_place(inst, mesh, cluster, block, k, corner + 2u);
            float3 w = rest_barycentrics(view_clip(a.world), view_clip(b.world), view_clip(c.world), float2(p) + 0.5);
            moved = (a.world - a.rest) * w.x + (b.world - b.rest) * w.y + (c.world - c.rest) * w.z;
        }
    }
    gbuffer_rest_write(p, moved, depth);
}
