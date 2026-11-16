#include "native.slang"
// A level of the bloom adds the one below it, wider, through a tent of 3x3 of
// its texels: the first level ends with every level added.
#include "lens.slang"

[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> chain : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> level : register(MIRAI_REGISTER(u, SLOT_PASS1), space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    int2 p = int2(id.xy);
    if (any(p >= int2(lens.target.xy))) return;
    uint below = lens.level.x + 1u;
    float lod = float(below);
    float2 texel = 1.0 / float2(texture_size(chain, below));
    float2 uv = (float2(p) + 0.5) * lens.target.zw;
    float3 wider = float3(0.0);
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float w = float((2 - abs(x)) * (2 - abs(y)));
            wider += chain.SampleLevel(linear_sampler, uv + float2(x, y) * texel, lod).rgb * w;
        }
    }
    level[p] = float4(level[p].rgb + wider / 16.0, 1.0);
}
