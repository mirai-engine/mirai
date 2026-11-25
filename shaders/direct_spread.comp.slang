#include "native.slang"
// The parts of the light that got there to each point (direct_points.comp),
// that of the local lights and that of the sun, each spread over the points of
// its surface within the radius of its penumbra (direct_samples.comp), along
// the rows and then, with params.axis, along the columns, as far as the parts
// lie within the noise of the samples of the window of the filter: a wide
// penumbra, which few samples leave noisy, comes out smooth; the border of a
// hard shadow, whose radius is small, stays on its points, and a shadow within
// a wide penumbra, deeper than that noise, keeps its depth. A group takes
// SPREAD_RUN points along the axis and DIRECT_SPREAD_MAX more to each side,
// once, in shared memory.
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
// The rows read the parts in the points and leave them spread in out_parts:
// x that of the local lights, plus 2 where a sample met what changed, y that
// of the sun, below 0 where it gives none; the columns read that and put it
// back in the points.
[[vk::binding(SLOT_PASS2, 0)]] [[vk::image_format("rg16f")]] RWTexture2D<float2> out_parts : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);
[[vk::binding(SLOT_PASS3, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> out_points : register(MIRAI_REGISTER(u, SLOT_PASS3), space0);
[[vk::binding(SLOT_PASS4, 0)]] [[vk::image_format("r16f")]] RWTexture2D<float> out_sun : register(MIRAI_REGISTER(u, SLOT_PASS4), space0);
// y: the radius of the penumbra of the sun at each point; w: that of the
// local lights (direct_samples.comp).
[[vk::binding(SLOT_PASS6, 0)]] Texture2D<float4> point_depth : register(MIRAI_REGISTER(t, SLOT_PASS6), space0);

groupshared float4 spread_points[SPREAD_TILE];  // w 1 for a surface, 2 for one a nested view drew
groupshared float4 spread_normals[SPREAD_TILE]; // w the width of a point there, metres
groupshared float2 spread_parts[SPREAD_TILE];
groupshared float2 spread_radii[SPREAD_TILE];   // of the penumbrae of the local lights and of the sun, points

// How far apart in deviations of their noise two parts may lie and still
// weigh alike, the least deviation of a part, and the points of the window of
// direct_points.comp whose samples its part holds.
#define SPREAD_ALIKE 3.0
#define SPREAD_LEAST 0.01
#define SPREAD_WINDOW 9.0

// The variance of a part v that n samples found, taken a sample towards a half.
float spread_variance(float v, float n) {
    float guess = (v * n + 0.5) / (n + 1.0);
    return guess * (1.0 - guess) / n + SPREAD_LEAST * SPREAD_LEAST;
}

// A part without the mark of a change.
float spread_part(float value) { return value >= 1.5 ? value - 2.0 : value; }

// What a tap d points away, whose part is v, weighs for a center whose part
// is `part` and whose penumbra reaches `radius` points.
float spread_weight(float d, float radius, float part, float variance, float v, float n) {
    if (d > radius) return 0.0;
    float w = 1.0 - d / (radius + 1.0);
    if (params.even != 0u) return w;
    float apart = v - part;
    return w * exp(-apart * apart / (2.0 * SPREAD_ALIKE * SPREAD_ALIKE * (variance + spread_variance(v, n))));
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
        float2 parts = float2(-1.0), radii = float2(0.0);
        if (all(q >= 0) && all(q < size)) {
            int2 source = q * scale;
            float depth = g_depth.Load(int3(source, 0)).r;
            if (!depth_empty(depth)) {
                Pixel pixel = pixel_at(source, (float2(source) + 0.5) * frame.inv_resolution, depth);
                point = float4(pixel.position, depth_nested(depth) ? 2.0 : 1.0);
                normal = float4(gbuffer_normal(source), float(scale) * (frame.footprint.x + frame.footprint.y * depth_distance(depth)));
                parts = columns ? out_parts[q] : float2(out_points[q].a, out_sun[q]);
                float4 held = point_depth.Load(int3(q, 0));
                radii = min(float2(held.w, held.y), float2(DIRECT_SPREAD_MAX));
            }
        }
        spread_points[i] = point;
        spread_normals[i] = normal;
        spread_parts[i] = parts;
        spread_radii[i] = radii;
    }
    GroupMemoryBarrierWithGroupSync();
    int2 p = start + along * int(index);
    if (any(p >= size)) return;
    int center = int(index) + DIRECT_SPREAD_MAX;
    float2 own = spread_parts[center];
    float2 result = own;
    if (spread_points[center].w > 0.5) {
        float4 held = point_depth.Load(int3(p, 0));
        // The local lights, then the sun: a part below 0 is none, and spreads none.
        float2 radius = float2(own.x >= 0.0 ? min(held.w, float(DIRECT_SPREAD_MAX)) : 0.0, own.y >= 0.0 ? min(held.y, float(DIRECT_SPREAD_MAX)) : 0.0);
        bool marked = own.x >= 1.5;
        float2 part = float2(spread_part(own.x), own.y);
        float2 sum = part, total = float2(1.0);
        float n = SPREAD_WINDOW * float(max(params.samples, 1u));
        float2 variance = float2(spread_variance(part.x, n), spread_variance(part.y, n));
        float3 position = spread_points[center].xyz;
        float4 facing = spread_normals[center];
        // A tap counts within the wider of the two penumbrae, its own and the
        // center's: the spread is the same both ways, so that a point whose taps
        // found no blocker still takes the penumbra of a neighbour that did.
        for (int d = 1; d <= DIRECT_SPREAD_MAX; d++) {
            [unroll]
            for (int side = -1; side <= 1; side += 2) {
                int tap = center + side * d;
                float2 reach = max(radius, spread_radii[tap]);
                if (float(d) > max(reach.x, reach.y)) continue;
                // A point across the opening of a nested view lies on another surface, however alike.
                if (spread_points[tap].w != spread_points[center].w) continue;
                if (!direct_surface(position, facing, spread_points[tap].xyz, spread_normals[tap].xyz, float(d))) continue;
                float2 value = spread_parts[tap];
                if (value.x >= 0.0 && own.x >= 0.0) {
                    float v = spread_part(value.x);
                    float w = spread_weight(float(d), reach.x, part.x, variance.x, v, n);
                    sum.x += w * v;
                    total.x += w;
                }
                if (value.y >= 0.0 && own.y >= 0.0) {
                    float w = spread_weight(float(d), reach.y, part.y, variance.y, value.y, n);
                    sum.y += w * value.y;
                    total.y += w;
                }
            }
        }
        if (own.x >= 0.0) result.x = sum.x / total.x + (marked ? 2.0 : 0.0);
        if (own.y >= 0.0) result.y = sum.y / total.y;
    }
    if (columns) {
        out_points[p] = float4(out_points[p].rgb, result.x);
        out_sun[p] = result.y;
    } else {
        out_parts[p] = result;
    }
}
