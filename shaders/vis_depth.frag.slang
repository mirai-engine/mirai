#include "native.slang"
//! atomics 64
// The depth of the visibility buffer given to the depth target and to the
// linear depth of the G-buffer, after each phase of its raster: the pyramid
// of the occlusion cull and the forward draws of the G-buffer (programs,
// extensions) test against it. Drawn with a greater-or-equal test, so a
// nearer surface drawn before stays.
#include "visibility.slang"

[[vk::binding(SLOT_PASS1, 0)]] StructuredBuffer<uint64_t> visibility : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);

struct Depth_Output {
    [[vk::location(0)]] float g_depth : SV_Target0;
    float depth : SV_Depth;
};

[shader("fragment")]
Depth_Output main(float4 pixel : SV_Position) {
    uint64_t word = visibility[visibility_pixel(uint2(pixel.xy))];
    if (word == 0ull) discard;
    Depth_Output output;
    output.depth = visibility_depth(word);
    float2 uv = pixel.xy * frame.inv_resolution;
    float4 from_eye = mul(frame.inv_view_proj, float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, output.depth, 1.0));
    output.g_depth = dot(from_eye.xyz / from_eye.w, frame.camera_forward.xyz);
    return output;
}
