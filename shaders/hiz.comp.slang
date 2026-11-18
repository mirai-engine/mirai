#include "native.slang"
// Depth pyramid for occlusion culling: each texel keeps the farthest linear
// depth of its footprint (background counts as infinitely far). Level 0 is
// half the render resolution; odd source sizes fold the extra row/column in.
#include "common.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

struct Params_Block { int2 source_size; uint from_depth; uint pad; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_POINT_SAMPLER, 0)]] SamplerState point_sampler : register(MIRAI_REGISTER(s, SLOT_POINT_SAMPLER), space0);
[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> source : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] [[vk::image_format("r32f")]] RWTexture2D<float4> target : register(MIRAI_REGISTER(u, SLOT_PASS1), space0);

float fetch_depth(int2 p) {
    float d = source.Load(int3(clamp(p, int2(0), params.source_size - 1), 0)).r;
    return (params.from_depth != 0u && d <= 0.0) ? 1e30 : d;
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    int2 p = int2(dispatch_id.xy);
    int2 size = texture_size(target);
    if (any(((p) >= (size)))) return;
    int2 s = p * 2;
    float d = max(max(fetch_depth(s), fetch_depth(s + int2(1, 0))), max(fetch_depth(s + int2(0, 1)), fetch_depth(s + int2(1, 1))));
    bool odd_x = (params.source_size.x & 1) != 0 && p.x == size.x - 1;
    bool odd_y = (params.source_size.y & 1) != 0 && p.y == size.y - 1;
    if (odd_x) d = max(d, max(fetch_depth(s + int2(2, 0)), fetch_depth(s + int2(2, 1))));
    if (odd_y) d = max(d, max(fetch_depth(s + int2(0, 2)), fetch_depth(s + int2(1, 2))));
    if (odd_x && odd_y) d = max(d, fetch_depth(s + int2(2, 2)));
    target[p] = float4(d);
}
