#include "native.slang"
//! variant hw MIRAI_HW_RT=1
// The contact occlusion of the light the probe volume gives each point (the
// first pixel of each scale x scale), which contact_pixels.comp takes to the
// pixels: the probes are a metre apart and do not see the corner of a table or
// the floor under a wardrobe. A point traces CONTACT_SAMPLES short rays of its
// hemisphere in the world, so what shadows it counts also off the screen or
// behind something nearer the eye. The rays of a point turn by a fixed pattern
// of 4x4 points, all of which contact_pixels.comp averages.
#include "lighting.slang"
#include <extension_hooks.slang>
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1
#define CONTACT_SAMPLES 4u
// Metres: how far from a pixel what shadows it can stand.
#define CONTACT_RADIUS 0.6

// scale: the pixels across a point, 1 or 2.
struct Params_Block { uint scale; uint pad0; uint pad1; uint pad2; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
#define GBUFFER_NORMAL SLOT_PASS0
#include "gbuffer.slang"
#include "pixel.slang"
#include "direct_samples.slang"
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
// The contact occlusion of each point, its linear depth (0: no surface) and
// its normal.
[[vk::binding(SLOT_PASS3, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> out_contact : register(MIRAI_REGISTER(u, SLOT_PASS3), space0);

float contact_occlusion(int2 q, float3 position, float3 n) {
    float3 t = normalize(abs(n.y) < 0.99 ? cross(n, float3(0.0, 1.0, 0.0)) : cross(n, float3(1.0, 0.0, 0.0)));
    float3 b = cross(n, t);
    // The 4x4 pattern a point's rays turn by, in sixteenths of a turn: by the point, not by
    // where it is, which the jitter of the view moves a little in every frame.
    const uint turns[16] = {0u, 8u, 2u, 10u, 12u, 4u, 14u, 6u, 3u, 11u, 1u, 9u, 15u, 7u, 13u, 5u};
    float turn = float(turns[(uint(q.x) & 3u) + 4u * (uint(q.y) & 3u)]) / 16.0 * 6.2831853;
    float3 origin = position + n * 0.01;
    float hidden = 0.0;
    [loop]
    for (uint i = 0u; i < CONTACT_SAMPLES; i++) {
        float u = (float(i) + 0.5) / float(CONTACT_SAMPLES);
        float phi = float(i) * 2.3999632 + turn;
        float r = sqrt(u);
        float3 dir = t * (r * cos(phi)) + b * (r * sin(phi)) + n * sqrt(1.0 - u);
        Ray_Path path;
        Hit hit = trace_ray(origin, dir, 0.0, CONTACT_RADIUS, true, path);
        // What stands nearer shadows more, so that the edge of the occlusion fades.
        if (hit.instance != INVALID) hidden += 1.0 - hit.t / CONTACT_RADIUS;
    }
    return saturate(1.0 - hidden / float(CONTACT_SAMPLES) * 1.5);
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    int scale = int(params.scale);
    int2 q = int2(id.xy);
    int2 size = direct_points(scale);
    if (any(q >= size)) return;
    int2 p = q * scale;
    float depth = g_depth.Load(int3(p, 0)).r;
    if (depth_empty(depth)) {
        out_contact[q] = float4(1.0, 0.0, 0.0, 0.0);
        return;
    }
    float3 position = pixel_at(p, (float2(p) + 0.5) * frame.inv_resolution, depth).position;
    float3 normal = gbuffer_normal(p);
    out_contact[q] = float4(contact_occlusion(q, position, normal), depth_distance(depth), oct_encode(normal));
}
