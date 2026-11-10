#include "native.slang"
#define MIRAI_NO_INSTANCES
//! per surface program
//! variant world MIRAI_UI_WORLD=1

#include "material_raster.slang"
#include "display.slang"
#include "studio.slang"
#include "ui_shape.slang"
#include <ui_programs.slang>
#ifdef MIRAI_UI_WORLD
#include "overlay.slang"
[[vk::binding(SLOT_PASS3, 0)]] Texture2D<float4> scene_depth : register(MIRAI_REGISTER(t, SLOT_PASS3), space0); // linear depth of the visible surface
 #endif
struct Params_Block {
    float2 viewport; // of the panel pass: the output, in pixels
    uint shape_base, shape_count;
#ifdef MIRAI_UI_WORLD
    float4 origin;   // w = 1 to hide the panel behind the scene
    float4 right;
    float4 down;
#endif
};
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS4, 0)]] StructuredBuffer<Ui_Shape> ui_shapes : register(MIRAI_REGISTER(t, SLOT_PASS4), space0);
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> font_atlas : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] Texture2D<float4> thumbnails : register(MIRAI_REGISTER(t, SLOT_PASS2), space0); // previews of assets, premultiplied alpha

// A fixed studio, independent of the scene's lights, exposure and GI. Uses the
// same material evaluation, normal mapping and BRDF as scene surfaces, with
// an analytic environment: no offscreen targets, reflection rays or new binds.
float4 material_preview(uint index, float2 coord) {
    float2 xy = (coord * 2.0 - 1.0) / 0.92;
    float radius2 = dot(xy, xy);
    float edge = max(fwidth(radius2), 1e-4);
    float coverage = 1.0 - smoothstep(1.0 - edge, 1.0, radius2);
    float3 n = normalize(float3(xy.x, -xy.y, sqrt(max(1.0 - radius2, 1e-4))));
    float3 position = n;
    float2 uv = float2(atan2(n.x, n.z) / (2.0 * PI) + 0.5, acos(clamp(n.y, -1.0, 1.0)) / PI);
    Material m = material_row(index);
    // The tangent of the sphere along u, the direction its longitude grows in;
    // the bitangent cross(n, tangent) points up its v, towards the top of the image.
    float3 sphere = n;
    float4 tangent = float4(normalize(float3(n.z, 0.0, -n.x) + float3(1e-6, 0.0, 0.0)), 1.0);
    if (material_has(m.textures[MATERIAL_MAP_NORMAL])) {
        n = tangent_frame_normal(n, tangent, material_map_normal(m, uv, uv, float2(0.0), false));
        if (n.z < 0.0) n = normalize(float3(n.xy, 1e-3));
    }
    Mirai_Surface_Context ctx = material_context(position, n, sphere, tangent, uv, uv, float2(0), false);
    ctx.position_dx = ddx(position); ctx.position_dy = ddy(position);
    Material_Sample values = material_sample(m, ctx, float3(1), float3(0), n);
    values.roughness = specular_antialiasing(n, values.roughness);
    if (values.layers.coat > 0.0) values.layers.coat_roughness = specular_antialiasing(values.layers.coat_normal, values.layers.coat_roughness);
    values.emission = studio_emission(sample_emission(values, values.layers.coat_normal.z), values.emission_relative);
    float3 radiance = studio_radiance(position, n, float3(0, 0, 1), m, values);
    if (m.alpha_mode == ALPHA_MASK) coverage *= values.alpha >= m.alpha_cutoff ? 1.0 : 0.0;
    return float4(studio_display(radiance), coverage);
}

// The alpha that, blended in display space as the UI blends, gives what the
// coverage of a glyph gives blended in linear light over the opposite
// luminance: the correction of Skia, without its added contrast. The UI does
// not know what is under the text; with it light text on a dark panel keeps
// its weight. ui.TEXT_GAMMA holds the same gamma for the tests.
static const float TEXT_GAMMA = 2.2;
float glyph_alpha(float coverage, float3 color) {
    float luminance = dot(pow(saturate(color), TEXT_GAMMA), float3(0.2126, 0.7152, 0.0722));
    float src = pow(luminance, 1.0 / TEXT_GAMMA);
    float dst = 1.0 - src;
    if (abs(src - dst) < 1.0 / 256.0) return coverage;
    float blended = pow(luminance * coverage + pow(dst, TEXT_GAMMA) * (1.0 - coverage), 1.0 / TEXT_GAMMA);
    return saturate((blended - dst) / (src - dst));
}

