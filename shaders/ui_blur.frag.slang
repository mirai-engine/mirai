#include "native.slang"
#include "common.slang"
struct Params_Block { float2 direction; float sigma; float pad; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_LINEAR_SAMPLER, 0)]] SamplerState linear_sampler : register(MIRAI_REGISTER(s, SLOT_LINEAR_SAMPLER), space0);
[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> source : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
struct Stage_Input { [[vk::location(0)]] float2 in_uv : TEXCOORD0; };
struct Stage_Output { [[vk::location(0)]] float4 out_color : SV_Target0; };
[shader("fragment")]
Stage_Output main(Stage_Input input) {
    Stage_Output output;
    float sigma = max(params.sigma, 0.5);
    float step_size = max(sigma * 3.0 / 12.0, 1.0);
    float4 sum = float4(0.0);
    float total = 0.0;
    [unroll] for (int i = -12; i <= 12; ++i) {
        float offset = float(i) * step_size;
        float weight = exp(-0.5 * offset * offset / (sigma * sigma));
        sum += source.SampleLevel(linear_sampler, input.in_uv + params.direction * offset, 0.0) * weight;
        total += weight;
    }
    output.out_color = sum / total;
    return output;
}
