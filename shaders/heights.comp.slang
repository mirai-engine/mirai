#include "native.slang"
// The heights of the scene (heights.slang) from the maps drawn from over it
// (render.heights_pass): each texel, the top of what its square of the map
// holds and of the texels of the map around that square, since a map holds
// the depth at the middle of each of its texels alone; and each group, the
// highest of its block.
#include "scene.slang"
#include "shadow_maps.slang"
#include "heights.slang"
#define MIRAI_GROUP_X 16
#define MIRAI_GROUP_Y 16
#define MIRAI_GROUP_Z 1

// first: the map of the nearest heights among those of the frame; rows: of
// the words of the lights in shadow_data; count: maps of heights.
struct Params_Block { uint first; uint rows; uint count; uint pad0; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] StructuredBuffer<uint4> shadow_data : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> atlas : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
// The texels of the texture of the heights, by rows.
[[vk::binding(SLOT_PASS2, 0)]] RWStructuredBuffer<float> heights : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);

groupshared float tops[HEIGHTS_BLOCK * HEIGHTS_BLOCK];

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID, uint3 group : SV_GroupID, uint local : SV_GroupIndex) {
    uint map = id.x / uint(HEIGHTS_SIDE);
    float top = -FLT_MAX;
    if (map < params.count) {
        Shadow_Map m = shadow_map_at(shadow_data, params.rows, params.first + map);
        // The texels of the map under the texel, and one more around them.
        float scale = float(m.rect.z) / float(HEIGHTS_SIDE);
        int2 texel = int2(int(id.x) % HEIGHTS_SIDE, int(id.y));
        int2 low = max(int2(floor(float2(texel) * scale)) - 1, int2(0));
        int2 high = min(int2(ceil(float2(texel + 1) * scale)), int2(m.rect.z) - 1);
        // Reversed depth: the greatest is the nearest to the top.
        float nearest = 0.0;
        for (int y = low.y; y <= high.y; y++) {
            for (int x = low.x; x <= high.x; x++) nearest = max(nearest, atlas.Load(int3(int2(m.rect.xy) + int2(x, y), 0)).r);
        }
        top = m.origin.y - shadow_map_distance(m, nearest);
    }
    uint width = HEIGHT_MAPS * uint(HEIGHTS_SIDE);
    heights[id.y * width + id.x] = top;
    tops[local] = top;
    GroupMemoryBarrierWithGroupSync();
    if (local != 0u) return;
    for (uint i = 1u; i < uint(HEIGHTS_BLOCK * HEIGHTS_BLOCK); i++) top = max(top, tops[i]);
    heights[(uint(HEIGHTS_SIDE) + group.y) * width + group.x] = top;
}
