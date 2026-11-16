// What the cull of the maps of the shadows (shadow_maps.comp by instance,
// shadow_clusters.comp by cluster) and the draws of their clusters
// (shadow_map.vert) share: their parameters, the words of
// render.Gpu_Shadow_State, and where in the list of the clusters the maps
// draw those of each draw lie.
#ifndef MIRAI_SHADOW_CULL_SLANG
#define MIRAI_SHADOW_CULL_SLANG
#include "cut.slang"
#include "shadow_maps.slang"
// instances: of the scene and of the batches drawn; maps: those the round
// culls for, whose indices lie in the buffer of the maps from word `list`,
// and the pages it draws of each a bit each from word `masks`
// (SHADOW_MASK_WORDS a map, by its index);
// rows: of the words of the lights in the buffer of the maps; glass: 1 while
// the maps keep the tint of glass, and for the draws of the tint and of the
// nearest glass; chunk_capacity, entry_capacity: of the lists of the chunks
// and of the clusters (render.Cull_List); moving: 1 the round of the casters
// that move (render.shadow_maps_pass), 0 that of those that stay, 2 that of
// the glass alone; movers:
// words of the bits of what moves, the instances of the scene then the
// batches drawn; listed: 1 while the round culls the `ranges` ranges of the
// movers after those words alone, `instances` in all (render.shadow_maps_plan).
struct Params_Block { uint instances; uint maps; uint rows; uint glass; uint chunk_capacity; uint entry_capacity; uint list; uint moving; uint movers; uint listed; uint ranges; uint masks; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
// The draws: of the clusters that hide whole, of those of masked materials,
// and of those of glass for the tint and the nearest glass.
#define SHADOW_DRAW_OPAQUE 0u
#define SHADOW_DRAW_TESTED 1u
#define SHADOW_DRAW_GLASS 2u
#define SHADOW_DRAW_COUNT 1u // the instances of draw d: word d * 4 + 1
#define SHADOW_CLUSTER_DISPATCH 12u
#define SHADOW_CHUNK_COUNT 15u
// Of a chunk, over its map: it draws the depth, and the glass; its instance
// is drawn at rest (a batch that sways less than a texel of the map).
#define SHADOW_CHUNK_REST 0x20000000u
#define SHADOW_CHUNK_DEPTH 0x40000000u
#define SHADOW_CHUNK_GLASS 0x80000000u
#define SHADOW_CHUNK_MAP 0xFFFFu
// How many clusters of a draw the list holds: half for those that hide
// whole, a quarter for each of the others.
uint shadow_room(uint draw) { return draw == SHADOW_DRAW_OPAQUE ? params.entry_capacity / 2u : params.entry_capacity / 4u; }
// Where in the list the cluster `slot` of a draw lies.
uint shadow_entry(uint draw, uint slot) { return (draw == SHADOW_DRAW_OPAQUE ? 0u : draw == SHADOW_DRAW_TESTED ? params.entry_capacity / 2u : params.entry_capacity - params.entry_capacity / 4u) + slot; }

uint shadow_word(StructuredBuffer<uint4> data, uint word) { return data[word >> 2u][word & 3u]; }

#define SHADOW_MASK_WORDS (SHADOW_MAP_PAGES * SHADOW_MAP_PAGES / 32u)

// Whether the round draws a page of a map (render.Shadow_Mask).
bool shadow_page_drawn(StructuredBuffer<uint4> data, uint map, uint2 page) {
    uint bit = page.y * SHADOW_MAP_PAGES + page.x;
    return ((shadow_word(data, params.masks + map * SHADOW_MASK_WORDS + (bit >> 5u)) >> (bit & 31u)) & 1u) != 0u;
}

// A page of a map as a word: the map, its column and its row (render.shadow_page_word).
uint shadow_page_word(uint map, uint2 page) { return map | page.x << 8u | page.y << 16u; }
uint shadow_page_map(uint word) { return word & 0xFFu; }
uint2 shadow_page_of(uint word) { return uint2((word >> 8u) & 0xFFu, (word >> 16u) & 0xFFu); }

// Its window of the square of its map, texels: x0, y0, x1, y1.
uint4 shadow_page_window(Shadow_Map m, uint2 page) {
    return uint4(page * SHADOW_PAGE, min((page + 1u) * SHADOW_PAGE, uint2(m.rect.z, m.rect.z)));
}

// The pages of a map a box of the world covers from the light, the first
// column and row then the last (render.shadow_page_rect); false where it
// covers none. A box that reaches the plane of a perspective one covers all.
bool shadow_page_rect(Shadow_Map m, float3 low, float3 high, out uint4 rect) {
    uint last = m.rect.z / SHADOW_PAGE - 1u;
    rect = uint4(0u, 0u, last, last);
    float2 lo = float2(FLT_MAX, FLT_MAX), hi = -float2(FLT_MAX, FLT_MAX);
    for (uint corner = 0u; corner < 8u; corner++) {
        float3 p = float3((corner & 1u) != 0u ? high.x : low.x, (corner & 2u) != 0u ? high.y : low.y, (corner & 4u) != 0u ? high.z : low.z);
        float3 local = shadow_map_local(m, p);
        float2 at = local.xy;
        if (!shadow_map_orthographic(m)) {
            if (local.z <= m.near * 0.5) return true;
            at /= local.z;
        }
        lo = min(lo, at);
        hi = max(hi, at);
    }
    float side = float(m.rect.z);
    float x0 = (lo.x - m.span.x) / (m.span.z - m.span.x) * side, x1 = (hi.x - m.span.x) / (m.span.z - m.span.x) * side;
    float y0 = (m.span.w - hi.y) / (m.span.w - m.span.y) * side, y1 = (m.span.w - lo.y) / (m.span.w - m.span.y) * side;
    if (x1 < 0.0 || y1 < 0.0 || x0 >= side || y0 >= side) return false;
    float end = float((last + 1u) * SHADOW_PAGE) - 1.0;
    rect = uint4(uint(clamp(x0, 0.0, end)), uint(clamp(y0, 0.0, end)), uint(clamp(x1, 0.0, end)), uint(clamp(y1, 0.0, end))) / SHADOW_PAGE;
    return true;
}

// Whether a round draws a page of a map within a rect of its pages.
bool shadow_pages_drawn(StructuredBuffer<uint4> data, uint map, uint4 rect) {
    for (uint y = rect.y; y <= rect.w; y++) {
        for (uint x = rect.x; x <= rect.z; x++) {
            if (shadow_page_drawn(data, map, uint2(x, y))) return true;
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
