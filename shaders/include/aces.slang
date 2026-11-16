// The ACES 2.0 Output Transform, as OpenColorIO 2.4+ implements it
// (ops/fixedfunction/ACES2; Copyright Contributors to the OpenColorIO Project,
// BSD-3-Clause: THIRD_PARTY_NOTICES.md). A colour is
// taken to J (lightness), M (colourfulness) and h (hue) of a CAM16-based model
// (Hellwig 2022 with the primaries and the compression of ACES), its J is tone
// scaled to the luminance of the display, its M compressed towards the reach
// gamut (AP1) and then into the display gamut along lines that keep its hue,
// and it returns to the RGB of the display. display_tables.comp builds the
// tables of hue it needs, display_lut.comp bakes it into the display LUT.
#ifndef MIRAI_ACES_SLANG
#define MIRAI_ACES_SLANG

// What white is, nits, and the viewing conditions of the model: a dim surround.
#define ACES_REFERENCE_LUMINANCE 100.0
#define ACES_L_A 100.0
#define ACES_Y_B 20.0
#define ACES_SURROUND_C 0.59
#define ACES_SURROUND_NC 0.9
#define ACES_J_SCALE 100.0
#define ACES_NL_OFFSET 27.13 // 0.2713 * 100
#define ACES_NL_SCALE 400.0

// Chroma compression.
#define ACES_CHROMA_COMPRESS 2.4
#define ACES_CHROMA_COMPRESS_FACT 3.3
#define ACES_CHROMA_EXPAND 1.3
#define ACES_CHROMA_EXPAND_FACT 0.69
#define ACES_CHROMA_EXPAND_THR 0.5

// Gamut compression.
#define ACES_SMOOTH_CUSPS 0.12
#define ACES_SMOOTH_M 0.27
#define ACES_CUSP_MID_BLEND 1.3
#define ACES_FOCUS_GAIN_BLEND 0.3
#define ACES_FOCUS_DISTANCE 1.35
#define ACES_FOCUS_DISTANCE_SCALING 1.75
#define ACES_COMPRESSION_THRESHOLD 0.75

// The tables of hue: one entry a degree.
#define ACES_HUES 360u

struct Primaries { float2 red; float2 green; float2 blue; float2 white; };

Primaries primaries_make(float2 red, float2 green, float2 blue, float2 white) {
    Primaries p;
    p.red = red;
    p.green = green;
    p.blue = blue;
    p.white = white;
    return p;
}

Primaries primaries_ap0() { return primaries_make(float2(0.7347, 0.2653), float2(0.0, 1.0), float2(0.0001, -0.077), float2(0.32168, 0.33767)); }
Primaries primaries_ap1() { return primaries_make(float2(0.713, 0.293), float2(0.165, 0.83), float2(0.128, 0.044), float2(0.32168, 0.33767)); }
Primaries primaries_rec709() { return primaries_make(float2(0.64, 0.33), float2(0.3, 0.6), float2(0.15, 0.06), float2(0.3127, 0.329)); }
// The cone space of the model: not a real set of primaries.
Primaries primaries_cam16() { return primaries_make(float2(0.8336, 0.1735), float2(2.3854, -1.4659), float2(0.087, -0.125), float2(0.333, 0.333)); }

float3x3 inverse3(float3x3 m) {
    float3 c0 = cross(m[1], m[2]);
    float3 c1 = cross(m[2], m[0]);
    float3 c2 = cross(m[0], m[1]);
    return transpose(float3x3(c0, c1, c2)) / dot(m[0], c0);
}

float3 xy_to_xyz(float2 c) { return float3(c.x / c.y, 1.0, (1.0 - c.x - c.y) / c.y); }

// RGB of a set of primaries to CIE XYZ, white of Y one.
float3x3 rgb_to_xyz(Primaries p) {
    float3x3 m = transpose(float3x3(xy_to_xyz(p.red), xy_to_xyz(p.green), xy_to_xyz(p.blue)));
    float3 s = mul(inverse3(m), xy_to_xyz(p.white));
    return float3x3(m[0] * s, m[1] * s, m[2] * s);
}

