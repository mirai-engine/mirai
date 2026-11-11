#include "native.slang"
// The first pass of the cull of the clusters the maps of the shadows draw
// this frame (shadow_maps.slang, shadow_cull.slang): a thread for each
// instance, of the scene or of a batch, and each map. An instance that may
// cast a shadow into the frustum of the map hands the clusters the cut of the
// view can take of it (instance_clusters) to shadow_clusters.comp in chunks,
// as cull.comp hands those the view draws to cull_clusters.comp: what casts a
// shadow is what the view draws, at the detail its distance from the eye asks
// for. Chunks past the capacity of their list are counted, and it grows for
// the frames after.
#include "trace.slang"
#include "cut.slang"
#include "shadow_maps.slang"
#include "shadow_cull.slang"
#include "cull_stats.slang"
#define MIRAI_GROUP_X 256
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

[[vk::binding(SLOT_PASS0, 0)]] StructuredBuffer<uint4> shadow_data : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
// Up to CULL_CHUNK clusters of an instance for a map: the instance, the map, the first cluster and how many.
[[vk::binding(SLOT_PASS1, 0)]] RWStructuredBuffer<uint4> chunks : register(MIRAI_REGISTER(u, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] RWStructuredBuffer<uint> shadow_state : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);
[[vk::binding(SLOT_PASS3, 0)]] RWStructuredBuffer<Stats_Block> stats : register(MIRAI_REGISTER(u, SLOT_PASS3), space0);

// The surface of a body of a medium: an open sheet of a solid such as water,
// whose light the volume of the medium gives.
bool glass_sheet(Instance inst) {
    Mesh mesh = meshes[instance_mesh(inst)];
    return (mesh.flags & MESH_FLAG_CLOSED) == 0u && material_solid(material_row(material_of(inst, 0u), inst.material_values));
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    uint instance = id.x, map = id.y;
    if (instance >= params.instances || map >= params.maps) return;
    float reach = 0.0;
    if (instance_batched(instance)) {
        Instance row = batch_row(batch_of(instance));
        // The slots after the last instance of a batch fill its last group.
        if (instance - frame.instance_count - batch_first(row) >= batch_count(row)) return;
        if ((batch_classes(row) & RAY_SHADOWS) == 0u) return;
        reach = batch_reach(row);
    }
    Instance inst = scene_instance(instance);
    if ((inst.meta.w & INSTANCE_FLAG_HIDDEN) != 0u) return;
    // Glass casts no shadow: it takes its place only in the tint of the maps,
    // and not a glass sheet.
    if ((inst.meta.w & INSTANCE_FLAG_BLENDED) != 0u && (params.glass == 0u || glass_sheet(inst))) return;
    Shadow_Map m = shadow_map_at(shadow_data, params.rows, map);
    if (!shadow_map_reaches(m, inst.bounds_min.xyz - reach, inst.bounds_max.xyz + reach)) return;
    Mesh mesh = meshes[instance_mesh(inst)];
    if (mesh.vertex_count == 0u || mesh.cluster_count == 0u) return;
    uint2 clusters = instance_clusters(inst, mesh);
    uint count = (clusters.y + CULL_CHUNK - 1u) / CULL_CHUNK;
    uint base;
    InterlockedAdd(shadow_state[SHADOW_CHUNK_COUNT], count, base);
    uint kept = base >= params.chunk_capacity ? 0u : min(count, params.chunk_capacity - base);
    if (kept < count) InterlockedAdd(stats[0].dropped[CULL_LIST_SHADOW_CHUNKS], count - kept);
    for (uint k = 0u; k < kept; k++) {
        uint first = k * CULL_CHUNK;
        chunks[base + k] = uint4(instance, map, clusters.x + first, min(CULL_CHUNK, clusters.y - first));
    }
    if (kept > 0u) {
        uint total = base + kept;
        InterlockedMax(shadow_state[SHADOW_CLUSTER_DISPATCH], min(total, CULL_DISPATCH_X));
        InterlockedMax(shadow_state[SHADOW_CLUSTER_DISPATCH + 1u], (total + CULL_DISPATCH_X - 1u) / CULL_DISPATCH_X);
    }
}
