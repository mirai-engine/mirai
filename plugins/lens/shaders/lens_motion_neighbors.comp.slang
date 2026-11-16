#include "native.slang"
// The longest blur of each tile and the eight around it: what can reach a
// pixel of the tile from outside it.
#include "lens.slang"

[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> tiles : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] [[vk::image_format("rg16f")]] RWTexture2D<float4> neighbors : register(MIRAI_REGISTER(u, SLOT_PASS1), space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    int2 p = int2(id.xy);
    int2 size = int2(lens.target.xy);
    if (any(p >= size)) return;
    float3 best = float3(0.0);
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float2 v = tiles.Load(int3(clamp(p + int2(x, y), int2(0), size - 1), 0)).rg;
            float l = dot(v, v);
            if (l > best.z) best = float3(v, l);
        }
    }
    neighbors[p] = float4(best.xy, 0.0, 0.0);
}
