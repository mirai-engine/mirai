#include "native.slang"
// The clusters the maps of the shadows draw this frame (shadow_maps.slang): a
// thread for each instance and map lists the clusters of the instance that
// reach into the frustum of the map, for shadow_map.vert to draw.
#include "cut.slang"
#include "shadow_maps.slang"
#define MIRAI_GROUP_X 256
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

// instances: of the scene; maps: drawn this frame; rows: of the words of the lights.
struct Params_Block { uint instances; uint maps; uint rows; uint pad0; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] StructuredBuffer<uint4> shadow_data : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
// The clusters to draw: the instance, the cluster and the map.
[[vk::binding(SLOT_PASS1, 0)]] RWStructuredBuffer<uint4> entries : register(MIRAI_REGISTER(u, SLOT_PASS1), space0);
// The draw of them (Draw_Indirect), whose instances count them.
[[vk::binding(SLOT_PASS2, 0)]] RWStructuredBuffer<uint> draw : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);

// The clusters of a mesh a map takes: of its finest level.
uint2 cluster_range(Mesh mesh) {
    bool streamed = (mesh.flags & MESH_FLAG_STREAMED) != 0u;
    return streamed || mesh.level_count == 0u ? uint2(0u, mesh.cluster_count) : mesh_level_clusters(mesh, 0u);
}

// Whether a map takes cluster k of an instance: resident at the finest level
// and, where its box is known (at rest, or posed by the skin this frame),
// reaching into the frustum.
bool cluster_taken(Instance inst, Mesh mesh, uint k, bool streamed, bool posed, Shadow_Map m) {
    Cluster c = mesh_cluster(mesh, k);
    if (streamed && !cluster_finest_resident(mesh, c)) return false;
    float3 low, high;
    if (posed) {
        Posed_Bounds pose;
        if (!posed_bounds(mesh, k, pose)) return true;
        instance_world_box(inst, pose.low, pose.high, low, high);
    } else {
        cluster_world_box(inst, mesh, c, low, high);
    }
    return shadow_map_reaches(m, low, high);
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    uint instance = id.x, map = id.y;
    if (instance >= params.instances || map >= params.maps) return;
    Instance inst = scene_instance(instance);
    if ((inst.meta.w & (INSTANCE_FLAG_HIDDEN | INSTANCE_FLAG_BLENDED)) != 0u) return;
    Shadow_Map m = shadow_map_at(shadow_data, params.rows, map);
    if (!shadow_map_reaches(m, inst.bounds_min.xyz, inst.bounds_max.xyz)) return;
    Mesh mesh = meshes[instance_mesh(inst)];
    if (mesh.vertex_count == 0u || mesh.cluster_count == 0u) return;
    bool streamed = (mesh.flags & MESH_FLAG_STREAMED) != 0u;
    uint2 range = cluster_range(mesh);
    bool posed = mesh.posed_word != INVALID;
    uint taken = 0u;
    for (uint k = range.x; k < range.x + range.y; k++) {
        if (cluster_taken(inst, mesh, k, streamed, posed, m)) taken++;
    }
    if (taken == 0u) return;
    uint first;
    InterlockedAdd(draw[1], taken, first);
    for (uint k = range.x; k < range.x + range.y && first < SHADOW_ENTRIES; k++) {
        if (!cluster_taken(inst, mesh, k, streamed, posed, m)) continue;
        entries[first] = uint4(instance, k, map, 0u);
        first++;
    }
}
