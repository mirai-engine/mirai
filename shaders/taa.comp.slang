#include "native.slang"
// Temporal anti-aliasing and upscaling (TAAU). Each output pixel reconstructs
// the current frame from the jittered render-resolution samples around it
// (Gaussian-weighted), reprojects the output-resolution history with a
// Catmull-Rom filter and clips it to the YCoCg variance box of the
// neighborhood. Blending happens in a luminance-compressed space of exposed
// light so outliers bright on screen do not ghost, whatever the light scale;
// the history stays in render units, with the depth of each pixel in its
// alpha: where it shows something nearer than everything around the pixel
// now, and wider than a pixel, what stood in front moved away, and the pixel
// starts again from this frame.
//
// A pixel whose surface stays still on screen averages its frames, up to
// TAA_STILL_FRAMES, four rounds of the sixteen points of the jitter
// (render.taa_jitter): an edge or a highlight narrower than a pixel, which
// the points meet in some frames and miss in others, would flicker over the
// few frames a moving pixel keeps. It counts its frames from where its
// history starts, so a pixel just uncovered or a view just cut settles as
// soon as before. What changes beyond the colors around it still shows at
// once: the box clips the history. A pixel whose shadow changed because what
// casts it moved (the mark shadow_temporal.comp leaves in the widths of its
// blocks) keeps what a moving pixel keeps: a shadow that moves over a still
// floor leaves no trail.
#include "scene.slang"
#include "grid.slang"
#include "pixel.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

