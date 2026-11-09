#include "native.slang"
// The third pass of the direct light of a view (direct_samples.slang), a
// thread for each point of the squares the frame does not take
// (direct_square): what the frame before had where its surface was, from the
// four texels around there of that surface, or where none is, as along an
// edge the jitter of the view moves, from those of the 3x3 around; none (a
// part of -1) where none are; with its linear depth, its normal and the
// radius of its penumbra there, for direct_spread.comp and the next frame.
#define GBUFFER_NORMAL SLOT_PASS0
#include "lighting.slang"
#include "gbuffer.slang"
#include "pixel.slang"
#include "direct_samples.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

// frames: those the samples are taken over (direct_square); the rest, those of
// direct_samples.comp.
struct Params_Block { uint frames; uint samples; float sun_radius; uint scale; uint hard; uint mode; uint pad3; uint pad4; float3 grid_origin; float grid_cell; uint3 grid_size; uint cells; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS4, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> samples_now : register(MIRAI_REGISTER(u, SLOT_PASS4), space0);
[[vk::binding(SLOT_PASS5, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> depth_now : register(MIRAI_REGISTER(u, SLOT_PASS5), space0);
[[vk::binding(SLOT_PASS6, 0)]] Texture2D<float4> samples_before : register(MIRAI_REGISTER(t, SLOT_PASS6), space0);
[[vk::binding(SLOT_PASS7, 0)]] Texture2D<float4> depth_before : register(MIRAI_REGISTER(t, SLOT_PASS7), space0);
[[vk::binding(SLOT_PASS9, 0)]] Texture2D<float4> g_motion : register(MIRAI_REGISTER(t, SLOT_PASS9), space0);

// How far the linear depth of a texel of the frame before may lie from where
// the surface was then, as a share of it and in metres, and the least cosine
// between their normals: where a surface meets another at about the same
// depth, as a box the floor, the normal tells them apart.
#define HISTORY_SHARE 0.03
#define HISTORY_SLACK 0.02
#define HISTORY_FACING 0.9

// Texel t of the frame before by w when it held samples of a surface at the
// linear depth `expected` with that normal, without the mark of a change,
// which was that frame's.
void history_tap(int2 t, float w, float expected, float3 normal, int2 size, inout float4 sum, inout float radius, inout float weight) {
    if (any(t < 0) || any(t >= size)) return;
    float4 then = depth_before.Load(int3(t, 0));
    if (!(then.x > 0.0) || abs(then.x - expected) > HISTORY_SHARE * expected + HISTORY_SLACK) return;
    if (dot(oct_decode(then.yz), normal) < HISTORY_FACING) return;
    float4 texel = samples_before.Load(int3(t, 0));
    if (texel.a < 0.0) return;
    sum += w * float4(texel.rgb, texel.a >= 1.5 ? texel.a - 2.0 : texel.a);
    radius += w * then.w;
    weight += w;
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 group : SV_GroupID, uint index : SV_GroupIndex) {
    uint frames = max(params.frames, 2u);
    int scale = int(max(params.scale, 1u));
    int2 p = direct_group_pixel(group.xy, index, frames, group.z + 1u);
    int2 source = p * scale;
    int2 size = direct_points(scale);
    if (any(p >= size)) return;
    float depth = g_depth.Load(int3(source, 0)).r;
    if (depth_empty(depth)) {
        samples_now[p] = float4(0.0, 0.0, 0.0, 1.0);
        depth_now[p] = float4(0.0);
        return;
    }
    float3 normal = gbuffer_normal(source);
    float2 uv = (float2(source) + 0.5) * frame.inv_resolution;
    Pixel pixel = pixel_at(source, uv, depth);
    // The point of the frame before there.
    float2 at = ((uv + g_motion.Load(int3(source, 0)).rg) * frame.resolution - 0.5) / float(scale);
    int2 low = int2(floor(at));
    float2 f = at - float2(low);
    float expected = previous_depth(source, depth, pixel.position);
    float4 sum = float4(0.0);
    float radius = 0.0, weight = 0.0;
    for (uint i = 0u; i < 4u; i++) {
        int2 o = int2(int(i & 1u), int(i >> 1u));
        float w = (o.x != 0 ? f.x : 1.0 - f.x) * (o.y != 0 ? f.y : 1.0 - f.y) + 1e-4;
        history_tap(low + o, w, expected, normal, size, sum, radius, weight);
    }
    int2 closest = int2(floor(at + 0.5));
    for (int i = 0; i < 9 && weight == 0.0; i++) {
        int2 o = int2(i % 3 - 1, i / 3 - 1);
        if (all(closest + o >= low) && all(closest + o <= low + 1)) continue;
        history_tap(closest + o, 1.0, expected, normal, size, sum, radius, weight);
    }
    samples_now[p] = weight > 0.0 ? sum / weight : float4(0.0, 0.0, 0.0, -1.0);
    depth_now[p] = float4(depth_distance(depth), oct_encode(normal), weight > 0.0 ? radius / weight : 0.0);
}
