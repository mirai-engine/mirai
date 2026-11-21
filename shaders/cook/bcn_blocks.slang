#include "bcn.slang"

#if defined(BC_ENCODE_6H) || defined(BC_ENCODE_7)
#include "bcn_bptc.slang"

#elif defined(BC_ENCODE_5)
float bc4_value(uint a, uint b, uint index) {
    if (index == 0) return a;
    if (index == 1) return b;
    if (a > b) return (float(a) * (8 - index) + float(b) * (index - 1)) / 7;
    if (index < 6) return (float(a) * (6 - index) + float(b) * (index - 1)) / 5;
    return index == 6 ? 0 : 255;
}

uint nearest_bc4(float v, uint2 ep, out float error) {
    bool extended = ep.x <= ep.y;
    uint steps = extended ? 5 : 7;
    float span = float(ep.y) - float(ep.x);
    float t = span != 0 ? saturate((v - float(ep.x)) / span) : 0;
    uint i = uint(floor(t * steps + 0.5));
    uint index = i == 0 ? 0 : (i == steps ? 1 : i + 1);
    float d = v - bc4_value(ep.x, ep.y, index);
    error = d * d;
    if (extended) {
        float e = v * v, f = (255 - v) * (255 - v);
        if (e < error) { error = e; index = 6; }
        if (f < error) { error = f; index = 7; }
    }
    return index;
}

struct ScalarFit {
    uint2 ep;
    float error;
};

ScalarFit scalar_fit(uint channel, uint2 ep) {
    ScalarFit result = {ep, 0};
    for (uint i = 0; i < 16; ++i) {
        float error;
        nearest_bc4(pixels[i][channel], ep, error);
        result.error += error;
    }
    return result;
}

uint2 bc4_endpoints(uint channel) {
    float low = 255, high = 0, interior_low = 255, interior_high = 0;
    for (uint i = 0; i < 16; ++i) {
        float x = pixels[i][channel];
        low = min(low, x);
        high = max(high, x);
        if (x > 0 && x < 255) {
            interior_low = min(interior_low, x);
            interior_high = max(interior_high, x);
        }
    }
    uint2 eight = uint2(uint(high), uint(low));
    uint2 six = uint2(uint(min(interior_low, interior_high)), uint(interior_high));
    if (params.fast != 0) {
        return scalar_fit(channel, eight).error <= scalar_fit(channel, six).error ? eight : six;
    }
    ScalarFit best = {eight, INVALID_FIT};
    for (uint mode = 0; mode < 2; ++mode) {
        uint2 ep = mode == 0 ? eight : six;
        for (uint pass = 0; pass < 3; ++pass) {
            LeastSquares ls = {};
            float error = 0;
            for (uint i = 0; i < 16; ++i) {
                float x = pixels[i][channel];
                float closest;
                uint match = nearest_bc4(x, ep, closest);
                error += closest;
                if (mode == 1 && match >= 6) continue;
                float t = match < 2 ? float(match) : float(match - 1) / (mode == 0 ? 7 : 5);
                add_sample(ls, t, x);
            }
            if (error < best.error) {
                best.ep = ep;
                best.error = error;
            }
            Line start = {float(ep.x), float(ep.y)};
            Line line = solve_line(ls, start);
            uint2 next = uint2(floor(float2(line.a.x, line.b.x) + 0.5));
            if (all(next == ep) || (mode == 0) != (next.x > next.y)) break;
            ep = next;
        }
    }

    uint2 center = best.ep;
    const int radius = 3;
    for (int y = -radius; y <= radius; ++y) {
        for (int x = -radius; x <= radius; ++x) {
            if ((x == 0 && y == 0) || abs(x) + abs(y) > radius) continue;
            uint2 ep = uint2(clamp(int2(center) + int2(x, y), 0, 255));
            ScalarFit trial = scalar_fit(channel, ep);
            if (trial.error < best.error) best = trial;
        }
    }
    return best.ep;
}

