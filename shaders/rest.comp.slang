#include "native.slang"
// Where the vertex hook moved the point of each pixel of the view from where
// it rests (the rest target of gbuffer.slang), after the resolve, while a
// batch gives the hook values: the triangle of a pixel of a batch is built
// again with the function of the raster (gbuffer_build.slang), with what the
// cull computed of the hook (cull_bins.comp) and without it, and taken at the
// barycentrics of the pixel center. Every other pixel moved nothing, and is
// not written: the depth the target keeps tells it apart (pixel_rest).
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

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    int2 p = int2(id.xy);
    if (any(p >= int2(frame.resolution))) return;
    uint own = visibility.Load(int3(p, 0));
    if (own == 0u) return;
    uint e = visibility_entry(own);
    Visible_Cluster entry = visible[e];
    if (!instance_batched(entry.instance)) return;
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
    float3 w = visibility_barycentrics(visibility_edges(view_clip(a.world), view_clip(b.world), view_clip(c.world)), float2(p) + 0.5);
    float3 moved = (a.world - a.rest) * w.x + (b.world - b.rest) * w.y + (c.world - c.rest) * w.z;
    gbuffer_rest_write(p, moved, g_depth.Load(int3(p, 0)).r);
}
