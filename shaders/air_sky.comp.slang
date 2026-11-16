#include "native.slang"
// The sky around an eye (Hillaire 2020, section 5.3), into its row of the sky
// table (air.slang): the light of the air and of the planet's ground in each
// direction, which depends only on the altitude of the eye and the height of
// the sun. render/air.odin runs it when one of them or the air changes.
#include "scene.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

struct Params_Block {
    Air_Data air;   // planet.w the altitude of the eye, rows.x its row
    float4 sun;     // x the cosine of the sun from the zenith
};
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
// The texels of the row as half floats, row after row, which render copies into it.
[[vk::binding(SLOT_PASS0, 0)]] RWStructuredBuffer<uint2> out_sky : register(MIRAI_REGISTER(u, SLOT_PASS0), space0);

#define AIR_SKY_STEPS 32u

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    uint2 p = dispatch_id.xy;
    if (any(p >= uint2(AIR_SKY_SIZE))) return;
    Air_Data a = params.air;
    float r = air_eye_radius(a);
    float mu, around;
    air_sky_at(a, r, (float2(p) + 0.5) / AIR_SKY_SIZE, mu, around);
    float across = sqrt(saturate(1.0 - mu * mu));
    float3 dir = float3(across * around, mu, across * sqrt(saturate(1.0 - around * around)));
    float mu_sun = params.sun.x;
    float3 sun = float3(sqrt(saturate(1.0 - mu_sun * mu_sun)), mu_sun, 0.0);
    float3 through;
    float3 light = air_march(a, float3(0.0, r, 0.0), dir, sun, FLT_MAX, AIR_SKY_STEPS, true, through);
    out_sky[p.y * uint(AIR_SKY_SIZE.x) + p.x] = half_bits(float4(light, 1.0));
}
