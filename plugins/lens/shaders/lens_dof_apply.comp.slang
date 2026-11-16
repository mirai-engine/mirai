#include "native.slang"
// The depth of field over the image: each pixel keeps its own color while its
// circle of confusion is a pixel or less, and takes the gathered layer as it
// grows to three, or where what is nearer blurs over it.
#include "lens.slang"

[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> image : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> result : register(MIRAI_REGISTER(u, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] Texture2D<float4> layer : register(MIRAI_REGISTER(t, SLOT_PASS2), space0);
[[vk::binding(SLOT_PASS3, 0)]] Texture2D<float4> linear_depth : register(MIRAI_REGISTER(t, SLOT_PASS3), space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    int2 p = int2(id.xy);
    if (any(p >= int2(lens.image.xy))) return;
    float2 uv = (float2(p) + 0.5) * lens.image.zw;
    float4 color = image.Load(int3(p, 0));
    float coc = lens_coc(lens_distance(linear_depth, uv));
    float2 layer_size = float2(texture_size(layer, 0));
    float4 blurred = layer.SampleLevel(linear_sampler, (float2(p) + 0.5) * 0.5 / layer_size, 0.0);
    float blur = smoothstep(1.0, 3.0, abs(coc));
    result[p] = float4(lerp(color.rgb, blurred.rgb, blur + blurred.a - blur * blurred.a), color.a);
}
