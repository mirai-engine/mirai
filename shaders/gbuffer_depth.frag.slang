#include "native.slang"
//! per surface program
#include "raster.slang"

// The clusters of the program list before the visibility of a view
// (render.visibility_pass), with the vertices gbuffer.vert gives them: their
// depth and their linear depth where gbuffer.frag will draw them after it,
// their fade and their mask as there, and no triangle of the visibility
// where they are in front.
struct Stage_Output {
    [[vk::location(0)]] uint2 hit : SV_Target0;
    [[vk::location(1)]] float depth : SV_Target1;
};
[shader("fragment")]
Stage_Output main(Raster_Input input, float4 pixel_position : SV_Position) {
    if ((input.in_flags & RASTER_FLAG_FADING) != 0u && fade_pixel_left(uint2(pixel_position.xy), float(input.in_flags >> RASTER_FADE_SHIFT) / 65535.0)) discard;
    if (!fragment_mask_covers(input, frame.texturing.x)) discard;
    Stage_Output output;
    output.hit = uint2(INVALID, 0u);
    output.depth = fragment_depth(input);
    return output;
}