float3 xy_normal(float2 p) {
    float2 xy = p * (2.0 / 255.0) - 1;
    float z2 = 1 - dot(xy, xy);
    return z2 >= 0 ? float3(xy, sqrt(z2)) : float3(xy * rsqrt(1 - z2), 0);
}

float normal_error(float3 a, float3 b) {
    float3 d = a - b;
    return dot(d, d) * (255.0 * 255.0 / 4.0);
}

static float bc5_x[8], bc5_y[8];

void bc5_palette(Fit fit) {
    uint2 a = unpack_bytes(fit.endpoints.x).xy;
    uint2 b = unpack_bytes(fit.endpoints.y).xy;
    for (uint j = 0; j < 8; ++j) {
        bc5_x[j] = bc4_value(a.x, b.x, j);
        bc5_y[j] = bc4_value(a.y, b.y, j);
    }
}

void assign_indices(inout Fit fit, bool fixed_endpoints) {
    bc5_palette(fit);
    fit.distortion = 0;
    for (uint i = 0; i < 16; ++i) {
        float2 v = pixels[i].xy;
        float2 first = INVALID_FIT, second = INVALID_FIT;
        uint2 best = 0, alternate = 0;
        for (uint j = 0; j < 8; ++j) {
            float2 d = abs(v - float2(bc5_x[j], bc5_y[j]));
            for (uint c = 0; c < 2; ++c) {
                if (d[c] < first[c]) {
                    second[c] = first[c]; alternate[c] = best[c];
                    first[c] = d[c]; best[c] = j;
                } else if (d[c] < second[c]) {
                    second[c] = d[c]; alternate[c] = j;
                }
            }
        }
        float3 target = xy_normal(v);
        float closest = normal_error(target, xy_normal(float2(bc5_x[best.x], bc5_y[best.y])));
        uint2 index = best;
        if (target.z < 0.95) {
            for (uint j = 1; j < 4; ++j) {
                uint2 candidate = uint2((j & 1) != 0 ? alternate.x : best.x,
                                        (j & 2) != 0 ? alternate.y : best.y);
                float e = normal_error(target,
                    xy_normal(float2(bc5_x[candidate.x], bc5_y[candidate.y])));
                if (e < closest) { closest = e; index = candidate; }
            }
        }
        set_index(fit, i, index.x);
        set_index(fit, i, index.y, 1);
        fit.distortion += closest;
    }
}

float measure(Fit fit) {
    bc5_palette(fit);
    float error = 0;
    for (uint i = 0; i < 16; ++i) {
        float2 value = float2(bc5_x[index_at(fit, i)], bc5_y[index_at(fit, i, 1)]);
        error += normal_error(xy_normal(pixels[i].xy), xy_normal(value));
    }
    return error;
}

void refit_indices(inout Fit fit) {
    for (uint c = 0; c < 2; ++c) {
        uint shift = 8 * c;
        uint2 ep = (fit.endpoints.xy >> shift) & 255;
        bool extended = ep.x <= ep.y;
        LeastSquares ls = {};
        for (uint i = 0; i < 16; ++i) {
            uint index = index_at(fit, i, c);
            if (extended && index >= 6) continue;
            float t = index < 2 ? index : float(index - 1) / (extended ? 5 : 7);
            add_sample(ls, t, pixels[i][c]);
        }
        Line fallback = {float(ep.x), float(ep.y)};
        Line line = solve_line(ls, fallback);
        uint2 pair = uint2(floor(float2(line.a.x, line.b.x) + 0.5));
        if (extended == (pair.x <= pair.y)) {
            fit.endpoints.xy = (fit.endpoints.xy & ~(255u << shift)) | (pair << shift);
        }
    }
    fit.distortion = measure(fit);
}

