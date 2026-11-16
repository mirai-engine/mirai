#include "native.slang"
// Motion blur (McGuire 2012, with the weights of Jimenez 2014): each pixel
// looks along the longest blur around it and along its own, by turns, on both
// sides. A sample counts where the blur of whichever of the two is in front
// reaches the other: what moves blurs over what stands behind it, and what
// stands still in front of something that moves stays sharp. What the samples
// do not cover keeps the color of the pixel. The samples are no farther apart
// than LENS_MOTION_SPACING pixels, up to LENS_MOTION_STEPS on each side, and
// fall in the same places every frame: the image after the temporal resolve
// has no history to smooth a pattern that changes.
#include "lens.slang"

#define LENS_MOTION_STEPS 32
#define LENS_MOTION_SPACING 1.0

[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> image : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> result : register(MIRAI_REGISTER(u, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] Texture2D<float4> motion : register(MIRAI_REGISTER(t, SLOT_PASS2), space0);
[[vk::binding(SLOT_PASS3, 0)]] Texture2D<float4> linear_depth : register(MIRAI_REGISTER(t, SLOT_PASS3), space0);
[[vk::binding(SLOT_PASS4, 0)]] Texture2D<float4> neighbors : register(MIRAI_REGISTER(t, SLOT_PASS4), space0);

// Which of the two is in front: x the sample is behind the pixel, y in front;
// they blend over a twentieth of the distance of the pixel.
float2 depth_order(float center, float sample) {
    float k = 1.0 / max(0.05 * min(center, sample), 0.01);
    float d = clamp((sample - center) * k, -1.0, 1.0);
    return saturate(0.5 + float2(d, -d));
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    int2 p = int2(id.xy);
    if (any(p >= int2(lens.image.xy))) return;
    float4 color = image.Load(int3(p, 0));
    float2 around = neighbors.Load(int3(min(p / int(lens.motion.y), int2(lens.motion.zw) - 1), 0)).rg;
    float around_length = length(around);
    if (around_length < 0.5) {
        result[p] = color;
        return;
    }
    float2 uv = (float2(p) + 0.5) * lens.image.zw;
    float2 own = lens_velocity(motion, linear_depth, uv);
    float own_length = length(own);
    float center = lens_distance(linear_depth, uv);
    int steps = clamp(int(ceil(around_length / LENS_MOTION_SPACING)), 2, LENS_MOTION_STEPS);
    float3 sum = float3(0.0);
    float weight = 0.0;
    for (int i = 0; i < steps; i++) {
        float2 along = (i & 1) != 0 && own_length > 0.5 ? own : around;
        float t = (float(i) + 0.5) / float(steps);
        for (int side = -1; side <= 1; side += 2) {
            float2 offset = along * (t * float(side));
            float2 at = uv + offset * lens.image.zw;
            float3 s = image.SampleLevel(linear_sampler, at, 0.0).rgb;
            float reach = length(lens_velocity(motion, linear_depth, at));
            float distance = length(offset);
            float2 order = depth_order(center, lens_distance(linear_depth, at));
            float2 spread = saturate(float2(own_length, reach) - max(distance - 1.0, 0.0));
            float w = dot(order, spread);
            sum += s * w;
            weight += w;
        }
    }
    float count = 2.0 * float(steps);
    result[p] = float4((sum + color.rgb * max(count - weight, 0.0)) / count, color.a);
}
