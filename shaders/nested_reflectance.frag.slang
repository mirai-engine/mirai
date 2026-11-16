#include "native.slang"
// The reflectance target of a view whose G-buffer was drawn without it, which
// its nested views need (render/frame.odin, nested_targets): each pixel drawn
// so far reflects what its albedo and metallic give, as pixel_reflectance of
// scene.slang reads it without the target.
#include "scene.slang"

[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> g_albedo : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);

[shader("fragment")]
float4 main(float4 pixel : SV_Position) : SV_Target0 {
    float4 albedo = g_albedo.Load(int3(int2(pixel.xy), 0));
    return specular_pack(specular_f0(albedo.rgb, albedo.a), 1.0);
}
