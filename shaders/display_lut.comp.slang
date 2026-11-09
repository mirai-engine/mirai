#include "native.slang"
// Bakes the display transform into the display LUT, one texel a thread: the
// scene-linear Rec.709 color at its place along the axes (display_unshaper)
// through the transform (render.Display_Transform) and its encoding.
#define DISPLAY_LUT_WRITER
#include "display.slang"
#include "aces.slang"
#define MIRAI_GROUP_X 4
#define MIRAI_GROUP_Y 4
#define MIRAI_GROUP_Z 4

// render.Display_Transform.
#define DISPLAY_TRANSFORM_NEUTRAL 0u

struct Params_Block { float4 red_green; float4 blue_white; float peak; uint transform; uint pad1; uint pad2; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] [[vk::image_format("rgba16f")]] RWTexture3D<float4> out_lut : register(MIRAI_REGISTER(u, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] StructuredBuffer<float4> tables : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    if (any(dispatch_id >= uint3(DISPLAY_LUT_SIZE))) return;
    float3 scene = display_unshaper(float3(dispatch_id) / (DISPLAY_LUT_SIZE - 1.0));
    if (params.transform == DISPLAY_TRANSFORM_NEUTRAL) {
        out_lut[dispatch_id] = float4(linear_to_srgb(saturate(pbr_neutral(scene))), 1.0);
        return;
    }
    Primaries display = primaries_make(params.red_green.xy, params.red_green.zw, params.blue_white.xy, params.blue_white.zw);
    Aces_Params a = aces_params(params.peak, display);
    float3 ap0 = mul(rgb_to_rgb_adapted(primaries_rec709(), primaries_ap0()), scene);
    float3 shown = aces_output(ap0, tables, a) * (ACES_REFERENCE_LUMINANCE / params.peak);
    out_lut[dispatch_id] = float4(linear_to_srgb(saturate(shown)), 1.0);
}