struct Params_Block {
    float history_valid;
    float feedback;      // weight of the current frame at full sample coverage
    float clip_gamma;    // variance box size in standard deviations
    float reactive;      // 1: reactive holds where the Blend stage drew this frame
    float shadows;       // 1: shadow_widths holds the blocks of shadows of this frame
    float pad0;
    float pad1;
    float pad2;
};
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> current_color : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> g_motion : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS2), space0);
[[vk::binding(SLOT_PASS3, 0)]] Texture2D<float4> history : register(MIRAI_REGISTER(t, SLOT_PASS3), space0);
[[vk::binding(SLOT_PASS4, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> out_color : register(MIRAI_REGISTER(u, SLOT_PASS4), space0);
// The share of each render pixel the Blend stage covered: it moves with no motion vectors, so the history keeps less of it.
[[vk::binding(SLOT_PASS5, 0)]] Texture2D<float4> reactive : register(MIRAI_REGISTER(t, SLOT_PASS5), space0);
// The frames the history of each pixel holds: of the last frame, and of this one.
[[vk::binding(SLOT_PASS6, 0)]] Texture2D<float> previous_frames : register(MIRAI_REGISTER(t, SLOT_PASS6), space0);
[[vk::binding(SLOT_PASS7, 0)]] [[vk::image_format("r16f")]] RWTexture2D<float> out_frames : register(MIRAI_REGISTER(u, SLOT_PASS7), space0);
// The widths of the blocks of 2x2 of shadows: z 1 where their ray met what changed.
[[vk::binding(SLOT_PASS8, 0)]] Texture2D<float4> shadow_widths : register(MIRAI_REGISTER(t, SLOT_PASS8), space0);

// Pixels a surface moves on screen in a frame below which it counts as still.
static const float TAA_STILL = 0.25;
static const float TAA_STILL_FRAMES = 64.0;
// The variance box of a still pixel widens to this many deviations as its
// history fills (TAA_STILL_WIDEN frames): the box of one frame's jittered
// samples around a sharp edge moves with the jitter, and clipped to it the
// average of the frames before jumped in every frame.
static const float TAA_STILL_GAMMA = 3.0;
static const float TAA_STILL_WIDEN = 16.0;

float3 compress(float3 c) { c *= frame.exposure; return c / (1.0 + luminance(c)); }
float3 expand(float3 c) { return c / (max(1.0 - luminance(c), 1e-4) * frame.exposure); }

// Five bilinear taps approximating a 4x4 Catmull-Rom filter.
float3 sample_catmull_rom(float2 uv, float2 size) {
    float2 position = uv * size;
    float2 center = floor(position - 0.5) + 0.5;
    float2 f = position - center;
    float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    float2 w3 = f * f * (-0.5 + 0.5 * f);
    float2 w12 = w1 + w2;
    float2 tc12 = (center + w2 / w12) / size;
    float2 tc0 = (center - 1.0) / size;
    float2 tc3 = (center + 2.0) / size;
    float3 result =
        history.SampleLevel(linear_sampler, float2(tc12.x, tc0.y), 0.0).rgb * (w12.x * w0.y) +
        history.SampleLevel(linear_sampler, float2(tc0.x, tc12.y), 0.0).rgb * (w0.x * w12.y) +
        history.SampleLevel(linear_sampler, float2(tc12.x, tc12.y), 0.0).rgb * (w12.x * w12.y) +
        history.SampleLevel(linear_sampler, float2(tc3.x, tc12.y), 0.0).rgb * (w3.x * w12.y) +
        history.SampleLevel(linear_sampler, float2(tc12.x, tc3.y), 0.0).rgb * (w12.x * w3.y);
    float weight = (w12.x * w0.y) + (w0.x * w12.y) + (w12.x * w12.y) + (w3.x * w12.y) + (w12.x * w3.y);
    return max(result / weight, float3(0.0));
}

float3 clip_to_box(float3 history_value, float3 box_min, float3 box_max) {
    float3 center = 0.5 * (box_max + box_min);
    float3 extent = 0.5 * (box_max - box_min) + 1e-5;
    float3 offset = history_value - center;
    float3 units = abs(offset / extent);
    float largest = max(units.x, max(units.y, units.z));
    return largest > 1.0 ? center + offset / largest : history_value;
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    int2 p = int2(dispatch_id.xy);
    int2 out_size = texture_size(out_color);
    if (any(((p) >= (out_size)))) return;
    float2 uv = (float2(p) + 0.5) / float2(out_size);
    int2 in_size = int2(frame.resolution);
    // Continuous position in the render grid. The jittered projection moves
    // content by +jitter, so sample i shows the unjittered point i + 0.5 - jitter.
    float2 ip = uv * frame.resolution - 0.5 + frame.jitter.xy;
    int2 base = int2(floor(ip + 0.5));
    float3 sum = float3(0.0);
    float weight_sum = 0.0;
    float peak = 0.0;
    float3 m1 = float3(0.0), m2 = float3(0.0);
    float closest = 1e30;
    float closest_depth = 0.0;
    float center = 0.0;
    int2 closest_pixel = clamp(base, int2(0), in_size - 1);
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int2 q = clamp(base + int2(dx, dy), int2(0), in_size - 1);
            float3 c = compress(current_color.Load(int3(q, 0)).rgb);
            float2 d = float2(q) - ip;
            float w = exp(-2.29 * dot(d, d));
            sum += c * w;
            weight_sum += w;
            peak = max(peak, w);
            float3 y = to_ycocg(c);
            m1 += y;
            m2 += y * y;
            float depth = g_depth.Load(int3(q, 0)).r;
            float z = depth_empty(depth) ? 1e29 : depth_distance(depth);
            if (z < closest) { closest = z; closest_depth = depth; closest_pixel = q; }
            if (dx == 0 && dy == 0) center = z;
        }
    }
    float3 current = sum / max(weight_sum, 1e-6);
    float3 result = current;
    float2 motion = g_motion.Load(int3(closest_pixel, 0)).rg;
    float2 previous_uv = uv + motion;
    // Empty G-buffer samples have no object motion. The reference plane has a
    // finite world position, so reproject it with the previous camera instead
    // of retaining lines at their old screen position during translation.
    if (closest >= 1e28) {
        float3 point;
        float distance;
        if (ground_grid_point(uv + frame.jitter.xy * frame.inv_resolution, point, distance)) {
            float4 previous_clip = view_clip_previous(point);
            previous_uv = previous_clip.w > 1e-4 ? previous_clip.xy / previous_clip.w * float2(0.5, -0.5) + 0.5 : float2(-1.0);
        }
    }
    bool inside = all(((previous_uv) >= (float2(0.0)))) && all(((previous_uv) <= (float2(1.0))));
    // The depth the history holds: that of the sample at the pixel, 0 for
    // nothing drawn; half floats end at 65504. It is compared with the nearest
    // of the samples around, so that the jitter of a still edge rejects nothing.
    // A pixel that follows a nearer neighbour which moves another way takes the
    // history of that neighbour, and its depth with it: it starts again once the
    // neighbour is gone.
    float2 own_motion = g_motion.Load(int3(clamp(base, int2(0), in_size - 1), 0)).rg;
    bool follows = dot((motion - own_motion) * float2(out_size), (motion - own_motion) * float2(out_size)) > 0.25;
    float held = follows ? closest : center;
    float seen = held >= 1e28 ? 0.0 : min(held, 6e4);
    float frames = 1.0;
    if (params.history_valid > 0.5 && inside) {
        float2 moved = motion * float2(out_size);
        bool still = dot(moved, moved) <= TAA_STILL * TAA_STILL;
        int2 at = clamp(base, int2(0), in_size - 1);
        if (still && params.shadows > 0.5) {
            int2 block = min(at / 2, texture_size(shadow_widths, 0) - 1);
            still = shadow_widths.Load(int3(block, 0)).z < 0.5;
        }
        float before_frames = previous_frames.SampleLevel(point_sampler, previous_uv, 0.0);
        float gamma = still ? lerp(params.clip_gamma, TAA_STILL_GAMMA, saturate(before_frames / TAA_STILL_WIDEN)) : params.clip_gamma;
        float3 mean = m1 / 9.0;
        float3 sigma = sqrt(max(m2 / 9.0 - mean * mean, float3(0.0)));
        float3 box_min = mean - gamma * sigma;
        float3 box_max = mean + gamma * sigma;
        float3 previous = compress(sample_catmull_rom(previous_uv, float2(out_size)));
        previous = from_ycocg(clip_to_box(to_ycocg(previous), box_min, box_max));
        // Upscaling: output pixels far from any new sample keep more history.
        frames = min(before_frames + 1.0, still ? TAA_STILL_FRAMES : 1.0 / params.feedback);
        float alpha = still ? clamp(peak / frames, 0.01, 1.0) : clamp(params.feedback * peak, 0.02, 1.0);
        if (params.reactive > 0.5) alpha = max(alpha, 0.85 * reactive.Load(int3(clamp(base, int2(0), in_size - 1), 0)).r);
        float kept = history.SampleLevel(point_sampler, previous_uv, 0.0).a;
        if (kept > 0.0) {
            // How deep what is seen now was for the previous camera.
            float before = 1e30;
            if (closest < 1e28) {
                float2 at = (float2(closest_pixel) + 0.5) * frame.inv_resolution;
                before = previous_depth(closest_pixel, closest_depth, pixel_at(closest_pixel, at, closest_depth).position);
            }
            float limit = 0.9 * before;
            if (kept < limit) {
                // What stood in front was wider than a pixel both ways. A wire
                // thinner than that, which the samples of this frame missed, is
                // still there: the history is all that holds it.
                float2 step = frame.inv_resolution;
                float left = history.SampleLevel(point_sampler, previous_uv - float2(step.x, 0.0), 0.0).a;
                float right = history.SampleLevel(point_sampler, previous_uv + float2(step.x, 0.0), 0.0).a;
                float up = history.SampleLevel(point_sampler, previous_uv - float2(0.0, step.y), 0.0).a;
                float down = history.SampleLevel(point_sampler, previous_uv + float2(0.0, step.y), 0.0).a;
                bool across = (left > 0.0 && left < limit) || (right > 0.0 && right < limit);
                bool along = (up > 0.0 && up < limit) || (down > 0.0 && down < limit);
                if (across && along) alpha = 1.0;
            }
        }
        result = lerp(previous, current, alpha);
        frames = min(frames, 1.0 / alpha);
    }
    out_color[p] = float4(finite_or_zero(expand(result)), seen);
    out_frames[p] = frames;
}
