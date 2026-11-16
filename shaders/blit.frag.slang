#include "native.slang"

// Copies the display-encoded LDR image to the swapchain. sRGB swapchains
// re-encode on write, so the value is decoded to linear first.
#include "common.slang"
struct Params_Block { uint decode_srgb; uint pad0, pad1, pad2; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_POINT_SAMPLER, 0)]] SamplerState point_sampler : register(MIRAI_REGISTER(s, SLOT_POINT_SAMPLER), space0);
[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> source : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);

float3 srgb_to_linear(float3 c) {
    return lerp(c / 12.92, pow((c + 0.055) / 1.055, float3(2.4)), step(float3(0.04045), c));
}

struct Stage_Input {
    [[vk::location(0)]] float2 in_uv : TEXCOORD0;
};
struct Stage_Output {
    [[vk::location(0)]] float4 out_color : SV_Target0;
};
[shader("fragment")]
Stage_Output main(Stage_Input input) {
    Stage_Output output;
    float4 c = source.SampleLevel(point_sampler, input.in_uv, 0.0);
    output.out_color = params.decode_srgb != 0u ? float4(srgb_to_linear(c.rgb), c.a) : c;
    return output;
}