// RGB of one set of primaries to another, adapting their whites as the
// Bradford transform does.
float3x3 rgb_to_rgb_adapted(Primaries from, Primaries to) {
    const float3x3 bradford = float3x3(0.8951, 0.2664, -0.1614, -0.7502, 1.7135, 0.0367, 0.0389, -0.0685, 1.0296);
    float3 ratio = mul(bradford, xy_to_xyz(to.white)) / mul(bradford, xy_to_xyz(from.white));
    float3x3 adapt = mul(inverse3(bradford), float3x3(bradford[0] * ratio.x, bradford[1] * ratio.y, bradford[2] * ratio.z));
    return mul(inverse3(rgb_to_xyz(to)), mul(adapt, rgb_to_xyz(from)));
}

// The non-linear response of the cones, normalised (the 400 of CAM16 is in the matrices).
float cone_compress(float v) {
    float f = pow(abs(v), 0.42);
    return sign(v) * f / (ACES_NL_OFFSET + f);
}

float cone_compress_inv(float v) {
    float r = min(abs(v), 0.99);
    return sign(v) * pow(ACES_NL_OFFSET * r / (1.0 - r), 1.0 / 0.42);
}

float3 cone_compress(float3 v) { return float3(cone_compress(v.x), cone_compress(v.y), cone_compress(v.z)); }
float3 cone_compress_inv(float3 v) { return float3(cone_compress_inv(v.x), cone_compress_inv(v.y), cone_compress_inv(v.z)); }

// The model for one set of primaries: RGB of them, 1 for 100 nits, to the
// adapted cone responses and those to achromatic and opponent signals.
struct Jmh_Params {
    float3x3 to_cones;
    float3x3 from_cones;
    float3x3 to_aab;
    float3x3 from_aab;
    float f_l_n;
    float cz;
    float a_w_j;
};

float aces_model_gamma() { return ACES_SURROUND_C * (1.48 + sqrt(ACES_Y_B / ACES_REFERENCE_LUMINANCE)); }

Jmh_Params jmh_params(Primaries p) {
    const float3x3 base_aab = float3x3(2.0, 1.0, 1.0 / 20.0, 1.0, -12.0 / 11.0, 1.0 / 11.0, 1.0 / 9.0, 1.0 / 9.0, -2.0 / 9.0);
    float3x3 rgb_to_cam16 = mul(inverse3(rgb_to_xyz(primaries_cam16())), rgb_to_xyz(p));
    float3 rgb_w = mul(rgb_to_cam16, float3(ACES_REFERENCE_LUMINANCE));
    float y_w = mul(rgb_to_xyz(p), float3(ACES_REFERENCE_LUMINANCE)).y;
    float k = 1.0 / (5.0 * ACES_L_A + 1.0);
    float k4 = k * k * k * k;
    float f_l = 0.2 * k4 * (5.0 * ACES_L_A) + 0.1 * (1.0 - k4) * (1.0 - k4) * pow(5.0 * ACES_L_A, 1.0 / 3.0);
    Jmh_Params j;
    j.f_l_n = f_l / ACES_REFERENCE_LUMINANCE;
    j.cz = aces_model_gamma();
    float3 d_rgb = j.f_l_n * y_w / rgb_w;
    float3 rgb_aw = cone_compress(d_rgb * rgb_w);
    float a_w = ACES_NL_SCALE * dot(base_aab[0], rgb_aw);
    j.a_w_j = cone_compress(f_l);
    float3x3 cam = rgb_to_cam16 * ACES_REFERENCE_LUMINANCE;
    j.to_cones = float3x3(cam[0] * d_rgb.x, cam[1] * d_rgb.y, cam[2] * d_rgb.z);
    j.from_cones = inverse3(j.to_cones);
    float opponent = ACES_NL_SCALE * 43.0 * ACES_SURROUND_NC;
    j.to_aab = float3x3(base_aab[0] * (ACES_NL_SCALE / a_w), base_aab[1] * opponent, base_aab[2] * opponent);
    j.from_aab = inverse3(j.to_aab);
    return j;
}

float3 rgb_to_aab(float3 rgb, Jmh_Params j) { return mul(j.to_aab, cone_compress(mul(j.to_cones, rgb))); }
float3 aab_to_rgb(float3 aab, Jmh_Params j) { return mul(j.from_cones, cone_compress_inv(mul(j.from_aab, aab))); }

float wrap_hue(float h) { return h - 360.0 * floor(h / 360.0); }

