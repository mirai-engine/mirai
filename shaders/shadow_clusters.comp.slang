#include "native.slang"
// The second pass of the cull of the maps of the shadows (shadow_cull.slang):
// a group for each chunk shadow_maps.comp handed over, a thread for each of
// its clusters. A cluster in the cut of the map goes, once for each page the
// round draws that its box covers (at rest, or posed by the skin this frame),
// to the list shadow_map.vert draws: those of masked or blended
// materials to the draw that takes their coverage. The draws of a round take
// at most params.bound
// clusters a frame, and of a page at most what the steps of the pages granted
// it (SHADOW_WORDS_COST): a cluster past them, or past the room of its draw,
// is left out, its page is not drawn whole this frame (SHADOW_COST_OVER) and
// waits, and a list without room grows for the frames after.
#include "trace.slang"
#include "cut.slang"
#include "shadow_maps.slang"
#define SHADOW_PAGES_SLOT SLOT_PASS6
#define SHADOW_PAGES_WRITTEN
#include "shadow_cull.slang"
#include "cull_stats.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

[[vk::binding(SLOT_PASS0, 0)]] StructuredBuffer<uint4> shadow_data : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] StructuredBuffer<uint4> chunks : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] RWStructuredBuffer<uint> shadow_state : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);
[[vk::binding(SLOT_PASS3, 0)]] RWStructuredBuffer<Stats_Block> stats : register(MIRAI_REGISTER(u, SLOT_PASS3), space0);
// The clusters to draw: the instance, the cluster, the page (shadow_page_word),
// and 1 for one drawn at rest.
[[vk::binding(SLOT_PASS4, 0)]] RWStructuredBuffer<uint4> entries : register(MIRAI_REGISTER(u, SLOT_PASS4), space0);
// The farthest depth the cache holds over the blocks of each page of the pool (shadow_hiz.comp).
[[vk::binding(SLOT_PASS7, 0)]] Texture2D<float4> hiz : register(MIRAI_REGISTER(t, SLOT_PASS7), space0);
#include "shadow_hidden.slang"

// A cluster into a draw for the page of the pool `pool`; false where the
// frame has no room for it.
bool shadow_add(uint draw, uint4 entry, uint pool) {
    uint taken = 0u, slot = 0u, own;
    InterlockedAdd(shadow_pages[shadow_taken_word(pool)], 1u, own);
    bool room = own < (shadow_pages[shadow_cost_word(pool)] & SHADOW_COST_CLUSTERS);
    if (room) InterlockedAdd(shadow_state[SHADOW_TAKEN], 1u, taken);
    room = room && taken < params.bound;
    if (room) InterlockedAdd(shadow_state[draw * 4u + SHADOW_DRAW_COUNT], 1u, slot);
    if (room && slot < shadow_room(draw)) {
        entries[shadow_entry(draw, slot)] = entry;
        return true;
    }
    if (room) InterlockedAdd(stats[0].dropped[CULL_LIST_SHADOW_ENTRIES], 1u);
    InterlockedAdd(stats[0].shadow[9], 1u);
    InterlockedOr(shadow_pages[shadow_cost_word(pool)], SHADOW_COST_OVER);
    return false;
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 group : SV_GroupID, uint3 lane : SV_GroupThreadID) {
    uint chunk = group.y * CULL_DISPATCH_X + group.x;
    if (chunk >= min(shadow_state[SHADOW_CHUNK_COUNT], params.chunk_capacity)) return;
    uint4 work = chunks[chunk];
    if (lane.x >= work.w) return;
    uint instance = work.x, map = work.y & SHADOW_CHUNK_MAP, k = work.z + lane.x;
    Instance inst = scene_instance(instance);
    Mesh mesh = meshes[instance_mesh(inst)];
    Cluster c = mesh_cluster(mesh, k);
    Shadow_Map m = shadow_map_mip(shadow_map_at(shadow_data, params.rows, map), (work.y >> SHADOW_CHUNK_MIP) & 7u);
    if (!cluster_in_cut(shadow_map_detail(m), inst, instance_scale(inst), mesh, c, frame.cut.x)) return;
    float3 low, high;
    bool rest = (work.y & SHADOW_CHUNK_REST) != 0u;
    // The texels of its box; of a pose not known yet, those of its instance.
    float4 texels;
    if (mesh.posed_word == INVALID || rest) {
        cluster_world_box(inst, mesh, c, low, high);
    } else {
        Posed_Bounds pose;
        if (posed_bounds(mesh, k, pose)) instance_world_box(inst, pose.low, pose.high, low, high);
        else { low = inst.bounds_min.xyz; high = inst.bounds_max.xyz; }
    }
    if (!shadow_map_reaches(m, low, high) || !shadow_box_texels(m, low, high, texels)) return;
    uint4 span, pages = shadow_texel_pages(m, texels);
    if (!shadow_pages_span(m, span)) return;
    pages = uint4(max(pages.xy, span.xy), min(pages.zw, span.zw));
    bool tested = ((inst.tested >> cluster_slot(c)) & 1u) != 0u;
    for (uint y = pages.y; y <= pages.w; y++) {
        for (uint x = pages.x; x <= pages.z; x++) {
            if (!shadow_page_drawn(m, uint2(x, y), texels)) continue;
            // In the round of what moves, where the cache holds the page and hides the cluster there.
            uint held = shadow_table_entry(m.rect.x, shadow_page_entry(m.rect, uint2(x, y)));
            if (params.moving == 1u && (held & SHADOW_PAGE_CACHED) != 0u && shadow_box_hidden(hiz, m, uint2(x, y), (held & SHADOW_ENTRY_POOL) - 1u, low, high)) continue;
            uint page = shadow_page_word(map, shadow_rect_mip(m.rect), uint2(x, y)), pool = (held & SHADOW_ENTRY_POOL) - 1u;
            if (shadow_add(tested ? SHADOW_DRAW_TESTED : SHADOW_DRAW_OPAQUE, uint4(instance, k, page, rest ? 1u : 0u), pool)) {
                if (params.moving == 0u) {
                    InterlockedAdd(stats[0].shadow[tested ? 1u : 0u], 1u);
                    InterlockedAdd(stats[0].shadow[2], cluster_triangle_count(c));
                } else {
                    InterlockedAdd(stats[0].shadow[3], 1u);
                }
            }
        }
    }
}