void snap_endpoints(inout Fit fit, uint step) {
    uint2 x = fit.endpoints.xy & 255;
    uint2 y = fit.endpoints.xy >> 8;
    x = min((x + step / 2) / step * step, 255);
    y = min((y + step / 2) / step * step, 255);
    fit.endpoints.xy = x | (y << 8);
    assign_indices(fit, false);
}

Fit encode_block() {
    uint2 x = bc4_endpoints(0), y = bc4_endpoints(1);
    Fit fit = {};
    fit.endpoints.xy = x | (y << 8);
    if (params.fast != 0) {
        for (uint i = 0; i < 16; ++i) {
            float error;
            set_index(fit, i, nearest_bc4(pixels[i].x, x, error));
            set_index(fit, i, nearest_bc4(pixels[i].y, y, error), 1);
        }
        return fit;
    }
    assign_indices(fit, false);
    return fit;
}

void store_block(uint block, Fit fit) {
    uint4 bits = 0;
    for (uint c = 0; c < 2; ++c) {
        uint at = 64 * c;
        put_bits(bits, at, (fit.endpoints.x >> (8 * c)) & 255, 8);
        put_bits(bits, at, (fit.endpoints.y >> (8 * c)) & 255, 8);
        for (uint i = 0; i < 16; ++i) put_bits(bits, at, index_at(fit, i, c), 3);
    }
    output.Store4(block * 16, bits);
}

uint index_bits(Fit fit) { return 96; }
uint endpoint_bits(Fit fit) { return 32; }

#else
uint quant_565(float3 v) {
    uint3 q = uint3(floor(v * (float3(31, 63, 31) / 255) + 0.5));
    return (q.x << 11) | (q.y << 5) | q.z;
}

float3 expand_565(uint q) {
    uint x = q >> 11, y = (q >> 5) & 63, z = q & 31;
    return float3((x << 3) | (x >> 2), (y << 2) | (y >> 4), (z << 3) | (z >> 2));
}

float3 bc1_value(float3 a, float3 b, uint index, bool three) {
    if (index == 0) return a;
    if (index == 1) return b;
    if (three) return index == 2 ? (a + b) * 0.5 : float3(0);
    return index == 2 ? (2 * a + b) / 3 : (a + 2 * b) / 3;
}

void assign_indices(inout Fit fit, bool fixed_endpoints, uint pair = 0) {
    float3 a = expand_565(fit.endpoints.x), b = expand_565(fit.endpoints.y);
    bool three = fit.endpoints.x <= fit.endpoints.y;
    fit.distortion = 0;
    for (uint i = 0; i < 16; ++i) {
        float3 target = (pixels[i].xyz + pixels[i ^ pair].xyz) * 0.5;
        float min_error = INVALID_FIT;
        uint best = 0;
        for (uint j = 0; j < (three ? 3 : 4); ++j) {
            float3 d = target - bc1_value(a, b, j, three);
            float error = dot(d, d);
            if (error < min_error) { min_error = error; best = j; }
        }
        float3 residual = pixels[i].xyz - bc1_value(a, b, best, three);
        fit.distortion += dot(residual, residual);
        set_index(fit, i, best);
    }
}

float measure(Fit fit) {
    float3 a = expand_565(fit.endpoints.x), b = expand_565(fit.endpoints.y);
    bool three = fit.endpoints.x <= fit.endpoints.y;
    float error = 0;
    for (uint i = 0; i < 16; ++i) {
        float3 d = pixels[i].xyz - bc1_value(a, b, index_at(fit, i), three);
        error += dot(d, d);
    }
    return error;
}

Fit fit_565(Line line, bool three = false) {
    uint a = quant_565(line.a.xyz), b = quant_565(line.b.xyz);
    Fit fit = {};
    fit.endpoints.xy = uint2(max(a, b), min(a, b));
    if (three) fit.endpoints.xy = fit.endpoints.yx;
    if (!three && a == b) {
        if (a == 0) fit.endpoints.x = 1;
        else fit.endpoints.y = b - 1;
    }
    assign_indices(fit, false);
    return fit;
}

