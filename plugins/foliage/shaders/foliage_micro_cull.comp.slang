// The micro foliage a view draws, in one phase after the scene: each
// instance its slot holds, within the distance of its look, whose sphere is
// in the frustum and not behind what the scene drew (the depth pyramid of
// this frame), goes to the list of its look, and the draw of its look counts
// it. The record zeroes the draws; the first threads give each its vertices.
#include "foliage_micro.slang"
#include "pyramid.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

struct Micro_Cull {
    uint4 count; // x: instances of the buffer, y: slots, z: looks, w: levels of the pyramid, 0 without one
};

[[vk::binding(SLOT_PASS0, 0)]] StructuredBuffer<Micro_Instance> micro_instances : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] StructuredBuffer<uint> micro_counts : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] RWStructuredBuffer<uint> micro_visible : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);
// Of each look: vertices, instances, first vertex, first instance.
[[vk::binding(SLOT_PASS3, 0)]] RWStructuredBuffer<uint> micro_draws : register(MIRAI_REGISTER(u, SLOT_PASS3), space0);
[[vk::binding(SLOT_PASS4, 0)]] StructuredBuffer<Micro_Slot> micro_slots : register(MIRAI_REGISTER(t, SLOT_PASS4), space0);
[[vk::binding(SLOT_PASS5, 0)]] StructuredBuffer<Micro_Look> micro_looks : register(MIRAI_REGISTER(t, SLOT_PASS5), space0);
[[vk::binding(SLOT_PASS6, 0)]] Texture2D<float4> pyramid : register(MIRAI_REGISTER(t, SLOT_PASS6), space0);
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Micro_Cull> cull : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    uint i = dispatch_id.x;
    if (i < cull.count.z) micro_draws[i * 4u] = micro_looks[i].mesh.y * CLUSTER_DRAW_VERTICES;
    if (i >= cull.count.x) return;
    Micro_Instance inst = micro_instances[i];
    if (inst.slot >= cull.count.y) return;
    Micro_Slot slot = micro_slots[inst.slot];
    // A place of the buffer no slot holds an instance at now.
    if (slot.info.w == MICRO_NOT_GENERATED || i < slot.info.x || i - slot.info.x >= min(micro_counts[inst.slot], slot.info.y)) return;
    if (slot.info.z >= cull.count.z) return;
    Micro_Look look = micro_looks[slot.info.z];
    Micro_Place m = micro_place(inst, slot, look);
    if (!(m.kept > 0.0)) return;
    float3 center = transform_point(m.world, look.sphere.xyz);
    // The wind bends it within a quarter of its size more.
    float radius = look.sphere.w * m.scale * 1.25;
    for (int k = 0; k < 6; k++) {
        float4 plane = frame.frustum[k];
        if (dot(plane.xyz, center) + plane.w < -radius) return;
    }
    if (cull.count.w > 0u && pyramid_hides(pyramid, cull.count.w, center - radius, center + radius, frame.view_proj_unjittered, frame.camera_position.xyz, frame.depth_plane)) return;
    uint at;
    InterlockedAdd(micro_draws[slot.info.z * 4u + 1u], 1u, at);
    if (at >= look.mesh.w) return;
    micro_visible[look.mesh.z + at] = i;
}
