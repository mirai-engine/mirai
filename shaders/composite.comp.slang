#include "native.slang"
// unlayered: while no instance with layers is in sight (gbuffer.slang).
//! constant unlayered MIRAI_GBUFFER_NO_LAYERS
// Final HDR composition: the direct light, the light around each pixel
// (indirect_compose) and its emission. The irradiance comes from the probe
// volume, darkened by its contact occlusion, or from the reference of the
// indirect light while it is on; the specular lobe takes the filtered
// traced reflection for the share the reflection pass traced, and the probe
// volume around its dominant direction for the rest. Under an atmosphere,
// the image shown takes the air between the eye and each pixel (its aerial
// perspective, air_aerial.comp).
#define GBUFFER_ALBEDO SLOT_PASS0
#define GBUFFER_NORMAL SLOT_PASS1
#define GBUFFER_EMISSION SLOT_PASS2
#include "gbuffer.slang"
#include "grid.slang"
#include "pixel.slang"
#include "probe_light.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

[[vk::binding(SLOT_PASS3, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS3), space0);
[[vk::binding(SLOT_PASS4, 0)]] Texture2D<float4> direct_light : register(MIRAI_REGISTER(t, SLOT_PASS4), space0);
// r: the contact occlusion of the probe volume (contact.comp); rgb with
// FRAME_FLAG_GI_GIVEN: the diffuse indirect light a custom pass of the pipeline gives.
[[vk::binding(SLOT_PASS5, 0)]] Texture2D<float4> indirect_input : register(MIRAI_REGISTER(t, SLOT_PASS5), space0);
[[vk::binding(SLOT_PASS6, 0)]] Texture3D<float4> aerial : register(MIRAI_REGISTER(t, SLOT_PASS6), space0);
[[vk::binding(SLOT_PASS7, 0)]] Texture2D<float4> reflections : register(MIRAI_REGISTER(t, SLOT_PASS7), space0); // rgb the filtered traced reflection
[[vk::binding(SLOT_PASS8, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> out_display : register(MIRAI_REGISTER(u, SLOT_PASS8), space0);

// What lies at distance along the ray of uv seen through the air: its light
// times what crosses, plus what the air sends.
float3 aerial_perspective(float3 color, float2 uv, float distance) {
    float slices = float(AIR_AERIAL_SLICES);
    // A texel holds the air to the end of its slice; nearer than the first, a share of it.
    float w = saturate(distance / AIR_AERIAL_DISTANCE - 0.5 / slices);
    float4 air = aerial.SampleLevel(linear_sampler, float3(uv, w), 0.0);
    float near = saturate(distance * slices / AIR_AERIAL_DISTANCE);
    return color * lerp(1.0, air.a, near) + air.rgb * near * sun_above_air();
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    int2 p = int2(dispatch_id.xy);
    if (any(((p) >= (int2(frame.resolution))))) return;
    float2 uv = (float2(p) + 0.5) * frame.inv_resolution;
    float depth = g_depth.Load(int3(p, 0)).r;
    if (depth_empty(depth)) {
        float3 sky_dir = view_direction(uv);
        bool nested = false;
#ifdef MIRAI_NESTED_VIEWS
        // Nothing was drawn in a pixel of a nested view: its sky is the one that view looks at.
        uint view = pixel_view(p);
        if (view != 0u) {
            sky_dir = transform_vector(frame.nested[view - 1u].to_world, sky_dir);
            nested = true;
        }
#endif
        float4 sky = float4(frame.background.w > 0.5 ? frame.background.rgb : sky_seen(sky_dir), 1.0);
        // The editor's reference grid goes behind transparency.
        float3 backdrop = nested ? sky.rgb : ground_grid_background(sky.rgb, uv);
        out_display[p] = float4(backdrop, 1.0);
        return;
    }
    Pixel pixel = pixel_at(p, uv, depth);
    Gbuffer_Pixel g = gbuffer_read(p);
    float4 motion = pixel_views.Load(int3(p, 0));
    Shading s = gbuffer_shading(g, pixel);
    float3 direct = direct_light.Load(int3(p, 0)).rgb;
    bool given = (frame.flags & (FRAME_FLAG_GI | FRAME_FLAG_GI_GIVEN)) == (FRAME_FLAG_GI | FRAME_FLAG_GI_GIVEN);
    uint wants = INDIRECT_SPECULAR | (s.coat > 0.0 ? INDIRECT_COAT : 0u) | (given ? 0u : INDIRECT_DIFFUSE);
    Indirect light = indirect_lobes(s.position, s.normal, s.view, s, wants, g.occlusion);
    if (given) light.irradiance = indirect_input.Load(int3(p, 0)).rgb * frame.gi_strength;
    else if ((frame.flags & FRAME_FLAG_GI) != 0u) light.irradiance *= indirect_input.Load(int3(p, 0)).r;
    float3 indirect = light.irradiance;
    light.traced_coat = (g.bits & GBUFFER_TRACE_COAT) != 0u;
    light.traced_share = reflection_weight(motion.b + ROUGHNESS_ROUNDING);
    if (light.traced_share > 0.0) light.traced = reflections.Load(int3(p, 0)).rgb;
    float3 color = finite_or_zero(direct + indirect_compose(s, light) + g.emission);
    if (frame.sky_map.y > 0.5 && frame.sun_direction.w > 0.5) color = aerial_perspective(color, uv, pixel.distance);
    switch (frame.debug_view) {
    case DEBUG_ALBEDO: color = g.base_color; break;
    case DEBUG_NORMAL: color = s.normal * 0.5 + 0.5; break;
    case DEBUG_DIRECT: color = direct; break;
    case DEBUG_INDIRECT: color = indirect; break;
    case DEBUG_PROBES: color = sample_probes(s.position, s.normal, s.view); break;
    case DEBUG_MOTION: color = float3(abs(motion.rg) * 50.0, 0.0); break;
    case DEBUG_DEPTH: color = float3(1.0 / (1.0 + depth_distance(depth) * 0.1)); break;
    case DEBUG_ROUGHNESS: color = float3(g.roughness); break;
    case DEBUG_METALLIC: color = float3(g.metallic); break;
    case DEBUG_EMISSION: color = g.emission; break;
    case DEBUG_UNLIT: color = g.base_color + g.emission; break;
    case DEBUG_LIGHTING: color = finite_or_zero(direct + indirect_compose(s, light)); break;
    default: break;
    }
    out_display[p] = float4(color, 1.0);
}
