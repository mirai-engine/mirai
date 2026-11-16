#include "native.slang"
// The farthest depth that a column of the grid and the two around it on each
// side see (fog.fog_record): what the light of the column is read with, by
// the filter of fog_integrate.comp and between columns by fog_apply.comp.
#include "fog.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> column_far : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] [[vk::image_format("r32f")]] RWTexture2D<float4> reach_out : register(MIRAI_REGISTER(u, SLOT_PASS1), space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    if (any(id.xy >= fog.grid.xy)) return;
    float far = 0.0;
    for (int y = -2; y <= 2; y++) {
        for (int x = -2; x <= 2; x++) {
            int2 at = clamp(int2(id.xy) + int2(x, y), int2(0), int2(fog.grid.xy) - 1);
            far = max(far, column_far.Load(int3(at, 0)).r);
        }
    }
    reach_out[id.xy] = float4(far, 0.0, 0.0, 0.0);
}
