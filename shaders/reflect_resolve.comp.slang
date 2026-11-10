#include "native.slang"
//! constant glass MIRAI_GLASS_RESOLVE
// Filters the traced reflections into the history, which composite (or, for
// the variant of a layer of glass, the pass that lights the layer) takes for
// the share of each specular lobe that was traced.
//  - Space: the rays of nearby pixels of the same surface stand in for more
//    rays of this one, over a disc that grows with roughness.
//  - Time: last frame's result is found where the reflected point was (a
//    mirror image moves like a point behind the mirror, not like the surface)
//    and blended in. That point is as far behind a flat mirror as it is in
//    front of it, and nearer the more the surface curves: a convex mirror
//    shrinks what it shows. It is read slightly blurred, so the filter widens
//    from frame to frame, and only from the same surface. A rough reflection
//    moves partly like its surface: it also looks where the surface was
//    (Stachowiak 2015), and weighs each of the two by how rough it is and by
//    how close it comes to what this frame's rays found, so that a copy of an
//    edge one of them carried to the wrong place counts for little; a point
//    between the two, which would show neither, is never read. On a surface
//    still on screen its color is not clamped to this frame's rays: a few
//    rays of a wide lobe say too little for that, and a clamp would throw
//    away what the frames before found. Where the surface moves several
//    pixels a frame, the place the past was read from is a guess, and a
//    bright one carried there trails: the history keeps within this frame's
//    rays.
// A near mirror stays sharp. Its illumination is exact within the light
// budget; above it, accumulate the sampled lighting in time without blur.
//
// From params.shared_from of roughness the rays come one per block of 2x2
// pixels, each traced from one pixel of its block: the filter weighs a ray by
// how much the pixel it was traced from resembles this one, so a ray is never
// carried across an edge. A near mirror that shares its rays keeps what it
// found on its own turn until the next one, four frames later.
#include "scene.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

