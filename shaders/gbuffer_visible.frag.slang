#include "native.slang"
// The surfaces the visibility of a view kept (render.gbuffer_visible_pass):
// of each pixel its triangle (visibility.frag) as the rasterizer would have
// drawn it there. Each attribute gbuffer.vert gives the corners is
// interpolated where the ray of the pixel crosses the triangle, and its
// change to the next pixels is taken from the triangle too
// (MATERIAL_GRADIENTS); then the material and the targets of gbuffer.frag.
// The fade and the mask of the material decided what the visibility kept.
//! variant plain MIRAI_GBUFFER_PLAIN=1
//! variant layers MIRAI_GBUFFER_LAYERS=1
//! constant nested MIRAI_NESTED_PIXELS
#define MATERIAL_GRADIENTS
#include "gbuffer_fragment.slang"
#include "visible_input.slang"
// The instance and the primitive each pixel kept; INVALID where none.
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<uint2> visibility : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);

[shader("fragment")]
Stage_Output main(float4 pixel_position : SV_Position) {
    uint2 hit = visibility.Load(int3(int2(pixel_position.xy), 0));
    if (hit.x == INVALID) discard;
    Raster_Input input = visible_input(hit.x, hit.y, pixel_position.xy);
    return gbuffer_fragment(input, fragment_evaluate(input));
}
