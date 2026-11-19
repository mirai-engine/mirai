// What the cull of the maps of the shadows (shadow_maps.comp by instance,
// shadow_clusters.comp by cluster) and the raster of their clusters into the
// pages (raster_lists.slang, vis_raster.vert) share: their parameters, the
// words of the state of the cull (render.Gpu_Cull_State), and where a page
// of a map lies in the pool.
#ifndef MIRAI_SHADOW_CULL_SLANG
#define MIRAI_SHADOW_CULL_SLANG
#include "cut.slang"
#include "shadow_maps.slang"
// reach, ranges: the words of the buffer of the maps what the culls by
// instance of each slot go over and their ranges of instances start at
// (render.Shadow_Reach); list: the word the slots a cull by instance goes
// over start at, of the buffer of the pages (SHADOW_WORK_SHIFT); masks: the
// word the pages the
// round draws start at, a bit for each entry of the table of each slot
// (SHADOW_MASK_WORDS a slot);
// rows: of the words of the lights in the buffer of the maps; chunk_capacity,
// entry_capacity: of the lists of the chunks and of the clusters
// (render.Cull_List); moving: 1 the round of the casters that move
// (render.shadow_maps_pass), 0 that of those that stay, whose pages span
// SHADOW_WORDS_BOUNDS for the round; movers:
// words of the bits of what moves, the instances of the scene then the
// batches drawn;
// plan: the word of the buffer of the maps the plans of the slots start at;
// part: 1 while
// the round draws of each page the texels SHADOW_WORDS_PART names alone (the
// cache, of a page it held the part where what stays changed, or the band of
// a page drawn over frames); bound: the units the draws of the round take
// in a frame (render.SHADOW_FRAME_UNITS); foresee: 1 while the pass by
// instance only foresees what each page takes, before the pages are granted;
// round, last, vertex_capacity, triangle_capacity, margin: those of the round
// of the lists of the raster that draws them (raster_vertices.comp); sway:
// the texel the view takes of a point at the reach of what sways in the maps
// (render.shadow_sway_texel).
struct Params_Block {
    uint reach; uint ranges; uint rows; uint chunk_capacity; uint entry_capacity; uint list; uint moving; uint movers;
    uint masks; uint plan; uint part; uint bound; uint foresee;
    uint round; uint last; uint vertex_capacity; uint triangle_capacity; float margin; float sway; uint pad1;
    // The eye the instances of a batch past its cull distance are left out
    // from, and how much farther than it (render.shadow_cull_eye).
    float4 cull;
};
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
// Of a chunk, over its map and the mip of it from bit SHADOW_CHUNK_MIP: its
// instance is drawn at rest (a batch that sways less than a texel of the map).
#define SHADOW_CHUNK_REST 0x20000000u
#define SHADOW_CHUNK_MAP 0xFFFFu
#define SHADOW_CHUNK_MIP 16u
// An entry of the list of the clusters the maps draw is a Visible_Cluster
// (visibility.slang) whose program word is the page it draws into
// (shadow_page_word), with SHADOW_ENTRY_REST where it is drawn at rest.
#define SHADOW_ENTRY_REST 0x80000000u

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

// What drawing what covers some texels of a map (its box) costs in a page of
// it, in units (SHADOW_UNIT_TEXELS): the texels its triangles cover there,
// SHADOW_MASKED_COST times as many for a masked material, and the vertices
// its clusters have, each placed once into the lists of the raster of the
// page and drawn once at most (SHADOW_UNIT_VERTICES). surface: the texels of
// the map the area of its triangles spans in all, of which a page charges
// the share its box has in the part of the page the round draws (part, from
// its corner), at most its triangles over each of those texels; 0 where it
// is not known, when it is taken as its box over them once.
uint shadow_units(uint2 page, uint4 part, float4 texels, uint triangles, bool masked, float surface, float vertices) {
    float4 at = texels - float4(page * SHADOW_PAGE, page * SHADOW_PAGE);
    float2 covered = max(min(at.zw, float2(part.zw)) - max(at.xy, float2(part.xy)), float2(1.0, 1.0));
    float2 box = max(texels.zw - texels.xy, float2(1.0, 1.0));
    float within = covered.x * covered.y;
    float area = surface > 0.0 ? min(surface * saturate(within / (box.x * box.y)), within * float(max(triangles, 1u))) : within;
    area = max(area, 1.0) * float(masked ? SHADOW_MASKED_COST : 1u);
    float placed = ceil(2.0 * vertices / float(SHADOW_UNIT_VERTICES));
    return uint(min(ceil(area / float(SHADOW_UNIT_TEXELS)) + placed, float(SHADOW_COST_UNITS / 4u)));
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

// Where a round draws a page of a map: the map at its mip, the page, its page
// of the pool, the texels of the map the round draws of it (shadow_page_part)
// and those as pixels of the pool from its lower left corner, the window of
// raster_triangle_shows.
struct Shadow_Page_Draw {
    Shadow_Map m;
    uint2 page;
    uint pool;
    uint4 drawn;
    float4 window;
};
// Of a page as a word (shadow_page_word); false where it has no page of the pool.
bool shadow_page_draw(StructuredBuffer<uint4> data, uint word, out Shadow_Page_Draw d) {
    d.m = shadow_map_mip(shadow_map_at(data, params.rows, shadow_page_map(word)), shadow_page_mip(word));
    d.page = shadow_page_of(word);
    d.pool = 0u;
    d.drawn = uint4(0u);
    d.window = float4(0.0);
    if (!shadow_page_pool(d.m, d.page, d.pool)) return false;
    uint4 page = shadow_page_window(d.m, d.page), part = shadow_page_part(d.pool);
    d.drawn = uint4(page.xy + part.xy, min(page.xy + part.zw, page.zw));
    // Texels of the pool, row 0 on top, then from its lower left corner.
    float4 at = float4(shadow_pool_corner(d.pool).xyxy + d.drawn - page.xyxy);
    d.window = float4(at.x, float(SHADOW_POOL) - at.w, at.z, float(SHADOW_POOL) - at.y);
    return true;
}

// Where a point of the world lies in the pool, clip space: where the map puts
// it, moved to the page of the pool of its page. inside: how far it lies within
// each side of the texels of the page drawn, which the clip distances of a
// draw keep its triangles to.
float4 shadow_page_clip(Shadow_Page_Draw d, float3 world, out float4 inside) {
    float4 clip = shadow_map_clip(d.m, shadow_map_local(d.m, world));
    // The texels drawn over the map, from -1 to 1, y up.
    float4 window = float4(d.drawn) / float(max(d.m.rect.z, 1u));
    float4 edges = float4(2.0 * window.x - 1.0, 1.0 - 2.0 * window.w, 2.0 * window.z - 1.0, 1.0 - 2.0 * window.y);
    inside = float4(clip.x - edges.x * clip.w, edges.z * clip.w - clip.x, clip.y - edges.y * clip.w, edges.w * clip.w - clip.y);
    // From -1 to 1 over the map to its page of the pool, row 0 on top: where
    // the corner of its square would lie were the page where it is.
    float side = float(d.m.rect.z) / float(SHADOW_POOL);
    float2 corner = (float2(shadow_pool_corner(d.pool)) - float2(d.page * SHADOW_PAGE)) / float(SHADOW_POOL);
    return float4((2.0 * corner.x + side) * clip.w - clip.w + side * clip.x,
        clip.w - (2.0 * corner.y + side) * clip.w + side * clip.y, clip.z, clip.w);
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
