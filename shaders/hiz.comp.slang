#include "native.slang"
// Depth pyramid for occlusion culling: each texel keeps the farthest depth of
// the pixels it covers, as the depth target holds it (reverse Z: the least
// value, 0 where nothing is). Texel j of level L covers pixels j * 2^(L+1) to
// (j + 1) * 2^(L+1), those of the view among them: a level is as large as it
// takes to cover the view, and the last texel of an odd size covers the
// pixels left (pyramid.slang).
//
// A dispatch makes up to DEPTH_PYRAMID_BATCH levels from the one before them: a
// group of 8x8 threads gathers a tile of 8x8 texels of the first, then reduces
// 4x4 of the next, 2x2 and 1. Its threads take their texels in an order where
// the four that reduce into one are a bank apart, so each level reads only
// what the group wrote, through group memory: it writes below the banks the
// level before read, so one wait a level orders its writes after those reads.
#include "common.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1
#define PYRAMID_TILE 8u

// source_size: of the view, or of the level before the first of this dispatch.
// levels: how many it makes, up to DEPTH_PYRAMID_BATCH. inv_extent: 1 over
// the size of the texture of the source, which holds more past the view.
struct Params_Block { int2 source_size; uint levels; uint pad0; float2 inv_extent; float2 pad1; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_POINT_SAMPLER, 0)]] SamplerState point_sampler : register(MIRAI_REGISTER(s, SLOT_POINT_SAMPLER), space0);
[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> source : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] [[vk::image_format("r32f")]] RWTexture2D<float4> target0 : register(MIRAI_REGISTER(u, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] [[vk::image_format("r32f")]] RWTexture2D<float4> target1 : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);
[[vk::binding(SLOT_PASS3, 0)]] [[vk::image_format("r32f")]] RWTexture2D<float4> target2 : register(MIRAI_REGISTER(u, SLOT_PASS3), space0);
[[vk::binding(SLOT_PASS4, 0)]] [[vk::image_format("r32f")]] RWTexture2D<float4> target3 : register(MIRAI_REGISTER(u, SLOT_PASS4), space0);

groupshared float farthest[PYRAMID_TILE * PYRAMID_TILE];

// The farthest depth of the 2x2 texels of the source from s: one gather at
// their shared corner. A texel past the source covers no pixel, holds what is
// past the view in a level larger than it, and counts as the near plane.
float gather_farthest(int2 s) {
    // w: (s.x, s.y), z: (s.x + 1, s.y), x: (s.x, s.y + 1), y: (s.x + 1, s.y + 1).
    float4 d = source.GatherRed(point_sampler, float2(s + 1) * params.inv_extent);
    // The columns and rows of the source from s: 2 or more, none past it.
    int2 left = params.source_size - s;
    if (left.x < 2) d.zy = float2(1.0);
    if (left.x < 1) d.xw = float2(1.0);
    if (left.y < 2) d.xy = float2(1.0);
    if (left.y < 1) d.zw = float2(1.0);
    return min(min(d.x, d.y), min(d.z, d.w));
}

// The texel of the tile of a thread: the bits of its index alternate x and
// y from the finest level up, so the four texels one of the next level
// reduces are a bank of a quarter of the threads apart.
uint2 pyramid_texel(uint index) {
    uint2 p = uint2(0u);
    [ForceUnroll] for (uint bit = 0u; bit < 3u; bit++) {
        p.x |= ((index >> (2u * bit)) & 1u) << (2u - bit);
        p.y |= ((index >> (2u * bit + 1u)) & 1u) << (2u - bit);
    }
    return p;
}

// The size of the level `k` past the first of this dispatch.
int2 pyramid_size(uint k) { return (params.source_size + int2((2 << k) - 1)) >> int(k + 1u); }

void pyramid_store(uint k, int2 p, float d) {
    if (any(p >= pyramid_size(k))) return;
    switch (k) {
    case 0u: target0[p] = float4(d); break;
    case 1u: target1[p] = float4(d); break;
    case 2u: target2[p] = float4(d); break;
    default: target3[p] = float4(d); break;
    }
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 group : SV_GroupID, uint index : SV_GroupIndex) {
    int2 p = int2(group.xy * PYRAMID_TILE + pyramid_texel(index));
    float d = gather_farthest(p * 2);
    pyramid_store(0u, p, d);
    for (uint k = 1u; k < DEPTH_PYRAMID_BATCH; k++) {
        if (k >= params.levels) break;
        uint bank = (PYRAMID_TILE >> k) * (PYRAMID_TILE >> k);
        if (index < bank * 4u) farthest[index] = d;
        GroupMemoryBarrierWithGroupSync();
        if (index < bank) {
            d = min(min(d, farthest[index + bank]), min(farthest[index + 2u * bank], farthest[index + 3u * bank]));
            p >>= 1;
            pyramid_store(k, p, d);
        }
    }
}
