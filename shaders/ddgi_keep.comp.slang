#include "native.slang"
// After the irradiance of the probes chosen this frame: each copies its tile
// into the atlas the next update filters neighbors from (ddgi_irradiance.comp),
// so that a probe never reads the tile of one being written in the same frame
// and a neighbor traced now gives what it held after its last trace.
#include "probe_update.slang"
#define TILE 8
#define MIRAI_GROUP_X TILE
#define MIRAI_GROUP_Y TILE
#define MIRAI_GROUP_Z 1

[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> irradiance : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS3, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> kept : register(MIRAI_REGISTER(u, SLOT_PASS3), space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 group_id : SV_GroupID, uint3 local_id : SV_GroupThreadID) {
    uint slot = group_id.x;
    if (slot >= chosen[0]) return;
    uint probe = chosen[1u + slot];
    uint per_row = frame.volume_atlas.x;
    int2 texel = int2(int(probe % per_row), int(probe / per_row)) * TILE + int2(local_id.xy);
    kept[texel] = irradiance.Load(int3(texel, 0));
}
