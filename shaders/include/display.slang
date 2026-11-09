// The display transform the project chooses: exposed scene-linear Rec.709
// (middle gray 0.18) to what the display shows, encoded. PBR Neutral is
// computed; ACES 2.0 is read from the LUT display_lut.comp bakes, whose axes
// are log2 of each channel around middle gray (display_shaper): a grading LUT
// in the same space goes before it.
#ifndef MIRAI_DISPLAY_SLANG
#define MIRAI_DISPLAY_SLANG
#include "scene.slang"

// render.DISPLAY_LUT_SIZE.
#define DISPLAY_LUT_SIZE 65
// Stops below and above middle gray the axes of the LUT reach: past what the
// tone scale clamps to for a display of 1000 nits.
#define DISPLAY_STOPS_BELOW 12.0
#define DISPLAY_STOPS_ABOVE 14.5

float3 linear_to_srgb(float3 c) {
    return lerp(c * 12.92, 1.055 * pow(c, float3(1.0 / 2.4)) - 0.055, step(float3(0.0031308), c));
}

// Where a scene-linear value falls along an axis of the LUT, from 0 to 1.
float3 display_shaper(float3 x) {
    return saturate((log2(max(x, 1e-10) / 0.18) + DISPLAY_STOPS_BELOW) / (DISPLAY_STOPS_BELOW + DISPLAY_STOPS_ABOVE));
}

// The scene-linear value at a place along an axis of the LUT.
float3 display_unshaper(float3 at) {
    return 0.18 * exp2(at * (DISPLAY_STOPS_BELOW + DISPLAY_STOPS_ABOVE) - DISPLAY_STOPS_BELOW);
}

// Khronos PBR Neutral: the base color of a material comes out as it is up to
// its highlights, which roll off toward white.
float3 pbr_neutral(float3 color) {
    const float start = 0.8 - 0.04;
    const float desaturation = 0.15;
    float x = min(color.r, min(color.g, color.b));
    float offset = x < 0.08 ? x - 6.25 * x * x : 0.04;
    color -= offset;
    float peak = max(color.r, max(color.g, color.b));
    if (peak < start) return color;
    const float d = 1.0 - start;
    float new_peak = 1.0 - d * d / (peak + d - start);
    color *= new_peak / peak;
    float g = 1.0 - 1.0 / (desaturation * (peak - new_peak) + 1.0);
    return lerp(color, float3(new_peak, new_peak, new_peak), g);
}

#ifndef DISPLAY_LUT_WRITER
[[vk::binding(SLOT_PASS5, 0)]] Texture3D<float4> display_lut : register(MIRAI_REGISTER(t, SLOT_PASS5), space0);

// The encoded color of a preview (thumbnails and the studio of the asset
// documents) for an exposed scene-linear one: PBR Neutral, whatever the
// display transform of the scene.
float3 preview_encode(float3 scene_linear) {
    return linear_to_srgb(saturate(pbr_neutral(max(scene_linear, 0.0))));
}

// The encoded color of the display for an exposed scene-linear one. PBR
// Neutral is computed: a LUT of this size shows its highlights in rings.
float3 display_encode(float3 scene_linear) {
    if ((frame.flags & FRAME_FLAG_NEUTRAL) != 0u) return preview_encode(scene_linear);
    float3 at = (display_shaper(scene_linear) * (DISPLAY_LUT_SIZE - 1.0) + 0.5) / DISPLAY_LUT_SIZE;
    return display_lut.SampleLevel(linear_sampler, at, 0.0).rgb;
}
#endif

#endif
