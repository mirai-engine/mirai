#include "native.slang"
//! atomics 64
// The raster of the visibility buffer (visibility.slang), with gbuffer.vert
// (visibility): no target, the nearest fragment of each pixel by an atomic
// maximum. What fades and the holes of a masked material are tested here,
// with its alpha alone; the material runs once per pixel in vis_resolve.frag.
#define MIRAI_VISIBILITY
#include "raster.slang"
#include "visibility.slang"

[[vk::binding(SLOT_PASS1, 0)]] RWStructuredBuffer<uint64_t> visibility : register(MIRAI_REGISTER(u, SLOT_PASS1), space0);

[shader("fragment")]
void main(Raster_Input input, float4 pixel : SV_Position) {
    uint2 at = uint2(pixel.xy);
    if ((input.in_flags & RASTER_FLAG_FADING) != 0u && fade_pixel_left(at, float(input.in_flags >> RASTER_FADE_SHIFT) / 65535.0)) return;
    if (!fragment_mask_covers(input, frame.texturing.x)) return;
    InterlockedMax(visibility[visibility_pixel(at)], visibility_pack(pixel.z, input.in_entry));
}
