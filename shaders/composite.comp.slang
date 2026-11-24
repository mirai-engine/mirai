#include "native.slang"
// unlayered: while no instance with layers is in sight (gbuffer.slang).
//! constant unlayered MIRAI_GBUFFER_NO_LAYERS
// unscattered: while no instance with a subsurface is in sight (subsurface.comp).
//! constant unscattered MIRAI_NO_SUBSURFACE
// Final HDR composition: the direct light, the light around each pixel
// (indirect_compose) and its emission. The irradiance comes from the probe
// volume, darkened by its contact occlusion, or from the reference of the
// indirect light while it is on; the specular lobe takes the probe volume
// around its dominant direction. contact_pixels.comp leaves both lights of the
// probe volume at each pixel; the coat and the other side of what lets light
// through read it here. Under an atmosphere, the image shown takes the air
// between the eye and each pixel (its aerial perspective, aerial.slang).
// A pixel with a subsurface shows the share of its diffuse light its base
// does not spread, and leaves the light a white Lambert reflector there takes
// to subsurface.comp, which spreads it and adds what it reflects of it.
#define GBUFFER_ALBEDO SLOT_PASS0
#define GBUFFER_NORMAL SLOT_PASS1
#define GBUFFER_EMISSION SLOT_PASS2
#include "gbuffer.slang"
#include "grid.slang"
#include "pixel.slang"
#include "probe_light.slang"
#include "aerial.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

[[vk::binding(SLOT_PASS3, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS3), space0);
[[vk::binding(SLOT_PASS4, 0)]] Texture2D<float4> direct_light : register(MIRAI_REGISTER(t, SLOT_PASS4), space0);
// gathered: 1 when the light of the probe volume of each pixel is in indirect_input;
// scattered: 1 when direct_filter.comp left in scatter the direct light of the subsurfaces.
struct Params_Block { uint gathered; uint scattered; uint pad1; uint pad2; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
// With params.gathered, the light of the probe volume around the normal by its
// contact occlusion and around the specular lobe, packed (contact_pixels.comp);
// rgb with FRAME_FLAG_GI_GIVEN: the diffuse indirect light a custom pass of the pipeline gives.
[[vk::binding(SLOT_PASS5, 0)]] Texture2D<float4> indirect_input : register(MIRAI_REGISTER(t, SLOT_PASS5), space0);
// rgb: of a pixel with a subsurface, the light a white Lambert reflector there
// takes, of the lights in, then with the light around, as the air keeps it; a:
// its distance, below 0 for every other pixel.
[[vk::binding(SLOT_PASS6, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> scatter : register(MIRAI_REGISTER(u, SLOT_PASS6), space0);
[[vk::binding(SLOT_PASS7, 0)]] Texture2D<float4> g_motion : register(MIRAI_REGISTER(t, SLOT_PASS7), space0);
[[vk::binding(SLOT_PASS8, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> out_display : register(MIRAI_REGISTER(u, SLOT_PASS8), space0);

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
        float4 sky = float4(sky_shown(sky_dir), 1.0);
        // The editor's reference grid goes behind transparency.
        float3 backdrop = nested ? sky.rgb : ground_grid_background(sky.rgb, uv);
        out_display[p] = float4(backdrop, 1.0);
        if (!MIRAI_NO_SUBSURFACE) scatter[p] = float4(0.0, 0.0, 0.0, -1.0);
        return;
    }
    Pixel pixel = pixel_at(p, uv, depth);
    Gbuffer_Pixel g = gbuffer_read(p);
    Shading s = gbuffer_shading(g, pixel);
    bool scatters = !MIRAI_NO_SUBSURFACE && (g.layers.bits & MATERIAL_LAYER_SUBSURFACE) != 0u;
    float3 diffuse = s.diffuse;
    if (scatters) s.diffuse *= 1.0 - g.layers.subsurface;
    float3 direct = direct_light.Load(int3(p, 0)).rgb;
    bool given = (frame.flags & (FRAME_FLAG_GI | FRAME_FLAG_GI_GIVEN)) == (FRAME_FLAG_GI | FRAME_FLAG_GI_GIVEN);
    bool gathered = params.gathered != 0u;
    uint wants = (s.coat > 0.0 ? INDIRECT_COAT : 0u) | (gathered ? 0u : INDIRECT_SPECULAR | (given ? 0u : INDIRECT_DIFFUSE));
    Indirect light = indirect_lobes(s.position, s.normal, s.view, s, wants, g.occlusion);
    float4 around = indirect_input.Load(int3(p, 0));
    if (given) light.irradiance = around.rgb * frame.indirect;
    if (gathered) {
        light.irradiance = light_unpack(around.x);
        light.radiance = light_unpack(around.y);
    }
    float3 indirect = light.irradiance;
    float3 color = finite_or_zero(direct + indirect_compose(s, light) + g.emission);
    Air_Between air = air_between(uv, pixel.distance);
    color = color * air.kept + air.sent;
    if (!MIRAI_NO_SUBSURFACE) {
        float3 lit = scatters && params.scattered != 0u ? scatter[p].rgb : float3(0.0);
        float3 around = light.irradiance * occlusion_bounced(diffuse, light.occlusion);
        scatter[p] = scatters ? float4(finite_or_zero(lit + around) * air.kept, pixel.distance) : float4(0.0, 0.0, 0.0, -1.0);
    }
    switch (frame.debug_view) {
    case DEBUG_ALBEDO: color = g.base_color; break;
    case DEBUG_NORMAL: color = s.normal * 0.5 + 0.5; break;
    case DEBUG_DIRECT: color = direct; break;
    case DEBUG_INDIRECT: color = indirect; break;
    case DEBUG_PROBES: color = sample_probes(s.position, s.normal, s.view); break;
    case DEBUG_MOTION: color = float3(abs(g_motion.Load(int3(p, 0)).rg) * 50.0, 0.0); break;
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
