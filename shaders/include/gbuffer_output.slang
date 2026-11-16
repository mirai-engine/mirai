// The targets of the G-buffer a surface writes, from its evaluated material:
// vis_resolve.frag once per pixel of the visibility target, gbuffer.frag for
// each fragment an extension draws.
#ifndef MIRAI_GBUFFER_OUTPUT_SLANG
#define MIRAI_GBUFFER_OUTPUT_SLANG
#include "raster.slang"
#include "gbuffer.slang"

struct Stage_Output {
    [[vk::location(0)]] float4 g_albedo : SV_Target0;
    [[vk::location(1)]] float4 g_normal : SV_Target1;
    [[vk::location(2)]] float4 g_emission : SV_Target2;
    [[vk::location(3)]] float4 g_motion : SV_Target3;
    [[vk::location(4)]] float g_depth : SV_Target4;
#ifndef MIRAI_GBUFFER_PLAIN
    [[vk::location(5)]] float4 g_specular : SV_Target5;
#endif
#ifdef MIRAI_GBUFFER_LAYERS
    [[vk::location(6)]] uint4 g_layers : SV_Target6;
#endif
#ifdef MIRAI_INSTANCE_IDS
    // The instance index that drew the pixel, + 1: 0 for a surface of the Gbuffer stage of an
    // extension. An instance of a batch writes its index past those of the scene
    // (scene.slang). It goes after the last target of the variant.
#if defined(MIRAI_GBUFFER_LAYERS)
    [[vk::location(7)]] uint g_instance : SV_Target7;
#elif defined(MIRAI_GBUFFER_PLAIN)
    [[vk::location(5)]] uint g_instance : SV_Target5;
#else
    [[vk::location(6)]] uint g_instance : SV_Target6;
#endif
#endif
};

Stage_Output gbuffer_output(Raster_Input input, Fragment f) {
    Stage_Output output;
    float2 current = input.in_clip.xy / input.in_clip.w;
    float2 previous = input.in_prev_clip.xy / input.in_prev_clip.w;
    Material_Layers layers = f.values.layers;
    uint bits = (layers.bits & MATERIAL_LAYER_UNLIT) | (f.values.emission_relative ? GBUFFER_EMISSION_RELATIVE : 0u);
    // The roughness of the lobe traced reflections follow, before specular antialiasing widens it.
    float decided = f.material_roughness;
#ifdef MIRAI_GBUFFER_LAYERS
    bits |= layers.bits;
    output.g_layers = gbuffer_layers_pack(layers);
    if (layers.coat > 0.0) {
        // Reflections trace the lobe that reflects more of what is around:
        // the coat, or the base under it.
        Shading s = shading_surface(input.in_world, f.normal, f.to_camera, f.values.base_color, f.values.metallic, f.values.roughness, f.values.f0, f.values.f90);
        shading_layers(s, layers, f.values.metallic);
        float3 base = environment_reflectance(s) * ((1.0 - s.coat) + s.below_coat * s.coat_through);
        if (coat_reflectance(s).r >= max(base.r, max(base.g, base.b))) {
            bits |= GBUFFER_TRACE_COAT;
            decided = f.coat_roughness;
        }
    }
#endif
    output.g_albedo = float4(clamp(f.values.base_color, 0.0, 1.0), f.values.metallic);
    output.g_normal = gbuffer_normal_pack(f.normal, f.values.roughness, bits);
    output.g_emission = float4(f.values.emission, f.values.occlusion);
#ifndef MIRAI_GBUFFER_PLAIN
    output.g_specular = specular_pack(f.values.f0, f.values.f90);
#endif
    // Screen-space offset to the previous frame in UV units (y down), and the
    // roughness by which traced reflections decide how to trace: the spread of
    // the normal across a pixel grows with distance, and a reflection would
    // change its kind as the camera moves away.
    output.g_motion = float4((previous - current) * float2(0.5, -0.5), decided, 1.0);
    output.g_depth = dot(input.in_world - frame.camera_position.xyz, frame.camera_forward.xyz);
#ifdef MIRAI_INSTANCE_IDS
    output.g_instance = input.in_instance == INVALID ? 0u : input.in_instance + 1u;
#endif
    return output;
}

// The pixels of a nested view keep their linear depth negative and the index
// of the view in the alpha of the motion target.
Stage_Output gbuffer_output_nested(Stage_Output output) {
    output.g_motion.a = 1.0 + float(frame.view_index);
    output.g_depth = -output.g_depth;
    return output;
}
#endif
