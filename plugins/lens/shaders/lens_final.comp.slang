#include "native.slang"
// What the lens does to the whole image, in one pass: the radial distortion
// (each place of the image shows what the lens bends to it, scaled so that
// the image still fills the view), with red farther from the center than
// green and blue nearer by the chromatic aberration; the bloom over it, the
// mean of every level, taken by its share; and the natural falloff towards
// the corners, cos^4 of the angle off the axis, by the vignette.
#include "lens.slang"

[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> image : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> result : register(MIRAI_REGISTER(u, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] Texture2D<float4> bloom : register(MIRAI_REGISTER(t, SLOT_PASS2), space0);

// Where the lens takes what shows at uv from, for a color that bends by
// `bend` times as much as green.
float2 bent(float2 uv, float bend) {
    float2 d = (uv - 0.5) * float2(lens.optics.z, 1.0);
    float r2 = dot(d, d) / (0.25 * (lens.optics.z * lens.optics.z + 1.0));
    return 0.5 + (uv - 0.5) * (lens.optics.w * bend * (1.0 + lens.effects.w * r2));
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    int2 p = int2(id.xy);
    if (any(p >= int2(lens.image.xy))) return;
    float2 uv = (float2(p) + 0.5) * lens.image.zw;
    float4 color = image.Load(int3(p, 0));
    float2 at = uv;
    if (lens.effects.w != 0.0 || lens.optics.x > 0.0) {
        at = bent(uv, 1.0);
        color.rgb = image.SampleLevel(linear_sampler, at, 0.0).rgb;
        if (lens.optics.x > 0.0) {
            color.r = image.SampleLevel(linear_sampler, bent(uv, 1.0 + lens.optics.x), 0.0).r;
            color.b = image.SampleLevel(linear_sampler, bent(uv, 1.0 - lens.optics.x), 0.0).b;
        }
    }
    if (lens.effects.x > 0.0) {
        float2 texel = 1.0 / float2(texture_size(bloom, 0));
        float3 spread = float3(0.0);
        for (int y = -1; y <= 1; y++) {
            for (int x = -1; x <= 1; x++) {
                float w = float((2 - abs(x)) * (2 - abs(y)));
                spread += bloom.SampleLevel(linear_sampler, at + float2(x, y) * texel, 0.0).rgb * w;
            }
        }
        color.rgb = lerp(color.rgb, spread / (16.0 * lens.effects.y), lens.effects.x);
    }
    if (lens.effects.z > 0.0 && lens.optics.y > 0.0) {
        float2 slope = (uv * 2.0 - 1.0) * float2(lens.optics.y * lens.optics.z, lens.optics.y);
        float fall = 1.0 / (1.0 + dot(slope, slope));
        color.rgb *= lerp(1.0, fall * fall, lens.effects.z);
    }
    result[p] = color;
}
