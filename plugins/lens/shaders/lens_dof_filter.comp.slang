#include "native.slang"
// The gathered layer through a tent of 3x3 pixels, which fills the gaps
// between the rings of samples.
#include "lens.slang"

[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> bokeh : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> layer : register(MIRAI_REGISTER(u, SLOT_PASS1), space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    int2 p = int2(id.xy);
    if (any(p >= int2(lens.target.xy))) return;
    float2 uv = (float2(p) + 0.5) * lens.target.zw;
    float2 o = 0.5 * lens.target.zw;
    float4 sum = bokeh.SampleLevel(linear_sampler, uv + float2(-o.x, -o.y), 0.0)
        + bokeh.SampleLevel(linear_sampler, uv + float2(o.x, -o.y), 0.0)
        + bokeh.SampleLevel(linear_sampler, uv + float2(-o.x, o.y), 0.0)
        + bokeh.SampleLevel(linear_sampler, uv + float2(o.x, o.y), 0.0);
    layer[p] = sum * 0.25;
}
