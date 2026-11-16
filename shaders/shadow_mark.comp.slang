#include "native.slang"
// The pages of the maps of the shadows the points of the direct light of a
// view read (render.shadow_maps_pass), before they are drawn: for each point
// (direct_maps.comp), the level of the sun and the map of each light of its
// cell that hold it, and every page the taps around it reach there
// (shadow_map_taps), a bit for each entry of the table of its slot. A still
// view keeps the marks of the frames before, and a page newly marked that is
// not drawn asks the steps of the pages to run (SHADOW_STEP_NEW).
#define GBUFFER_NORMAL SLOT_PASS0
#define SHADOW_DATA_SLOT SLOT_PASS9
#include "lighting.slang"
#include "gbuffer.slang"
#include "pixel.slang"
#include "direct_samples.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

// Those of direct_samples.comp.
struct Params_Block { uint pad0; uint samples; float sun_radius; uint scale; uint hard; uint resume; uint glass; uint pad4; float3 grid_origin; float grid_cell; uint3 grid_size; uint cells;
    uint shadow_on; uint shadow_rows; uint shadow_maps; uint shadow_sun; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
// The buffer of the pages of the view (render.Shadow_Raster.pages).
[[vk::binding(SLOT_PASS2, 0)]] RWStructuredBuffer<uint> pages : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);
[[vk::binding(SLOT_PASS6, 0)]] StructuredBuffer<uint4> light_grid : register(MIRAI_REGISTER(t, SLOT_PASS6), space0);
#include "shadow_maps.slang"
#include "direct_grid.slang"

// The pages of map m the taps around a point read: where they go does not
// depend on the way to the light, which shadow_map_seen takes only to tell a
// point that turns from it (here, as one that faces it).
void shadow_mark(Shadow_Map m, bool sun, float3 position, float3 n, float radius, float across, float grow) {
    Shadow_Taps t;
    if (!shadow_map_taps(m, sun, n, position, n, radius, across, grow, t)) return;
    float reach = shadow_taps_reach(t);
    int last = int(m.rect.z) - 1;
    int2 low = clamp(int2(floor(t.texel - reach)), 0, last), high = clamp(int2(floor(t.texel + reach)), 0, last);
    uint2 first = uint2(low) / SHADOW_PAGE, end = uint2(high) / SHADOW_PAGE;
    for (uint y = first.y; y <= end.y; y++) {
        for (uint x = first.x; x <= end.x; x++) {
            uint entry = shadow_page_entry(m.rect, uint2(x, y));
            uint word = SHADOW_WORDS_NEEDED + m.rect.x * SHADOW_MASK_WORDS + (entry >> 5u), bit = 1u << (entry & 31u);
            if ((pages[word] & bit) != 0u) continue;
            uint before;
            InterlockedOr(pages[word], bit, before);
            if ((before & bit) == 0u && shadow_entry_asks(shadow_table_entry(m.rect.x, entry))) pages[SHADOW_STEP_NEW] = 1u;
        }
    }
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    int scale = int(max(params.scale, 1u));
    int2 p = int2(dispatch_id.xy);
    if (any(p >= direct_points(scale))) return;
    int2 source = p * scale;
    float depth = g_depth.Load(int3(source, 0)).r;
    if (depth_empty(depth)) return;
    float2 uv = (float2(source) + 0.5) * frame.inv_resolution;
    Pixel pixel = pixel_at(source, uv, depth);
    float3 normal = gbuffer_normal(source);
    float across = float(scale) * (frame.footprint.x + frame.footprint.y * depth_distance(depth));
    Shadow_Map m;
    Sun_Pick pick;
    float pixel_across = across / float(scale);
    if (direct_sun_weight(pixel.position, normal) > 0.0 && sun_pick(pixel.position, pixel_across, pick)) {
        shadow_mark(sun_level(pick.level), true, pixel.position, normal, params.sun_radius, across, pick.grow);
        if (pick.blend > 0.0) shadow_mark(sun_level(pick.level + 1u), true, pixel.position, normal, params.sun_radius, across, 1.0);
    }
    uint4 row = direct_cell(pixel.position);
    uint count = direct_items(row);
    for (uint i = 0u; i < count; i++) {
        uint item = direct_item(row, i);
        if (item == DIRECT_CELL_TABLE || !light_map_of(item, pixel.position, m)) continue;
        Sun_Pick mip = light_pick(m, pixel.position, pixel_across, light_extent(lights[item]));
        shadow_mark(shadow_map_mip(m, mip.level), false, pixel.position, normal, light_extent(lights[item]), across, mip.grow);
        if (mip.blend > 0.0) shadow_mark(shadow_map_mip(m, mip.level + 1u), false, pixel.position, normal, light_extent(lights[item]), across, 1.0);
    }
}
