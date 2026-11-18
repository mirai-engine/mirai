#include "native.slang"
// The first pass of the cull of the clusters the maps of the shadows draw in
// a round (shadow_maps.slang, shadow_cull.slang): a thread for each instance,
// of the scene or of a batch, and each map of the round, where it draws the
// pages its mask names, at each mip of the map it draws pages of. The round
// of what stays draws into them the casters that do not move; that of what
// moves, those that do. An instance that may cast a shadow into the window, and
// covers a texel of its map, hands the clusters of the cut of the map that its levels can
// take (instance_clusters) to shadow_clusters.comp in chunks, as cull.comp
// hands those the view draws to cull_clusters.comp, at the detail of each
// mip, and foresees what each page it covers takes of them, which the steps of
// the pages bound before the cluster pass (shadow_pages.comp). Chunks past the
// capacity of their list are counted, and it grows for the frames after; the
// pages they would draw into are not drawn whole, and wait for those frames.
#include "trace.slang"
#include "cut.slang"
#include "shadow_maps.slang"
#define SHADOW_PAGES_SLOT SLOT_PASS6
#define SHADOW_PAGES_WRITTEN
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
// The farthest depth the cache holds over the blocks of each page of the pool (shadow_hiz.comp).
[[vk::binding(SLOT_PASS7, 0)]] Texture2D<float4> hiz : register(MIRAI_REGISTER(t, SLOT_PASS7), space0);
#include "shadow_hidden.slang"

bool instance_moves(uint instance) {
    uint bit = instance_batched(instance) ? frame.instance_count + batch_of(instance) : instance;
    uint word = bit >> 5u;
    return word < params.movers && (movers[word] & (1u << (bit & 31u))) != 0u;
}

// What a round hands each page it draws that the texels of a box cover: of
// the clusters of the box, the share of its texels that lie in the part of
// the page drawn, at least one (SHADOW_WORDS_COST).
void shadow_foresee(Shadow_Map m, float4 texels, uint clusters) {
    uint4 span, rect = shadow_texel_pages(m, texels);
    if (!shadow_pages_span(m, span)) return;
    rect = uint4(max(rect.xy, span.xy), min(rect.zw, span.zw));
    float2 size = max(texels.zw - texels.xy, float2(1.0, 1.0));
    for (uint y = rect.y; y <= rect.w; y++) {
        for (uint x = rect.x; x <= rect.z; x++) {
            uint pool;
            if (!shadow_page_drawn(m, uint2(x, y), texels) || !shadow_page_pool(m, uint2(x, y), pool)) continue;
            uint4 part = shadow_page_part(pool);
            float2 corner = float2(uint2(x, y) * SHADOW_PAGE);
            float2 within = min(texels.zw, corner + float2(part.zw)) - max(texels.xy, corner + float2(part.xy));
            float share = saturate(max(within.x, 1.0) * max(within.y, 1.0) / (size.x * size.y));
            // Far past any bound it counts no more, below the flags of the word.
            uint word = shadow_cost_word(pool);
            if (shadow_pages[word] < SHADOW_COST_CLUSTERS / 2u) InterlockedAdd(shadow_pages[word], min(max(uint(ceil(float(clusters) * share)), 1u), SHADOW_COST_CLUSTERS / 2u));
        }
    }
}

// The pages of the round that the texels of a box cover are not drawn whole
// this frame (SHADOW_COST_OVER): a chunk of the clusters of the box found no
// room in its list.
void shadow_left_over(Shadow_Map m, float4 texels) {
    uint4 span, rect = shadow_texel_pages(m, texels);
    if (!shadow_pages_span(m, span)) return;
    rect = uint4(max(rect.xy, span.xy), min(rect.zw, span.zw));
    for (uint y = rect.y; y <= rect.w; y++) {
        for (uint x = rect.x; x <= rect.z; x++) {
            uint pool;
            if (!shadow_page_drawn(m, uint2(x, y), texels) || !shadow_page_pool(m, uint2(x, y), pool)) continue;
            uint word = shadow_cost_word(pool);
            if ((shadow_pages[word] & SHADOW_COST_OVER) == 0u) InterlockedOr(shadow_pages[word], SHADOW_COST_OVER);
        }
    }
}

