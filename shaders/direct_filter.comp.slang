#include "native.slang"
//! variant hw MIRAI_HW_RT=1
//! variant unlayered MIRAI_GBUFFER_NO_LAYERS=1
//! variant hw_unlayered MIRAI_HW_RT=1 MIRAI_GBUFFER_NO_LAYERS=1
// The last pass of the direct light of a view (direct_samples.slang): the
// light with nothing in the way that direct_samples.comp found, over the
// window of 3x3 of the pattern on the surface of the point, which holds each
// place of it once, by the part of it that got there over the points of that
// window where it lies within the noise of the samples; a point without
// samples (direct_history.comp) takes those of the window on its surface, and
// none where none is (DIRECT_FILTER_POINTS). direct_spread.comp spreads that
// part over its penumbra. Then each pixel takes it from the points around it
// of its surface (DIRECT_FILTER_PIXELS), with a point for each 2x2 pixels from
// the four around it: by its reflectance, plus the lights that cast no shadows
// as they are, those of extensions each through its ray, and the other side of
// a surface that lets light through by its own rays (direct_lighting). It also
// leaves 1 where a sample met what changed, for TAA.
#define GBUFFER_ALBEDO SLOT_PASS3
#define GBUFFER_NORMAL SLOT_PASS0
#include "lighting.slang"
#include "gbuffer.slang"
#include <extension_hooks.slang>
#include "pixel.slang"
#include "direct_samples.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

#define DIRECT_FILTER_POINTS 1u
#define DIRECT_FILTER_PIXELS 2u

