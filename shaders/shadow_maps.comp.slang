#include "native.slang"
// The first pass of the cull of the clusters the maps of the shadows draw in
// a round (shadow_maps.slang, shadow_cull.slang): a thread for each instance,
// of the scene or of a batch, that may reach a map of the round, of the
// ranges the plan found for it (render.shadow_reach), where it draws the
// pages its mask names, at each mip of the map it draws pages of, over the
// slots the steps of the pages chose within the bound of the frame. The round
// of what stays draws into them the casters that do not move; that of what
// moves, those that do. An instance that may cast a shadow into the window, and
// covers a texel of its map, hands the clusters of the cut of the map that its levels can
// take (instance_clusters) to shadow_clusters.comp in chunks, as cull.comp
// hands those the view draws to cull_clusters.comp, at the detail of each
// mip, and foresees what each page it covers takes of them, which the steps of
// the pages bound before the cluster pass (shadow_pages.comp). Chunks past the
// capacity of their list are counted, and it grows for the frames after; no
// page of the round is drawn whole then, and they wait for those frames.
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

// What a round hands each page it draws that the texels of a box cover, in
// units (shadow_units): the texels of the part of the page drawn the box
// covers, and the vertices of the share of its clusters whose texels lie
// there, `vertices` each (SHADOW_WORDS_COST); and the chunks the instance
// hands over (SHADOW_WORDS_REACH). Of a batch that sways in the map, the
// pages of the atlas it shows in, where the cache does not hide its box
// (SHADOW_SWAY_NOW).
void shadow_foresee(Shadow_Map m, float4 texels, uint clusters, float vertices, bool masked, bool sways, float3 low, float3 high) {
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
            uint units = shadow_units(uint2(x, y), part, texels, CLUSTER_TRIANGLES, masked, 0.0, max(float(clusters) * share, 1.0) * vertices);
            // Far past any bound it counts no more, below the flags of the word.
            uint word = shadow_cost_word(pool);
            if (shadow_pages[word] < SHADOW_COST_UNITS / 2u) InterlockedAdd(shadow_pages[word], min(units, SHADOW_COST_UNITS / 2u));
            InterlockedAdd(shadow_pages[SHADOW_WORDS_REACH + params.moving * SHADOW_POOL_PAGES + pool], (clusters + CULL_CHUNK - 1u) / CULL_CHUNK);
            if (!sways || (shadow_pages[SHADOW_WORDS_SWAY + pool] & SHADOW_SWAY_NOW) != 0u) continue;
            if ((shadow_table_entry(m.rect.x, shadow_page_entry(m.rect, uint2(x, y))) & SHADOW_PAGE_CACHED) != 0u && shadow_box_hidden(hiz, m, uint2(x, y), pool, low, high)) continue;
            InterlockedOr(shadow_pages[SHADOW_WORDS_SWAY + pool], SHADOW_SWAY_NOW);
        }
    }
}

uint work_word(uint at) { return shadow_pages[params.list + at]; }

