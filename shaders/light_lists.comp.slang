#include "native.slang"
// The lists of the lights that cast no shadows of the screen tiles of a view
// (light_lists.slang, render/light_lists.odin), a thread a tile: the box of
// the points of its pixels and that of their normals, then what the walks of
// the tree would visit for any point in them. Each walk is followed over the
// cell with bounds in place of a point. A group none of whose lights can
// reach the cell is left out with what lies under it; one that opens whole at
// every point is left out and what lies under it listed; one that stands for
// its lights at every point (what it may err at most, against the least light
// the estimate gives the cell) is listed alone; any other is listed with what
// lies under it, and each point weighs them as its walk would. The bounds are
// loose, never tight: a list holds more than a point needs, never less.
//
// A list keeps LIGHT_LIST_ROUGH nodes of the estimate and LIGHT_LIST_FINE of
// the light. A cell that would list more lists none (LIGHT_LIST_WALK): its
// points walk the tree, each by itself (Stats_Block.lists counts it).
#define GBUFFER_NORMAL SLOT_PASS0
#define LIGHT_LISTS_WRITTEN
#include "gbuffer.slang"
#include "pixel.slang"
#include "cull_stats.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

// tiles: across and down the view.
struct Params_Block { uint2 tiles; uint pad0; uint pad1; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] [[vk::image_format("r32ui")]] RWTexture2D<uint> out_lists : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);
[[vk::binding(SLOT_PASS3, 0)]] RWStructuredBuffer<Stats_Block> list_stats : register(MIRAI_REGISTER(u, SLOT_PASS3), space0);
#include "light_cells.slang"

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    if (any(id.xy >= params.tiles)) return;
    int2 block = int2(id.xy) * LIGHT_LIST_BLOCK;
    int2 corner = int2(id.xy) * int(LIGHT_LIST_TILE);
    int2 size = int2(frame.resolution);
    cell.low = float3(FLT_MAX);
    cell.high = float3(-FLT_MAX);
    cell.normal_low = float3(1.0);
    cell.normal_high = float3(-1.0);
    for (uint k = 0u; k < LIGHT_LIST_TILE * LIGHT_LIST_TILE; k++) {
        int2 p = corner + int2(int(k % LIGHT_LIST_TILE), int(k / LIGHT_LIST_TILE));
        if (any(p >= size)) continue;
        float depth = g_depth.Load(int3(p, 0)).r;
        if (depth_empty(depth)) continue;
        float3 position = pixel_at(p, (float2(p) + 0.5) * frame.inv_resolution, depth).position;
        float3 normal = gbuffer_normal(p);
        cell.low = min(cell.low, position);
        cell.high = max(cell.high, position);
        cell.normal_low = min(cell.normal_low, normal);
        cell.normal_high = max(cell.normal_high, normal);
    }
    if (cell.low.x > cell.high.x) {
        out_lists[block] = 0u;
        return;
    }
    cell.middle = 0.5 * (cell.low + cell.high);
    cell.radius = 0.5 * length(cell.high - cell.low);

    uint count;
    bool listed = cell_list(block, count);
    InterlockedAdd(list_stats[0].lists[0], 1u);
    if (!listed) {
        InterlockedAdd(list_stats[0].lists[2], 1u);
        return;
    }
    InterlockedAdd(list_stats[0].lists[1], count);
    InterlockedMax(list_stats[0].lists[3], count);
}
