#include "native.slang"
// A level of the bloom from the one before, or the first from the image, with
// the 13 samples of Jimenez 2014: five overlapping boxes of 4 texels. From the
// image each box weighs by how dark it is (Karis): a single bright pixel does
// not flicker as it crosses the texels of the level.
#include "lens.slang"

[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> source : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> level : register(MIRAI_REGISTER(u, SLOT_PASS1), space0);

float3 tap(float2 uv, float2 texel, float2 offset, float lod) {
    return source.SampleLevel(linear_sampler, uv + offset * texel, lod).rgb;
}

float3 karis(float3 a, float3 b, float3 c, float3 d, out float weight) {
    float3 box = (a + b + c + d) * 0.25;
    weight = 1.0 / (1.0 + dot(box, float3(0.2126, 0.7152, 0.0722)));
    return box * weight;
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    int2 p = int2(id.xy);
    if (any(p >= int2(lens.target.xy))) return;
    bool first = lens.level.y != 0u;
    float lod = first ? 0.0 : float(lens.level.x) - 1.0;
    float2 texel = 1.0 / float2(texture_size(source, uint(lod)));
    float2 uv = (float2(p) + 0.5) * lens.target.zw;
    float3 a = tap(uv, texel, float2(-2.0, -2.0), lod), b = tap(uv, texel, float2(0.0, -2.0), lod), c = tap(uv, texel, float2(2.0, -2.0), lod);
    float3 d = tap(uv, texel, float2(-2.0, 0.0), lod), e = tap(uv, texel, float2(0.0, 0.0), lod), f = tap(uv, texel, float2(2.0, 0.0), lod);
    float3 g = tap(uv, texel, float2(-2.0, 2.0), lod), h = tap(uv, texel, float2(0.0, 2.0), lod), i = tap(uv, texel, float2(2.0, 2.0), lod);
    float3 j = tap(uv, texel, float2(-1.0, -1.0), lod), k = tap(uv, texel, float2(1.0, -1.0), lod);
    float3 l = tap(uv, texel, float2(-1.0, 1.0), lod), m = tap(uv, texel, float2(1.0, 1.0), lod);
    float3 color;
    if (first) {
        float w0, w1, w2, w3, w4;
        float3 sum = karis(j, k, l, m, w0) * 0.5
            + karis(a, b, d, e, w1) * 0.125 + karis(b, c, e, f, w2) * 0.125
            + karis(d, e, g, h, w3) * 0.125 + karis(e, f, h, i, w4) * 0.125;
        color = sum / (w0 * 0.5 + (w1 + w2 + w3 + w4) * 0.125);
    } else {
        color = e * 0.125 + (a + c + g + i) * 0.03125 + (b + d + f + h) * 0.0625 + (j + k + l + m) * 0.125;
    }
    level[p] = float4(min(color, float3(65000.0)), 1.0);
}
