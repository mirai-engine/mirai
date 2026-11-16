#include "native.slang"
// The transmittance table of the air (air.slang): what crosses it from each
// radius and direction to its top. render/air.odin runs it when the air changes.
#include "scene.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

struct Params_Block { Air_Data air; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
// Its texels as half floats, row after row, which render copies into the table.
[[vk::binding(SLOT_PASS0, 0)]] RWStructuredBuffer<uint2> out_table : register(MIRAI_REGISTER(u, SLOT_PASS0), space0);

#define AIR_TRANSMITTANCE_STEPS 64u

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    uint2 p = dispatch_id.xy;
    if (any(p >= uint2(AIR_TRANSMITTANCE_SIZE))) return;
    Air_Data a = params.air;
    float r, mu;
    air_transmittance_at(a, (float2(p) + 0.5) / AIR_TRANSMITTANCE_SIZE, r, mu);
    float length = air_to_top(a, r, mu);
    float3 depth = float3(0.0);
    // The midpoint of each step: the table is the base the others march on.
    for (uint i = 0u; i < AIR_TRANSMITTANCE_STEPS; i++) {
        float t = length * (float(i) + 0.5) / float(AIR_TRANSMITTANCE_STEPS);
        float at = sqrt(t * t + 2.0 * r * mu * t + r * r);
        depth += air_medium(a, at - a.planet.x).extinction;
    }
    out_table[p.y * uint(AIR_TRANSMITTANCE_SIZE.x) + p.x] = half_bits(float4(exp(-depth * length / float(AIR_TRANSMITTANCE_STEPS)), 1.0));
}
