#include "native.slang"
//! variant glass MIRAI_GLASS_RESOLVE=1
// Filters the traced reflections of this frame, which composite (or, for the
// variant of a layer of glass, the pass that lights the layer) takes for the
// share of each specular lobe that was traced. Nothing of another frame comes
// in: each cell traced the stratum of the lobe of its place in a fixed pattern
// (reflect_pattern_stratum), and a reflection that is not a mirror is the mean
// of the cells of the same surface over a tile of the pattern around the
// pixel, each stratum once. The tile slides with the pixel, so that pixels of
// one block do not take one value, and takes in the relief of a surface (the
// waves of water) that turns its normal less than an edge does.
//
// A mirror traces its own direction. From params.shared_from of roughness the
// rays come one per block of 2x2 pixels, each traced from one pixel of its
// block: the filter weighs a ray by how much the pixel it was traced from
// resembles this one, so a ray is never carried across an edge; a mirror that
// shares its rays takes the blocks around it by how near their pixels are.
#include "scene.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

struct Params_Block { float shared_from; float pad0; float pad1; float pad2; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> traced : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);      // rgb radiance, a hit distance
#define GBUFFER_NORMAL SLOT_PASS1
#include "gbuffer.slang"
#include "pixel.slang"
[[vk::binding(SLOT_PASS2, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS2), space0);
[[vk::binding(SLOT_PASS6, 0)]] Texture2D<float4> g_motion : register(MIRAI_REGISTER(t, SLOT_PASS6), space0);
[[vk::binding(SLOT_PASS8, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> out_filtered : register(MIRAI_REGISTER(u, SLOT_PASS8), space0); // rgb radiance, the distance of the surface
[[vk::binding(SLOT_PASS9, 0)]] Texture2D<float4> traced_shared : register(MIRAI_REGISTER(t, SLOT_PASS9), space0); // the same, one ray per block of 2x2 pixels

// How much a tap of a surface turned away counts, as a power of the cosine.
#define TILE_FACING 8.0

// The roughness the trace pass decided a pixel by: a layer of glass has only
// the one specular antialiasing widened, the opaque G-buffer the material's.
float decided_roughness(int2 p, float4 normal) {
#ifdef MIRAI_GLASS_RESOLVE
    return normal.a + ROUGHNESS_ROUNDING;
#else
    return g_motion.Load(int3(p, 0)).b + ROUGHNESS_ROUNDING;
#endif
}

// The ray that stands for pixel q, and the pixel it was traced from.
float4 traced_at(int2 q, bool by_block, int2 size, out int2 source) {
    source = q;
    if (!by_block) return traced.Load(int3(q, 0));
    int2 cell = q >> 1;
    source = min(cell * 2 + reflect_block_pixel(cell), size - 1);
    return traced_shared.Load(int3(cell, 0));
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    int2 p = int2(dispatch_id.xy);
    int2 size = int2(frame.resolution);
    if (any(((p) >= (size)))) return;
    float4 normal = gbuffer_normal_roughness(p);
    float depth = g_depth.Load(int3(p, 0)).r;
    float roughness = decided_roughness(p, normal);
    if (depth_empty(depth) || reflection_weight(roughness) <= 0.0) {
        out_filtered[p] = float4(0.0);
        return;
    }
    bool mirror = roughness <= MIRROR_ROUGHNESS;
    bool by_block = roughness >= params.shared_from;
    // Where the pixel lies among the cells, and the tile of the pattern around
    // it, its two ends sharing the strata they hold.
    float2 center = by_block ? (float2(p) + 0.5) * 0.5 - 0.5 : float2(p);
    float half_tile = float(REFLECT_PATTERN) * 0.5;
    int reach = !mirror ? REFLECT_PATTERN / 2 + 1 : (by_block ? 1 : 0);
    int2 cell = int2(round(center));
    float3 sum = float3(0.0);
    float weight_sum = 0.0;
    for (int dy = -reach; dy <= reach; dy++) {
        for (int dx = -reach; dx <= reach; dx++) {
            int2 c = cell + int2(dx, dy);
            int2 q = by_block ? c * 2 : c;
            if (any(((q) < (int2(0)))) || any(((q) >= (size)))) continue;
            float w;
            if (!mirror) {
                float2 low = max(float2(c) - 0.5, center - half_tile);
                float2 high = min(float2(c) + 0.5, center + half_tile);
                float2 share = clamp(high - low, 0.0, 1.0);
                w = share.x * share.y;
                if (w <= 0.0) continue;
            }
            int2 source;
            float4 tap = traced_at(q, by_block, size, source);
            if (tap.a < 0.0) continue;
            if (mirror) {
                float2 d = abs(float2(source - p)) / 3.0;
                w = max(1.0 - d.x, 0.0) * max(1.0 - d.y, 0.0);
            }
            if (any(source != p)) {
                float4 tap_normal = gbuffer_normal_roughness(source);
                float tap_depth = g_depth.Load(int3(source, 0)).r;
                w *= pow(max(dot(tap_normal.xyz, normal.xyz), 0.0), TILE_FACING)
                    * exp(-abs(depth_distance(tap_depth) - depth_distance(depth)) / (0.05 * depth_distance(depth) + 1e-4))
                    * exp(-abs(decided_roughness(source, tap_normal) - roughness) * 8.0);
                if (!depth_same_side(tap_depth, depth)) w = 0.0;
            }
            sum += tap.rgb * w;
            weight_sum += w;
        }
    }
    float3 result = weight_sum > 1e-3 ? sum / weight_sum : float3(0.0);
    out_filtered[p] = float4(finite_or_zero(result), depth_distance(depth));
}
