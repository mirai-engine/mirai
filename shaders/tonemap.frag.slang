#include "native.slang"

#include "scene.slang"
#include "display.slang"
#include "exposure.slang"
[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> hdr_color : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> highlight_mask : register(MIRAI_REGISTER(t, SLOT_PASS1), space0); // premultiplied display color and coverage
[[vk::binding(SLOT_PASS2, 0)]] Texture2D<float4> scene_depth : register(MIRAI_REGISTER(t, SLOT_PASS2), space0);    // linear depth of the visible surface
[[vk::binding(SLOT_PASS3, 0)]] StructuredBuffer<Exposure_State> exposure : register(MIRAI_REGISTER(t, SLOT_PASS3), space0); // of this frame (exposure_adapt.comp)
struct Params_Block {
    float4 outline;   // x = enabled, y = glow radius in window points, zw = window size in points
    float4 bounds;    // conservative highlighted screen bounds (min/max UV), including the neighborhood radius
    float4 wide;      // x = View_Wide: 0 the image of the window, 1 its display encoding kept wide, 2 the exposed linear image
};
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);

struct Stage_Input {
    [[vk::location(0)]] float2 in_uv : TEXCOORD0;
};
struct Stage_Output {
    [[vk::location(0)]] float4 out_color : SV_Target0;
};
// The image is stored with 8 bits a channel, where a smooth gradient shows
// its steps as bands: noise of up to a level either side, the same every
// frame, breaks them into a grain too fine to see. Triangular, from two
// interleaved gradient noises (Jimenez 2014); none on black and white, which
// have no steps to break.
float3 dither(float3 color, float2 pixel) {
    float a = frac(52.9829189 * frac(dot(pixel, float2(0.06711056, 0.00583715))));
    float b = frac(52.9829189 * frac(dot(pixel + float2(41.0, 23.0), float2(0.06711056, 0.00583715))));
    float3 room = saturate(min(color, 1.0 - color) * 255.0);
    return color + (a + b - 1.0) * (1.0 / 255.0) * room;
}

[shader("fragment")]
Stage_Output main(Stage_Input input, float4 pixel_position : SV_Position) {
    Stage_Output output;
    float3 hdr = hdr_color.SampleLevel(linear_sampler, input.in_uv, 0.0).rgb;
    // A wide image has no steps to break and no editor coat.
    if (params.wide.x > 1.5) {
        output.out_color = float4(hdr * exposure[0].exposure * frame.tint.rgb, 1.0);
        return output;
    }
    if (params.wide.x > 0.5) {
        output.out_color = float4(frame.debug_view == 0u ? display_encode(hdr * exposure[0].exposure * frame.tint.rgb) : linear_to_srgb(clamp(hdr, 0.0, 1.0)), 1.0);
        return output;
    }
    float3 color = frame.debug_view == 0u ? display_encode(hdr * exposure[0].exposure * frame.tint.rgb) : linear_to_srgb(clamp(hdr, 0.0, 1.0));
    if (params.outline.x > 0.5 && all(((input.in_uv) >= (params.bounds.xy))) && all(((input.in_uv) <= (params.bounds.zw)))) {
        float4 coat = highlight_mask.SampleLevel(linear_sampler, input.in_uv, 0.0);
        color = color * (1.0 - coat.a) + coat.rgb;
    }
    output.out_color = float4(dither(color, floor(pixel_position.xy)), 1.0);
    return output;
}
