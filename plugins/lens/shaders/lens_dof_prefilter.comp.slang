#include "native.slang"
// The layer of half the size the depth of field gathers from: the mean of
// each 2x2 pixels of the image, and the circle of confusion of the four that
// blurs most, in pixels of the layer, below 0 in front of the focus.
#include "lens.slang"

[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> image : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> linear_depth : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> layer : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    int2 p = int2(id.xy);
    if (any(p >= int2(lens.target.xy))) return;
    int2 size = int2(lens.image.xy);
    float3 color = float3(0.0);
    float nearest = 1e9, farthest = -1e9;
    for (int i = 0; i < 4; i++) {
        int2 q = min(p * 2 + int2(i & 1, i >> 1), size - 1);
        color += image.Load(int3(q, 0)).rgb;
        float coc = lens_coc(lens_distance(linear_depth, (float2(q) + 0.5) * lens.image.zw));
        nearest = min(nearest, coc);
        farthest = max(farthest, coc);
    }
    float coc = -nearest > farthest ? nearest : farthest;
    layer[p] = float4(color * 0.25, coc * 0.5);
}
