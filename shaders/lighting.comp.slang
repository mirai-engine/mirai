#include "native.slang"
// unlayered: while no instance with layers is in sight (gbuffer.slang).
//! constant unlayered MIRAI_GBUFFER_NO_LAYERS
// Direct lighting for every visible pixel: the sun, the local lights and
// those of extensions with nothing in their way, times the share of their
// light that reaches the blocks around the pixel (shadow_trace.comp,
// filtered), and the local lights that cast no shadows as they are. The
// output is the radiance the surface reflects, diffuse and
// specular. It traces nothing: a pixel whose light needs rays of its own
// (thin geometry, or an edge, with no block that holds its surface) goes to
// the list lighting_traced.comp walks, so that the registers of a traversal
// do not hold back every pixel. So does the light of the other side of a
// thin surface that lets light through: its blocks hold the shadows of its
// side alone.
#define GBUFFER_ALBEDO SLOT_PASS3
#define GBUFFER_NORMAL SLOT_PASS0
#include "lighting.slang"
#include "gbuffer.slang"
#include <extension_hooks.slang>
#include "pixel.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> out_direct : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);
// The filtered share of light of shadow_trace.comp, one texel per 2x2 pixels,
// and the surface each texel stands for.
[[vk::binding(SLOT_PASS4, 0)]] Texture2D<float4> shadow_share : register(MIRAI_REGISTER(t, SLOT_PASS4), space0);
[[vk::binding(SLOT_PASS5, 0)]] Texture2D<float4> shadow_geometry : register(MIRAI_REGISTER(t, SLOT_PASS5), space0);
// z: the light that reaches the blocks around with nothing in the way, smoothed (shadow_penumbra.comp).
[[vk::binding(SLOT_PASS6, 0)]] Texture2D<float4> shadow_light : register(MIRAI_REGISTER(t, SLOT_PASS6), space0);
// The pixels lighting_traced.comp lights: how many, then each one
// (DIRECT_TRACED_* in lighting.slang); and the size of its dispatch.
[[vk::binding(SLOT_PASS7, 0)]] RWStructuredBuffer<uint> traced : register(MIRAI_REGISTER(u, SLOT_PASS7), space0);
[[vk::binding(SLOT_PASS8, 0)]] RWStructuredBuffer<uint> traced_dispatch : register(MIRAI_REGISTER(u, SLOT_PASS8), space0);

// The light of the pixel with nothing in its way; `total`, roughly how much
// reaches it.
float3 unshadowed_lighting(Shading s, float total) {
    float3 result = local_lighting(s, total);
    if (frame.sun_direction.w >= 0.5) {
        float cosine = dot(s.normal, frame.sun_direction.xyz);
        if (cosine > 0.0) result += sun_light(s.position) * cosine * shading_response(s, frame.sun_direction.xyz);
    }
#ifdef MIRAI_HOOK_LIGHTS
    for (uint i = 0u; i < mirai_extension_light_count(); i++) {
        Extension_Light light;
        if (mirai_extension_light(i, s.position, s.normal, float2(-1.0, 0.0), light)) result += extension_radiance(s, light);
    }
#endif
    return result;
}

// The share of the blocks around the pixel that lie on its surface, and how
// much light reaches them; a < 0 when none holds frames of it, and
// lighting_traced.comp traces the rays of the pixel.
float4 upsample_share(int2 p, float3 n, float depth, out float total) {
    total = 0.0;
    int2 half_size = texture_size(shadow_share, 0);
    float2 hp = float2(p) * 0.5;
    int2 base = int2(floor(hp));
    float2 f = hp - float2(base);
    float3 sum = float3(0.0);
    float weight_sum = 0.0;
    for (int i = 0; i < 4; i++) {
        int2 offset = int2(i & 1, i >> 1);
        int2 q = clamp(base + offset, int2(0), half_size - 1);
        float4 g = shadow_geometry.Load(int3(q, 0));
        if (depth_empty(g.w) || !depth_same_side(g.w, depth) || abs(depth_distance(g.w) - depth_distance(depth)) > 0.05 * depth_distance(depth) || dot(g.xyz, n) < 0.8) continue;
        float4 share = shadow_share.Load(int3(q, 0));
        // A block with no frames holds no share of its surface (shadow_temporal.comp).
        if (share.a < 0.5) continue;
        float w = (offset.x == 1 ? f.x : 1.0 - f.x) * (offset.y == 1 ? f.y : 1.0 - f.y) + 1e-3;
        sum += share.rgb * w;
        total += shadow_light.Load(int3(q, 0)).z * w;
        weight_sum += w;
    }
    if (weight_sum > 0.0) total /= weight_sum;
    return weight_sum > 0.0 ? float4(sum / weight_sum, 1.0) : float4(0.0, 0.0, 0.0, -1.0);
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    int2 p = int2(dispatch_id.xy);
    if (any(((p) >= (int2(frame.resolution))))) return;
    float depth = g_depth.Load(int3(p, 0)).r;
    if (depth_empty(depth)) { out_direct[p] = float4(0.0); return; }
    float2 uv = (float2(p) + 0.5) * frame.inv_resolution;
    Pixel pixel = pixel_at(p, uv, depth);
    Shading s = gbuffer_shading(gbuffer_read(p), pixel);
    float total = 0.0;
    float4 share = upsample_share(p, s.normal, depth, total);
    float3 unshadowed = unshadowed_lighting(s, total);
    // Without a block of its surface, the pixel traces its rays only if some
    // light faces it.
    bool thin = share.a <= 0.0 && luminance(unshadowed) > 0.0;
    bool back = shading_transmits(s);
    // The lights that cast no shadows trace nothing: what lighting_traced.comp
    // lights adds them with the rest.
    out_direct[p] = float4(thin ? float3(0.0) : unshadowed * share.rgb + shadowless_lighting(s, total), 1.0);
    if (thin || back) {
        uint index;
        InterlockedAdd(traced[0], 1u, index);
        uint groups;
        if (index % DIRECT_TRACED_GROUP == 0u) InterlockedAdd(traced_dispatch[0], 1u, groups);
        traced[DIRECT_TRACED_FIRST + index] = uint(p.x) | (uint(p.y) << DIRECT_TRACED_Y_SHIFT) | (thin ? DIRECT_TRACED_FRONT : 0u) | (back ? DIRECT_TRACED_BACK : 0u);
    }
}
