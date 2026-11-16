#include "native.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1
[[vk::binding(0, 0)]] Texture2D<float4> source : register(t0, space0);
[[vk::binding(1, 0)]] SamplerState point_sampler : register(s1, space0);
[[vk::binding(2, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> target : register(u2, space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    int2 p = int2(dispatch_id.xy);
    int2 size = texture_size(target);
    if (p.x >= size.x || p.y >= size.y) return;
    float4 c = source.SampleLevel(point_sampler, (float2(p) + 0.5) / float2(size), 0.0);
    target[p] = float4(c.rgb * 2.0, 1.0);
}
