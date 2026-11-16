#include "native.slang"
#include "scene.slang"
#include "overlay.slang"
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> scene_depth : register(MIRAI_REGISTER(t, SLOT_PASS1), space0); // linear depth of the visible surface
struct Params_Block {
    float2 viewport;  // of the output, in pixels
    uint depth_test;  // 1: lines are hidden behind the scene
    uint pad;
};
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);

struct Stage_Input {
    [[vk::location(0)]] float4 in_color : TEXCOORD0;
    [[vk::location(1)]] float in_depth : TEXCOORD1;
    float4 pixel : SV_Position;
};
struct Stage_Output {
    [[vk::location(0)]] float4 out_color : SV_Target0;
};
[shader("fragment")]
Stage_Output main(Stage_Input input) {
    Stage_Output output;
    if (params.depth_test != 0u && overlay_occluded(scene_depth, input.pixel.xy / params.viewport, input.in_depth)) discard;
    output.out_color = input.in_color;
    return output;
}
