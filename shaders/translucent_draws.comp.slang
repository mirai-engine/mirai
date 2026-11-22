#include "native.slang"
// The draw of each blended instance of a view, in the order the view draws
// them (render.translucent_draws_record), as rhi.Draw_Indexed_Indirect over
// the meshes drawn whole: the levels its cut can take (instance_clusters),
// whose vertices gbuffer.vert takes or collapses one by one, or nothing where
// the depth pyramid of this frame hides its box or its mesh is not listed.
#include "cut.slang"
#include "pyramid.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

struct Params_Block { uint count; uint hiz_levels; uint occlusion; uint pad; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] StructuredBuffer<uint> entries : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> hiz : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] RWStructuredBuffer<uint> draws : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    uint k = dispatch_id.x;
    if (k >= params.count) return;
    uint index = entries[k];
    Instance inst = scene_instance(index);
    Mesh mesh = meshes[instance_mesh(inst)];
    bool hidden = params.occlusion != 0u && pyramid_hides(hiz, params.hiz_levels, inst.bounds_min.xyz, inst.bounds_max.xyz,
        frame.view_proj_unjittered, frame.camera_position.xyz, frame.depth_plane);
    uint2 clusters = instance_clusters(view_detail(), inst, mesh);
    bool drawn = !hidden && mesh.draw_first != INVALID;
    uint at = k * 5u;
    draws[at] = drawn ? clusters.y * CLUSTER_DRAW_VERTICES : 0u;
    draws[at + 1u] = 1u;
    draws[at + 2u] = drawn ? mesh.draw_first + clusters.x * CLUSTER_DRAW_VERTICES : 0u;
    draws[at + 3u] = 0u;
    draws[at + 4u] = index;
}
