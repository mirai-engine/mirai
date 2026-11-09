#include "native.slang"
// The exposure value of a view for this frame. Metered: the geometric mean of
// what its histogram counts, each pixel of sky as a middle gray card under the
// open sky and sun (sky_card), the luminance of a middle gray card, between the
// darkest EXPOSURE_LOW and the brightest EXPOSURE_HIGH of its pixels, is made
// middle gray (a light meter of K = 12.5 gives EV100 = log2(L * 100 / K)) and
// kept to the range of the camera. The view comes to it exponentially, as in
// Unity and Godot: whatever the change, 95 % of the way in params.adaptation
// seconds when the light falls and in EXPOSURE_UP of that when it grows. At
// params.speed, as in Unreal and Bevy: params.adaptation seconds for each EV
// it darkens, EXPOSURE_SPEED_UP times as fast when the light grows, and within
// EXPOSURE_TRANSITION EV of it exponentially, at the rate it had there. The
// first image of a view and the first after a discontinuity (a camera cut,
// another world: params.generation) take it at once. Manual: the EV100 of the
// camera. It clears the histogram for the next frame.
#include "scene.slang"
#include "exposure.slang"
#define MIRAI_GROUP_X 128
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1
// The shares of the pixels, darkest first, between which the meter reads.
#define EXPOSURE_LOW 0.1
#define EXPOSURE_HIGH 0.9
// The share of params.adaptation the view takes to come to more light.
#define EXPOSURE_UP 0.5
// Time constants in params.adaptation: exp(-3) leaves 5 % of a change.
#define EXPOSURE_SETTLE 3.0
// At params.speed: how many times faster the view adapts to more light than
// to less, and the EV from the target where its approach turns exponential.
#define EXPOSURE_SPEED_UP 3.0
#define EXPOSURE_TRANSITION 1.5

struct Params_Block {
    uint manual;
    float ev100;        // manual
    float compensation; // EV added
    float adaptation;   // seconds to come 95 % of the way to less light, or at speed for each EV of it; 0: at once
    float2 range;       // EV100 the meter keeps to
    float dt;
    float light_scale;  // render units per nit
    uint generation;    // of the discontinuities of the view
    uint speed;         // render.Exposure_Adaptation.Speed
    float bias;         // render.display_exposure_bias: EV above the meter under the display transform
    uint pad1;
};
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] RWStructuredBuffer<uint> histogram : register(MIRAI_REGISTER(u, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] RWStructuredBuffer<Exposure_State> state : register(MIRAI_REGISTER(u, SLOT_PASS1), space0);

groupshared uint counts[EXPOSURE_BINS];

// What a middle gray card facing up shows under the sky and the sun at the
// eye, nothing in their way: the light the sky gives the scene. A pixel of sky
// counts as this whichever way it looks, so that looking up or down in one
// place meters the same light.
float sky_card() {
    float3 light = sky_irradiance(float3(0.0, 1.0, 0.0));
    if (frame.sun_direction.w > 0.5) light += sun_light(frame.camera_position.xyz) * max(frame.sun_direction.y, 0.0);
    return MIDDLE_GRAY * luminance(light) / params.light_scale;
}

// From `current` toward `target`, EV100, over dt seconds.
float exposure_adapt(float current, float target, float dt) {
    float apart = target - current;
    if (params.speed != 0u) {
        float speed = (apart > 0.0 ? EXPOSURE_SPEED_UP : 1.0) / params.adaptation;
        if (abs(apart) > EXPOSURE_TRANSITION) return current + sign(apart) * min(speed * dt, abs(apart));
        return target - apart * exp(-dt * speed / EXPOSURE_TRANSITION);
    }
    float time = params.adaptation * (apart > 0.0 ? EXPOSURE_UP : 1.0);
    return target - apart * exp(-EXPOSURE_SETTLE * dt / time);
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint index : SV_GroupIndex) {
    counts[index] = histogram[index];
    histogram[index] = 0u;
    GroupMemoryBarrierWithGroupSync();
    if (index != 0u) return;
    uint sky = histogram[EXPOSURE_SKY];
    histogram[EXPOSURE_SKY] = 0u;
    if (sky != 0u) {
        float nits = sky_card();
        if (nits > 0.0) counts[exposure_bin(nits)] += sky;
    }
    Exposure_State s = state[0];
    bool held = s.valid != 0u && s.generation == params.generation;
    float ev100 = params.ev100;
    if (params.manual == 0u) {
        float total = 0.0;
        for (uint i = 0u; i < EXPOSURE_BINS; i++) total += float(counts[i]);
        float low = total * EXPOSURE_LOW;
        float high = total * EXPOSURE_HIGH;
        float below = 0.0, sum = 0.0, weight = 0.0;
        for (uint i = 0u; i < EXPOSURE_BINS; i++) {
            float count = float(counts[i]);
            float kept = clamp(below + count, low, high) - clamp(below, low, high);
            sum += kept * lerp(EXPOSURE_LOG_MIN, EXPOSURE_LOG_MAX, (float(i) + 0.5) / float(EXPOSURE_BINS));
            weight += kept;
            below += count;
        }
        if (weight > 0.0) {
            ev100 = clamp(sum / weight + log2(100.0 / 12.5), params.range.x, params.range.y);
            if (held && params.adaptation > 0.0) ev100 = exposure_adapt(s.ev100, ev100, params.dt);
        } else {
            // Nothing to meter (a backdrop, or what glows relative to the
            // exposure): the exposure holds, or begins at a middle gray card
            // under the strongest light, which the light scale brings near one.
            ev100 = s.valid != 0u ? s.ev100 : exposure_first(params.light_scale, params.range);
        }
    }
    s.ev100 = ev100;
    s.exposure = MIDDLE_GRAY * (100.0 / 12.5) * exp2(params.bias + params.compensation - ev100) / params.light_scale;
    s.valid = 1u;
    s.generation = params.generation;
    state[0] = s;
}
