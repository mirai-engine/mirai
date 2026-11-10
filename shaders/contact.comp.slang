#include "native.slang"
//! variant hw MIRAI_HW_RT=1
// The contact occlusion of the light the probe volume gives each pixel: the
// probes are a metre apart and do not see the corner of a table or the floor
// under a wardrobe. Mode 0 traces
// CONTACT_RAYS short rays of the hemisphere of each pixel in the world, so
// what shadows it counts also off the screen or behind something nearer the
// eye; mode 1 blurs that over the surface, on its side of the opening of a
// nested view, whose pixels it traces from where their surface is in the
// world as those of the view. Nothing in it changes from frame
// to frame: the rays of a pixel turn by a fixed pattern of 4x4 pixels, which
// the blur removes.
#include "lighting.slang"
#include <extension_hooks.slang>
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1
// Metres: how far from a pixel what shadows it can stand.
#define CONTACT_RADIUS 0.6

struct Params_Block { uint mode; uint pad0; uint pad1; uint pad2; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
#define GBUFFER_NORMAL SLOT_PASS0
#include "gbuffer.slang"
#include "pixel.slang"
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
// What mode 0 wrote, for mode 1.
[[vk::binding(SLOT_PASS2, 0)]] Texture2D<float4> raw_contact : register(MIRAI_REGISTER(t, SLOT_PASS2), space0);
[[vk::binding(SLOT_PASS3, 0)]] [[vk::image_format("r16f")]] RWTexture2D<float> out_contact : register(MIRAI_REGISTER(u, SLOT_PASS3), space0);

float contact_occlusion(int2 p, float depth) {
    float2 uv = (float2(p) + 0.5) * frame.inv_resolution;
    Pixel pixel = pixel_at(p, uv, depth);
    float3 n = gbuffer_normal(p);
    float3 t = normalize(abs(n.y) < 0.99 ? cross(n, float3(0.0, 1.0, 0.0)) : cross(n, float3(1.0, 0.0, 0.0)));
    float3 b = cross(n, t);
    // The 4x4 pattern a pixel's rays turn by, in sixteenths of a turn: by the pixel, not by
    // its point, which the jitter of the view moves a little in every frame.
    const uint turns[16] = {0u, 8u, 2u, 10u, 12u, 4u, 14u, 6u, 3u, 11u, 1u, 9u, 15u, 7u, 13u, 5u};
    float turn = float(turns[(uint(p.x) & 3u) + 4u * (uint(p.y) & 3u)]) / 16.0 * 6.2831853;
    float3 origin = pixel.position + n * 0.01;
    float hidden = 0.0;
    [loop]
    for (uint i = 0u; i < CONTACT_RAYS; i++) {
        float u = (float(i) + 0.5) / float(CONTACT_RAYS);
        float phi = float(i) * 2.3999632 + turn;
        float r = sqrt(u);
        float3 dir = t * (r * cos(phi)) + b * (r * sin(phi)) + n * sqrt(1.0 - u);
        Ray_Path path;
        Hit hit = trace_ray(origin, dir, 0.0, CONTACT_RADIUS, true, path);
        // What stands nearer shadows more, so that the edge of the occlusion fades.
        if (hit.instance != INVALID) hidden += 1.0 - hit.t / CONTACT_RADIUS;
    }
    return saturate(1.0 - hidden / float(CONTACT_RAYS) * 1.5);
}

float contact_blur(int2 p, float depth) {
    float own = depth_distance(depth);
    float3 n = gbuffer_normal(p);
    float sum = 0.0, weights = 0.0;
    int2 size = int2(frame.resolution);
    [loop]
    for (int y = -2; y <= 1; y++) {
        [loop]
        for (int x = -2; x <= 1; x++) {
            int2 q = clamp(p + int2(x, y), int2(0), size - 1);
            float d = g_depth.Load(int3(q, 0)).r;
            if (depth_empty(d) || !depth_same_side(d, depth)) continue;
            float w = exp(-abs(depth_distance(d) - own) / max(own * 0.02, 1e-3));
            w *= pow(saturate(dot(gbuffer_normal(q), n)), 8.0);
            sum += raw_contact.Load(int3(q, 0)).r * w;
            weights += w;
        }
    }
    return weights > 0.0 ? sum / weights : 1.0;
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    int2 p = int2(dispatch_id.xy);
    if (any(p >= int2(frame.resolution))) return;
    float depth = g_depth.Load(int3(p, 0)).r;
    if (depth_empty(depth)) {
        out_contact[p] = 1.0;
        return;
    }
    out_contact[p] = params.mode == 0u ? contact_occlusion(p, depth) : contact_blur(p, depth);
}
