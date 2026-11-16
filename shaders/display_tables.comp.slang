#include "native.slang"
// The tables of hue of the ACES 2.0 Output Transform for a display (aces.slang),
// one degree a thread, as OpenColorIO builds them: the cusp of the display
// gamut, the gamma of its upper hull and the reach of AP1 at the J of the
// peak. display_lut.comp reads them.
#include "common.slang"
#include "aces.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

struct Params_Block { float4 red_green; float4 blue_white; float peak; uint pad0; uint pad1; uint pad2; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] RWStructuredBuffer<float4> out_tables : register(MIRAI_REGISTER(u, SLOT_PASS0), space0);

bool any_below_zero(float3 rgb) { return any(rgb < 0.0); }

// The M of the boundary of AP1 at the lightness of the peak: first by steps,
// then halving.
float reach_m(float hue, Aces_Params a) {
    float low = 0.0;
    float high = 50.0;
    while (high < 1300.0 && !any_below_zero(jmh_to_rgb(float3(a.limit_j_max, high, hue), a.reach))) {
        low = high;
        high += 50.0;
    }
    while (high - low > 1e-2) {
        float m = 0.5 * (low + high);
        if (any_below_zero(jmh_to_rgb(float3(a.limit_j_max, m, hue), a.reach))) high = m;
        else low = m;
    }
    return high;
}

// The corners of the cube of the display, R, Y, G, C, B and M: hues that
// go around in order.
float3 cube_corner(uint corner) {
    return float3(((corner + 1u) % 6u) < 3u ? 1.0 : 0.0, ((corner + 5u) % 6u) < 3u ? 1.0 : 0.0, ((corner + 3u) % 6u) < 3u ? 1.0 : 0.0);
}

// The J and M of the most colorful color of the display at a hue: on an edge
// of its cube between two corners, found by halving along it.
float2 display_cusp(float hue, Aces_Params a) {
    float3 rgb[8];
    float3 jmh[8];
    float3 found_rgb[6];
    float3 found_jmh[6];
    uint lowest = 0u;
    for (uint i = 0u; i < 6u; i++) {
        found_rgb[i] = cube_corner(i) * (a.peak / ACES_REFERENCE_LUMINANCE);
        found_jmh[i] = rgb_to_jmh(found_rgb[i], a.limit);
        if (found_jmh[i].z < found_jmh[lowest].z) lowest = i;
    }
    for (uint i = 0u; i < 6u; i++) {
        rgb[i + 1u] = found_rgb[(i + lowest) % 6u];
        jmh[i + 1u] = found_jmh[(i + lowest) % 6u];
    }
    rgb[0] = rgb[6];
    jmh[0] = jmh[6];
    rgb[7] = rgb[1];
    jmh[7] = jmh[1];
    jmh[0].z -= 360.0;
    jmh[7].z += 360.0;
    uint upper = 1u;
    for (uint i = 1u; i < 8u; i++) {
        if (jmh[i].z > hue) {
            upper = i;
            break;
        }
    }
    uint lower = upper - 1u;
    if (jmh[lower].z == hue) return jmh[lower].xy;
    float low = 0.0;
    float high = 1.0;
    for (uint step = 0u; step < 40u && high - low > 1e-7; step++) {
        float t = 0.5 * (low + high);
        float3 sample = rgb_to_jmh(lerp(rgb[lower], rgb[upper], t), a.limit);
        if (sample.z < jmh[lower].z) high = t;
        else if (sample.z >= jmh[upper].z) low = t;
        else if (sample.z > hue) high = t;
        else low = t;
    }
    return rgb_to_jmh(lerp(rgb[lower], rgb[upper], 0.5 * (low + high)), a.limit).xy;
}

// Whether an upper hull of a gamma takes every test point out of the display gamut.
bool gamma_fits(float2 cusp, float hue, float gamma_top_inv, Aces_Params a) {
    const float positions[5] = {0.01, 0.1, 0.5, 0.8, 0.99};
    float focus_j = focus_j_of(cusp.x, a);
    float threshold = lerp(cusp.x, a.limit_j_max, ACES_FOCUS_GAIN_BLEND);
    for (uint i = 0u; i < 5u; i++) {
        float test_j = lerp(cusp.x, a.limit_j_max, positions[i]);
        float slope_gain = focus_gain(test_j, threshold, a);
        float j_source = solve_j_intersect(test_j, cusp.y, focus_j, a.limit_j_max, slope_gain);
        float slope = compression_slope(j_source, focus_j, a.limit_j_max, slope_gain);
        float j_cusp = solve_j_intersect(cusp.x, cusp.y, focus_j, a.limit_j_max, slope_gain);
        float m = gamut_boundary_m(cusp, a.limit_j_max, gamma_top_inv, a.lower_hull_gamma_inv, j_source, slope, j_cusp);
        float3 rgb = jmh_to_rgb(float3(j_source + slope * m, m, hue), a.limit);
        if (!any(rgb > a.peak / ACES_REFERENCE_LUMINANCE)) return false;
    }
    return true;
}

// The smallest gamma of the upper hull that leaves no test point inside the gamut.
float upper_hull_gamma_inv(float2 cusp, float hue, Aces_Params a) {
    float low = 0.0;
    float high = 0.4;
    while (high < 5.0 && !gamma_fits(cusp, hue, 1.0 / high, a)) {
        low = high;
        high += 0.4;
    }
    while (high - low > 1e-5) {
        float gamma = 0.5 * (low + high);
        if (gamma_fits(cusp, hue, 1.0 / gamma, a)) high = gamma;
        else low = gamma;
    }
    return 1.0 / high;
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    uint i = dispatch_id.x;
    if (i >= ACES_HUES) return;
    Aces_Params a = aces_params(params.peak, primaries_make(params.red_green.xy, params.red_green.zw, params.blue_white.xy, params.blue_white.zw));
    float hue = float(i);
    float2 cusp = display_cusp(hue, a);
    cusp.y *= 1.0 + ACES_SMOOTH_M * ACES_SMOOTH_CUSPS;
    out_tables[i] = float4(cusp, upper_hull_gamma_inv(cusp, hue, a), reach_m(hue, a));
}
