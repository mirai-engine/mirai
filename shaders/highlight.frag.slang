#include "native.slang"
//! per surface program
#include "raster.slang"

// Editor selection mask: only highlighted instances are drawn, with a depth
// buffer of their own, so the objects around a selection (or in front of it)
// never cut its silhouette. The tonemap pass outlines the edges of this mask.

struct Stage_Output {
    [[vk::location(0)]] float2 mask : SV_Target0;
};
[shader("fragment")]
Stage_Output main(Raster_Input input) {
    Stage_Output output;
    if (!fragment_mask_covers(input, 0.0)) discard;
    output.mask = float2(float(input.in_flags & RASTER_HIGHLIGHT_MASK), dot(input.in_world - frame.camera_position.xyz, frame.camera_forward.xyz));
    return output;
}
