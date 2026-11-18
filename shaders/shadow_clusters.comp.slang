#include "native.slang"
// The second pass of the cull of the maps of the shadows (shadow_cull.slang):
// a group for each chunk shadow_maps.comp handed over, a thread for each of
// its clusters. A cluster in the cut of the map goes, once for each page the
// round draws that its box covers (at rest, or posed by the skin this frame),
// to the list the lists of the raster draw into the pages
// (raster_lists.slang): in the tested raster bin those of masked or blended
// materials, which their coverage decides, all of them two-sided. The draws
// of a round take at most params.bound units a frame (SHADOW_UNIT_TEXELS),
// and of a page at most what the steps of the pages granted it
// (SHADOW_WORDS_COST), each cluster what its box covers of the page, its
// triangles and its vertices: a cluster that begins past them, or past the
// room of the list, is left out, its page is not drawn whole this frame
// (SHADOW_COST_OVER) and waits, and a list without room grows for the frames
// after.
#include "trace.slang"
#include "cut.slang"
#include "shadow_maps.slang"
#include "visibility.slang"
#include "raster_lists.slang"
#define SHADOW_PAGES_SLOT SLOT_PASS6
#define SHADOW_PAGES_WRITTEN
#include "shadow_cull.slang"
#include "cull_stats.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

[[vk::binding(SLOT_PASS0, 0)]] StructuredBuffer<uint4> shadow_data : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] StructuredBuffer<uint4> chunks : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
// The state of the cull (render.Gpu_Cull_State): the chunks, the clusters
// listed, the units taken, and the entries the round of the raster takes.
[[vk::binding(SLOT_PASS2, 0)]] RWStructuredBuffer<uint> shadow_state : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);
[[vk::binding(SLOT_PASS3, 0)]] RWStructuredBuffer<Stats_Block> stats : register(MIRAI_REGISTER(u, SLOT_PASS3), space0);
// The clusters to draw (SHADOW_ENTRY_REST), and of each what the passes of
// the raster keep (abi.RASTER_ENTRY_WORDS): its raster bin.
[[vk::binding(SLOT_PASS4, 0)]] RWStructuredBuffer<Visible_Cluster> entries : register(MIRAI_REGISTER(u, SLOT_PASS4), space0);
[[vk::binding(SLOT_PASS5, 0)]] RWStructuredBuffer<uint> raster_entries : register(MIRAI_REGISTER(u, SLOT_PASS5), space0);
// The farthest depth the cache holds over the blocks of each page of the pool (shadow_hiz.comp).
[[vk::binding(SLOT_PASS7, 0)]] Texture2D<float4> hiz : register(MIRAI_REGISTER(t, SLOT_PASS7), space0);
#include "shadow_hidden.slang"

// A cluster that costs `units` into the raster bin `bin` for the page of the
// pool `pool`; false where the frame has no room for it.
bool shadow_add(uint bin, Visible_Cluster entry, uint pool, uint units) {
    uint taken = 0u, slot = 0u, own;
    if (pool >= SHADOW_POOL_PAGES) return false;
    // What its page takes counts whole, for the frames after; past the bound
    // of the frame it waits without counting into the frame.
    InterlockedAdd(shadow_pages[shadow_taken_word(pool)], units, own);
    bool room = own < (shadow_pages[shadow_cost_word(pool)] & SHADOW_COST_UNITS) && shadow_state[CULL_SHADOW_TAKEN] < params.bound;
    if (room) InterlockedAdd(shadow_state[CULL_SHADOW_TAKEN], units, taken);
    room = room && taken < params.bound;
    if (room) InterlockedAdd(shadow_state[CULL_LISTED], 1u, slot);
    if (room && slot < params.entry_capacity) {
        entries[slot] = entry;
        raster_entries[slot * RASTER_ENTRY_WORDS + RASTER_ENTRY_BIN] = cull_listed_word(bin, 0u);
        raster_entries[slot * RASTER_ENTRY_WORDS + RASTER_ENTRY_ROUND] = 0u;
        InterlockedMax(shadow_state[CULL_RASTER_PENDING + 1u], slot + 1u);
        return true;
    }
    if (room) InterlockedAdd(stats[0].dropped[CULL_LIST_SHADOW_ENTRIES], 1u);
    InterlockedAdd(stats[0].shadow[9], 1u);
    if ((shadow_pages[shadow_cost_word(pool)] & SHADOW_COST_OVER) == 0u) InterlockedOr(shadow_pages[shadow_cost_word(pool)], SHADOW_COST_OVER);
    return false;
}

