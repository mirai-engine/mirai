#include "native.slang"
// The part of the light that got there to each point (direct_filter.comp,
// DIRECT_FILTER_POINTS) spread over the points of its surface within the
// radius of its penumbra (direct_samples.comp), along the rows and then, with
// params.axis, along the columns, as far as the parts lie within the noise of
// the samples of the window of the filter: a wide penumbra, which few samples
// leave noisy, comes out smooth; the border of a hard shadow, whose radius is
// small, stays on its points, and a shadow within a wide penumbra, deeper than
// that noise, keeps its depth. A group takes SPREAD_RUN points along the axis
// and DIRECT_SPREAD_MAX more to each side, once, in shared memory.
#define GBUFFER_NORMAL SLOT_PASS0
#include "lighting.slang"
#include "gbuffer.slang"
#include "pixel.slang"
#include "direct_samples.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1
#define SPREAD_RUN 64
#define SPREAD_TILE (SPREAD_RUN + 2 * DIRECT_SPREAD_MAX)

// axis: 0 the rows, 1 the columns; scale: the pixels across a point;
// samples: those of a point; even: 1 while there are shadow maps, to weigh
// every point of the surface within the radius alike, the hard shadows of the
// maps averaged over their penumbrae.
struct Params_Block { uint axis; uint scale; uint samples; uint even; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
// The rows read the part in the points and leave it spread in out_part, plus
// 2 where a sample met what changed, below 0 where a point has none; the
// columns read that and put it back in the points.
[[vk::binding(SLOT_PASS2, 0)]] [[vk::image_format("r16f")]] RWTexture2D<float> out_part : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);
[[vk::binding(SLOT_PASS3, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> out_points : register(MIRAI_REGISTER(u, SLOT_PASS3), space0);
// w: the radius of the penumbra of each point (direct_samples.comp).
[[vk::binding(SLOT_PASS6, 0)]] Texture2D<float4> point_depth : register(MIRAI_REGISTER(t, SLOT_PASS6), space0);

groupshared float4 spread_points[SPREAD_TILE];  // w 1 for a surface, 2 for one a nested view drew
groupshared float4 spread_normals[SPREAD_TILE]; // w the width of a point there, metres
groupshared float spread_parts[SPREAD_TILE];

// How far apart in deviations of their noise two parts may lie and still
// weigh alike, the least deviation of a part, and the points of the window of
// direct_filter.comp whose samples its part holds.
#define SPREAD_ALIKE 3.0
#define SPREAD_LEAST 0.01
#define SPREAD_WINDOW 9.0

// The variance of a part v that n samples found, taken a sample towards a half.
float spread_variance(float v, float n) {
    float guess = (v * n + 0.5) / (n + 1.0);
    return guess * (1.0 - guess) / n + SPREAD_LEAST * SPREAD_LEAST;
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 group : SV_GroupID, uint index : SV_GroupIndex) {
    bool columns = params.axis != 0u;
    int scale = int(max(params.scale, 1u));
    int2 size = direct_points(scale);
    int2 along = columns ? int2(0, 1) : int2(1, 0);
    int2 start = columns ? int2(int(group.x), int(group.y) * SPREAD_RUN) : int2(int(group.x) * SPREAD_RUN, int(group.y));
    for (uint i = index; i < uint(SPREAD_TILE); i += uint(SPREAD_RUN)) {
        int2 q = start + along * (int(i) - DIRECT_SPREAD_MAX);
        float4 point = float4(0.0), normal = float4(0.0);
        float part = -1.0;
        if (all(q >= 0) && all(q < size)) {
            int2 source = q * scale;
            float depth = g_depth.Load(int3(source, 0)).r;
            if (!depth_empty(depth)) {
                Pixel pixel = pixel_at(source, (float2(source) + 0.5) * frame.inv_resolution, depth);
                point = float4(pixel.position, depth_nested(depth) ? 2.0 : 1.0);
                normal = float4(gbuffer_normal(source), float(scale) * (frame.footprint.x + frame.footprint.y * depth_distance(depth)));
                part = columns ? out_part[q] : out_points[q].a;
            }
        }
        spread_points[i] = point;
        spread_normals[i] = normal;
        spread_parts[i] = part;
    }
    GroupMemoryBarrierWithGroupSync();
    int2 p = start + along * int(index);
    if (any(p >= size)) return;
    int center = int(index) + DIRECT_SPREAD_MAX;
    float own = spread_parts[center];
    float result = own;
    if (own >= 0.0 && spread_points[center].w > 0.5) {
        bool marked = own >= 1.5;
        float part = marked ? own - 2.0 : own;
        float radius = min(point_depth.Load(int3(p, 0)).w, float(DIRECT_SPREAD_MAX));
        float sum = part, total = 1.0;
        float n = SPREAD_WINDOW * float(max(params.samples, 1u));
        float own_variance = spread_variance(part, n);
        int reach = int(radius);
        float3 position = spread_points[center].xyz;
        float4 facing = spread_normals[center];
        for (int d = 1; d <= reach; d++) {
            float w = 1.0 - float(d) / (radius + 1.0);
            [unroll]
            for (int side = -1; side <= 1; side += 2) {
                int tap = center + side * d;
                float value = spread_parts[tap];
                // A point across the opening of a nested view lies on another surface, however alike.
                if (value < 0.0 || spread_points[tap].w != spread_points[center].w) continue;
                if (dot(facing.xyz, spread_normals[tap].xyz) < 0.9) continue;
                if (abs(dot(spread_points[tap].xyz - position, facing.xyz)) > 2.0 * facing.w * float(d) + 1e-4) continue;
                float v = value >= 1.5 ? value - 2.0 : value;
                float apart = v - part;
                float alike = params.even != 0u ? w : w * exp(-apart * apart / (2.0 * SPREAD_ALIKE * SPREAD_ALIKE * (own_variance + spread_variance(v, n))));
                sum += alike * v;
                total += alike;
            }
        }
        result = sum / total + (marked ? 2.0 : 0.0);
    }
    if (columns) {
        out_points[p] = float4(out_points[p].rgb, result);
    } else {
        out_part[p] = result;
    }
}
