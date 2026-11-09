#include "native.slang"
//! variant hw MIRAI_HW_RT=1
// The contact occlusion of the light the probe volume gives each point (the
// first pixel of each scale x scale), which contact_pixels.comp takes to the
// pixels: the probes are a metre apart and do not see the corner of a table or
// the floor under a wardrobe. A point traces CONTACT_SAMPLES short rays of its
// hemisphere in the world, so what shadows it counts also off the screen or
// behind something nearer the eye. The rays of a point turn by a fixed pattern
// of 4x4 points, all of which contact_pixels.comp averages. Over `frames`, as
// the direct light (direct_square), mode 0 traces the points of the squares
// the frame takes, and mode 1 takes the others from what the frame before had
// where their surface was, tracing those where it had none.
#include "lighting.slang"
#include <extension_hooks.slang>
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1
#define CONTACT_SAMPLES 4u
// Metres: how far from a pixel what shadows it can stand.
#define CONTACT_RADIUS 0.6

// scale: the pixels across a point, 1 or 2.
struct Params_Block { uint scale; uint frames; uint mode; uint pad0; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
#define GBUFFER_NORMAL SLOT_PASS0
#include "gbuffer.slang"
#include "pixel.slang"
#include "direct_samples.slang"
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
// The contact occlusion of each point, its linear depth (0: no surface) and
// its normal: of this frame and of the frame before.
[[vk::binding(SLOT_PASS3, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> out_contact : register(MIRAI_REGISTER(u, SLOT_PASS3), space0);
[[vk::binding(SLOT_PASS6, 0)]] Texture2D<float4> contact_before : register(MIRAI_REGISTER(t, SLOT_PASS6), space0);
[[vk::binding(SLOT_PASS9, 0)]] Texture2D<float4> g_motion : register(MIRAI_REGISTER(t, SLOT_PASS9), space0);

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

// How far the linear depth of a point of the frame before may lie from where
// the surface was then, as a share of it and in metres, and the least cosine
// between their normals, as direct_history.comp.
#define HISTORY_SHARE 0.03
#define HISTORY_SLACK 0.02
#define HISTORY_FACING 0.9

void history_tap(int2 t, float w, float expected, float3 normal, int2 size, inout float sum, inout float weight) {
    if (any(t < 0) || any(t >= size)) return;
    float4 then = contact_before.Load(int3(t, 0));
    if (!(then.y > 0.0) || abs(then.y - expected) > HISTORY_SHARE * expected + HISTORY_SLACK) return;
    if (dot(oct_decode(then.zw), normal) < HISTORY_FACING) return;
    sum += w * then.x;
    weight += w;
}

// What the frame before had where the surface of a point was, from the four
// points around there of that surface, or the 3x3 around; -1 where none is.
float contact_history(int2 source, float depth, float3 position, float3 normal, int2 size, int scale) {
    float2 uv = (float2(source) + 0.5) * frame.inv_resolution;
    float2 at = ((uv + g_motion.Load(int3(source, 0)).rg) * frame.resolution - 0.5) / float(scale);
    int2 low = int2(floor(at));
    float2 f = at - float2(low);
    float expected = previous_depth(source, depth, position);
    float sum = 0.0, weight = 0.0;
    for (uint i = 0u; i < 4u; i++) {
        int2 o = int2(int(i & 1u), int(i >> 1u));
        history_tap(low + o, (o.x != 0 ? f.x : 1.0 - f.x) * (o.y != 0 ? f.y : 1.0 - f.y) + 1e-4, expected, normal, size, sum, weight);
    }
    int2 closest = int2(floor(at + 0.5));
    for (int i = 0; i < 9 && weight == 0.0; i++) {
        int2 o = int2(i % 3 - 1, i / 3 - 1);
        if (all(closest + o >= low) && all(closest + o <= low + 1)) continue;
        history_tap(closest + o, 1.0, expected, normal, size, sum, weight);
    }
    return weight > 0.0 ? sum / weight : -1.0;
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 group : SV_GroupID, uint index : SV_GroupIndex) {
    uint frames = max(params.frames, 1u);
    int scale = int(params.scale);
    int2 q = direct_group_pixel(group.xy, index, frames, params.mode == 0u ? 0u : group.z + 1u);
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
    float contact = params.mode == 0u ? -1.0 : contact_history(p, depth, position, normal, size, scale);
    if (contact < 0.0) contact = contact_occlusion(q, position, normal);
    out_contact[q] = float4(contact, depth_distance(depth), oct_encode(normal));
}
