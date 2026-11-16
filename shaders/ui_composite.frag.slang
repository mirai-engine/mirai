#include "native.slang"
#include "common.slang"
#include "ui_shape.slang"

struct Params_Block { float4 bounds; float4 values; float2 viewport; float2 pad; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_LINEAR_SAMPLER, 0)]] SamplerState linear_sampler : register(MIRAI_REGISTER(s, SLOT_LINEAR_SAMPLER), space0);
[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> source : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
struct Stage_Input { [[vk::location(0)]] float2 in_uv : TEXCOORD0; };
struct Stage_Output { [[vk::location(0)]] float4 out_color : SV_Target0; };
[shader("fragment")]
Stage_Output main(Stage_Input input) {
    Stage_Output output;
    float distance = ui_rounded_distance(input.in_uv * params.viewport, params.bounds, float4(params.values.x));
    float coverage = saturate(0.5 - distance / max(fwidth(distance), 1e-4));
    float4 color = source.SampleLevel(linear_sampler, input.in_uv, 0.0);
    output.out_color = color * (saturate(params.values.y) * coverage);
    return output;
}