// The texels of map m the area of the triangles of a cluster spans, by its
// instance (render.mesh_cluster_areas), at the depth of the middle of its box;
// 0 where its mesh does not say it.
float cluster_surface(Shadow_Map m, Instance inst, Mesh mesh, uint ordinal, float3 low, float3 high) {
    if (mesh.area_word == INVALID) return 0.0;
    float scale = instance_scale(inst);
    float texel = shadow_map_texel(m, max(shadow_map_local(m, 0.5 * (low + high)).z, m.near));
    return asfloat(indices[mesh.area_word + ordinal]) * scale * scale / max(texel * texel, 1e-12);
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 group : SV_GroupID, uint3 lane : SV_GroupThreadID) {
    uint chunk = group.y * CULL_DISPATCH_X + group.x;
    if (chunk >= min(shadow_state[CULL_CHUNK_COUNT], params.chunk_capacity)) return;
    uint4 work = chunks[chunk];
    if (lane.x >= work.w) return;
    uint instance = work.x, map = work.y & SHADOW_CHUNK_MAP, k = work.z + lane.x;
    if (map >= SHADOW_SLOTS) return;
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
    float surface = cluster_surface(m, inst, mesh, k, low, high);
    uint4 span, pages = shadow_texel_pages(m, texels);
    if (!shadow_pages_span(m, span)) return;
    pages = uint4(max(pages.xy, span.xy), min(pages.zw, span.zw));
    bool tested = ((inst.tested >> cluster_slot(c)) & 1u) != 0u;
    // What the raster reads of it for every page alike.
    Cluster_Block b = cluster_block(mesh, c);
    Visible_Cluster entry;
    entry.instance = instance;
    entry.cluster = mesh_cluster_word(mesh, k);
    entry.material = material_of(inst, cluster_material(mesh, c));
    entry.vertices = b.vertices;
    entry.triangles = b.triangles;
    entry.page = cluster_page_word(mesh, c);
    entry.along = cluster_along(shadow_map_detail(m), inst, instance_scale(inst), mesh, c, frame.cut.x);
    uint bin = RASTER_BIN_TWO_SIDED | (tested ? RASTER_BIN_TESTED : 0u);
    uint vertices = cluster_vertex_count(c), triangles = cluster_triangle_count(c);
    for (uint y = pages.y; y <= pages.w; y++) {
        for (uint x = pages.x; x <= pages.z; x++) {
            if (!shadow_page_drawn(m, uint2(x, y), texels)) continue;
            // In the round of what moves, where the cache holds the page and hides the cluster there.
            uint held = shadow_table_entry(m.rect.x, shadow_page_entry(m.rect, uint2(x, y)));
            if (params.moving == 1u && (held & SHADOW_PAGE_CACHED) != 0u && shadow_box_hidden(hiz, m, uint2(x, y), (held & SHADOW_ENTRY_POOL) - 1u, low, high)) continue;
            uint pool = (held & SHADOW_ENTRY_POOL) - 1u;
            entry.program = shadow_page_word(map, shadow_rect_mip(m.rect), uint2(x, y)) | (rest ? SHADOW_ENTRY_REST : 0u);
            uint units = shadow_units(uint2(x, y), shadow_page_part(pool), texels, triangles, tested, surface, float(vertices));
            if (shadow_add(bin, entry, pool, units)) {
                if (params.moving == 0u) {
                    InterlockedAdd(stats[0].shadow[tested ? 1u : 0u], 1u);
                } else {
                    InterlockedAdd(stats[0].shadow[3], 1u);
                }
                InterlockedAdd(stats[0].shadow[2], triangles);
                InterlockedAdd(stats[0].shadow[11u + params.moving], units);
            }
        }
    }
}
