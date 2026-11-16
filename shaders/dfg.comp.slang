#include "native.slang"
// The split-sum table of the specular lobe (dfg_integrate), built once when
// the renderer starts: two half floats a texel, which render copies into the
// entry DFG_TEXTURE of the texture table.
#include "scene.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

[[vk::binding(SLOT_PASS0, 0)]] RWStructuredBuffer<uint> out_table : register(MIRAI_REGISTER(u, SLOT_PASS0), space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    uint2 p = dispatch_id.xy;
    if (any(p >= uint2(DFG_SIZE))) return;
    float2 at = float2(p) / (DFG_SIZE - 1.0);
    float2 dfg = dfg_integrate(max(at.x, 1e-3), at.y);
    out_table[p.y * DFG_SIZE + p.x] = half_bits(saturate(dfg.x)) | (half_bits(saturate(dfg.y)) << 16u);
}
