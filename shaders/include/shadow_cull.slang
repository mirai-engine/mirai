// What the cull of the maps of the shadows (shadow_maps.comp by instance,
// shadow_clusters.comp by cluster) and the draws of their clusters
// (shadow_map.vert) share: their parameters, the words of
// render.Gpu_Shadow_State, and where in the list of the clusters the maps
// draw those of each draw lie.
#ifndef MIRAI_SHADOW_CULL_SLANG
#define MIRAI_SHADOW_CULL_SLANG
#include "cut.slang"
#include "shadow_maps.slang"
// instances: of the scene and of the batches drawn; maps: the slots, of
// which those the round culls for lie in the buffer of the pages from word
// `list`, and the pages it draws of each a bit for each entry of its table
// from word `masks` (SHADOW_MASK_WORDS a slot);
// rows: of the words of the lights in the buffer of the maps; chunk_capacity,
// entry_capacity: of the lists of the chunks and of the clusters
// (render.Cull_List); moving: 1 the round of the casters that move
// (render.shadow_maps_pass), 0 that of those that stay, whose pages span
// SHADOW_WORDS_BOUNDS for the round; movers:
// words of the bits of what moves, the instances of the scene then the
// batches drawn; listed: 1 while the round culls the `ranges` ranges of the
// movers after those words alone, `instances` in all (render.shadow_maps_plan);
// plan: the word of the buffer of the maps the plans of the slots start at;
// part: 1 while
// the round draws of each page the texels SHADOW_WORDS_PART names alone (the
// cache, of a page it held the part where what stays changed, or the band of
// a page drawn over frames); bound: the clusters the draws of the round take
// in a frame (render.SHADOW_FRAME_CLUSTERS); foresee: 1 while the pass by
// instance only foresees what each page takes, before the pages are granted.
struct Params_Block { uint instances; uint maps; uint rows; uint chunk_capacity; uint entry_capacity; uint list; uint moving; uint movers; uint listed; uint ranges; uint masks; uint plan; uint part; uint bound; uint foresee; uint pad0; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
// The draws: of the clusters that hide whole and of those of masked materials.
#define SHADOW_DRAW_OPAQUE 0u
#define SHADOW_DRAW_TESTED 1u
#define SHADOW_DRAW_COUNT 1u // the instances of draw d: word d * 4 + 1
#define SHADOW_CLUSTER_DISPATCH 8u
#define SHADOW_CHUNK_COUNT 11u
#define SHADOW_TAKEN 12u
// Of a chunk, over its map and the mip of it from bit SHADOW_CHUNK_MIP: its
// instance is drawn at rest (a batch that sways less than a texel of the map).
#define SHADOW_CHUNK_REST 0x20000000u
#define SHADOW_CHUNK_MAP 0xFFFFu
#define SHADOW_CHUNK_MIP 16u
// How many clusters of a draw the list holds: half for each.
uint shadow_room(uint draw) { return params.entry_capacity / 2u; }
// Where in the list the cluster `slot` of a draw lies.
uint shadow_entry(uint draw, uint slot) { return draw * (params.entry_capacity / 2u) + slot; }

uint shadow_word(StructuredBuffer<uint4> data, uint word) { return data[word >> 2u][word & 3u]; }

// The buffer of the pages of the view (render.Shadow_Raster.pages,
// shadow_pages.comp): the slots of a round and the pages it draws; the cull
// writes what it foresees and what found no room (SHADOW_WORDS_COST).
#ifdef SHADOW_PAGES_WRITTEN
[[vk::binding(SHADOW_PAGES_SLOT, 0)]] RWStructuredBuffer<uint> shadow_pages : register(MIRAI_REGISTER(u, SHADOW_PAGES_SLOT), space0);
#else
[[vk::binding(SHADOW_PAGES_SLOT, 0)]] StructuredBuffer<uint> shadow_pages : register(MIRAI_REGISTER(t, SHADOW_PAGES_SLOT), space0);
#endif

// The word of what the cache (moving 0) or the atlas (moving 1) draws into a
// page of the pool this frame (SHADOW_WORDS_COST).
uint shadow_cost_word(uint pool) { return SHADOW_WORDS_COST + params.moving * SHADOW_POOL_PAGES + pool; }
// And of the clusters its draws took of that page.
uint shadow_taken_word(uint pool) { return SHADOW_WORDS_TAKEN + params.moving * SHADOW_POOL_PAGES + pool; }

// Whether the round draws a page of a map at its mip, a bit for each entry.
bool shadow_page_drawn(Shadow_Map m, uint2 page) {
    uint bit = shadow_page_entry(m.rect, page);
    return shadow_place_valid(m.rect.x, bit) && ((shadow_pages[params.masks + m.rect.x * SHADOW_MASK_WORDS + (bit >> 5u)] >> (bit & 31u)) & 1u) != 0u;
}

// The page of the pool a page of a map lies at; false where it has none.
bool shadow_page_pool(Shadow_Map m, uint2 page, out uint pool) {
    uint e = shadow_table_entry(m.rect.x, shadow_page_entry(m.rect, page));
    return shadow_entry_pool(e, pool) && (e >> SHADOW_ENTRY_COARSER) == 0u;
}

// The texels of a page of the pool the round draws, from its corner: the
// first column and row, then one past the last (SHADOW_WORDS_PART); the whole
// page for a round that draws its pages whole.
uint4 shadow_page_part(uint pool) {
    if (params.part == 0u) return uint4(0u, 0u, SHADOW_PAGE, SHADOW_PAGE);
    if (pool >= SHADOW_POOL_PAGES) return uint4(SHADOW_PAGE, SHADOW_PAGE, 0u, 0u);
    uint at = SHADOW_WORDS_PART + pool * 4u;
    return uint4(SHADOW_PAGE - shadow_pages[at], SHADOW_PAGE - shadow_pages[at + 1u], shadow_pages[at + 2u], shadow_pages[at + 3u]);
}

// Whether those are all the texels of the page.
bool shadow_part_whole(uint4 part) { return all(part == uint4(0u, 0u, SHADOW_PAGE, SHADOW_PAGE)); }

// Whether the round draws texels of a page of a map among those a box covers
// (shadow_box_texels): its page, and of a page drawn in part, that part.
bool shadow_page_drawn(Shadow_Map m, uint2 page, float4 texels) {
    if (!shadow_page_drawn(m, page)) return false;
    if (params.part == 0u) return true;
    uint pool;
    if (!shadow_page_pool(m, page, pool)) return false;
    uint4 part = shadow_page_part(pool);
    float4 at = texels - float4(page * SHADOW_PAGE, page * SHADOW_PAGE);
    return at.x < float(part.z) && at.y < float(part.w) && at.z >= float(part.x) && at.w >= float(part.y);
}

// A page of a map as a word: the map, its column, its row and its mip (render.shadow_page_word).
uint shadow_page_word(uint map, uint mip, uint2 page) { return map | page.x << 8u | page.y << 15u | mip << 22u; }
uint shadow_page_map(uint word) { return word & 0xFFu; }
uint shadow_page_mip(uint word) { return (word >> 22u) & 7u; }
uint2 shadow_page_of(uint word) { return uint2((word >> 8u) & 0x7Fu, (word >> 15u) & 0x7Fu); }

// The mips of the maps of a slot: a level of the sun has its finest alone.
uint shadow_slot_mips(uint slot) { return slot < SHADOW_SUN_MAPS ? 1u : SHADOW_MIPS; }

// Its window of the square of its map, texels: x0, y0, x1, y1.
uint4 shadow_page_window(Shadow_Map m, uint2 page) {
    return uint4(page * SHADOW_PAGE, min((page + 1u) * SHADOW_PAGE, uint2(m.rect.z, m.rect.z)));
}

// The pages of a map at its mip the round draws lie within: false where it draws none there.
bool shadow_pages_span(Shadow_Map m, out uint4 span) {
    span = uint4(0u);
    if (m.rect.x >= SHADOW_SLOTS || shadow_rect_mip(m.rect) >= SHADOW_MIPS) return false;
    uint at = SHADOW_WORDS_BOUNDS + ((params.moving * SHADOW_SLOTS + m.rect.x) * SHADOW_MIPS + shadow_rect_mip(m.rect)) * 4u;
    uint4 words = uint4(shadow_pages[at], shadow_pages[at + 1u], shadow_pages[at + 2u], shadow_pages[at + 3u]);
    span = uint4(SHADOW_MAP_PAGES - words.x, SHADOW_MAP_PAGES - words.y, words.z - 1u, words.w - 1u);
    return words.x != 0u;
}

// Whether a round draws texels of a map at its mip among those a box covers
// (shadow_box_texels).
bool shadow_pages_drawn(Shadow_Map m, float4 texels) {
    uint4 span, rect = shadow_texel_pages(m, texels);
    if (!shadow_pages_span(m, span)) return false;
    rect = uint4(max(rect.xy, span.xy), min(rect.zw, span.zw));
    if (any(rect.xy > rect.zw)) return false;
    for (uint y = rect.y; y <= rect.w; y++) {
        for (uint x = rect.x; x <= rect.z; x++) {
            if (shadow_page_drawn(m, uint2(x, y), texels)) return true;
        }
    }
    return false;
}

// A window of a map as a map of its own, for what reaches it.
Shadow_Map shadow_map_window(Shadow_Map m, uint4 window) {
    float side = float(max(m.rect.z, 1u));
    float4 span = m.span;
    float2 size = span.zw - span.xy;
    m.span = float4(span.x + size.x * float(window.x) / side, span.y + size.y * (1.0 - float(window.w) / side),
                    span.x + size.x * float(window.z) / side, span.y + size.y * (1.0 - float(window.y) / side));
    return m;
}

// Where a map chooses the detail of what it draws from: its light, a pixel
// being a texel of the map where the cluster lies, so that what it holds does
// not depend on the eye and stays valid while the casters stay.
Detail shadow_map_detail(Shadow_Map m) {
    Detail d;
    float across = (m.span.z - m.span.x) / float(max(m.rect.z, 1u));
    bool orthographic = shadow_map_orthographic(m);
    d.eye = float4(m.origin, orthographic ? 0.0 : m.near);
    d.footprint = orthographic ? float2(across, 0.0) : float2(0.0, across);
    d.axis = m.forward;
    return d;
}

// Whether a box is too small to cover the middle of a texel of a map from
// the nearest it lies: what it hides the map cannot hold.
bool shadow_map_unseen(Shadow_Map m, float3 low, float3 high) {
    float2 span = detail_span(shadow_map_detail(m), low, high);
    return length(high - low) < shadow_map_texel(m, max(span.x, m.near));
}
#endif
