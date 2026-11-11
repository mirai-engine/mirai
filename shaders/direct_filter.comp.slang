#include "native.slang"
//! variant hw MIRAI_HW_RT=1
// unlayered: while no instance with layers is in sight (gbuffer.slang).
//! constant unlayered MIRAI_GBUFFER_NO_LAYERS
// The last pass of the direct light of a view (direct_samples.slang): each
// pixel takes what its points hold (direct_points.comp, direct_spread.comp),
// with a point for each 2x2 pixels from the four around it of its surface.
// The local lights give it their light with nothing in the way by its
// reflectance and the part of it that got there. The sun gives it its own
// light, as its normal and its material take it, by the part of the sun that
// got there: its shape is that of the pixels, not of the points. Then the
// lights that cast no shadows as they are, those of extensions each through
// its ray, and the other side of a surface that lets light through by its own
// rays (direct_lighting). It also leaves 1 where a sample met what changed,
// for TAA.
#define GBUFFER_ALBEDO SLOT_PASS3
#define GBUFFER_NORMAL SLOT_PASS0
#define SUN_SHADOW_SLOT SLOT_PASS8
#define SHADOW_TINT_SLOT SLOT_PASS9
#include "lighting.slang"
#include "shadow_maps.slang"
#include "gbuffer.slang"
#include <extension_hooks.slang>
#include "pixel.slang"
#include "direct_samples.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

// scale: the pixels across a point; hard: the shadow rays of a point that
// traces its own (direct_lighting); glass: not 0 where glass colors the light
// of the sun (direct_samples.comp); the rest, those of direct_samples.comp.
struct Params_Block { uint pad0; uint samples; float sun_radius; uint scale; uint hard; uint pad1; uint glass; uint pad2; float3 grid_origin; float grid_cell; uint3 grid_size; uint cells; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> out_direct : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);
// The part of the sun that got to each point, below 0 where it gives none.
[[vk::binding(SLOT_PASS4, 0)]] Texture2D<float4> sun_points : register(MIRAI_REGISTER(t, SLOT_PASS4), space0);
[[vk::binding(SLOT_PASS5, 0)]] [[vk::image_format("r8")]] RWTexture2D<float> out_marks : register(MIRAI_REGISTER(u, SLOT_PASS5), space0);
// rgb: what the glass on the way leaves of the light of the sun at each point.
[[vk::binding(SLOT_PASS6, 0)]] Texture2D<float4> sun_glass : register(MIRAI_REGISTER(t, SLOT_PASS6), space0);
// The light of the local lights with nothing in the way over the reflectance
// at each point, and the part of it that got there, plus 2 where a sample met
// what changed.
[[vk::binding(SLOT_PASS7, 0)]] Texture2D<float4> points_in : register(MIRAI_REGISTER(t, SLOT_PASS7), space0);

// What the points give a pixel of the sun: how much of it got there, below 0
// where none of them tells, and what the glass on the way leaves of it.
struct Sun_Part {
    float part;
    float3 glass;
};

// The light of pixel p: that of the local lights with nothing in the way over
// its reflectance by the part of it that got there, and its own of the sun by
// the part of it that did.
float3 filter_light(int2 p, float depth, float3 normal, float3 open, float part, Sun_Part sun) {
    Pixel pixel = pixel_at(p, (float2(p) + 0.5) * frame.inv_resolution, depth);
    Shading s = gbuffer_shading(gbuffer_read(p), pixel);
    float3 reflectance = max(s.diffuse + specular_albedo(s), float3(0.02));
    float3 light = open * reflectance * part + shadowless_lighting(s, 0.0);
    float cosine = dot(s.normal, frame.sun_direction.xyz);
    if (frame.sun_direction.w > 0.5 && cosine > 0.0) {
        float3 radiance = sun_light(pixel.position) * cosine * shading_response(s, frame.sun_direction.xyz);
        if (luminance(radiance) > 0.0) {
            // Where no point of its surface tells, its map does, as it tells the points.
            float seen = sun.part < 0.0 ? sun_shadow_seen(pixel.position, normal, false) : sun.part;
            // The glass on its way: where a map holds the pixel, as its tint says there.
            Shadow_Map held;
            float3 glass = sun_map_of(pixel.position, held) && !shadow_tint_programmed(held, pixel.position) ? shadow_tint(held, pixel.position) : sun.glass;
            light += radiance * glass * (seen < 0.0 ? 1.0 : seen);
        }
    }
    float bias = view_bias(pixel.distance);
#ifdef MIRAI_HOOK_LIGHTS
    light += direct_lighting(s, bias, 0u, LIGHTS_EXTENSION);
#endif
    if (shading_transmits(s)) light += direct_lighting(shading_back(s), bias, params.hard, LIGHTS_ALL);
    return finite_or_zero(light);
}

