#include "native.slang"
// The second pass of the cull of the maps of the shadows (shadow_cull.slang):
// a group for each chunk shadow_maps.comp handed over, a thread for each of
// its clusters. A cluster in the cut of the view that reaches into the
// frustum of the map, where its box is known (at rest, or posed by the skin
// this frame), goes to the list shadow_map.vert draws, those of instances
// with masked or blended materials to the draw that takes their coverage.
// Clusters past the room of their draw are counted, and the list grows for
// the frames after.
#include "trace.slang"
#include "cut.slang"
#include "shadow_maps.slang"
#include "shadow_cull.slang"
#include "cull_stats.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

[[vk::binding(SLOT_PASS0, 0)]] StructuredBuffer<uint4> shadow_data : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] StructuredBuffer<uint4> chunks : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] RWStructuredBuffer<uint> shadow_state : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);
[[vk::binding(SLOT_PASS3, 0)]] RWStructuredBuffer<Stats_Block> stats : register(MIRAI_REGISTER(u, SLOT_PASS3), space0);
// The clusters to draw: the instance, the cluster and the map.
[[vk::binding(SLOT_PASS4, 0)]] RWStructuredBuffer<uint4> entries : register(MIRAI_REGISTER(u, SLOT_PASS4), space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 group : SV_GroupID, uint3 lane : SV_GroupThreadID) {
    uint chunk = group.y * CULL_DISPATCH_X + group.x;
    if (chunk >= min(shadow_state[SHADOW_CHUNK_COUNT], params.chunk_capacity)) return;
    uint4 work = chunks[chunk];
    if (lane.x >= work.w) return;
    uint instance = work.x, map = work.y, k = work.z + lane.x;
    Instance inst = scene_instance(instance);
    Mesh mesh = meshes[instance_mesh(inst)];
    Cluster c = mesh_cluster(mesh, k);
    if (!cluster_in_cut(inst, instance_scale(inst), mesh, c, frame.cut.x)) return;
    float3 low, high;
    if (mesh.posed_word == INVALID) {
        cluster_world_box(inst, mesh, c, low, high);
        if (!shadow_map_reaches(shadow_map_at(shadow_data, params.rows, map), low, high)) return;
    } else {
        Posed_Bounds pose;
        if (posed_bounds(mesh, k, pose)) {
            instance_world_box(inst, pose.low, pose.high, low, high);
            if (!shadow_map_reaches(shadow_map_at(shadow_data, params.rows, map), low, high)) return;
        }
    }
    bool tested = (inst.meta.w & (INSTANCE_FLAG_ALPHA_TESTED | INSTANCE_FLAG_BLENDED)) != 0u;
    uint slot;
    InterlockedAdd(shadow_state[SHADOW_DRAW_COUNT + (tested ? 4u : 0u)], 1u, slot);
    if (slot >= shadow_room(tested)) {
        InterlockedAdd(stats[0].dropped[CULL_LIST_SHADOW_ENTRIES], 1u);
        return;
    }
    entries[shadow_entry(tested, slot)] = uint4(instance, k, map, 0u);
}
