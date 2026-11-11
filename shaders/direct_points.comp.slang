#include "native.slang"
// The third pass of the direct light of a view (direct_samples.slang): what
// the samples of direct_samples.comp gave each point, over the window of 3x3
// of the pattern on its surface, which holds each place of it once. The light
// of the local lights with nothing in the way is the mean of the window; the
// part of it that got there, and the part of the sun that did, are taken over
// the points of the window where they lie within the noise of the samples.
// direct_spread.comp spreads those parts over their penumbrae, and
// direct_filter.comp takes them to the pixels.
#define GBUFFER_NORMAL SLOT_PASS0
#include "lighting.slang"
#include "gbuffer.slang"
#include "pixel.slang"
#include "direct_samples.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

// scale: the pixels across a point; samples: those of a point.
struct Params_Block { uint scale; uint samples; uint pad0; uint pad1; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
// What direct_samples.comp left at each point: the light of the local lights
// and the part of it that got there; and the part of the sun that did (a),
// below 0 where it gives none.
[[vk::binding(SLOT_PASS4, 0)]] Texture2D<float4> samples_in : register(MIRAI_REGISTER(t, SLOT_PASS4), space0);
[[vk::binding(SLOT_PASS5, 0)]] Texture2D<float4> sun_in : register(MIRAI_REGISTER(t, SLOT_PASS5), space0);
// What the window gives each point: the light of the local lights with nothing
// in the way over the reflectance, and the part of it that got there, plus 2
// where a sample met what changed; and the part of the sun that got there,
// below 0 where it gives none.
[[vk::binding(SLOT_PASS6, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> out_points : register(MIRAI_REGISTER(u, SLOT_PASS6), space0);
[[vk::binding(SLOT_PASS7, 0)]] [[vk::image_format("r16f")]] RWTexture2D<float> out_sun : register(MIRAI_REGISTER(u, SLOT_PASS7), space0);

// The points a group holds, its own and one to each side.
#define FILTER_APRON 1
#define FILTER_TILE (MIRAI_GROUP_X + 2 * FILTER_APRON)
groupshared float4 filter_points[FILTER_TILE * FILTER_TILE];  // w 1 for a surface, 2 for one a nested view drew
groupshared float4 filter_normals[FILTER_TILE * FILTER_TILE]; // w the width of a point there, metres
groupshared float4 filter_samples[FILTER_TILE * FILTER_TILE];
groupshared float filter_suns[FILTER_TILE * FILTER_TILE];

// How far apart in deviations of their noise two parts may lie and still
// weigh alike, and the least deviation of a part, for the half floats.
#define FILTER_ALIKE 2.0
#define FILTER_LEAST 0.01

// Whether a tap `apart` points away lies on the surface of the center: not
// across the opening of a nested view (w), however alike.
bool filter_same(int center, int tap, float apart) {
    if (filter_points[tap].w < 0.5 || filter_points[tap].w != filter_points[center].w) return false;
    return direct_surface(filter_points[center].xyz, filter_normals[center], filter_points[tap].xyz, filter_normals[tap].xyz, apart);
}

// The variance of a part v that n samples found: the binomial of v taken a
// sample towards a half, so that a point whose samples all agree keeps some.
float filter_variance(float v, float n) {
    float guess = (v * n + 0.5) / (n + 1.0);
    return guess * (1.0 - guess) / n + FILTER_LEAST * FILTER_LEAST;
}

float filter_alike(float own, float own_variance, float v, float variance) {
    float apart = v - own;
    return exp(-apart * apart / (2.0 * FILTER_ALIKE * FILTER_ALIKE * (own_variance + variance)));
}

// The part of the local lights (sun false) or of the sun a tap holds, below 0
// where it holds none.
float filter_part(int tap, bool sun) {
    if (sun) return filter_suns[tap];
    float a = filter_samples[tap].a;
    return a >= 1.5 ? a - 2.0 : a;
}

// The part `own` of the center over the points of the window alike in it. A
// pair of taps across the center weighs as the less alike of the two, so that
// a ramp keeps its slope and a border its place.
float filter_window(int2 at, int center, bool sun, float own, float n) {
    float own_variance = filter_variance(own, n);
    float sum = own, total = 1.0;
    for (int y = 0; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            if (y == 0 && x <= 0) continue;
            int ahead = (at.x + x) + (at.y + y) * FILTER_TILE;
            int behind = (at.x - x) + (at.y - y) * FILTER_TILE;
            float2 parts = float2(filter_part(ahead, sun), filter_part(behind, sun));
            bool2 found = bool2(parts.x >= 0.0 && filter_same(center, ahead, 1.0), parts.y >= 0.0 && filter_same(center, behind, 1.0));
            float2 w = float2(found.x ? filter_alike(own, own_variance, parts.x, filter_variance(parts.x, n)) : 0.0, found.y ? filter_alike(own, own_variance, parts.y, filter_variance(parts.y, n)) : 0.0);
            if (found.x && found.y) w = float2(min(w.x, w.y), min(w.x, w.y));
            sum += dot(w, parts);
            total += w.x + w.y;
        }
    }
    return sum / total;
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 group : SV_GroupID, uint3 local : SV_GroupThreadID, uint index : SV_GroupIndex) {
    int scale = int(max(params.scale, 1u));
    int2 size = direct_points(scale);
    int2 corner = int2(group.xy) * int2(MIRAI_GROUP_X, MIRAI_GROUP_Y) - FILTER_APRON;
    for (uint i = index; i < uint(FILTER_TILE * FILTER_TILE); i += uint(MIRAI_GROUP_X * MIRAI_GROUP_Y)) {
        int2 q = corner + int2(int(i % uint(FILTER_TILE)), int(i / uint(FILTER_TILE)));
        float4 point = float4(0.0), normal = float4(0.0), texel = float4(0.0, 0.0, 0.0, 1.0);
        float sun = -1.0;
        if (all(q >= 0) && all(q < size)) {
            int2 source = q * scale;
            float depth = g_depth.Load(int3(source, 0)).r;
            if (!depth_empty(depth)) {
                Pixel pixel = pixel_at(source, (float2(source) + 0.5) * frame.inv_resolution, depth);
                point = float4(pixel.position, depth_nested(depth) ? 2.0 : 1.0);
                normal = float4(gbuffer_normal(source), float(scale) * (frame.footprint.x + frame.footprint.y * depth_distance(depth)));
                texel = samples_in.Load(int3(q, 0));
                sun = sun_in.Load(int3(q, 0)).a;
            }
        }
        filter_points[i] = point;
        filter_normals[i] = normal;
        filter_samples[i] = texel;
        filter_suns[i] = sun;
    }
    GroupMemoryBarrierWithGroupSync();
    int2 p = int2(group.xy) * int2(MIRAI_GROUP_X, MIRAI_GROUP_Y) + int2(local.xy);
    if (any(p >= size)) return;
    int2 at = int2(local.xy) + FILTER_APRON;
    int center = at.x + at.y * FILTER_TILE;
    if (filter_points[center].w < 0.5) {
        out_points[p] = float4(0.0, 0.0, 0.0, 1.0);
        out_sun[p] = -1.0;
        return;
    }
    // The light with nothing in the way over the window of the pattern.
    float3 open = filter_samples[center].rgb;
    float taps = 1.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            int tap = (at.x + x) + (at.y + y) * FILTER_TILE;
            if ((x == 0 && y == 0) || !filter_same(center, tap, float(max(abs(x), abs(y))))) continue;
            open += filter_samples[tap].rgb;
            taps += 1.0;
        }
    }
    float n = float(max(params.samples, 1u));
    bool marked = filter_samples[center].a >= 1.5;
    float part = filter_window(at, center, false, filter_part(center, false), n);
    out_points[p] = float4(finite_or_zero(open / taps), part + (marked ? 2.0 : 0.0));
    float sun = filter_suns[center];
    if (sun >= 0.0) sun = filter_window(at, center, true, sun, n);
    out_sun[p] = sun;
}
