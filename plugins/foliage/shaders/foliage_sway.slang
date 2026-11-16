// How the wind sways foliage, the one way of the hook of the vertices of its
// batches (foliage_vertex.slang), of the compute of its variants
// (foliage_sway.comp.slang) and of its impostors (foliage_impostor.vert.slang).
#ifndef FOLIAGE_SWAY_SLANG
#define FOLIAGE_SWAY_SLANG
#include "origin.slang"
#define FOLIAGE_WAVE float2(0.37, 0.71) // foliage.WIND_WAVE: radians a metre along x and z of the world of the gust wave

// The phase of the gust wave at a place relative to an origin, radians, as
// foliage.wind_wave gives it: what the origin adds to it is taken in turns of
// 20π, which the two waves of foliage_wind_lean repeat together in.
float foliage_wave(float3 at, int3 origin) {
    return origin_phase(origin, float3(FOLIAGE_WAVE.x, 0.0, FOLIAGE_WAVE.y) / 62.831853) * 62.831853 + dot(at.xz, FOLIAGE_WAVE);
}

// The lean of a plant in a wind of velocity `wind` (m/s) with `gusts` cycles
// per second, radians along x and z of the space its up is +y in: by
// `weight` (the red of its vertex color) and `amount` (radians per m/s:
// foliage.sway_amount of its type), at `phase` radians of the gust wave
// where it stands and `time` seconds. A vertical wind leans nothing, and one
// past foliage.WIND_SPEED_MAX leans as much as it.
float2 foliage_wind_lean(float3 wind, float gusts, float weight, float amount, float phase, float time) {
    float speed = length(wind);
    if (speed > 20.0) wind *= 20.0 / speed;
    float p = phase + time * gusts * 6.2831853;
    float sway = 0.6 + 0.4 * (sin(p) * 0.7 + sin(p * 2.3 + 1.7) * 0.3);
    return wind.xz * (amount * weight * sway);
}

// A point `p` from where its plant stands, up +y, bent by a lean: how high
// it stands turns about the place by the length of the lean toward it, and
// how far it spreads level stays. A stalk keeps its length and what lies
// level does not move.
float3 foliage_bend(float3 p, float2 lean) {
    float angle = length(lean);
    if (!(angle > 1e-5)) return p;
    float height = max(p.y, 0.0);
    float2 side = lean / angle;
    float s = sin(angle);
    return p + float3(side.x * s, cos(angle) - 1.0, side.y * s) * height;
}
#endif