float3 aab_to_jmh(float3 aab, Jmh_Params j) {
    if (aab.x <= 0.0) return float3(0.0);
    return float3(ACES_J_SCALE * pow(aab.x, j.cz), length(aab.yz), wrap_hue(degrees(atan2(aab.z, aab.y))));
}

float3 jmh_to_aab(float3 jmh, Jmh_Params j) {
    float h = radians(jmh.z);
    return float3(pow(max(jmh.x, 0.0) / ACES_J_SCALE, 1.0 / j.cz), jmh.y * cos(h), jmh.y * sin(h));
}

float3 rgb_to_jmh(float3 rgb, Jmh_Params j) { return aab_to_jmh(rgb_to_aab(rgb, j), j); }
float3 jmh_to_rgb(float3 jmh, Jmh_Params j) { return aab_to_rgb(jmh_to_aab(jmh, j), j); }

// The lightness of an achromatic luminance (nits for 100 at white), and back.
float y_to_j(float y, Jmh_Params j) {
    return sign(y) * ACES_J_SCALE * pow(cone_compress(abs(y) * j.f_l_n) / j.a_w_j, j.cz);
}

float achromatic_to_y(float a, Jmh_Params j) { return cone_compress_inv(j.a_w_j * a) / j.f_l_n; }

// What the transform needs of a display of `peak` nits, its limiting gamut
// and its tables.
struct Aces_Params {
    Jmh_Params input;    // AP0
    Jmh_Params reach;    // AP1
    Jmh_Params limit;    // the primaries of the display
    float peak;
    // tone scale
    float n_r;
    float g;
    float t_1;
    float c_t;
    float s_2;
    float m_2;
    float forward_limit;
    float log_peak;
    // chroma and gamut compression
    float limit_j_max;
    float model_gamma_inv;
    float sat;
    float sat_thr;
    float compr;
    float chroma_compress_scale;
    float mid_j;
    float focus_dist;
    float lower_hull_gamma_inv;
};

Aces_Params aces_params(float peak, Primaries display) {
    Aces_Params a;
    a.input = jmh_params(primaries_ap0());
    a.reach = jmh_params(primaries_ap1());
    a.limit = jmh_params(display);
    a.peak = peak;
    // The tone scale of Daniele Siragusano: 0.18 gives c_d nits on a display of 100.
    const float c = 0.18, c_d = 10.013, w_g = 0.14, r_hit_min = 128.0, r_hit_max = 896.0;
    a.n_r = 100.0;
    a.g = 1.15;
    a.t_1 = 0.04;
    float r_hit = r_hit_min + (r_hit_max - r_hit_min) * (log(peak / a.n_r) / log(10000.0 / 100.0));
    float m_0 = peak / a.n_r;
    float m_1 = 0.5 * (m_0 + sqrt(m_0 * (m_0 + 4.0 * a.t_1)));
    float u = pow((r_hit / m_1) / ((r_hit / m_1) + 1.0), a.g);
    float m = m_1 / u;
    float w_i = log2(peak / 100.0);
    a.c_t = c_d / a.n_r * (1.0 + w_i * w_g);
    float g_ip = 0.5 * (a.c_t + sqrt(a.c_t * (a.c_t + 4.0 * a.t_1)));
    float g_ipp2 = -(m_1 * pow(g_ip / m, 1.0 / a.g)) / (pow(g_ip / m, 1.0 / a.g) - 1.0);
    float w_2 = c / g_ipp2;
    a.s_2 = w_2 * m_1 * ACES_REFERENCE_LUMINANCE;
    float u_2 = pow((r_hit / m_1) / ((r_hit / m_1) + w_2), a.g);
    a.m_2 = m_1 / u_2;
    a.forward_limit = 8.0 * r_hit;
    a.log_peak = log10(peak / a.n_r);
    a.limit_j_max = y_to_j(peak, a.input);
    a.model_gamma_inv = 1.0 / aces_model_gamma();
    a.compr = ACES_CHROMA_COMPRESS + ACES_CHROMA_COMPRESS * ACES_CHROMA_COMPRESS_FACT * a.log_peak;
    a.sat = max(0.2, ACES_CHROMA_EXPAND - ACES_CHROMA_EXPAND * ACES_CHROMA_EXPAND_FACT * a.log_peak);
    a.sat_thr = ACES_CHROMA_EXPAND_THR / peak;
    a.chroma_compress_scale = pow(0.03379 * peak, 0.30596) - 0.45135;
    a.mid_j = y_to_j(a.c_t * ACES_REFERENCE_LUMINANCE, a.input);
    a.focus_dist = ACES_FOCUS_DISTANCE + ACES_FOCUS_DISTANCE * ACES_FOCUS_DISTANCE_SCALING * a.log_peak;
    a.lower_hull_gamma_inv = 1.0 / (1.14 + 0.07 * a.log_peak);
    return a;
}

