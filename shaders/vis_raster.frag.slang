#include "native.slang"
// The raster of the visibility target (visibility.slang), with gbuffer.vert
// (visibility, tested): the id of the triangle nearest at each pixel, by the
// hardware depth test. Without `tested`, the clusters whose every pixel is
// there: no discard, so hidden fragments are rejected before they run.
// tested: those of a masked material or of an instance that fades, whose
// pixels its fade and its alpha alone decide, with the alpha of its program
// (surface_coverage.slang) when it has one; nothing it samples is reported to
// the residency of textures. The material runs once per pixel later
// (vis_resolve.frag).
//! variant tested MIRAI_VISIBILITY_TESTED=1
#define MIRAI_VISIBILITY
#ifdef MIRAI_VISIBILITY_TESTED
#include "raster.slang"
#include <surface_coverage.slang>
#endif
#include "visibility.slang"

#ifdef MIRAI_VISIBILITY_TESTED
// Whether a fragment of a tested cluster is there: not left out by its fade,
// and not a hole of its masked material.
bool vis_covers(Raster_Input input, uint2 pixel) {
    if ((input.in_flags & RASTER_FLAG_FADING) != 0u && fade_pixel_left(pixel, float(input.in_flags >> RASTER_FADE_SHIFT) / 65535.0)) return false;
    Material m = fragment_material(input);
    if (m.alpha_mode != ALPHA_MASK) return true;
    float bias = frame.texturing.x;
    float alpha;
    if (m.program_id == 0u) {
        alpha = material_base_color(m, input.in_uv, input.in_uv1, float2(bias), input.in_color, false).a;
    } else {
        float3 normal = fragment_surface_normal(input, m, to_eye(input.in_world), bias);
        Mirai_Surface_Context ctx = fragment_footprint(fragment_instance(material_context(input.in_world, normal, input.in_uv, input.in_uv1, float2(bias), false), input), input);
        ctx.material = m.row;
        float4 parameters[16];
        material_parameters(m.row, ctx.material_values, parameters);
        if (!mirai_program_alpha(m.program_id, parameters, ctx, alpha)) alpha = MATERIAL_DEFAULT_OPACITY;
    }
    return material_covers(m, alpha);
}

[shader("fragment")]
uint main(Raster_Input input, float4 pixel : SV_Position, bool front_facing : SV_IsFrontFace) : SV_Target0 {
    input = raster_facing(input, front_facing);
    if (!vis_covers(input, uint2(pixel.xy))) discard;
    return input.in_id;
}
#else
struct Stage_Input {
    [[vk::location(0)]] nointerpolation uint in_id : TEXCOORD0;
};

[shader("fragment")]
[earlydepthstencil]
uint main(Stage_Input input) : SV_Target0 {
    return input.in_id;
}
#endif
