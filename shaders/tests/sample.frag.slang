#include "native.slang"

[[vk::binding(1, 0)]] Texture2D<float4> source : register(t1, space0);
[[vk::binding(2, 0)]] SamplerState point_sampler : register(s2, space0);

struct Stage_Input {
    [[vk::location(0)]] float4 in_color : TEXCOORD0;
};
struct Stage_Output {
    [[vk::location(0)]] float4 out_color : SV_Target0;
};
// The texel of the source at the coordinates the vertices carry in their color.
[shader("fragment")]
Stage_Output main(Stage_Input input) {
    Stage_Output output;
    output.out_color = source.SampleLevel(point_sampler, input.in_color.xy, 0.0);
    return output;
}
