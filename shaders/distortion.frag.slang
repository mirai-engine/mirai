#include "native.slang"

// The lit image displaced by what the Blend stage of a side of glass drew into
// the distortion target (render.pass_distortion_begin): each pixel shows the
// copy of the image at its place plus its offset, once however many
// particles overlap there. What lies in front of what displaces the pixel, at
// the place it would show, is not pulled over it: the pixel keeps its own
// color. The second target is the share of the pixel TAA keeps less history
// of, by how far it moved.
#include "common.slang"
#include "depth.slang"

struct Params_Block { float2 size; float2 inv_size; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_LINEAR_SAMPLER, 0)]] SamplerState linear_sampler : register(MIRAI_REGISTER(s, SLOT_LINEAR_SAMPLER), space0);
[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> scene_copy : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> offsets : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] Texture2D<float4> linear_depth : register(MIRAI_REGISTER(t, SLOT_PASS2), space0);

// Offsets below this many pixels leave the pixel as it is.
#define DISTORTION_LEAST_PIXELS 0.01
// Pixels of shift at which the pixel keeps the least of its history.
#define DISTORTION_REACTIVE_PIXELS 4.0
// The share nearer than what displaces a pixel the place it shows may be and still count as behind it.
#define DISTORTION_FRONT 0.02

struct Stage_Input {
    [[vk::location(0)]] float2 in_uv : TEXCOORD0;
};
struct Stage_Output {
    [[vk::location(0)]] float4 out_color : SV_Target0;
    [[vk::location(1)]] float4 out_coverage : SV_Target1;
};

[shader("fragment")]
Stage_Output main(Stage_Input input, float4 pixel_position : SV_Position) {
    Stage_Output output;
    int2 pixel = int2(pixel_position.xy);
    float4 given = offsets.Load(int3(pixel, 0));
    float2 offset = given.xy;
    float shift = length(offset * params.size);
    if (!(shift > DISTORTION_LEAST_PIXELS) || isinf(shift)) discard;
    float2 uv = clamp((float2(pixel) + 0.5) * params.inv_size + offset, 0.5 * params.inv_size, 1.0 - 0.5 * params.inv_size);
    // The depth of what displaces the pixel, by the weights it added; the sky at the place is behind anything.
    float distorter = given.z / max(given.w, 1e-6);
    float there = linear_depth.Load(int3(int2(uv * params.size), 0)).r;
    if (!depth_empty(there) && depth_distance(there) < distorter * (1.0 - DISTORTION_FRONT)) discard;
    output.out_color = scene_copy.SampleLevel(linear_sampler, uv, 0.0);
    output.out_coverage = float4(saturate(shift / DISTORTION_REACTIVE_PIXELS), 0.0, 0.0, 0.0);
    return output;
}
