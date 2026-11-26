// The micro foliage a view draws, written in its Instances stage into the
// batch of each look (render.batch_reserve), before the cull of the scene,
// which draws them with its two phases of occlusion, depth buckets and
// visibility raster: a group of threads a tile the view sees
// (micro.odin keeps those it does not out), a thread an instance it holds.
// What is past the cull distance of its look, outside the frustum or thinned
// away by distance (micro_thin) goes before it is placed whole; the
// rest shrinks into the ground between the fade and the cull distances,
// grows from it at the edge of the thinning, widens where its neighbours
// thinned, and goes to the batch a wave at a time.
#include "foliage_micro.slang"
#include "batch_instance.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

[[vk::binding(SLOT_PASS0, 0)]] StructuredBuffer<Micro_Instance> micro_instances : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] StructuredBuffer<uint> micro_counts : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
// The u32 pool of the scene, where the batches are (render.pass_batch_target).
[[vk::binding(SLOT_PASS3, 0)]] RWStructuredBuffer<uint> pool : register(MIRAI_REGISTER(u, SLOT_PASS3), space0);
[[vk::binding(SLOT_PASS4, 0)]] StructuredBuffer<Micro_Slot> micro_slots : register(MIRAI_REGISTER(t, SLOT_PASS4), space0);
[[vk::binding(SLOT_PASS5, 0)]] StructuredBuffer<Micro_Look> micro_looks : register(MIRAI_REGISTER(t, SLOT_PASS5), space0);
// The slots of the tiles the view sees, a group of threads each along y.
[[vk::binding(SLOT_PASS6, 0)]] StructuredBuffer<uint> micro_seen : register(MIRAI_REGISTER(t, SLOT_PASS6), space0);
// Of the frame (foliage.MICRO_COUNTERS): instances given to a batch, those of
// them past its room, thinned away, and growing at the edge of the thinning.
[[vk::binding(SLOT_PASS7, 0)]] RWStructuredBuffer<uint> counters : register(MIRAI_REGISTER(u, SLOT_PASS7), space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID, uint3 group_id : SV_GroupID) {
    uint slot_index = micro_seen[group_id.y];
    Micro_Slot slot = micro_slots[slot_index];
    uint i = dispatch_id.x;
    if (slot.info.w == MICRO_NOT_GENERATED || i >= min(micro_counts[slot_index], slot.info.y)) return;
    Micro_Look look = micro_looks[slot.info.z];
    if (look.target.z == 0u) return;
    Micro_Instance inst = micro_instances[slot.info.x + i];
    float3 local = micro_local(inst, slot);
    float3 pivot = transform_point(slot.world, local);
    float distance = length(pivot - frame.camera_position.xyz);
    if (look.distance.y > 0.0 && distance >= look.distance.y) return;
    // A sphere about where it stands that holds it however it is turned,
    // widened and bent by the wind (a quarter of its size more).
    float largest = max(look.scale.y, look.scale.y * look.scale.w) * look.turn.w;
    float radius = ((length(look.sphere.xyz) + look.sphere.w) * largest * MICRO_THIN_WIDEN + max(abs(look.offset.x), abs(look.offset.y)) * look.turn.w) * 1.25;
    for (int k = 0; k < 6; k++) {
        float4 plane = frame.frustum[k];
        if (dot(plane.xyz, pivot) + plane.w < -radius) return;
    }
    Micro_Thin thin = micro_thin(distance, look.distance.z, micro_thin_unit(inst, slot));
    if (!(thin.grow > 0.0)) {
        InterlockedAdd(counters[2], 1u);
        return;
    }
    Micro_Place m = micro_place(inst, slot, look, local);
    // Far away it shrinks into the ground where it stands.
    float kept = look.distance.y > 0.0 ? saturate((look.distance.y - distance) / max(look.distance.y - look.distance.x, 1e-3)) : 1.0;
    float3 size = m.size * (kept * thin.grow) * float3(thin.widen, 1.0, thin.widen);
    if (!(size.y > 1e-3)) return;
    if (thin.grow < 1.0) InterlockedAdd(counters[3], 1u);
    uint lanes = WaveActiveCountBits(true), first = 0u;
    if (WaveIsFirstLane()) {
        InterlockedAdd(pool[look.target.y], lanes, first);
        InterlockedAdd(counters[0], lanes);
    }
    uint at = WaveReadLaneFirst(first) + WavePrefixCountBits(true);
    if (at >= look.target.z) {
        InterlockedAdd(counters[1], 1u);
        return;
    }
    batch_instance_write(pool, look.target.x + at * BATCH_WORDS, m.place - look.anchor.xyz, m.rotation, size);
}
