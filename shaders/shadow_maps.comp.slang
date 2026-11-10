#include "native.slang"
// The clusters the maps of the shadows draw this frame (shadow_maps.slang): a
// thread for each instance, of the scene or of a batch, and each map lists
// the clusters of the instance that reach into the frustum of the map, for
// shadow_map.vert to draw. They are those of the cut of the view
// (cluster_cut): what casts a shadow is what the view draws, at the detail
// its distance from the eye asks for. The clusters of an instance with masked
// or blended materials go apart, from the end of the list, to be drawn with
// their coverage.
#include "trace.slang"
#include "cut.slang"
#include "shadow_maps.slang"
#define MIRAI_GROUP_X 256
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

// instances: of the scene and of the batches drawn; maps: drawn this frame;
// rows: of the words of the lights.
struct Params_Block { uint instances; uint maps; uint rows; uint pad0; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] StructuredBuffer<uint4> shadow_data : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
// The clusters to draw: the instance, the cluster and the map.
[[vk::binding(SLOT_PASS1, 0)]] RWStructuredBuffer<uint4> entries : register(MIRAI_REGISTER(u, SLOT_PASS1), space0);
// The draws of them (two Draw_Indirect), whose instances count them: those
// that hide whole, then those whose materials say where.
[[vk::binding(SLOT_PASS2, 0)]] RWStructuredBuffer<uint> draw : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);

// Whether a map takes cluster k of an instance: in the cut of the view and,
// where its box is known (at rest, or posed by the skin this frame), reaching
// into the frustum.
bool cluster_taken(Instance inst, float scale, Mesh mesh, uint k, bool posed, Shadow_Map m) {
    Cluster c = mesh_cluster(mesh, k);
    if (!cluster_in_cut(inst, scale, mesh, c, frame.cut.x)) return false;
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
    float reach = 0.0;
    if (instance_batched(instance)) {
        Instance row = batch_row(batch_of(instance));
        // The slots after the last instance of a batch fill its last group.
        if (instance - frame.instance_count - batch_first(row) >= batch_count(row)) return;
        if ((batch_classes(row) & RAY_SHADOWS) == 0u) return;
        reach = batch_reach(row);
    }
    Instance inst = scene_instance(instance);
    if ((inst.meta.w & (INSTANCE_FLAG_HIDDEN | INSTANCE_FLAG_BLENDED)) != 0u) return;
    Shadow_Map m = shadow_map_at(shadow_data, params.rows, map);
    if (!shadow_map_reaches(m, inst.bounds_min.xyz - reach, inst.bounds_max.xyz + reach)) return;
    Mesh mesh = meshes[instance_mesh(inst)];
    if (mesh.vertex_count == 0u || mesh.cluster_count == 0u) return;
    float scale = instance_scale(inst);
    bool posed = mesh.posed_word != INVALID;
    uint taken = 0u;
    for (uint k = 0u; k < mesh.cluster_count; k++) {
        if (cluster_taken(inst, scale, mesh, k, posed, m)) taken++;
    }
    if (taken == 0u) return;
    bool tested = (inst.meta.w & INSTANCE_FLAG_ALPHA_TESTED) != 0u;
    uint first;
    InterlockedAdd(draw[tested ? 5u : 1u], taken, first);
    uint room = tested ? SHADOW_TESTED_ENTRIES : SHADOW_ENTRIES - SHADOW_TESTED_ENTRIES;
    for (uint k = 0u; k < mesh.cluster_count && first < room; k++) {
        if (!cluster_taken(inst, scale, mesh, k, posed, m)) continue;
        entries[tested ? SHADOW_ENTRIES - 1u - first : first] = uint4(instance, k, map, 0u);
        first++;
    }
}