struct Params_Block { float history_valid; float max_radius; float blend; float shared_from; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> traced : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);      // rgb radiance, a hit distance
#define GBUFFER_NORMAL SLOT_PASS1
#include "gbuffer.slang"
#include "pixel.slang"
[[vk::binding(SLOT_PASS2, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS2), space0);
// Whether the glass passes ran in the previous frame: with no glass in sight
// they do not, and the history is older than that. Read for a layer of glass.
struct Seen_Block { uint glass_seen; };
[[vk::binding(SLOT_PASS4, 0)]] StructuredBuffer<Seen_Block> seen_block : register(MIRAI_REGISTER(t, SLOT_PASS4), space0);
[[vk::binding(SLOT_PASS5, 0)]] Texture2D<float4> history : register(MIRAI_REGISTER(t, SLOT_PASS5), space0);     // rgb radiance, a depth of the surface it belongs to
[[vk::binding(SLOT_PASS6, 0)]] Texture2D<float4> g_motion : register(MIRAI_REGISTER(t, SLOT_PASS6), space0);

// The roughness the trace pass decided a pixel by: a layer of glass has only
// the one specular antialiasing widened, the opaque G-buffer the material's.
float decided_roughness(int2 p, float4 normal) {
    if (MIRAI_GLASS_RESOLVE) return normal.a + ROUGHNESS_ROUNDING;
    return g_motion.Load(int3(p, 0)).b + ROUGHNESS_ROUNDING;
}
[[vk::binding(SLOT_PASS8, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> out_history : register(MIRAI_REGISTER(u, SLOT_PASS8), space0);
[[vk::binding(SLOT_PASS9, 0)]] Texture2D<float4> traced_shared : register(MIRAI_REGISTER(t, SLOT_PASS9), space0); // the same, one ray per block of 2x2 pixels

#define TAPS 8
// Pixels a surface moves on screen in a frame from which its history starts
// keeping within this frame's rays, and from which it keeps there wholly;
// and how far from their mean, in their deviations and as a share of it.
#define HISTORY_MOVING_FROM 1.0
#define HISTORY_MOVING 4.0
#define HISTORY_REACH 2.0
#define HISTORY_SHARE 0.05
// Pixels to each side over which the turn of the normal is measured.
#define CURVATURE_REACH 4

// How fast the normal of the surface turns around a pixel, per unit of
// distance along it. Only a turn that goes on evenly through the pixel
// counts: the relief of a normal map turns the normal back and forth, and the
// surface under it reflects like the plane it is.
float surface_curvature(int2 p, int2 size, float3 n, float depth, float3 position) {
    float curvature = 0.0;
    for (int axis = 0; axis < 2; axis++) {
        int2 step = axis == 0 ? int2(CURVATURE_REACH, 0) : int2(0, CURVATURE_REACH);
        int2 a = p - step, b = p + step;
        if (any(((a) < (int2(0)))) || any(((b) >= (size)))) continue;
        float da = g_depth.Load(int3(a, 0)).r;
        float db = g_depth.Load(int3(b, 0)).r;
        if (depth_empty(da) || depth_empty(db) || !depth_same_side(da, depth) || !depth_same_side(db, depth)) continue;
        if (abs(depth_distance(da) - depth_distance(depth)) > 0.1 * depth_distance(depth) || abs(depth_distance(db) - depth_distance(depth)) > 0.1 * depth_distance(depth)) continue;
        float3 na = gbuffer_normal(a);
        float3 nb = gbuffer_normal(b);
        float turn = length(nb - na);
        float span = length(pixel_at(b, (float2(b) + 0.5) * frame.inv_resolution, db).position - pixel_at(a, (float2(a) + 0.5) * frame.inv_resolution, da).position);
        if (turn <= 1e-4 || span <= 1e-6) continue;
        float even = 1.0 - smoothstep(0.15, 0.4, length(n - 0.5 * (na + nb)) / turn);
        curvature = max(curvature, even * turn / span);
    }
    return curvature;
}

// Last frame's radiance of this surface around `at`, read in a cross that
// widens with blur; weight 0 where none of it belongs to this surface. depth:
// how far the surface is, whichever view drew it then.
float4 history_around(float2 at, float blur, float depth) {
    float3 sum = float3(0.0);
    float count = 0.0;
    for (int i = 0; i < (blur > 0.0 ? 5 : 1); i++) {
        float2 offset = i == 0 ? float2(0.0) : float2((i & 1) != 0 ? 1.0 : -1.0, (i & 2) != 0 ? 1.0 : -1.0) * (1.5 * blur);
        float2 tap_at = at + offset * frame.inv_resolution;
        if (any(((tap_at) < (float2(0.0)))) || any(((tap_at) >= (float2(1.0))))) continue;
        float4 tap = history.SampleLevel(linear_sampler, tap_at, 0.0);
        if (tap.a <= 0.0 || abs(tap.a - depth) > 0.15 * depth) continue;
        sum += tap.rgb;
        count += 1.0;
    }
    return count > 0.0 ? float4(sum / count, count) : float4(0.0);
}

// The ray that stands for pixel q, and the pixel it was traced from.
float4 traced_at(int2 q, bool by_block, int2 size, out int2 source) {
    source = q;
    if (!by_block) return traced.Load(int3(q, 0));
    int2 cell = q >> 1;
    source = min(cell * 2 + block_pixel(frame.frame_index, 2u), size - 1);
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
    bool history_valid = params.history_valid > 0.5;
    if (MIRAI_GLASS_RESOLVE) history_valid = history_valid && seen_block[0].glass_seen != 0u;
    if (depth_empty(depth) || reflection_weight(roughness) <= 0.0) {
        out_history[p] = float4(0.0);
        return;
    }
    // 0 for a mirror, 1 at the roughness limit.
    float blur = roughness > MIRROR_ROUGHNESS ? clamp(roughness / max(frame.texturing.y, 1e-3), 0.0, 1.0) : 0.0;
    bool by_block = roughness >= params.shared_from;

    float3 sum = float3(0.0);
    float3 squares = float3(0.0);
    float distance_sum = 0.0;
    float weight_sum = 0.0;
    uint seed = seed_for(uint2(p), frame.frame_index, 29u);
    float rotation = random01(seed) * 2.0 * PI;
    // Shared rays are two pixels apart: the disc reaches the blocks around.
    float radius = max(params.max_radius * blur, by_block ? 3.0 : 0.0);
    bool waiting = false;
    // Tap 0 is the pixel itself.
    for (int i = 0; i <= (blur > 0.0 ? TAPS : 0); i++) {
        int2 q = p;
        if (i > 0) {
            // A spiral: taps spread evenly over the disc, turned every frame.
            float r = radius * sqrt((float(i) - 0.5) / float(TAPS));
            float angle = rotation + float(i) * 2.399963;
            q = p + int2(round(float2(cos(angle), sin(angle)) * r));
            if (all(q == p) || any(((q) < (int2(0)))) || any(((q) >= (size)))) continue;
        }
        int2 source;
        float4 tap = traced_at(q, by_block, size, source);
        if (i == 0 && blur <= 0.0) waiting = any(source != p);
        if (tap.a < 0.0) continue;
        float w = 1.0;
        if (any(source != p)) {
            float4 tap_normal = gbuffer_normal_roughness(source);
            float tap_depth = g_depth.Load(int3(source, 0)).r;
            w = pow(max(dot(tap_normal.xyz, normal.xyz), 0.0), 32.0)
                * exp(-abs(depth_distance(tap_depth) - depth_distance(depth)) / (0.05 * depth_distance(depth) + 1e-4))
                * exp(-abs(decided_roughness(source, tap_normal) - roughness) * 8.0);
            if (!depth_same_side(tap_depth, depth)) w = 0.0;
        }
        sum += tap.rgb * w;
        squares += tap.rgb * tap.rgb * w;
        distance_sum += tap.a * w;
        weight_sum += w;
    }
    // No ray of this surface nearby this frame: the past says what it reflects.
    bool found = weight_sum > 1e-3;
    float3 current = found ? sum / weight_sum : float3(0.0);
    float hit_distance = found ? distance_sum / weight_sum : 0.0;

    float3 result = current;
    float2 uv = (float2(p) + 0.5) * frame.inv_resolution;
    Pixel pixel = pixel_at(p, uv, depth);
    if ((blur > 0.0 || waiting || !found) && history_valid) {
        float3 view = pixel.view;
        float3 position = pixel.position;
        // Where the reflected point was last frame, seen as a point behind the surface.
        float behind = hit_distance / (1.0 + 2.0 * surface_curvature(p, size, normal.xyz, depth, position) * hit_distance);
        float4 clip = previous_clip(p, depth, position + view * behind);
        float2 mirrored = float2(clip.x / clip.w * 0.5 + 0.5, 0.5 - clip.y / clip.w * 0.5);
        float2 motion = g_motion.Load(int3(p, 0)).rg;
        float2 surface = uv + motion;
        float4 old = history_around(clip.w > 0.0 ? mirrored : surface, blur, depth_distance(depth));
        if (blur > 0.0 && clip.w > 0.0) {
            float4 stuck = history_around(surface, blur, depth_distance(depth));
            if (old.a <= 0.0) old = stuck;
            else if (stuck.a > 0.0) {
                float near = found ? luminance(current) : 0.5 * (luminance(old.rgb) + luminance(stuck.rgb));
                float scale = 0.1 * max(max(luminance(old.rgb), luminance(stuck.rgb)), near) + 1e-3;
                float by_point = (1.0 - blur * blur) / pow(scale + abs(luminance(old.rgb) - near), 2.0);
                float by_surface = blur * blur / pow(scale + abs(luminance(stuck.rgb) - near), 2.0);
                old = float4((old.rgb * by_point + stuck.rgb * by_surface) / (by_point + by_surface), 1.0);
            }
        }
        float moving = smoothstep(HISTORY_MOVING_FROM, HISTORY_MOVING, length(motion * frame.resolution));
        if (found && old.a > 0.0 && moving > 0.0) {
            float3 reach = HISTORY_REACH * sqrt(max(squares / weight_sum - current * current, float3(0.0))) + HISTORY_SHARE * current;
            old.rgb = lerp(old.rgb, clamp(old.rgb, current - reach, current + reach), moving);
        }
        // The sharper the reflection, the less it leans on the past.
        float feedback = lerp(1.0, params.blend, smoothstep(0.0, 0.3, blur));
        if (old.a > 0.0) result = lerp(old.rgb, current, found && !waiting ? feedback : 0.0);
    }
    result = finite_or_zero(result);
    out_history[p] = float4(result, depth_distance(depth));
}
