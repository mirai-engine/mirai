#include "native.slang"
// The farthest depth the cache of the maps of the shadows holds over blocks
// of each page of its pool (render.Shadow_Raster.hiz), for the pages the
// cache drew this frame (shadow_pages.comp, the list of the round of what
// stays): a group for each page, SHADOW_HIZ_BLOCK texels a block at its first
// mip, each mip after twice as wide, the last the whole page. What moves is
// culled against it where the cache holds a page (shadow_clusters.comp), and
// a change of what stays where the cache hides it does not draw it again
// (shadow_pages.comp).
#include "scene.slang"
#include "shadow_pages.slang"
#define MIRAI_GROUP_X 256
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> cache : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] StructuredBuffer<uint> pages : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] [[vk::image_format("r32f")]] RWTexture2D<float> hiz0 : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);
[[vk::binding(SLOT_PASS3, 0)]] [[vk::image_format("r32f")]] RWTexture2D<float> hiz1 : register(MIRAI_REGISTER(u, SLOT_PASS3), space0);
[[vk::binding(SLOT_PASS4, 0)]] [[vk::image_format("r32f")]] RWTexture2D<float> hiz2 : register(MIRAI_REGISTER(u, SLOT_PASS4), space0);
[[vk::binding(SLOT_PASS5, 0)]] [[vk::image_format("r32f")]] RWTexture2D<float> hiz3 : register(MIRAI_REGISTER(u, SLOT_PASS5), space0);
[[vk::binding(SLOT_PASS6, 0)]] [[vk::image_format("r32f")]] RWTexture2D<float> hiz4 : register(MIRAI_REGISTER(u, SLOT_PASS6), space0);

groupshared float farthest[256];

void store(uint mip, int2 at, float depth) {
    if (mip == 1u) hiz1[at] = depth;
    else if (mip == 2u) hiz2[at] = depth;
    else if (mip == 3u) hiz3[at] = depth;
    else hiz4[at] = depth;
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 group : SV_GroupID, uint3 lane3 : SV_GroupThreadID) {
    uint lane = lane3.x;
    uint drawn = min(pages[SHADOW_WORDS_COUNTS + SHADOW_COUNT_DRAWN], SHADOW_POOL_PAGES);
    if (group.x >= drawn) return;
    uint pool = pages[SHADOW_WORDS_JOBS + group.x] & SHADOW_ENTRY_POOL;
    uint2 corner = shadow_pool_corner(pool);
    uint side = SHADOW_PAGE / SHADOW_HIZ_BLOCK;
    uint2 block = uint2(lane % side, lane / side);
    // Reversed depth: the farthest is the least.
    float depth = 1.0;
    for (uint y = 0u; y < SHADOW_HIZ_BLOCK; y++) {
        for (uint x = 0u; x < SHADOW_HIZ_BLOCK; x++) depth = min(depth, cache.Load(int3(int2(corner + block * SHADOW_HIZ_BLOCK + uint2(x, y)), 0)).r);
    }
    int2 first = int2(corner / SHADOW_HIZ_BLOCK);
    hiz0[first + int2(block)] = depth;
    farthest[lane] = depth;
    GroupMemoryBarrierWithGroupSync();
    for (uint mip = 1u; mip < SHADOW_HIZ_MIPS; mip++) {
        uint wide = side >> mip;
        float down = 1.0;
        uint2 at = uint2(lane % wide, lane / wide);
        if (lane < wide * wide) {
            uint below = side >> (mip - 1u);
            for (uint k = 0u; k < 4u; k++) down = min(down, farthest[(at.y * 2u + (k >> 1u)) * below + at.x * 2u + (k & 1u)]);
        }
        GroupMemoryBarrierWithGroupSync();
        if (lane < wide * wide) {
            farthest[lane] = down;
            store(mip, (first >> int(mip)) + int2(at), down);
        }
        GroupMemoryBarrierWithGroupSync();
    }
}
