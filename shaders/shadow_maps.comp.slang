#include "native.slang"
// The first pass of the cull of the clusters the maps of the shadows draw in
// a round (shadow_maps.slang, shadow_cull.slang): a thread for each instance,
// of the scene or of a batch, and each map of the round, where it draws the
// pages its mask names. The round of what stays draws into them the casters
// that do not move; that of what moves, those that do, and the glass of the
// tint. An instance that may cast a shadow into the window, and
// covers a texel of its map, hands the clusters of the cut of the map that its levels can
// take (instance_clusters) to shadow_clusters.comp in chunks, as cull.comp
// hands those the view draws to cull_clusters.comp. Chunks past the capacity
// of their list are counted, and it grows for the frames after.
#include "trace.slang"
#include "cut.slang"
#include "shadow_maps.slang"
#include "shadow_cull.slang"
#include "cull_stats.slang"
#define MIRAI_GROUP_X 256
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

[[vk::binding(SLOT_PASS0, 0)]] StructuredBuffer<uint4> shadow_data : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
// Up to CULL_CHUNK clusters of an instance for a job: the instance, the job
// with what it draws there (SHADOW_CHUNK_*), the first cluster and how many.
[[vk::binding(SLOT_PASS1, 0)]] RWStructuredBuffer<uint4> chunks : register(MIRAI_REGISTER(u, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] RWStructuredBuffer<uint> shadow_state : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);
[[vk::binding(SLOT_PASS3, 0)]] RWStructuredBuffer<Stats_Block> stats : register(MIRAI_REGISTER(u, SLOT_PASS3), space0);
// A bit for each instance that moves, then the list of those a round of
// what moves culls (Params_Block.listed).
[[vk::binding(SLOT_PASS5, 0)]] StructuredBuffer<uint> movers : register(MIRAI_REGISTER(t, SLOT_PASS5), space0);

// The surface of a body of a medium: an open sheet of a solid such as water,
// whose light the volume of the medium gives.
bool glass_sheet(Instance inst) {
    Mesh mesh = meshes[instance_mesh(inst)];
    return (mesh.flags & MESH_FLAG_CLOSED) == 0u && material_solid(material_row(material_of(inst, 0u), inst.material_values));
}

bool instance_moves(uint instance) {
    uint bit = instance_batched(instance) ? frame.instance_count + batch_of(instance) : instance;
    uint word = bit >> 5u;
    return word < params.movers && (movers[word] & (1u << (bit & 31u))) != 0u;
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    uint instance = id.x, job = id.y;
    if (instance >= params.instances || job >= params.maps) return;
    uint map = shadow_word(shadow_data, params.list + job);
    if (params.listed != 0u) {
        // The range of the thread: the last whose first thread is not past it.
        uint low = 0u, high = params.ranges;
        while (high - low > 1u) {
            uint middle = (low + high) / 2u;
            if (movers[params.movers + 2u * middle + 1u] <= instance) low = middle; else high = middle;
        }
        instance = movers[params.movers + 2u * low] + instance - movers[params.movers + 2u * low + 1u];
    }
    float reach = 0.0;
    if (instance_batched(instance)) {
        Instance row = batch_row(batch_of(instance));
        // The slots after the last instance of a batch fill its last group.
        if (instance - frame.instance_count - batch_first(row) >= batch_count(row)) return;
        if ((batch_classes(row) & RAY_SHADOWS) == 0u) return;
        reach = batch_reach(row);
    }
    Instance inst = scene_instance(instance);
    if ((inst.meta.w & INSTANCE_FLAG_HIDDEN) != 0u || (inst.meta.x & INSTANCE_UNSHADOWED) != 0u) return;
    // Glass casts no shadow: it takes its place only in the tint of the maps,
    // and not a glass sheet nor one of a batch.
    bool all_glass = (inst.meta.w & INSTANCE_FLAG_BLENDED) != 0u;
    bool glass = params.moving == 2u && params.glass != 0u && (inst.meta.w & (INSTANCE_FLAG_TRANSLUCENT | INSTANCE_FLAG_BLENDED)) != 0u
        && !instance_batched(instance) && !(all_glass && glass_sheet(inst));
    if (all_glass && !glass) return;
    Shadow_Map m = shadow_map_at(shadow_data, params.rows, map);
    float3 low = inst.bounds_min.xyz - reach, high = inst.bounds_max.xyz + reach;
    uint4 pages;
    if (!shadow_map_reaches(m, low, high) || shadow_map_unseen(m, low, high) || !shadow_page_rect(m, low, high, pages)
        || !shadow_pages_drawn(shadow_data, map, pages)) return;
    Mesh mesh = meshes[instance_mesh(inst)];
    if (mesh.vertex_count == 0u || mesh.cluster_count == 0u) return;
    // A batch of a deformable sways as far as its mesh says (render.batch_sway):
    // a map whose texel there is wider draws it at rest and keeps it, as what
    // stays; a finer one draws it as it is, and while it sways, as what moves.
    bool rest = false;
    bool moves = instance_moves(instance);
    if (instance_batched(instance) && mesh.posed_word != INVALID) {
        float texel = shadow_map_texel(m, max(detail_span(shadow_map_detail(m), low, high).x, m.near));
        rest = !(mesh.sway * instance_scale(inst) > texel);
        moves = moves && !rest;
    }
    bool depth = !all_glass && params.moving != 2u && moves == (params.moving != 0u);
    if (!depth && !glass) return;
    uint2 clusters = instance_clusters(shadow_map_detail(m), inst, mesh);
    uint count = (clusters.y + CULL_CHUNK - 1u) / CULL_CHUNK;
    uint base;
    InterlockedAdd(shadow_state[SHADOW_CHUNK_COUNT], count, base);
    uint kept = base >= params.chunk_capacity ? 0u : min(count, params.chunk_capacity - base);
    if (kept < count) InterlockedAdd(stats[0].dropped[CULL_LIST_SHADOW_CHUNKS], count - kept);
    uint what = map | (depth ? SHADOW_CHUNK_DEPTH : 0u) | (glass ? SHADOW_CHUNK_GLASS : 0u) | (rest ? SHADOW_CHUNK_REST : 0u);
    for (uint k = 0u; k < kept; k++) {
        uint first = k * CULL_CHUNK;
        chunks[base + k] = uint4(instance, what, clusters.x + first, min(CULL_CHUNK, clusters.y - first));
    }
    if (kept > 0u) {
        uint total = base + kept;
        InterlockedMax(shadow_state[SHADOW_CLUSTER_DISPATCH], min(total, CULL_DISPATCH_X));
        InterlockedMax(shadow_state[SHADOW_CLUSTER_DISPATCH + 1u], (total + CULL_DISPATCH_X - 1u) / CULL_DISPATCH_X);
    }
}
