#include "native.slang"
// The raster of the visibility target (visibility.slang), with
// vis_raster.vert: the word of the triangle nearest at each pixel, by the
// hardware depth test. A primitive of a draw is a triangle listed
// (raster_lists.slang), in order from the first of the draw, and its word is
// read where raster_triangles.comp wrote it. Without `tested`, the clusters
// whose every pixel is there: no discard, so hidden fragments are rejected
// before they run.
// tested: those of a masked material or of an instance that fades, whose
// pixels its fade and the mask map of its material alone decide; no program
// runs. The material runs once per pixel later (vis_resolve.frag).
//! variant tested MIRAI_VISIBILITY_TESTED=1
#define MIRAI_VISIBILITY
#ifdef MIRAI_VISIBILITY_TESTED
#define MATERIAL_RASTER
#endif
#include "visibility.slang"
// The word of each triangle listed (visibility_id).
[[vk::binding(SLOT_PASS2, 0)]] StructuredBuffer<uint> raster_ids : register(MIRAI_REGISTER(t, SLOT_PASS2), space0);

#ifdef MIRAI_VISIBILITY_TESTED
struct Stage_Input {
    [[vk::location(0)]] nointerpolation uint in_first : TEXCOORD0;
    [[vk::location(1)]] nointerpolation uint2 in_material : TEXCOORD1;
    [[vk::location(2)]] nointerpolation uint in_fade : TEXCOORD2;
    [[vk::location(3)]] float2 in_uv : TEXCOORD3;
};

// Whether a fragment of a tested cluster is there: not left out by its fade,
// and not a hole of the mask of its masked material.
bool vis_covers(Stage_Input input, uint2 pixel) {
    if (input.in_fade != 0u && fade_pixel_left(pixel, float(input.in_fade) / 65535.0)) return false;
    Material m = material_row(input.in_material.x, input.in_material.y);
    if (m.alpha_mode != ALPHA_MASK) return true;
    return material_covers(m, material_mask(m, input.in_uv, input.in_uv, float2(frame.texturing.x), false));
}

[shader("fragment")]
uint main(Stage_Input input, float4 pixel : SV_Position, uint primitive : SV_PrimitiveID) : SV_Target0 {
    if (!vis_covers(input, uint2(pixel.xy))) discard;
    return raster_ids[input.in_first + primitive];
}
#else
struct Stage_Input {
    [[vk::location(0)]] nointerpolation uint in_first : TEXCOORD0;
};

[shader("fragment")]
[earlydepthstencil]
uint main(Stage_Input input, uint primitive : SV_PrimitiveID) : SV_Target0 {
    return raster_ids[input.in_first + primitive];
}
#endif
