#include "native.slang"
// The widest circle of confusion in front of the focus of each tile of the
// layer (a group per tile): how far the foreground around a pixel can blur
// over it.
#include "lens.slang"

[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> layer : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] [[vk::image_format("r16f")]] RWTexture2D<float4> tiles : register(MIRAI_REGISTER(u, SLOT_PASS1), space0);

groupshared float widest[MIRAI_GROUP_X * MIRAI_GROUP_Y];

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 group : SV_GroupID, uint3 thread : SV_GroupThreadID, uint index : SV_GroupIndex) {
    int2 size = int2(lens.target.xy);
    float front = 0.0;
    for (int y = 0; y < LENS_DOF_TILE; y += MIRAI_GROUP_Y) {
        for (int x = 0; x < LENS_DOF_TILE; x += MIRAI_GROUP_X) {
            int2 q = int2(group.xy) * LENS_DOF_TILE + int2(thread.xy) + int2(x, y);
            if (all(q < size)) front = max(front, -layer.Load(int3(q, 0)).a);
        }
    }
    widest[index] = front;
    GroupMemoryBarrierWithGroupSync();
    for (uint step = (MIRAI_GROUP_X * MIRAI_GROUP_Y) / 2; step > 0; step >>= 1) {
        if (index < step) widest[index] = max(widest[index], widest[index + step]);
        GroupMemoryBarrierWithGroupSync();
    }
    if (index == 0) tiles[int2(group.xy)] = float4(widest[0], 0.0, 0.0, 0.0);
}
