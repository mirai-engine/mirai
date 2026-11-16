#include "native.slang"
// The aerial perspective of a view (Hillaire 2020, section 5.4): a volume of
// AIR_AERIAL_SIZE² columns over the view and AIR_AERIAL_SLICES slices along
// it to AIR_AERIAL_DISTANCE, each texel the light the air sends to the eye
// from as far as the end of its slice, and what of what lies there crosses it
// (the mean of the channels). render/air.odin runs it when the view, the sun or the air change.
#include "scene.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

struct Params_Block {
    float4x4 from_clip; // the inverse of the view-projection without jitter: a point of clip space from the eye
};
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] [[vk::image_format("rgba16f")]] RWTexture3D<float4> out_aerial : register(MIRAI_REGISTER(u, SLOT_PASS0), space0);

// Steps a slice is marched in.
#define AIR_AERIAL_STEPS 2u

float3 clip_point(float2 ndc, float z) {
    float4 h = mul(params.from_clip, float4(ndc, z, 1.0));
    return h.xyz / h.w;
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    uint2 p = dispatch_id.xy;
    if (any(p >= uint2(AIR_AERIAL_SIZE))) return;
    Air_Data a = frame.air;
    float2 uv = (float2(p) + 0.5) / float(AIR_AERIAL_SIZE);
    float2 ndc = float2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
    float3 dir = normalize(clip_point(ndc, 0.25) - clip_point(ndc, 0.75));
    if (dot(dir, frame.camera_forward.xyz) < 0.0) dir = -dir;
    float3 eye = float3(0.0, air_eye_radius(a), 0.0);
    float3 sun = frame.sun_direction.xyz;
    float3 light = float3(0.0), through = float3(1.0);
    float slice = AIR_AERIAL_DISTANCE / float(AIR_AERIAL_SLICES);
    float dt = slice / float(AIR_AERIAL_STEPS);
    // The middle of each step: what a texel holds ends at the end of its slice.
    for (uint s = 0u; s < AIR_AERIAL_SLICES; s++) {
        for (uint i = 0u; i < AIR_AERIAL_STEPS; i++) {
            float3 at = eye + dir * (slice * float(s) + dt * (float(i) + 0.5));
            Air_Medium m = air_medium(a, length(at) - a.planet.x);
            float3 step = exp(-m.extinction * dt);
            light += through * (air_inscattering(a, m, at, dir, sun) * (1.0 - step) / max(m.extinction, 1e-12));
            through *= step;
        }
        out_aerial[int3(p, int(s))] = float4(light, dot(through, float3(1.0 / 3.0)));
    }
}
