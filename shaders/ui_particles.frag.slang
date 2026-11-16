#include "native.slang"
// A particle view (render.Particle_View) for the UI: the light its sprites
// left, exposed at 1, through the display transform, with the share of the
// pixel they cover as alpha. The color is taken out of that share, so that
// the UI blending it by its alpha gives back what the sprites gave.
#include "display.slang"
struct Params_Block { uint pad0, pad1, pad2, pad3; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> radiance : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> coverage : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);

struct Stage_Input {
    [[vk::location(0)]] float2 in_uv : TEXCOORD0;
};
struct Stage_Output {
    [[vk::location(0)]] float4 out_color : SV_Target0;
};
[shader("fragment")]
Stage_Output main(Stage_Input input, float4 pixel_position : SV_Position) {
    Stage_Output output;
    int3 p = int3(int2(pixel_position.xy), 0);
    float3 light = finite_or_zero(radiance.Load(p).rgb);
    float alpha = saturate(coverage.Load(p).r);
    float3 color = alpha > 1e-4 ? display_encode(max(light, float3(0.0)) / alpha) : float3(0.0);
    output.out_color = float4(color, alpha);
    return output;
}