// Pixel p from the four points around it of its surface; where none is, the
// local lights from the nearest.
[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    int2 p = int2(id.xy);
    int2 size = int2(frame.resolution);
    if (any(p >= size)) return;
    float depth = g_depth.Load(int3(p, 0)).r;
    if (depth_empty(depth)) {
        out_direct[p] = float4(0.0);
        out_marks[p] = 0.0;
        return;
    }
    int scale = int(max(params.scale, 1u));
    int2 points = direct_points(scale);
    Pixel pixel = pixel_at(p, (float2(p) + 0.5) * frame.inv_resolution, depth);
    float4 normal = float4(gbuffer_normal(p), frame.footprint.x + frame.footprint.y * depth_distance(depth));
    float2 at = (float2(p) + 0.5) / float(scale) - 0.5;
    int2 low = int2(floor(at));
    float2 f = at - float2(low);
    float4 sum = float4(0.0), nearest = float4(0.0);
    float weight = 0.0, best = -1.0;
    Sun_Part sun = {0.0, float3(0.0)};
    float sun_weight = 0.0;
    bool marked = false;
    for (uint i = 0u; i < 4u; i++) {
        int2 o = int2(int(i & 1u), int(i >> 1u));
        int2 q = clamp(low + o, int2(0), points - 1);
        int2 source = q * scale;
        float tap_depth = g_depth.Load(int3(source, 0)).r;
        if (depth_empty(tap_depth)) continue;
        float4 texel = points_in.Load(int3(q, 0));
        // Across the opening of a nested view only where no point on its side is.
        if (!depth_same_side(tap_depth, depth)) {
            if (best < 0.0) nearest = float4(texel.rgb, texel.a >= 1.5 ? texel.a - 2.0 : texel.a);
            continue;
        }
        marked = marked || texel.a >= 1.5;
        if (texel.a >= 1.5) texel.a -= 2.0;
        float w = (o.x != 0 ? f.x : 1.0 - f.x) * (o.y != 0 ? f.y : 1.0 - f.y) + 1e-4;
        if (w > best) {
            best = w;
            nearest = texel;
        }
        Pixel tap = pixel_at(source, (float2(source) + 0.5) * frame.inv_resolution, tap_depth);
        if (!direct_surface(pixel.position, normal, tap.position, gbuffer_normal(source), float(scale))) continue;
        sum += w * texel;
        weight += w;
        float held = sun_points.Load(int3(q, 0)).x;
        if (held < 0.0) continue;
        sun.part += w * held;
        sun.glass += w * (params.glass != 0u ? sun_glass.Load(int3(q, 0)).rgb : float3(1.0));
        sun_weight += w;
    }
    float4 texel = weight > 0.0 ? sum / weight : nearest;
    if (sun_weight > 0.0) {
        sun.part /= sun_weight;
        sun.glass /= sun_weight;
    } else {
        sun.part = -1.0;
        sun.glass = float3(1.0);
    }
    out_direct[p] = float4(filter_light(p, depth, normal.xyz, texel.rgb, saturate(texel.a), sun), 1.0);
    out_marks[p] = marked ? 1.0 : 0.0;
}
