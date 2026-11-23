// What the passes of glass share (glass_light.comp, glass.comp and
// glass_inside.comp): the layer they light and, but in glass_light.comp
// (GLASS_LIGHT), the scene behind it and where the view that leaves a solid
// meets it on screen.
#ifndef MIRAI_GLASS_PASS_SLANG
#define MIRAI_GLASS_PASS_SLANG
#include "glass.slang"
#include "gbuffer.slang"
#include <extension_hooks.slang>
#include "depth.slang"

// light_budget: lights of a point of the layer (glass_light.comp);
// max_distance: the farthest the view goes; snapshot: the dispatch copies the
// scene (glass.comp); medium: the instance plus one of the solid the camera
// may be in, 0 none, and medium_row the row of its material; near_top: m over
// and under its top within which each pixel decides whether it starts in it
// (glass_inside.comp).
struct Params_Block { uint light_budget; uint pad; float max_distance; uint snapshot; uint medium; float near_top; uint medium_row; uint pad1; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> layer_albedo : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);   // rgb base color, a metallic
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> layer_normal : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);   // encoded as the normal target of the G-buffer
[[vk::binding(SLOT_PASS2, 0)]] Texture2D<float4> layer_emission : register(MIRAI_REGISTER(t, SLOT_PASS2), space0); // rgb emission, a alpha
[[vk::binding(SLOT_PASS3, 0)]] Texture2D<uint2> layer_ids : register(MIRAI_REGISTER(t, SLOT_PASS3), space0);     // material row, instance
[[vk::binding(SLOT_PASS4, 0)]] Texture2D<float4> layer_depth : register(MIRAI_REGISTER(t, SLOT_PASS4), space0);
[[vk::binding(SLOT_PASS7, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> out_color : register(MIRAI_REGISTER(u, SLOT_PASS7), space0);
[[vk::binding(SLOT_PASS9, 0)]] Texture2D<float4> layer_specular : register(MIRAI_REGISTER(t, SLOT_PASS9), space0); // rgb F0, a F90

// The surface of the layer at a pixel.
Glass glass_of(int2 p, float2 uv, float depth, float4 albedo, float4 normal, float4 emission) {
    Glass g;
    g.position = position_from_depth(uv, depth);
    g.normal = gbuffer_normal_unpack(normal);
    g.view = -view_direction(uv);
    g.base_color = albedo.rgb;
    g.alpha = emission.a;
    g.metallic = albedo.a;
    g.roughness = normal.z;
    g.emission = emission.rgb;
    g.occlusion = 1.0;
    float4 specular = layer_specular.Load(int3(p, 0));
    g.f0 = specular.rgb;
    g.f90 = specular.a;
    // The layers target of the layer is bound in place of the G-buffer's.
    g.layers = gbuffer_layers(p, gbuffer_bits_unpack(normal));
    return g;
}

#ifndef GLASS_LIGHT
[[vk::binding(SLOT_PASS5, 0)]] Texture2D<float4> scene : register(MIRAI_REGISTER(t, SLOT_PASS5), space0);          // everything behind the layer, lit
[[vk::binding(SLOT_PASS8, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS8), space0);        // the opaque scene

// Width of the lobe a rough surface scatters transmitted light into, per unit
// of its GGX alpha.
static const float SCATTER_SPREAD = 0.6;

float opaque_depth(float2 uv) {
    float depth = g_depth.SampleLevel(point_sampler, uv, 0.0).r;
    return depth_empty(depth) ? frame.camera_forward.w : depth_distance(depth);
}

// What lies behind the layer around uv spread over a disc `radius` pixels
// wide, the same every frame: four taps half the disc out, each from the
// level of the scene (glass_levels.comp) about half the disc wide, which
// holds the pixels the layer stands in front of alone; the scene at uv where
// none of those is near.
float3 scene_blurred(float2 uv, float radius) {
    float3 sharp = scene.SampleLevel(linear_sampler, uv, 0.0).rgb;
    if (!(radius >= 0.75)) return sharp;
    uint width, height, levels;
    scene.GetDimensions(0u, width, height, levels);
    if (levels < 2u) return sharp;
    radius = min(radius, 0.08 * frame.resolution.y);
    float level = clamp(log2(radius) - 0.5, 1.0, float(levels - 1u));
    float2 reach = 0.5 * radius * frame.inv_resolution;
    float4 sum = scene.SampleLevel(linear_sampler, uv + float2(0.8, 0.6) * reach, level) + scene.SampleLevel(linear_sampler, uv + float2(-0.6, 0.8) * reach, level)
        + scene.SampleLevel(linear_sampler, uv + float2(-0.8, -0.6) * reach, level) + scene.SampleLevel(linear_sampler, uv + float2(0.6, -0.8) * reach, level);
    if (!(sum.a > 1e-4)) return sharp;
    return lerp(sharp, sum.rgb / sum.a, saturate((radius - 0.75) / 1.25));
}

// The scene around uv as a rough layer at layer_distance shows it: spread over
// a disc that grows with what is between the layer and the scene behind it.
float3 scene_through(float2 uv, float layer_distance, float roughness) {
    if (roughness <= MIRROR_ROUGHNESS) return scene.SampleLevel(linear_sampler, uv, 0.0).rgb;
    float alpha = roughness * roughness;
    float behind = opaque_depth(uv);
    // Pixels a world radius covers at the depth of the scene.
    return scene_blurred(uv, max(behind - layer_distance, 0.0) * alpha * SCATTER_SPREAD / max(frame.footprint.x + frame.footprint.y * max(behind, 1e-3), 1e-9));
}


// A sheet the view does not leave (the surface of water): it shows what the
// pixel holds behind it, moved aside by the part of its refraction the relief
// of the surface gives, against that of its plane alone, by the way through
// the medium. A rippling surface bends what lies under it smoothly, the more
// the deeper it lies; the bend of the plane, alike at every pixel, is left
// out, since it would look for what lies under the sheet where the screen
// holds what stands over it. Where the pixel it lands on holds nothing behind
// the sheet, the pixel shows its own. What it shows is softened over a disc
// that grows with that way, as the scattering of the medium blurs what lies
// deep. travelled: the way through the medium to what the pixel holds.
#define SHEET_SHIFT_MOST 0.04 // of the height of the view
#define SHEET_BLUR 0.03       // metres of blur on what lies behind for each metre of the way to it
struct Sheet_Seen {
    float3 radiance;
    float travelled;
    float3 direction; // the way through the medium
};

// Whether the pixel at uv holds the layer, and so what lies under it: the
// layer is drawn only in front of the opaque scene (glass_layer.frag).
bool sheet_behind(float2 uv) {
    return layer_depth.Load(int3(min(int2(uv * frame.resolution), int2(frame.resolution) - 1), 0)).r > 0.0;
}

Sheet_Seen sheet_through(Material m, Glass g, float2 uv) {
    Sheet_Seen seen;
    float behind = opaque_depth(uv);
    float3 held = position_from_depth(uv, behind);
    seen.travelled = length(held - g.position);
    float ior = m.ior;
    float3 flat = abs(g.normal.y) > 0.3 ? float3(0.0, g.normal.y >= 0.0 ? 1.0 : -1.0, 0.0) : g.normal;
    float3 bent = refract(-g.view, g.normal, 1.0 / ior);
    float3 even = refract(-g.view, flat, 1.0 / ior);
    bool turned = dot(bent, bent) > 0.0 && dot(even, even) > 0.0;
    seen.direction = turned ? bent : -g.view;
    float2 at = uv;
    if (turned) {
        float2 shift = project_uv(held + (bent - even) * seen.travelled) - uv;
        float most = SHEET_SHIFT_MOST * frame.resolution.y;
        float pixels = length(shift * frame.resolution);
        if (pixels > most) shift *= most / pixels;
        float2 moved = clamp(uv + shift, 0.5 * frame.inv_resolution, 1.0 - 0.5 * frame.inv_resolution);
        if (sheet_behind(moved)) at = moved;
    }
    float radius = SHEET_BLUR * seen.travelled / max(frame.footprint.x + frame.footprint.y * max(behind, 1e-3), 1e-9);
    seen.radiance = scene_blurred(at, seen.travelled < material_clear_reach(m) ? radius : 0.0);
    return seen;
}

// What the scene shows of the view that leaves the layer at `exit` along
// `direction`: the screen where the view would be as far beyond `exit` as the
// pixel holds the opaque scene, clamped to its edges. Where that point holds
// something in front of the layer, the pixel shows its own.
float3 scene_refracted(float3 exit, float3 direction, float depth, float roughness, float2 uv) {
    float reach = min(length(position_from_depth(uv, opaque_depth(uv)) - exit), params.max_distance);
    float3 met = exit + direction * reach;
    float2 at = view_depth(met) > 0.0 ? clamp(project_uv(met), 0.5 * frame.inv_resolution, 1.0 - 0.5 * frame.inv_resolution) : uv;
    if (opaque_depth(at) < depth) at = uv;
    return scene_through(at, depth, roughness);
}
#endif

#endif
