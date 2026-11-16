#include "native.slang"
// Depth pyramid for occlusion culling: each texel keeps the farthest linear
// depth of its footprint (background counts as infinitely far). Level 0 is
// half the render resolution, made from the depth target (reverse Z, 0 where
// nothing is); odd source sizes fold the extra row/column in.
#include "common.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

// from_depth: the source is the depth target, whose value d at the point p =
// (ndc x, ndc y, d, 1) of a pixel is at the linear depth dot(along, p) / dot(by, p).
// Relative: well above the rounding of the depth and of the inverse of the
// projection, well below any distance between two surfaces that matters.
#define HIZ_DEPTH_SLACK 1e-4

struct Params_Block { int2 source_size; uint from_depth; uint pad; float4 along; float4 by; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_POINT_SAMPLER, 0)]] SamplerState point_sampler : register(MIRAI_REGISTER(s, SLOT_POINT_SAMPLER), space0);
[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> source : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] [[vk::image_format("r32f")]] RWTexture2D<float4> target : register(MIRAI_REGISTER(u, SLOT_PASS1), space0);

float fetch_depth(int2 p) {
    int2 at = clamp(p, int2(0), params.source_size - 1);
    float d = source.Load(int3(at, 0)).r;
    if (params.from_depth == 0u) return d;
    if (d <= 0.0) return 1e30;
    float2 ndc = (float2(at) + 0.5) / float2(params.source_size) * float2(2.0, -2.0) + float2(-1.0, 1.0);
    float4 point = float4(ndc, d, 1.0);
    // What f32 holds of the depth and of the inverse of the projection puts the
    // linear depth a hair nearer or farther than the surface that wrote it:
    // the step farther keeps the surface itself from being hidden by it.
    return dot(params.along, point) / dot(params.by, point) * (1.0 + HIZ_DEPTH_SLACK);
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
