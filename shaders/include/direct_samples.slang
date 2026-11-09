// How a pixel of a view takes its direct light from samples
// (render/frame.odin pass_direct): what direct_rays.comp, direct_samples.comp
// and direct_filter.comp share.
//
// Each pixel weighs the lights of its cell of the grid at its point
// (direct_grid.slang), and the sun where no map of the view holds the point
// (sun_map_of: where one does, it tells how much of the sun gets there and the
// sun takes no samples), and spreads its samples over them by those weights, one at each m-th of their sum from the place of the pixel in a 3x3
// pattern on: a light with a k-th of the weight takes about m/k samples and
// none is drawn by chance. The cost of a pixel is that of its samples and of
// the lights it weighs, DIRECT_FEW at most, whatever the number of lights.
#ifndef MIRAI_DIRECT_SAMPLES_SLANG
#define MIRAI_DIRECT_SAMPLES_SLANG

// What stopped the ray of a pixel (direct_rays.comp): an instance, or
// DIRECT_NONE; DIRECT_CHANGED where it met what changed (occluder_changed).
#define DIRECT_NONE 0x7FFFFFFFu
#define DIRECT_CHANGED 0x80000000u

// The place of a pixel in the pattern of 3x3: consecutive places stand apart,
// as in an ordered dither, so that a window of 3x3 holds each once.
static const uint DIRECT_PLACES[9] = {0u, 7u, 3u, 6u, 5u, 2u, 4u, 1u, 8u};
uint direct_place(int2 p) { return DIRECT_PLACES[uint(p.x) % 3u + 3u * (uint(p.y) % 3u)]; }

// Where its samples start among the m-ths of the sum of the weights.
float direct_start(uint place) { return (float(place) + 0.5) / 9.0; }

// The points of a view the samples are taken at: one for each pixel, or the
// first of each `scale` x `scale` of them; what follows counts in points.
int2 direct_points(int scale) { return (int2(frame.resolution) + scale - 1) / scale; }

// The pixel of thread t of a group of 4x4 squares of 2x2 pixels, the threads
// of a square together.
int2 direct_group_pixel(uint2 group, uint t) {
    uint2 square = uint2(group.x * 4u + ((t >> 2u) & 3u), group.y * 4u + (t >> 4u));
    return int2(square * 2u + uint2(t & 1u, (t >> 1u) & 1u));
}

// Whether a point at `point`, with that normal, lies on the surface of a
// center at `center` with its normal and the width of a point there (w),
// `apart` points away.
bool direct_surface(float3 center, float4 normal, float3 point, float3 point_normal, float apart) {
    if (dot(normal.xyz, point_normal) < 0.9) return false;
    return abs(dot(point - center, normal.xyz)) <= 2.0 * normal.w * apart + 1e-4;
}

// The most points a penumbra spreads the part of the light that got there to
// each side (direct_spread.comp), and that reach over the width of the
// penumbra: the weights of the spread fall off to nothing at it, and so wide
// they ramp the border of a hard shadow as the disc of a light does.
#define DIRECT_SPREAD_MAX 16
#define DIRECT_SPREAD_REACH 0.62

// The width in metres of the penumbra a sample towards `light` (the sun for
// INVALID), which reaches `reach` metres, casts with what hid it `near` metres
// away: the angle of the sun, or the width of the light, by that distance over
// the one from what hid it to the light.
float direct_penumbra(uint light, float reach, float near, float sun_radius) {
    if (light == INVALID) return 2.0 * sun_radius * near;
    float radius = light_extent(lights[light]);
    return 2.0 * radius * near / max(reach + radius - near, radius);
}

// Whether a pixel traces one of its samples through the whole scene: one of
// each 2x2, so that a group traces 16 rays.
bool direct_traces(int2 p) { return ((p.x | p.y) & 1) == 0; }

// The sample of the m of a pixel traced through the whole scene: the 16 rays
// of a group spread over all m in the order their squares stand in it, so
// that they go to every light that takes samples and find what the samples
// of the group meet; INVALID for a pixel that traces none.
uint direct_traced(int2 p, uint m) {
    if (!direct_traces(p)) return INVALID;
    uint2 square = uint2(p) >> 1u;
    uint at = (square.x & 3u) + 4u * (square.y & 3u);
    return (at * m) / 16u % m;
}

// Sample k of the m of a pixel: the point of its light, of sixteen across it
// (light_point, sun_ray), so that the samples of a window of the pattern spread
// over the light; how the disc is turned, another for each square of the
// pattern; and where among the lights of a group it picks.
float direct_point(uint place, uint m, uint k) { return 16.0 * (float(place + 9u * k) + 0.5) / float(9u * m); }
float direct_spin(int2 p) {
    uint h = hash_u32(uint(p.x / 3) * 73856093u ^ uint(p.y / 3) * 19349663u);
    return float(h) * (2.0 * PI / 4294967296.0);
}
float direct_pick(uint place, uint m, uint k) { return frac(0.5 + float(place * m + k) * 0.6180339887); }

// The weight of the sun at a point: the luminance of its light on the surface.
float direct_sun_weight(float3 position, float3 normal) {
    if (frame.sun_direction.w < 0.5) return 0.0;
    return luminance(sun_light(position)) * saturate(dot(normal, frame.sun_direction.xyz));
}

#endif