Line refine_565(Fit fit) {
    bool three = fit.endpoints.x <= fit.endpoints.y;
    LeastSquares ls = {};
    for (uint i = 0; i < 16; ++i) {
        uint j = index_at(fit, i);
        float t = j < 2 ? j : (three ? 0.5 : float(j - 1) / 3);
        add_sample(ls, t, pixels[i]);
    }
    Line fallback = {float4(expand_565(fit.endpoints.x), 0),
                     float4(expand_565(fit.endpoints.y), 0)};
    return solve_line(ls, fallback);
}

void refit_indices(inout Fit fit) {
    Line line = refine_565(fit);
    uint a = quant_565(line.a.xyz), b = quant_565(line.b.xyz);
    if ((a > b) == (fit.endpoints.x > fit.endpoints.y)) fit.endpoints.xy = uint2(a, b);
    fit.distortion = measure(fit);
}

Fit encode_block() {
    float4 lo = 255, hi = 0;
    for (uint i = 0; i < 16; ++i) {
        lo = min(lo, pixels[i]);
        hi = max(hi, pixels[i]);
    }
    Line box = {lo, hi};
    Fit best = fit_565(box);
    Line axis = initial_line(0, 0, float4(1, 1, 1, 0));
    choose(best, fit_565(axis));
    if (params.fast == 0) choose(best, fit_565(axis, true));
    for (uint attempt = 0; attempt < (params.fast != 0 ? 1 : 3); ++attempt) {
        Fit refined = fit_565(refine_565(best), best.endpoints.x <= best.endpoints.y);
        if (refined.distortion >= best.distortion) break;
        best = refined;
    }
    if (params.fast == 0) {
        for (uint pass = 0; pass < 4; ++pass) {
            uint side = pass & 1;
            bool three = best.endpoints.x <= best.endpoints.y;
            for (uint c = 0; c < 3; ++c) {
                uint shift = c == 0 ? 11 : (c == 1 ? 5 : 0);
                uint mask = c == 1 ? 63 : 31;
                int v = int((best.endpoints[side] >> shift) & mask);
                for (int d = -1; d <= 1; d += 2) {
                    if (v + d < 0 || v + d > int(mask)) continue;
                    Fit trial = best;
                    trial.endpoints[side] = (trial.endpoints[side] & ~(mask << shift)) |
                        (uint(v + d) << shift);
                    if (three != (trial.endpoints.x <= trial.endpoints.y)) continue;
                    assign_indices(trial, true);
                    choose(best, trial);
                }
            }
        }
        for (uint c = 0; c < 3; ++c) {
            uint shift = c == 0 ? 11 : (c == 1 ? 5 : 0);
            uint mask = c == 1 ? 63 : 31;
            Fit center = best;
            int2 v = int2((center.endpoints.xy >> shift) & mask);
            for (int d = -1; d <= 1; d += 2) {
                for (int sign = -1; sign <= 1; sign += 2) {
                    int2 q = v + int2(d, d * sign);
                    if (any(q < 0) || any(q > int(mask))) continue;
                    Fit trial = center;
                    trial.endpoints.xy = (trial.endpoints.xy & ~(mask << shift)) |
                                         (uint2(q) << shift);
                    if ((center.endpoints.x > center.endpoints.y) !=
                        (trial.endpoints.x > trial.endpoints.y)) continue;
                    assign_indices(trial, true);
                    choose(best, trial);
                }
            }
        }
    }
    return best;
}

void store_block(uint block, Fit fit) {
    uint4 bits = 0;
    uint at = 0;
    put_bits(bits, at, fit.endpoints.x, 16);
    put_bits(bits, at, fit.endpoints.y, 16);
    for (uint i = 0; i < 16; ++i) put_bits(bits, at, index_at(fit, i), 2);
    output.Store2(block * 8, bits.xy);
}

uint index_bits(Fit fit) { return 32; }
uint endpoint_bits(Fit fit) { return 32; }
#endif
