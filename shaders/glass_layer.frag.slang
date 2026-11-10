#include "native.slang"
//! per surface program
// One layer of blended surfaces, for the pass that lights glass once per
// pixel: the nearest one in front of the opaque scene, or the nearest one
// behind the layer before it. The nearest one can also be a back face of the
// solid the camera may be in (params.medium): with nothing of it nearer, the
// camera is inside it and the view leaves it there (GBUFFER_GLASS_EXIT).
// layers: with the layers of its material in a target of their own
// (gbuffer_layers_pack), while some blended instance of the scene has them;
// the others keep only the unlit bit.
//! variant layers MIRAI_GLASS_LAYERS=1
#ifndef MIRAI_GLASS_LAYERS
#define MIRAI_MATERIAL_NO_LAYERS true
#endif
// It reports the levels it samples of each texture (texture_feedback in scene.slang).
#define MIRAI_TEXTURE_FEEDBACK
#include "raster.slang"
#include "gbuffer.slang"
#include "depth.slang"

struct Params_Block { uint peeled; uint medium; uint pad1; uint pad2; }; // medium: instance plus one, 0 none
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> nearer_depth : register(MIRAI_REGISTER(t, SLOT_PASS1), space0); // the layer before this one

struct Stage_Output {
    [[vk::location(0)]] float4 out_albedo : SV_Target0;
    [[vk::location(1)]] float4 out_normal : SV_Target1;
    [[vk::location(2)]] float4 out_emission : SV_Target2;
    [[vk::location(3)]] uint2 out_ids : SV_Target3;
    [[vk::location(4)]] float out_depth : SV_Target4;
    [[vk::location(5)]] float4 out_specular : SV_Target5;
#ifdef MIRAI_GLASS_LAYERS
    [[vk::location(6)]] uint4 out_layers : SV_Target6;
#endif
};
[shader("fragment")]
Stage_Output main(Raster_Input input, float4 pixel_position : SV_Position, bool front_facing : SV_IsFrontFace) {
    Stage_Output output;
    int2 p = int2(pixel_position.xy);
    float depth = fragment_depth(input);
    float opaque = g_depth.Load(int3(p, 0)).r;
    if (!depth_empty(opaque) && depth >= depth_distance(opaque)) discard;
    if (params.peeled != 0u && !behind_layer(depth, nearer_depth.Load(int3(p, 0)).r)) discard;
    uint bits = 0u;
    if (!fragment_blended(input, front_facing)) {
        Material m = material_row(input.in_material);
        if (params.peeled != 0u || input.in_instance + 1u != params.medium || m.alpha_mode != ALPHA_BLEND || !material_solid(m)) discard;
        bits = GBUFFER_GLASS_EXIT;
    }
    Fragment f = fragment_evaluate(input, opaque);
    bits |= f.values.layers.bits;
#ifdef MIRAI_GLASS_LAYERS
    output.out_layers = gbuffer_layers_pack(f.values.layers);
#endif
    output.out_albedo = float4(clamp(f.values.base_color, 0.0, 1.0), f.values.metallic);
    output.out_normal = gbuffer_normal_pack(f.normal, f.values.roughness, bits);
    output.out_emission = float4(f.values.emission, f.values.alpha);
    output.out_ids = uint2(input.in_material, input.in_instance);
    output.out_depth = depth;
    output.out_specular = specular_pack(f.values.f0, f.values.f90);
    return output;
}