float aces_tonescale(float y, Aces_Params a) {
    float f = a.m_2 * pow(max(y, 0.0) / (max(y, 0.0) + a.s_2), a.g);
    return max(0.0, f * f / (f + a.t_1)) * a.n_r;
}

float chroma_compress_norm(float cos_h, float sin_h, float scale) {
    float cos_2h = 2.0 * cos_h * cos_h - 1.0;
    float sin_2h = 2.0 * cos_h * sin_h;
    float cos_3h = 4.0 * cos_h * cos_h * cos_h - 3.0 * cos_h;
    float sin_3h = 3.0 * sin_h - 4.0 * sin_h * sin_h * sin_h;
    float m = 11.34072 * cos_h + 16.46899 * cos_2h + 7.8838 * cos_3h + 14.66441 * sin_h - 6.37224 * sin_2h + 9.19364 * sin_3h + 77.12896;
    return m * scale;
}

float aces_toe(float x, float limit, float k1_in, float k2_in) {
    if (x > limit) return x;
    float k2 = max(k2_in, 0.001);
    float k1 = sqrt(k1_in * k1_in + k2 * k2);
    float k3 = (limit + k1) / (limit + k2);
    float minus_b = k3 * x - k1;
    return 0.5 * (minus_b + sqrt(minus_b * minus_b + 4.0 * k2 * k3 * x));
}

float chroma_compress(float j, float m, float j_ts, float m_norm, float reach_m, Aces_Params a) {
    if (m == 0.0) return m;
    float nj = j_ts / a.limit_j_max;
    float snj = max(0.0, 1.0 - nj);
    float limit = pow(nj, a.model_gamma_inv) * reach_m / m_norm;
    float c = m * pow(j_ts / j, a.model_gamma_inv) / m_norm;
    c = limit - aces_toe(limit - c, limit - 0.001, snj * a.sat, sqrt(nj * nj + a.sat_thr));
    c = aces_toe(c, limit, nj * a.compr, snj);
    return c * m_norm;
}

float focus_gain(float j, float analytical_threshold, Aces_Params a) {
    float gain = a.limit_j_max * a.focus_dist;
    if (j > analytical_threshold) {
        float adjust = log10((a.limit_j_max - analytical_threshold) / max(0.0001, a.limit_j_max - j));
        gain *= adjust * adjust + 1.0;
    }
    return gain;
}

float solve_j_intersect(float j, float m, float focus_j, float max_j, float slope_gain) {
    float m_scaled = m / slope_gain;
    float a = m_scaled / focus_j;
    if (j < focus_j) {
        float b = 1.0 - m_scaled;
        float c = -j;
        return -2.0 * c / (b + sqrt(b * b - 4.0 * a * c));
    }
    float b = -(1.0 + m_scaled + max_j * a);
    float c = max_j * m_scaled + j;
    return -2.0 * c / (b - sqrt(b * b - 4.0 * a * c));
}

float smin_scaled(float a, float b, float scale) {
    float s = ACES_SMOOTH_CUSPS * scale;
    float h = max(s - abs(a - b), 0.0) / s;
    return min(a, b) - h * h * h * s * (1.0 / 6.0);
}

float compression_slope(float intersect_j, float focus_j, float limit_j_max, float slope_gain) {
    float scaler = intersect_j < focus_j ? intersect_j : limit_j_max - intersect_j;
    return scaler * (intersect_j - focus_j) / (focus_j * slope_gain);
}

// Where a line from the J axis meets a boundary J = J_max (M / M_max)^(1/gamma),
// approximated through the intersection of a reference line.
float line_boundary_m(float j_axis, float slope, float inv_gamma, float j_max, float m_max, float j_reference) {
    float shifted = j_reference * pow(j_axis / j_reference, inv_gamma);
    return shifted * m_max / (j_max - slope * m_max);
}

