// How the wind sways foliage, the one way of the hook of the vertices of its
// batches (foliage_vertex.slang) and of its impostors (foliage_impostor.vert.slang).
#ifndef FOLIAGE_SWAY_SLANG
#define FOLIAGE_SWAY_SLANG
#include "origin.slang"
#define FOLIAGE_WAVE float2(0.37, 0.71) // radians a metre along x and z of the world of the gust wave
#define FOLIAGE_FLUTTER_RATE 1.5 // cycles a second a leaf flutters at
#define FOLIAGE_FLUTTER_WAVE float3(4.1, 3.3, 3.7) // radians a metre of the plant: leaves a hand apart flutter apart

// The phase of the gust wave at a place relative to an origin, radians: what
// the origin adds to it is taken in turns of 20π, which the two waves of
// foliage_gust repeat together in.
float foliage_wave(float3 at, int3 origin) {
    return origin_phase(origin, float3(FOLIAGE_WAVE.x, 0.0, FOLIAGE_WAVE.y) / 62.831853) * 62.831853 + dot(at.xz, FOLIAGE_WAVE);
}

// How much of its lean a plant takes at `phase` radians of the gust wave
// where it stands and `time` seconds, in a wind of `gusts` cycles a second:
// from 0.2 to 1.
float foliage_gust(float gusts, float phase, float time) {
    float p = phase + time * gusts * 6.2831853;
    return 0.6 + 0.4 * (sin(p) * 0.7 + sin(p * 2.3 + 1.7) * 0.3);
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
    return wind.xz * (amount * weight * foliage_gust(gusts, phase, time));
}

// How the leaves of a plant flutter in that wind, by `amount` (metres per
// m/s: foliage.flutter_amount of its type): x, the metres a leaf flutters,
// as much more in a gust as the plant leans; y, the beat of the plant,
// radians, which its leaves beat apart from by where they rest. None for a
// type that does not flutter, or in a calm.
float2 foliage_wind_flutter(float3 wind, float gusts, float amount, float phase, float time) {
    float metres = amount * min(length(wind.xz), 20.0) * foliage_gust(gusts, phase, time);
    if (!(metres > 0.0)) return float2(0.0);
    return float2(metres, frac(time * FOLIAGE_FLUTTER_RATE) * 6.2831853 + phase * 7.0);
}

// Where a leaf `rest` metres from where its plant stands goes as it
// flutters by `flutter` (foliage_wind_flutter, weighed by its vertex
// color), from where its plant bends it: round a loop up and down and along
// the lean, apart from the leaves a hand away.
float3 foliage_flutter(float3 rest, float2 lean, float2 flutter) {
    float s, c;
    sincos(flutter.y + dot(rest, FOLIAGE_FLUTTER_WAVE), s, c);
    float2 side = lean * rsqrt(max(dot(lean, lean), 1e-12));
    return flutter.x * float3(side.x * c, s, side.y * c);
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