// The slot and the instance of a thread of the dispatch: the last slot the
// dispatch goes over whose threads start no later, and of the ranges of
// instances of its list that reach it (render.Shadow_Reach), the last that
// starts no later; false past them.
bool shadow_work_instance(uint thread, uint list, out uint slot, out uint instance) {
    slot = SHADOW_SLOTS;
    instance = 0u;
    uint count = work_word(0u);
    if (count == 0u) return false;
    uint low = 0u, high = count;
    while (high - low > 1u) {
        uint middle = (low + high) / 2u;
        if ((work_word(1u + middle) >> SHADOW_WORK_SHIFT) <= thread) low = middle; else high = middle;
    }
    uint entry = work_word(1u + low), local = thread - (entry >> SHADOW_WORK_SHIFT);
    slot = entry & ((1u << SHADOW_WORK_SHIFT) - 1u);
    if (slot >= SHADOW_SLOTS) return false;
    uint at = params.reach + slot * SHADOW_REACH_WORDS + list * 3u, first = shadow_word(shadow_data, at), ranges = shadow_word(shadow_data, at + 1u);
    if (ranges == 0u || local >= shadow_word(shadow_data, at + 2u)) return false;
    low = 0u;
    high = ranges;
    while (high - low > 1u) {
        uint middle = (low + high) / 2u;
        if (shadow_word(shadow_data, params.ranges + 2u * (first + middle) + 1u) <= local) low = middle; else high = middle;
    }
    uint range = params.ranges + 2u * (first + low);
    instance = shadow_word(shadow_data, range) + local - shadow_word(shadow_data, range + 1u);
    return true;
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    uint thread = id.y * SHADOW_CULL_ROW * MIRAI_GROUP_X + id.x, slot, instance;
    if (!shadow_work_instance(thread, params.moving, slot, instance)) return;
    uint map = slot;
    float reach = 0.0, cull = 0.0;
    if (instance_batched(instance)) {
        Instance row = batch_row(batch_of(instance));
        // The slots after the last instance of a batch fill its last group.
        if (instance - frame.instance_count - batch_first(row) >= batch_count(row)) return;
        if ((batch_classes(row) & RAY_SHADOWS) == 0u) return;
        reach = batch_reach(row);
        cull = batch_cull(row);
    }
    Instance inst = scene_instance(instance);
    if ((inst.meta.w & INSTANCE_FLAG_HIDDEN) != 0u || (inst.meta.x & INSTANCE_UNSHADOWED) != 0u) return;
    // Glass casts no shadow in the maps, nor colors their light.
    if ((inst.meta.w & INSTANCE_FLAG_BLENDED) != 0u) return;
    Shadow_Map whole = shadow_map_at(shadow_data, params.rows, map);
    float3 low = inst.bounds_min.xyz - reach, high = inst.bounds_max.xyz + reach;
    if (!shadow_map_reaches(whole, low, high)) return;
    // Past its cull distance, as the view leaves it out (render.shadow_culled).
    if (cull > 0.0 && length(params.cull.xyz - clamp(params.cull.xyz, low, high)) > cull + params.cull.w) return;
    Mesh mesh = meshes[instance_mesh(inst)];
    if (mesh.vertex_count == 0u || mesh.cluster_count == 0u) return;
    for (uint mip = 0u; mip < shadow_slot_mips(map); mip++) {
        Shadow_Map m = shadow_map_mip(whole, mip);
        float4 texels;
        if (shadow_map_unseen(m, low, high) || !shadow_box_texels(m, low, high, texels) || !shadow_pages_drawn(m, texels)) continue;
        // A batch of a deformable sways as far as its mesh says (render.batch_sway):
        // a map whose texel there is wider draws it at rest and keeps it, as what
        // stays; a finer one draws it as it is, and while it sways, as what moves.
        bool rest = false, sways = false;
        bool moves = instance_moves(instance);
        if (instance_batched(instance) && mesh.posed_word != INVALID) {
            float texel = shadow_map_texel(m, max(detail_span(shadow_map_detail(m), low, high).x, m.near));
            rest = !(mesh.sway * instance_scale(inst) > texel);
            moves = moves && !rest;
            sways = moves;
        }
        // A slot that let go of every page draws what stays too into the atlas, in the round of what moves.
    bool whole = params.moving == 1u && (shadow_data[(params.plan >> 2u) + map].x & SHADOW_PLAN_RESET) != 0u;
        if (!whole && moves != (params.moving != 0u)) continue;
        uint2 clusters = instance_clusters(shadow_map_detail(m), inst, mesh);
        if (params.foresee != 0u) {
            // The vertices of a cluster of its mesh on the average.
            float vertices = clamp(ceil(float(mesh.vertex_count) / float(mesh.cluster_count)), 3.0, float(CLUSTER_VERTICES));
            shadow_foresee(m, texels, clusters.y, vertices, inst.tested != 0u, sways && params.moving == 1u, low, high);
            continue;
        }
        uint count = (clusters.y + CULL_CHUNK - 1u) / CULL_CHUNK;
        uint base;
        InterlockedAdd(shadow_state[CULL_CHUNK_COUNT], count, base);
        uint kept = base >= params.chunk_capacity ? 0u : min(count, params.chunk_capacity - base);
        if (kept < count) {
            InterlockedAdd(stats[0].dropped[CULL_LIST_SHADOW_CHUNKS], count - kept);
            InterlockedAdd(shadow_pages[SHADOW_WORDS_COUNTS + SHADOW_COUNT_DROPPED + params.moving], count - kept);
        }
        uint what = map | mip << SHADOW_CHUNK_MIP | (rest ? SHADOW_CHUNK_REST : 0u);
        for (uint k = 0u; k < kept; k++) {
            uint first = k * CULL_CHUNK;
            chunks[base + k] = uint4(instance, what, clusters.x + first, min(CULL_CHUNK, clusters.y - first));
        }
        if (kept > 0u) {
            uint total = base + kept;
            InterlockedMax(shadow_state[CULL_CHUNK_DISPATCH], min(total, CULL_DISPATCH_X));
            InterlockedMax(shadow_state[CULL_CHUNK_DISPATCH + 1u], (total + CULL_DISPATCH_X - 1u) / CULL_DISPATCH_X);
        }
    }
}