float gamut_boundary_m(float2 cusp, float j_max, float gamma_top_inv, float gamma_bottom_inv, float j_source, float slope, float j_cusp) {
    float lower = line_boundary_m(j_source, slope, gamma_bottom_inv, cusp.x, cusp.y, j_cusp);
    float upper = line_boundary_m(j_max - j_source, -slope, gamma_top_inv, j_max - cusp.x, cusp.y, j_max - j_cusp);
    return smin_scaled(lower, upper, cusp.y);
}

float focus_j_of(float cusp_j, Aces_Params a) { return lerp(cusp_j, a.mid_j, min(1.0, ACES_CUSP_MID_BLEND - cusp_j / a.limit_j_max)); }

float remap_m(float m, float gamut_m, float reach_m) {
    float proportion = max(gamut_m / reach_m, ACES_COMPRESSION_THRESHOLD);
    float threshold = proportion * gamut_m;
    if (m <= threshold || proportion >= 1.0) return m;
    float reach_offset = reach_m - threshold;
    float scale = reach_offset / (reach_offset / (gamut_m - threshold) - 1.0);
    float nd = (m - threshold) / scale;
    return threshold + scale * nd / (1.0 + nd);
}

// A hue of the tables: cusp J and M (with its smoothing), the inverse gamma
// of the upper hull of the display gamut and the reach of AP1 at limit J.
float4 hue_entry(StructuredBuffer<float4> tables, float h) {
    float at = wrap_hue(h);
    uint i = min(uint(at), ACES_HUES - 1u);
    return lerp(tables[i], tables[(i + 1u) % ACES_HUES], at - float(i));
}

float3 gamut_compress(float3 jmh, float4 entry, Aces_Params a) {
    float j = jmh.x;
    float m = jmh.y;
    if (j <= 0.0) return float3(0.0, 0.0, jmh.z);
    if (m <= 0.0 || j > a.limit_j_max) return float3(j, 0.0, jmh.z);
    float2 cusp = entry.xy;
    float focus_j = focus_j_of(cusp.x, a);
    float threshold = lerp(cusp.x, a.limit_j_max, ACES_FOCUS_GAIN_BLEND);
    float slope_gain = focus_gain(j, threshold, a);
    float j_source = solve_j_intersect(j, m, focus_j, a.limit_j_max, slope_gain);
    float slope = compression_slope(j_source, focus_j, a.limit_j_max, slope_gain);
    float j_cusp = solve_j_intersect(cusp.x, cusp.y, focus_j, a.limit_j_max, slope_gain);
    float boundary = gamut_boundary_m(cusp, a.limit_j_max, entry.z, a.lower_hull_gamma_inv, j_source, slope, j_cusp);
    if (boundary <= 0.0) return float3(j, 0.0, jmh.z);
    float reach = line_boundary_m(j_source, slope, a.model_gamma_inv, a.limit_j_max, entry.w, a.limit_j_max);
    float remapped = remap_m(m, boundary, reach);
    return float3(j_source + remapped * slope, remapped, jmh.z);
}

// ACES2065-1 (AP0) to the RGB of the display, linear, 1 for 100 nits, from 0
// to peak / 100.
float3 aces_output(float3 ap0, StructuredBuffer<float4> tables, Aces_Params a) {
    // Within AP1, below what the tone scale reaches.
    float3x3 ap0_to_ap1 = mul(inverse3(rgb_to_xyz(primaries_ap1())), rgb_to_xyz(primaries_ap0()));
    float3 ap1 = clamp(mul(ap0_to_ap1, ap0), 0.0, a.forward_limit);
    float3 aab = rgb_to_aab(mul(inverse3(ap0_to_ap1), ap1), a.input);
    float3 jmh = aab_to_jmh(aab, a.input);
    float4 entry = hue_entry(tables, jmh.z);
    float h = radians(jmh.z);
    float m_norm = chroma_compress_norm(cos(h), sin(h), a.chroma_compress_scale);
    float j_ts = y_to_j(aces_tonescale(achromatic_to_y(aab.x, a.input), a), a.input);
    float3 toned = float3(j_ts, chroma_compress(jmh.x, jmh.y, j_ts, m_norm, entry.w, a), jmh.z);
    float3 compressed = gamut_compress(toned, entry, a);
    return clamp(jmh_to_rgb(compressed, a.limit), 0.0, a.peak / ACES_REFERENCE_LUMINANCE);
}

#endif
