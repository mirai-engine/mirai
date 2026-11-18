//! mirai needs nested_views
#include "native.slang"
// The farthest depth each column of the grid sees (fog.fog_record): a group
// for each column takes the pixels of the view under it. What nothing was
// drawn on counts as the end of the grid.
#include "fog.slang"
#include "depth.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> linear_depth : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] [[vk::image_format("r32f")]] RWTexture2D<float4> far_out : register(MIRAI_REGISTER(u, SLOT_PASS1), space0);

groupshared float farthest[MIRAI_GROUP_X * MIRAI_GROUP_Y];

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 column : SV_GroupID, uint3 thread : SV_GroupThreadID, uint index : SV_GroupIndex) {
    int2 size = int2(frame.resolution);
    int2 low = int2(column.xy) * size / int2(fog.grid.xy);
    int2 high = (int2(column.xy) + 1) * size / int2(fog.grid.xy);
    float far = 0.0;
    for (int y = low.y + int(thread.y); y < high.y; y += MIRAI_GROUP_Y) {
        for (int x = low.x + int(thread.x); x < high.x; x += MIRAI_GROUP_X) {
            float depth = linear_depth.Load(int3(x, y, 0)).r;
            far = max(far, depth_empty(depth) ? fog.distance : depth_distance(depth));
        }
    }
    farthest[index] = far;
    GroupMemoryBarrierWithGroupSync();
    for (uint half = MIRAI_GROUP_X * MIRAI_GROUP_Y / 2u; half > 0u; half >>= 1u) {
        if (index < half) farthest[index] = max(farthest[index], farthest[index + half]);
        GroupMemoryBarrierWithGroupSync();
    }
    if (index == 0u) far_out[column.xy] = float4(farthest[0], 0.0, 0.0, 0.0);
}
