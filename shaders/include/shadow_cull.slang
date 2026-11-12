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
// culls for, whose indices lie in the buffer of the maps from word `list`;
// rows: of the words of the lights in the buffer of the maps; glass: 1 while
// the maps keep the tint of glass, and for the draws of the tint and of the
// nearest glass; chunk_capacity, entry_capacity: of the lists of the chunks
// and of the clusters (render.Cull_List); moving: the round of the casters
// that move (render.shadow_maps_pass), 0 that of those that stay; movers:
// words of the bits of the instances that move.
struct Params_Block { uint instances; uint maps; uint rows; uint glass; uint chunk_capacity; uint entry_capacity; uint list; uint moving; uint movers; uint pad0; uint pad1; uint pad2; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
// The draws: of the clusters that hide whole, of those of masked materials,
// and of those of glass for the tint and the nearest glass.
#define SHADOW_DRAW_OPAQUE 0u
#define SHADOW_DRAW_TESTED 1u
#define SHADOW_DRAW_GLASS 2u
#define SHADOW_DRAW_COUNT 1u // the instances of draw d: word d * 4 + 1
#define SHADOW_CLUSTER_DISPATCH 12u
#define SHADOW_CHUNK_COUNT 15u
// Of a chunk, over its map: it draws the depth, and the glass.
#define SHADOW_CHUNK_DEPTH 0x40000000u
#define SHADOW_CHUNK_GLASS 0x80000000u
#define SHADOW_CHUNK_MAP 0xFFFFu
// How many clusters of a draw the list holds: half for those that hide
// whole, a quarter for each of the others.
uint shadow_room(uint draw) { return draw == SHADOW_DRAW_OPAQUE ? params.entry_capacity / 2u : params.entry_capacity / 4u; }
// Where in the list the cluster `slot` of a draw lies.
uint shadow_entry(uint draw, uint slot) { return (draw == SHADOW_DRAW_OPAQUE ? 0u : draw == SHADOW_DRAW_TESTED ? params.entry_capacity / 2u : params.entry_capacity - params.entry_capacity / 4u) + slot; }

// A job of a round: a map, and the window of its square it draws, texels
// from its corner: x0, y0, x1, y1 (render.shadow_job).
struct Shadow_Job {
    uint map;
    uint4 window;
};

uint shadow_word(StructuredBuffer<uint4> data, uint word) { return data[word >> 2u][word & 3u]; }

Shadow_Job shadow_job(StructuredBuffer<uint4> data, uint job) {
    uint a = shadow_word(data, params.list + 2u * job), b = shadow_word(data, params.list + 2u * job + 1u);
    Shadow_Job j;
    j.map = a & 0xFFu;
    j.window = uint4((a >> 8u) & 0xFFFu, a >> 20u, b & 0xFFFFu, b >> 16u);
    return j;
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
