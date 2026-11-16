#include "native.slang"
// The longest blur of each tile of the image (a group per tile).
#include "lens.slang"

[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> motion : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> linear_depth : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] [[vk::image_format("rg16f")]] RWTexture2D<float4> tiles : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);

groupshared float3 longest[MIRAI_GROUP_X * MIRAI_GROUP_Y];

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 group : SV_GroupID, uint3 thread : SV_GroupThreadID, uint index : SV_GroupIndex) {
    int side = int(lens.motion.y);
    int2 corner = int2(group.xy) * side;
    int2 size = int2(lens.image.xy);
    float3 best = float3(0.0);
    for (int y = int(thread.y); y < side; y += MIRAI_GROUP_Y) {
        for (int x = int(thread.x); x < side; x += MIRAI_GROUP_X) {
            int2 q = corner + int2(x, y);
            if (any(q >= size)) continue;
            float2 v = lens_velocity(motion, linear_depth, (float2(q) + 0.5) * lens.image.zw);
            float l = dot(v, v);
            if (l > best.z) best = float3(v, l);
        }
    }
    longest[index] = best;
    GroupMemoryBarrierWithGroupSync();
    for (uint step = (MIRAI_GROUP_X * MIRAI_GROUP_Y) / 2; step > 0; step >>= 1) {
        if (index < step && longest[index + step].z > longest[index].z) longest[index] = longest[index + step];
        GroupMemoryBarrierWithGroupSync();
    }
    if (index == 0) tiles[int2(group.xy)] = float4(longest[0].xy, 0.0, 0.0);
}
