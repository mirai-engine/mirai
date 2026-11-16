#include "native.slang"
// The caustic pattern of the frame (water.caustics_record): the light of the
// sun the small waves of a surface gather and spread over a plane
// WATER_CAUSTIC_DEPTH under it, as the area each part of the surface sends it
// to: what lands on a smaller one is brighter. One repeat of the waves
// (WATER_DETAIL_SIZE) across the texture, 1 where the surface is flat.
#define WATER_STAGE
#include "scene.slang"
#include "water.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1
static const float WATER_CAUSTIC_DEPTH = 6.0;

[[vk::binding(SLOT_PASS0, 0)]] [[vk::image_format("r16f")]] RWTexture2D<float> pattern : register(MIRAI_REGISTER(u, SLOT_PASS0), space0);

// Where the light that crosses the surface at xz lands on the plane under it.
float2 landing(float2 xz, float3 sun) {
    float2 slope = water_detail_slope(xz, frame.time.x);
    float3 normal = normalize(float3(-slope.x, 1.0, -slope.y));
    float3 under = refract(-sun, normal, 1.0 / water.ior);
    return xz + under.xz * (WATER_CAUSTIC_DEPTH / max(-under.y, 0.2));
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    if (any(id.xy >= uint2(water.texels))) return;
    float3 sun = frame.sun_direction.w > 0.5 ? frame.sun_direction.xyz : float3(0.0, 1.0, 0.0);
    float step = WATER_DETAIL_SIZE / float(water.texels);
    float2 xz = (float2(id.xy) + 0.5) * step;
    float2 dx = landing(xz + float2(0.5 * step, 0.0), sun) - landing(xz - float2(0.5 * step, 0.0), sun);
    float2 dz = landing(xz + float2(0.0, 0.5 * step), sun) - landing(xz - float2(0.0, 0.5 * step), sun);
    float area = abs(dx.x * dz.y - dx.y * dz.x) / (step * step);
    pattern[id.xy] = clamp(1.0 / max(area, 1e-3), 0.0, 6.0);
}
