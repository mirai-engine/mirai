#include "native.slang"
//! per surface program
// plain: without the reflectance target, for a scene of default dielectrics
// (pixel_reflectance in scene.slang). layers: with the reflectance and the
// layers targets, while an instance whose materials have layers is in sight;
// the others keep only the unlit bit of the layers.
//! variant plain MIRAI_GBUFFER_PLAIN=1
//! variant layers MIRAI_GBUFFER_LAYERS=1
// Both are variants: a stage declares its targets, and a pipeline has them all.
// Behind a constant, Vulkan warns of a write to an absent target at each draw,
// and the Metal source, made once, writes a color the pipeline has no target for.
// nested: the pixels of a nested view, which keep their linear depth negative
// and the index of the view in the alpha of the motion target.
//! constant nested MIRAI_NESTED_PIXELS
#ifndef MIRAI_GBUFFER_LAYERS
// Without the layers target no instance with layers is in sight.
#define MIRAI_MATERIAL_NO_LAYERS true
#endif
// It reports the levels it samples of each texture (texture_feedback in scene.slang).
#define MIRAI_TEXTURE_FEEDBACK
#include "gbuffer_output.slang"

[shader("fragment")]
Stage_Output main(Raster_Input input, float4 pixel_position : SV_Position) {
    if ((input.in_flags & RASTER_FLAG_FADING) != 0u && fade_pixel_left(uint2(pixel_position.xy), float(input.in_flags >> RASTER_FADE_SHIFT) / 65535.0)) discard;
    Fragment f = fragment_evaluate(input);
    // Blended surfaces are drawn after the scene is lit; the holes of a masked one show what is behind.
    if (!material_covers(f.material, f.values.alpha)) discard;
    Stage_Output output = gbuffer_output(input, f);
    if (MIRAI_NESTED_PIXELS) {
        output.g_motion.a = 1.0 + float(frame.view_index);
        output.g_depth = -output.g_depth;
    }
    return output;
}
