#include "native.slang"
// The table of the light past the first order of scattering (Hillaire 2020,
// section 5.5): from each altitude and height of the sun, the light of the
// second order with an isotropic phase over the whole sphere, and the share
// the air sends on again, whose geometric series gives every order after.
// A group of AIR_SCATTERING_DIRECTIONS threads for each texel, a direction each,
// always the same ones. render/air.odin runs it when the air changes.
#include "scene.slang"
#define AIR_SCATTERING_DIRECTIONS 64u
#define AIR_SCATTERING_STEPS 20u
#define MIRAI_GROUP_X 1
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 64

struct Params_Block { Air_Data air; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
// Its texels as half floats, row after row, which render copies into the table.
[[vk::binding(SLOT_PASS0, 0)]] RWStructuredBuffer<uint2> out_table : register(MIRAI_REGISTER(u, SLOT_PASS0), space0);

groupshared float3 second[AIR_SCATTERING_DIRECTIONS];
groupshared float3 again[AIR_SCATTERING_DIRECTIONS];

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 group : SV_GroupID, uint3 thread : SV_GroupThreadID) {
    Air_Data a = params.air;
    uint i = thread.z;
    float2 unit = air_unit((float2(group.xy) + 0.5) / AIR_SCATTERING_SIZE, float2(AIR_SCATTERING_SIZE));
    float mu_sun = unit.x * 2.0 - 1.0;
    float r = lerp(a.planet.x + AIR_GROUND_MARGIN, a.planet.y, saturate(unit.y));
    float3 place = float3(0.0, r, 0.0);
    float3 sun = float3(sqrt(saturate(1.0 - mu_sun * mu_sun)), mu_sun, 0.0);
    // A grid of 8 x 8 cells of equal area over the sphere.
    float2 cell = (float2(float(i % 8u), float(i / 8u)) + 0.5) / 8.0;
    float around = 2.0 * PI * cell.x;
    float mu = 1.0 - 2.0 * cell.y;
    float across = sqrt(saturate(1.0 - mu * mu));
    float3 dir = float3(across * cos(around), mu, across * sin(around));

    float start, end;
    air_segment(a, r, mu, start, end);
    float dt = max(end - start, 0.0) / float(AIR_SCATTERING_STEPS);
    float3 through = float3(1.0), light = float3(0.0), sent = float3(0.0);
    for (uint s = 0u; s < AIR_SCATTERING_STEPS; s++) {
        float3 at = place + dir * (start + dt * (float(s) + 0.5));
        float at_r = length(at);
        Air_Medium m = air_medium(a, at_r - a.planet.x);
        float3 scattering = m.rayleigh + m.mie;
        float3 step = exp(-m.extinction * dt);
        float3 share = (1.0 - step) / max(m.extinction, 1e-12);
        sent += through * scattering * share;
        float3 lit = air_sun(a, at_r, dot(at, sun) / at_r) * scattering / (4.0 * PI);
        light += through * lit * share;
        through *= step;
    }
    if (air_meets_ground(a, r, mu)) {
        float3 at = place + dir * end;
        float mu_ground = dot(normalize(at), sun);
        light += through * a.ground.rgb / PI * air_sun(a, a.planet.x, mu_ground) * max(mu_ground, 0.0);
    }
    second[i] = light;
    again[i] = sent;
    GroupMemoryBarrierWithGroupSync();
    for (uint half = AIR_SCATTERING_DIRECTIONS / 2u; half > 0u; half >>= 1u) {
        if (i < half) {
            second[i] += second[i + half];
            again[i] += again[i + half];
        }
        GroupMemoryBarrierWithGroupSync();
    }
    if (i != 0u) return;
    // The mean over the sphere of each, with the isotropic phase.
    float3 l2 = second[0] / float(AIR_SCATTERING_DIRECTIONS);
    float3 f = again[0] / float(AIR_SCATTERING_DIRECTIONS);
    out_table[group.y * uint(AIR_SCATTERING_SIZE) + group.x] = half_bits(float4(l2 / max(1.0 - f, 1e-4), 1.0));
}