// samples: those of a point; scale: the pixels across a point; hard: the
// shadow rays of a point that traces its own (direct_lighting); mode: the run
// (DIRECT_FILTER_POINTS, _PIXELS); the rest, those of direct_samples.comp.
struct Params_Block { uint frames; uint samples; float sun_radius; uint scale; uint hard; uint mode; uint pad3; uint pad4; float3 grid_origin; float grid_cell; uint3 grid_size; uint cells; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> out_direct : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);
// The samples of each point, a part below 0 where it has none; and what the
// window gives each point, plus 2 where a sample met what changed.
[[vk::binding(SLOT_PASS4, 0)]] Texture2D<float4> samples_in : register(MIRAI_REGISTER(t, SLOT_PASS4), space0);
[[vk::binding(SLOT_PASS5, 0)]] [[vk::image_format("r8")]] RWTexture2D<float> out_marks : register(MIRAI_REGISTER(u, SLOT_PASS5), space0);
[[vk::binding(SLOT_PASS6, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> out_points : register(MIRAI_REGISTER(u, SLOT_PASS6), space0);
[[vk::binding(SLOT_PASS7, 0)]] Texture2D<float4> points_in : register(MIRAI_REGISTER(t, SLOT_PASS7), space0);

// The points a group holds, its own and one to each side.
#define FILTER_APRON 1
#define FILTER_TILE (MIRAI_GROUP_X + 2 * FILTER_APRON)
groupshared float4 filter_points[FILTER_TILE * FILTER_TILE];  // w 1 for a surface, 2 for one a nested view drew
groupshared float4 filter_normals[FILTER_TILE * FILTER_TILE]; // w the width of a point there, metres
groupshared float4 filter_samples[FILTER_TILE * FILTER_TILE];

// How far apart in deviations of their noise two parts may lie and still
// weigh alike, and the least deviation of a part, for the half floats.
#define FILTER_ALIKE 2.0
#define FILTER_LEAST 0.01

// Whether a point at `point`, with that normal, lies on the surface of a
// center at `center` with its normal and the width of a point there, `apart`
// points away.
bool filter_surface(float3 center, float4 normal, float3 point, float3 point_normal, float apart) {
    if (dot(normal.xyz, point_normal) < 0.9) return false;
    return abs(dot(point - center, normal.xyz)) <= 2.0 * normal.w * apart + 1e-4;
}

// Whether a tap `apart` points away lies on the surface of the center: not
// across the opening of a nested view (w), however alike.
bool filter_same(int center, int tap, float apart) {
    if (filter_points[tap].w < 0.5 || filter_points[tap].w != filter_points[center].w) return false;
    return filter_surface(filter_points[center].xyz, filter_normals[center], filter_points[tap].xyz, filter_normals[tap].xyz, apart);
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

// The part of a sample texel, without the mark of a change.
float filter_part(float4 texel) { return texel.a >= 1.5 ? texel.a - 2.0 : texel.a; }

// Whether a texel holds samples.
bool filter_held(int tap) { return filter_samples[tap].a >= 0.0; }

// The light of pixel p from the light with nothing in the way over its
// reflectance and the part of it that got there.
float3 filter_light(int2 p, float depth, float3 open, float part) {
    Pixel pixel = pixel_at(p, (float2(p) + 0.5) * frame.inv_resolution, depth);
    Shading s = gbuffer_shading(gbuffer_read(p), pixel);
    float3 reflectance = max(s.diffuse + specular_albedo(s), float3(0.02));
    float3 light = open * reflectance * part + shadowless_lighting(s, 0.0);
    float bias = view_bias(pixel.distance);
#ifdef MIRAI_HOOK_LIGHTS
    light += direct_lighting(s, bias, 0u, LIGHTS_EXTENSION);
#endif
    if (shading_transmits(s)) light += direct_lighting(shading_back(s), bias, params.hard, LIGHTS_ALL);
    return finite_or_zero(light);
}

// Pixel p from the four points around it that hold samples of its surface;
// where none does, the nearest that holds any.
void filter_pixel(int2 p) {
    int2 size = int2(frame.resolution);
    if (any(p >= size)) return;
    float depth = g_depth.Load(int3(p, 0)).r;
    if (depth_empty(depth)) {
        out_direct[p] = float4(0.0);
        out_marks[p] = 0.0;
        return;
    }
    int scale = int(params.scale);
    int2 points = direct_points(scale);
    Pixel pixel = pixel_at(p, (float2(p) + 0.5) * frame.inv_resolution, depth);
    float4 normal = float4(gbuffer_normal(p), frame.footprint.x + frame.footprint.y * depth_distance(depth));
    float2 at = (float2(p) + 0.5) / float(scale) - 0.5;
    int2 low = int2(floor(at));
    float2 f = at - float2(low);
    float4 sum = float4(0.0), nearest = float4(0.0);
    float weight = 0.0, best = -1.0;
    bool marked = false;
    for (uint i = 0u; i < 4u; i++) {
        int2 o = int2(int(i & 1u), int(i >> 1u));
        int2 q = clamp(low + o, int2(0), points - 1);
        int2 source = q * scale;
        float tap_depth = g_depth.Load(int3(source, 0)).r;
        if (depth_empty(tap_depth)) continue;
        float4 texel = points_in.Load(int3(q, 0));
        if (texel.a < 0.0) continue;
        // Across the opening of a nested view only where no point on its side is.
        if (!depth_same_side(tap_depth, depth)) {
            if (best < 0.0) nearest = float4(texel.rgb, filter_part(texel));
            continue;
        }
        marked = marked || texel.a >= 1.5;
        texel.a = filter_part(texel);
        float w = (o.x != 0 ? f.x : 1.0 - f.x) * (o.y != 0 ? f.y : 1.0 - f.y) + 1e-4;
        if (w > best) {
            best = w;
            nearest = texel;
        }
        Pixel tap = pixel_at(source, (float2(source) + 0.5) * frame.inv_resolution, tap_depth);
        if (!filter_surface(pixel.position, normal, tap.position, gbuffer_normal(source), float(scale))) continue;
        sum += w * texel;
        weight += w;
    }
    float4 texel = weight > 0.0 ? sum / weight : nearest;
    out_direct[p] = float4(filter_light(p, depth, texel.rgb, saturate(texel.a)), 1.0);
    out_marks[p] = marked ? 1.0 : 0.0;
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 group : SV_GroupID, uint3 local : SV_GroupThreadID, uint index : SV_GroupIndex) {
    if (params.mode == DIRECT_FILTER_PIXELS) {
        filter_pixel(int2(group.xy) * int2(MIRAI_GROUP_X, MIRAI_GROUP_Y) + int2(local.xy));
        return;
    }
    int scale = int(params.scale);
    int2 size = direct_points(scale);
    int2 corner = int2(group.xy) * int2(MIRAI_GROUP_X, MIRAI_GROUP_Y) - FILTER_APRON;
    for (uint i = index; i < uint(FILTER_TILE * FILTER_TILE); i += uint(MIRAI_GROUP_X * MIRAI_GROUP_Y)) {
        int2 q = corner + int2(int(i % uint(FILTER_TILE)), int(i / uint(FILTER_TILE)));
        float4 point = float4(0.0), normal = float4(0.0), texel = float4(0.0, 0.0, 0.0, 1.0);
        if (all(q >= 0) && all(q < size)) {
            int2 source = q * scale;
            float depth = g_depth.Load(int3(source, 0)).r;
            if (!depth_empty(depth)) {
                Pixel pixel = pixel_at(source, (float2(source) + 0.5) * frame.inv_resolution, depth);
                point = float4(pixel.position, depth_nested(depth) ? 2.0 : 1.0);
                normal = float4(gbuffer_normal(source), float(scale) * (frame.footprint.x + frame.footprint.y * depth_distance(depth)));
                texel = samples_in.Load(int3(q, 0));
            }
        }
        filter_points[i] = point;
        filter_normals[i] = normal;
        filter_samples[i] = texel;
    }
    GroupMemoryBarrierWithGroupSync();
    int2 p = int2(group.xy) * int2(MIRAI_GROUP_X, MIRAI_GROUP_Y) + int2(local.xy);
    if (any(p >= size)) return;
    int2 at = int2(local.xy) + FILTER_APRON;
    int center = at.x + at.y * FILTER_TILE;
    if (filter_points[center].w < 0.5) {
        out_points[p] = float4(0.0, 0.0, 0.0, 1.0);
        return;
    }
    float4 own_texel = filter_samples[center];
    bool marked = own_texel.a >= 1.5;
    // The light with nothing in the way over the window of the pattern; of its
    // points that hold samples on any surface where none on its own do.
    float3 open = float3(0.0);
    float parts = 0.0, taps = 0.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            int tap = (at.x + x) + (at.y + y) * FILTER_TILE;
            if (!filter_held(tap) || ((x != 0 || y != 0) && !filter_same(center, tap, float(max(abs(x), abs(y)))))) continue;
            open += filter_samples[tap].rgb;
            parts += filter_part(filter_samples[tap]);
            taps += 1.0;
        }
    }
    if (taps == 0.0) {
        out_points[p] = float4(0.0, 0.0, 0.0, -1.0);
        return;
    }
    open /= taps;
    // The part that got there over the points of the window alike in it. A pair
    // of taps across the center weighs as the less alike of the two, so that a
    // ramp keeps its slope and a border its place. A point without samples
    // weighs those of the window against their mean.
    bool held = filter_held(center);
    float own = held ? filter_part(own_texel) : parts / taps;
    float n = float(max(params.samples, 1u));
    float own_variance = filter_variance(own, n);
    float sum = held ? own : 0.0, total = held ? 1.0 : 0.0;
    for (int y = 0; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            if (y == 0 && x <= 0) continue;
            int ahead = (at.x + x) + (at.y + y) * FILTER_TILE;
            int behind = (at.x - x) + (at.y - y) * FILTER_TILE;
            float2 parts = float2(filter_part(filter_samples[ahead]), filter_part(filter_samples[behind]));
            bool2 found = bool2(filter_held(ahead) && filter_same(center, ahead, 1.0), filter_held(behind) && filter_same(center, behind, 1.0));
            float2 w = float2(found.x ? filter_alike(own, own_variance, parts.x, filter_variance(parts.x, n)) : 0.0, found.y ? filter_alike(own, own_variance, parts.y, filter_variance(parts.y, n)) : 0.0);
            if (found.x && found.y) w = float2(min(w.x, w.y), min(w.x, w.y));
            sum += dot(w, parts);
            total += w.x + w.y;
        }
    }
    float part = total > 0.0 ? sum / total : own;
    out_points[p] = float4(finite_or_zero(open), part + (marked ? 2.0 : 0.0));
}
