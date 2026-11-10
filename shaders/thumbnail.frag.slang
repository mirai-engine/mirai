//! per surface program
//! variant values MIRAI_THUMBNAIL_VALUES
// impostor: the frames of an impostor (render.impostor_capture).
//! variant impostor MIRAI_THUMBNAIL_IMPOSTOR
#include "native.slang"
#define MIRAI_RASTER_STUDIO
#include "raster.slang"
#include "studio.slang"
#include "display.slang"

struct Stage_Input {
    [[vk::location(0)]] float3 normal : TEXCOORD0;
    [[vk::location(1)]] float4 color : TEXCOORD1; // of the mesh
    [[vk::location(2)]] nointerpolation float3 emission : TEXCOORD2;
    [[vk::location(3)]] float3 world : TEXCOORD3;
    [[vk::location(4)]] float2 uv0 : TEXCOORD4;
    [[vk::location(5)]] float2 uv1 : TEXCOORD5;
    [[vk::location(6)]] nointerpolation uint material : TEXCOORD6;
    [[vk::location(7)]] float4 tangent : TEXCOORD7;
};

#ifdef MIRAI_THUMBNAIL_IMPOSTOR
// A frame of an impostor: its base color and coverage, and the normal in the
// space of the mesh with the depth from the near plane of the frame (0) to
// its far one (1).
struct Stage_Output {
    float4 color : SV_Target0;
    float4 normal : SV_Target1;
};
#endif

#ifdef MIRAI_THUMBNAIL_VALUES
// The views of a capture: the image as the studio shows it, and what the
// material gives at the pixel as it writes it, before the renderer clamps it.
struct Stage_Output {
    float4 display : SV_Target0;
    float4 lit : SV_Target1;      // radiance by the exposure of the studio; a: covered
    float4 albedo : SV_Target2;   // base color and alpha
    float4 surface : SV_Target3;  // roughness, metallic, occlusion
    float4 normal : SV_Target4;   // the normal it writes and its length
    float4 emission : SV_Target5; // in nits, or relative to the exposure
};
#endif

// What the material gives at the pixel as it writes it, before the renderer clamps it.
struct Thumbnail_Values {
    float3 base_color;
    float3 normal;
    float4 surface; // roughness, metallic, occlusion
    float3 emission;
    float alpha;
};

Thumbnail_Values thumbnail_values(Raster_Input raster, Fragment surface) {
    Material m = surface.material;
    float3 n;
    Mirai_Surface_Context ctx = fragment_context(raster, m, surface.to_camera, n);
    Material_Sample sample = material_sample(m, ctx, raster.in_color, raster.in_emission, n);
    Thumbnail_Values v;
    v.base_color = sample.base_color;
    v.normal = n;
    v.surface = float4(sample.roughness, sample.metallic, sample.occlusion, 0.0);
    v.emission = sample.emission;
    v.alpha = sample.alpha;
    Mirai_Surface written = mirai_surface_default(ctx);
    if (m.program_id != 0u && mirai_evaluate_program(m.program_id, materials[m.row].custom_params, ctx, written)) {
        v.base_color = written.base_color * raster.in_color;
        v.normal = written.normal;
        v.surface = float4(written.roughness, written.metallic, written.occlusion, 0.0);
        v.emission = written.emission + raster.in_emission;
        v.alpha = written.alpha;
    }
    return v;
}

[shader("fragment")]
#if defined(MIRAI_THUMBNAIL_VALUES) || defined(MIRAI_THUMBNAIL_IMPOSTOR)
Stage_Output main(Stage_Input input) {
#else
float4 main(Stage_Input input) : SV_Target0 {
#endif
    Raster_Input raster;
    raster.in_normal = input.normal;
    raster.in_color = material_vertex_tint(material_row(input.material), input.color.rgb);
    raster.in_vertex_color = input.color;
    raster.in_emission = input.emission;
    raster.in_world = input.world;
    raster.in_uv = input.uv0;
    raster.in_uv1 = input.uv1;
    raster.in_material = input.material;
    raster.in_tangent = input.tangent;
    raster.in_flags = 0u;
    raster.in_clip = float4(0);
    raster.in_prev_clip = float4(0);
    raster.in_instance = INVALID;
    raster.in_surface = 0u;
    Fragment surface = fragment_evaluate(raster);
    if (!material_covers(surface.material, surface.values.alpha) && surface.material.alpha_mode != ALPHA_BLEND) discard;
    float alpha = surface.material.alpha_mode == ALPHA_BLEND ? saturate(surface.values.alpha) : 1.0;
    if (alpha < 0.05) discard;
#ifdef MIRAI_THUMBNAIL_IMPOSTOR
    // Far away a blended surface is drawn as covering or not.
    if (alpha < 0.5) discard;
    Stage_Output frame_output;
    frame_output.color = float4(saturate(surface.values.base_color), 1.0);
    float depth = (dot(raster.in_world - frame.camera_position.xyz, frame.camera_forward.xyz) - frame.camera_position.w) / max(frame.camera_forward.w - frame.camera_position.w, 1e-6);
    frame_output.normal = float4(normalize(surface.normal) * 0.5 + 0.5, saturate(depth));
    return frame_output;
#else
    // The studio takes render units as nits and exposes them itself.
    bool studio = (frame.flags & FRAME_FLAG_STUDIO) != 0u;
    float3 radiance;
    if (studio) {
        surface.values.emission = studio_emission(surface.values.emission, surface.values.emission_relative);
        radiance = studio_radiance(raster.in_world, surface.normal, surface.to_camera, surface.material, surface.values);
    } else {
        radiance = outdoor_radiance(raster.in_world, surface.normal, surface.to_camera, surface.material, surface.values);
    }
    float exposure = studio ? STUDIO_EXPOSURE : frame.exposure;
#ifdef MIRAI_THUMBNAIL_VALUES
    Thumbnail_Values v = thumbnail_values(raster, surface);
    Stage_Output output;
    output.display = float4(preview_encode(radiance * exposure) * alpha, alpha);
    output.lit = float4(radiance * exposure, 1.0);
    output.albedo = float4(v.base_color, v.alpha);
    output.surface = v.surface;
    output.normal = float4(v.normal, length(v.normal));
    output.emission = float4(v.emission, 0.0);
    return output;
#else
    if (frame.debug_view == DEBUG_NONE) return float4(preview_encode(radiance * exposure) * alpha, alpha);
    Thumbnail_Values v = thumbnail_values(raster, surface);
    float3 shown;
    switch (frame.debug_view) {
    case DEBUG_ALBEDO: shown = linear_to_srgb(saturate(v.base_color)); break;
    case DEBUG_NORMAL: shown = linear_to_srgb(saturate(v.normal * 0.5 + 0.5)); break;
    case DEBUG_ROUGHNESS: shown = linear_to_srgb(float3(saturate(v.surface.x))); break;
    case DEBUG_METALLIC: shown = linear_to_srgb(float3(saturate(v.surface.y))); break;
    case DEBUG_EMISSION: shown = preview_encode((studio ? studio_emission(v.emission, surface.values.emission_relative) : v.emission) * exposure); break;
    default: shown = preview_encode(radiance * exposure); break;
    }
    return float4(shown * alpha, alpha);
#endif
#endif
}