// Marks the pages of map m that the box of an instance that swayed covers,
// where what moves changed (SHADOW_WORDS_MOVED), but where the cache holds
// the page and hides the box there.
void shadow_sway_mark(Shadow_Map m, float4 texels, float3 low, float3 high) {
    uint4 rect = shadow_texel_pages(m, texels);
    for (uint y = rect.y; y <= rect.w; y++) {
        for (uint x = rect.x; x <= rect.z; x++) {
            uint entry = shadow_page_entry(m.rect, uint2(x, y)), slot = m.rect.x, pool;
            if (!shadow_place_valid(slot, entry)) continue;
            uint e = shadow_table_entry(slot, entry);
            if ((e & SHADOW_PAGE_CACHED) != 0u && shadow_entry_pool(e, pool) && shadow_box_hidden(hiz, m, uint2(x, y), pool, low, high)) continue;
            uint word = SHADOW_WORDS_MOVED + slot * SHADOW_MASK_WORDS + (entry >> 5u), bit = 1u << (entry & 31u);
            if ((shadow_pages[word] & bit) == 0u) InterlockedOr(shadow_pages[word], bit);
        }
    }
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    uint instance = id.x, job = id.y;
    if (instance >= params.instances || job >= params.maps) return;
    bool sway = params.foresee == SHADOW_CULL_SWAY;
    uint map = sway ? shadow_word(shadow_data, params.list + job) : shadow_pages[params.list + job];
    if (map >= SHADOW_SLOTS) return;
    if (params.listed != 0u) {
        // The range of the thread: the last whose first thread is not past it.
        uint low = 0u, high = params.ranges;
        uint ranges = params.movers + 2u * params.range_first;
        while (high - low > 1u) {
            uint middle = (low + high) / 2u;
            if (movers[ranges + 2u * middle + 1u] <= instance) low = middle; else high = middle;
        }
        instance = movers[ranges + 2u * low] + instance - movers[ranges + 2u * low + 1u];
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
    // Glass casts no shadow in the maps, nor colors their light.
    if ((inst.meta.w & INSTANCE_FLAG_BLENDED) != 0u) return;
    Shadow_Map whole = shadow_map_at(shadow_data, params.rows, map);
    float3 low = inst.bounds_min.xyz - reach, high = inst.bounds_max.xyz + reach;
    if (!shadow_map_reaches(whole, low, high)) return;
    Mesh mesh = meshes[instance_mesh(inst)];
    if (mesh.vertex_count == 0u || mesh.cluster_count == 0u) return;
    for (uint mip = 0u; mip < shadow_slot_mips(map); mip++) {
        Shadow_Map m = shadow_map_mip(whole, mip);
        float4 texels;
        if (shadow_map_unseen(m, low, high) || !shadow_box_texels(m, low, high, texels) || (!sway && !shadow_pages_drawn(m, texels))) continue;
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
        if (sway) {
            if (!rest) shadow_sway_mark(m, texels, low, high);
            continue;
        }
        // A slot that let go of every page draws what stays too into the atlas, in the round of what moves.
    bool whole = params.moving == 1u && (shadow_data[(params.plan >> 2u) + map].x & SHADOW_PLAN_RESET) != 0u;
        if (!whole && moves != (params.moving != 0u)) continue;
        uint2 clusters = instance_clusters(shadow_map_detail(m), inst, mesh);
        if (params.foresee != 0u) {
            shadow_foresee(m, texels, clusters.y);
            continue;
        }
        uint count = (clusters.y + CULL_CHUNK - 1u) / CULL_CHUNK;
        uint base;
        InterlockedAdd(shadow_state[SHADOW_CHUNK_COUNT], count, base);
        uint kept = base >= params.chunk_capacity ? 0u : min(count, params.chunk_capacity - base);
        if (kept < count) {
            InterlockedAdd(stats[0].dropped[CULL_LIST_SHADOW_CHUNKS], count - kept);
            shadow_left_over(m, texels);
        }
        uint what = map | mip << SHADOW_CHUNK_MIP | (rest ? SHADOW_CHUNK_REST : 0u);
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
}
