#include "native.slang"
// The draw of each decal of the scene (render/decals.odin), in its order, as
// rhi.Draw_Indexed_Indirect over the meshes drawn whole: the levels its cut
// can take (instance_clusters), whose vertices decal.vert takes or collapses
// one by one, or nothing where the view does not draw its instance (hidden,
// out of its layers, faded out, out of its frustum) or the depth pyramid of
// this frame hides its box. Its first instance is the entry, which decal.vert
// reads its instance and its slot from.
#include "cut.slang"
#include "pyramid.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

struct Params_Block { uint count; uint hiz_levels; uint occlusion; uint pad; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
// Of each entry, its instance and the slot of its mesh.
[[vk::binding(SLOT_PASS0, 0)]] StructuredBuffer<uint2> entries : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> hiz : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] RWStructuredBuffer<uint> draws : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);

bool decal_frustum(float3 low, float3 high) {
    for (int i = 0; i < 6; i++) {
        float4 plane = frame.frustum[i];
        if (dot(plane.xyz, lerp(low, high, step(float3(0.0), plane.xyz))) + plane.w < 0.0) return false;
    }
    float3 clipped = lerp(low, high, step(float3(0.0), frame.clip_plane.xyz));
    return dot(frame.clip_plane.xyz, clipped) + frame.clip_plane.w >= 0.0;
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    uint k = dispatch_id.x;
    if (k >= params.count) return;
    uint index = entries[k].x;
    Instance inst = scene_instance(index);
    Mesh mesh = meshes[instance_mesh(inst)];
    bool faded = max(view_body_fade(inst.meta.w), material_values_fade(inst.material_values)) >= 1.0;
    bool shown = (inst.meta.w & INSTANCE_FLAG_HIDDEN) == 0u && !faded && mesh.draw_first != INVALID
        && view_draws_layers(inst.meta.w >> INSTANCE_LAYERS_SHIFT, inst.meta.w)
        && decal_frustum(inst.bounds_min.xyz, inst.bounds_max.xyz)
        && !(params.occlusion != 0u && pyramid_hides(hiz, params.hiz_levels, inst.bounds_min.xyz, inst.bounds_max.xyz,
            frame.view_proj_unjittered, frame.camera_position.xyz, frame.depth_plane));
    uint2 clusters = shown ? instance_clusters(view_detail(), inst, mesh) : uint2(0u, 0u);
    uint at = k * 5u;
    draws[at] = clusters.y * CLUSTER_DRAW_VERTICES;
    draws[at + 1u] = 1u;
    draws[at + 2u] = shown ? mesh.draw_first + clusters.x * CLUSTER_DRAW_VERTICES : 0u;
    draws[at + 3u] = 0u;
    draws[at + 4u] = k;
}
