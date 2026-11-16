//! mirai needs nested_views
#include "native.slang"
// The mode of inspection "nested" of the editor, in the Inspect stage of the
// view that shows it: each pixel in the color of the nested view that drew it
// (a portal, a mirror), those of the view itself in grey, shaded by the lit
// image under them.
#include "scene.slang"
#include "pixel.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

[[vk::binding(SLOT_PASS0, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> image : register(MIRAI_REGISTER(u, SLOT_PASS0), space0);

// Four colors, one for each nested view.
static const float3 VIEW_COLORS[4] = {float3(0.9, 0.3, 0.2), float3(0.2, 0.7, 0.3), float3(0.25, 0.45, 0.95), float3(0.9, 0.75, 0.2)};

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    int2 p = int2(dispatch_id.xy);
    if (any(p >= int2(frame.resolution))) return;
    uint view = pixel_view(p);
    float shade = 0.25 + 0.75 * saturate(luminance(image[p].rgb));
    image[p] = float4(view == 0u ? float3(0.5 * shade) : VIEW_COLORS[(view - 1u) & 3u] * shade, 1.0);
}