// A node colored by a ui program, cut to its rounded corners.
float4 ui_program_color(float2 p, Ui_Shape shape) {
    float distance = ui_rounded_distance(p, shape.bounds, shape.radii);
    float coverage = saturate(0.5 - distance / max(fwidth(distance), 1e-4));
    Mirai_Ui_Context ctx;
    ctx.size = shape.bounds.zw;
    ctx.uv = (p - shape.bounds.xy) / max(shape.bounds.zw, float2(1e-4));
    ctx.color = shape.fill;
    ctx.time = frame.time.x;
    float4 packed[16];
    for (uint i = 0u; i < 16u; ++i) packed[i] = float4(0.0);
    packed[0] = shape.params;
    float4 color = mirai_evaluate_ui(asuint(shape.stroke.x), packed, ctx);
    return float4(color.rgb, saturate(color.a) * coverage);
}

struct Stage_Input {
    [[vk::location(0)]] float4 in_color : TEXCOORD0;
    [[vk::location(1)]] float2 in_uv : TEXCOORD1;
    [[vk::location(2)]] nointerpolation uint in_material : TEXCOORD2;
#ifdef MIRAI_UI_WORLD
    [[vk::location(3)]] float in_depth : TEXCOORD3;
    float4 pixel : SV_Position;
#endif
};
struct Stage_Output {
    [[vk::location(0)]] float4 out_color : SV_Target0;
};
[shader("fragment")]
Stage_Output main(Stage_Input input) {
    Stage_Output output;
#ifdef MIRAI_UI_WORLD
    if (params.origin.w > 0.5 && overlay_occluded(scene_depth, input.pixel.xy / params.viewport, input.in_depth)) discard;
#endif
    if ((input.in_material & 0x20000000u) != 0u && (input.in_material & 0xc0000000u) == 0u) {
        uint index = input.in_material & 0x1fffffffu;
        output.out_color = index < params.shape_count ? ui_shape_color(input.in_uv, ui_shapes[params.shape_base + index]) * input.in_color : float4(0.0);
    } else if ((input.in_material & 0xf0000000u) == 0x10000000u) {
        uint index = input.in_material & 0x0fffffffu;
        output.out_color = index < params.shape_count ? ui_program_color(input.in_uv, ui_shapes[params.shape_base + index]) * input.in_color : float4(0.0);
    } else if (input.in_material == 1u) {
        float coverage = font_atlas.SampleLevel(linear_sampler, input.in_uv, 0.0).r;
        output.out_color = float4(input.in_color.rgb, input.in_color.a * glyph_alpha(coverage, input.in_color.rgb));
    } else if (input.in_material == 2u) {
        // A preview is shown smaller than it is stored: four taps cover the pixel.
        float2 dx = ddx(input.in_uv) * 0.25;
        float2 dy = ddy(input.in_uv) * 0.25;
        float4 c = thumbnails.SampleLevel(linear_sampler, input.in_uv - dx - dy, 0.0)
               + thumbnails.SampleLevel(linear_sampler, input.in_uv + dx - dy, 0.0)
               + thumbnails.SampleLevel(linear_sampler, input.in_uv - dx + dy, 0.0)
               + thumbnails.SampleLevel(linear_sampler, input.in_uv + dx + dy, 0.0);
        c *= 0.25;
        output.out_color = float4(c.a > 0.0 ? c.rgb / c.a : float3(0.0), c.a) * input.in_color;
    } else if ((input.in_material & 0x80000000u) != 0u) {
        output.out_color = material_preview(input.in_material & 0x7fffffffu, input.in_uv) * input.in_color;
    } else if ((input.in_material & 0x40000000u) != 0u) {
        // An image of the texture table, filtered over the pixel and shown as
        // the display color it stores.
        float4 c = mirai_sample_texture_grad(input.in_material & 0x3fffffffu, input.in_uv, ddx(input.in_uv), ddy(input.in_uv));
        output.out_color = float4(linear_to_srgb(c.rgb), c.a) * input.in_color;
    } else {
        output.out_color = input.in_color;
    }
    return output;
}
