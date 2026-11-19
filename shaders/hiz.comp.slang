#include "native.slang"
// Depth pyramid for occlusion culling: each texel keeps the farthest linear
// depth of the pixels it covers (background counts as infinitely far). Texel
// j of level L covers pixels j * 2^(L+1) to (j + 1) * 2^(L+1), those of the
// view among them: a level is as large as it takes to cover the view, and
// the last texel of an odd size covers the pixels left (pyramid.slang).
// Level 0 is made from the depth target (reverse Z, 0 where nothing is).
//
// A dispatch makes up to DEPTH_PYRAMID_BATCH levels from the one before them: a
// group of 8x8 threads reduces a tile of 8x8 texels of the first, then 4x4
// of the next, 2x2 and 1 through group memory. Its threads take their texels
// in an order where the four that reduce into one are a bank apart, so each
// level reads only what the group wrote.
#include "common.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1
#define PYRAMID_TILE 8u

// from_depth: the source is the depth target, whose value d at the point p =
// (ndc x, ndc y, d, 1) of a pixel is at the linear depth dot(along, p) / dot(by, p).
// Relative: well above the rounding of the depth and of the inverse of the
// projection, well below any distance between two surfaces that matters.
#define HIZ_DEPTH_SLACK 1e-4

// source_size: of the depth target or of the level before the first of this
// dispatch. levels: how many it makes, up to DEPTH_PYRAMID_BATCH.
struct Params_Block { int2 source_size; uint from_depth; uint levels; float4 along; float4 by; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> source : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] [[vk::image_format("r32f")]] RWTexture2D<float4> target0 : register(MIRAI_REGISTER(u, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] [[vk::image_format("r32f")]] RWTexture2D<float4> target1 : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);
[[vk::binding(SLOT_PASS3, 0)]] [[vk::image_format("r32f")]] RWTexture2D<float4> target2 : register(MIRAI_REGISTER(u, SLOT_PASS3), space0);
[[vk::binding(SLOT_PASS4, 0)]] [[vk::image_format("r32f")]] RWTexture2D<float4> target3 : register(MIRAI_REGISTER(u, SLOT_PASS4), space0);

groupshared float farthest[PYRAMID_TILE * PYRAMID_TILE];

// The farthest depth a texel of the source holds; what is past the source
// covers no pixel and holds nothing.
float fetch_depth(int2 p) {
    if (any(p >= params.source_size)) return 0.0;
    float d = source.Load(int3(p, 0)).r;
    if (params.from_depth == 0u) return d;
    if (d <= 0.0) return 1e30;
    float2 ndc = (float2(p) + 0.5) / float2(params.source_size) * float2(2.0, -2.0) + float2(-1.0, 1.0);
    float4 point = float4(ndc, d, 1.0);
    // What f32 holds of the depth and of the inverse of the projection puts the
    // linear depth a hair nearer or farther than the surface that wrote it:
    // the step farther keeps the surface itself from being hidden by it.
    return dot(params.along, point) / dot(params.by, point) * (1.0 + HIZ_DEPTH_SLACK);
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
    int2 s = p * 2;
    float d = max(max(fetch_depth(s), fetch_depth(s + int2(1, 0))), max(fetch_depth(s + int2(0, 1)), fetch_depth(s + int2(1, 1))));
    pyramid_store(0u, p, d);
    for (uint k = 1u; k < DEPTH_PYRAMID_BATCH; k++) {
        if (k >= params.levels) break;
        uint bank = (PYRAMID_TILE >> k) * (PYRAMID_TILE >> k);
        GroupMemoryBarrierWithGroupSync();
        if (index < bank * 4u) farthest[index] = d;
        GroupMemoryBarrierWithGroupSync();
        if (index < bank) {
            d = max(max(d, farthest[index + bank]), max(farthest[index + 2u * bank], farthest[index + 3u * bank]));
            p >>= 1;
            pyramid_store(k, p, d);
        }
    }
}
