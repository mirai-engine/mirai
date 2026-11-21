uint index_width(Fit fit) {
#ifdef BC_ENCODE_6H
    return fit.mode == 11 ? 4 : 3;
#else
    return fit.mode == 6 ? 4 : (fit.mode == 1 ? 3 : 2);
#endif
}

uint partition_of(Fit fit) {
#ifdef BC_ENCODE_6H
    return fit.mode == 11 ? 0 : partitions[fit.partition];
#else
    return fit.mode == 1 ? partitions[fit.partition] : 0;
#endif
}

#ifdef BC_ENCODE_7
bool separate_alpha(Fit fit) { return fit.mode == 5; }
#else
bool separate_alpha(Fit fit) { return false; }
#endif

uint index_bits(Fit fit) {
    return 16 * index_width(fit) - (partition_of(fit) == 0 ? 1 : 2) +
        (separate_alpha(fit) ? 31 : 0);
}

uint endpoint_bits(Fit fit) {
    return 128 - index_bits(fit);
}

#ifdef BC_ENCODE_6H
uint hdr_precision(uint mode) {
    if (mode == 2) return 7;
    if (mode == 10) return 6;
    return 10;
}

uint3 unpack_hdr(uint ep) {
    return (ep >> uint3(0, 10, 20)) & 1023;
}

uint pack_hdr(uint3 ep) {
    return ep.x | (ep.y << 10) | (ep.z << 20);
}

uint3 unquant_hdr(uint ep, uint precision) {
    uint3 q = unpack_hdr(ep);
    uint3 value = ((q << 16) + 32768) >> precision;
    uint top = (1u << precision) - 1;
    return uint3(q.x == 0 ? 0 : (q.x == top ? 65535 : value.x),
                 q.y == 0 ? 0 : (q.y == top ? 65535 : value.y),
                 q.z == 0 ? 0 : (q.z == top ? 65535 : value.z));
}

uint quant_hdr(float3 v, uint precision) {
    uint top = (1u << precision) - 1;
    float3 levels = clamp(v * (float(top + 1) / 255) - 0.5, 0, float(top));
    return pack_hdr(uint3(floor(levels + 0.5)));
}

float4 decoded_endpoints(Fit fit, uint at) {
    uint3 unquantized = unquant_hdr(fit.endpoints[at], hdr_precision(fit.mode));
    return float4(float3((unquantized * 31) >> 6) * (255.0 / 31743.0), 255);
}

float4 interpolate_endpoints(Fit fit, uint at, uint w) {
    uint precision = hdr_precision(fit.mode);
    uint3 a = unquant_hdr(fit.endpoints[at], precision);
    uint3 b = unquant_hdr(fit.endpoints[at + 1], precision);
    uint3 half_bits = ((((64 - w) * a + w * b + 32) >> 6) * 31) >> 6;
    return float4(float3(half_bits) * (255.0 / 31743.0), 255);
}

uint3 hdr_delta(uint mode, uint ep, uint origin) {
    return (unpack_hdr(ep) - unpack_hdr(origin)) & ((1u << hdr_precision(mode)) - 1);
}

bool legal_endpoints(Fit fit) {
    if (fit.mode >= 10) return true;
    uint precision = hdr_precision(fit.mode);
    uint half_range = fit.mode == 1 ? 16 : 32;
    uint limit = (1u << precision) - half_range;
    for (uint e = 1; e < 4; ++e) {
        uint3 delta = hdr_delta(fit.mode, fit.endpoints[e], fit.endpoints.x);
        if (any((delta >= half_range) & (delta < limit))) return false;
    }
    return true;
}

void set_endpoints(inout Fit fit, uint at, Line line, uint parity) {
    uint precision = hdr_precision(fit.mode);
    fit.endpoints[at] = quant_hdr(line.a.xyz, precision);
    fit.endpoints[at + 1] = quant_hdr(line.b.xyz, precision);
}

#else
float4 decoded_endpoints(Fit fit, uint at) {
    uint4 ep = unpack_bytes(fit.endpoints[at]);
    if (fit.mode == 1) ep = (ep << 1) | (ep >> 6);
    if (fit.mode == 5) ep.xyz = (ep.xyz << 1) | (ep.xyz >> 6);
    if (fit.mode == 1) ep.w = 255;
    return float4(ep);
}

float4 interpolate_endpoints(Fit fit, uint at, uint w) {
    uint4 a = uint4(decoded_endpoints(fit, at));
    uint4 b = uint4(decoded_endpoints(fit, at + 1));
    return float4(((64 - w) * a + w * b + 32) >> 6);
}

bool legal_endpoints(Fit fit) { return true; }

bool alpha_kept(float source_alpha, float decoded_alpha) {
    if ((source_alpha == 0 || source_alpha == 255) && source_alpha != decoded_alpha) {
        return false;
    }
    return cutoff_byte == 0 || (source_alpha >= cutoff_byte) == (decoded_alpha >= cutoff_byte);
}

uint4 quant_with_parity(float4 value, uint parity, uint bits) {
    float scale = float((1u << bits) - 1) / 255;
    return 2 * uint4(clamp(floor((value * scale - parity) * 0.5 + 0.5),
                                   0, float((1u << (bits - 1)) - 1))) + parity;
}

void set_endpoints(inout Fit fit, uint at, Line line, uint parity) {
    uint4 a, b;
    switch (fit.mode) {
    case 1: {
        uint4 a0 = quant_with_parity(line.a, 0, 7), b0 = quant_with_parity(line.b, 0, 7);
        uint4 a1 = quant_with_parity(line.a, 1, 7), b1 = quant_with_parity(line.b, 1, 7);
        float3 d0a = float3((a0.xyz << 1) | (a0.xyz >> 6)) - line.a.xyz;
        float3 d0b = float3((b0.xyz << 1) | (b0.xyz >> 6)) - line.b.xyz;
        float3 d1a = float3((a1.xyz << 1) | (a1.xyz >> 6)) - line.a.xyz;
        float3 d1b = float3((b1.xyz << 1) | (b1.xyz >> 6)) - line.b.xyz;
        bool odd = dot(d1a, d1a) + dot(d1b, d1b) < dot(d0a, d0a) + dot(d0b, d0b);
        a = odd ? a1 : a0;
        b = odd ? b1 : b0;
        break;
    }
    case 5:
        a = uint4(floor(line.a * float4(127.0 / 255, 127.0 / 255, 127.0 / 255, 1) + 0.5));
        b = uint4(floor(line.b * float4(127.0 / 255, 127.0 / 255, 127.0 / 255, 1) + 0.5));
        break;
    default:
        a = quant_with_parity(line.a, parity & 1, 8);
        b = quant_with_parity(line.b, parity >> 1, 8);
        break;
    }
    fit.endpoints[at] = pack_bytes(a);
    fit.endpoints[at + 1] = pack_bytes(b);
}
#endif

static float4 palette[2][16];

void prepare_palette(Fit fit, uint partition, uint width) {
    for (uint s = 0; s < (partition == 0 ? 1 : 2); ++s) {
        for (uint j = 0; j < (1u << width); ++j) {
            palette[s][j] = interpolate_endpoints(fit, 2 * s, weight(width, j));
        }
    }
}

void reverse_subset(inout Fit fit, uint partition, uint subset, uint width, bool alpha) {
    uint a = fit.endpoints[subset * 2];
    uint b = fit.endpoints[subset * 2 + 1];
    uint mask = !separate_alpha(fit) ? 0xffffffffu : (alpha ? 0xff000000u : 0x00ffffffu);
    fit.endpoints[subset * 2] = (a & ~mask) | (b & mask);
    fit.endpoints[subset * 2 + 1] = (b & ~mask) | (a & mask);
    for (uint i = 0; i < 16; ++i) {
        if (subset_of(partition, i) == subset) {
            set_index(fit, i, (1u << width) - 1 - index_at(fit, i, uint(alpha)), uint(alpha));
        }
    }
}

void assign_indices(inout Fit fit, bool fixed_endpoints) {
    uint partition = partition_of(fit);
    uint width = index_width(fit);
    uint count = 1u << width;
    prepare_palette(fit, partition, width);
    fit.distortion = 0;
    bool separate = separate_alpha(fit);
    for (uint i = 0; i < 16; ++i) {
        uint subset = subset_of(partition, i);
        uint limit = fixed_endpoints && anchor_of(partition, i) ? count / 2 : count;
        float error = INVALID_FIT, alpha_error = INVALID_FIT;
        uint index = 0, alpha_index = 0;
        float4 v = pixels[i];
        for (uint j = 0; j < limit; ++j) {
            float4 p = palette[subset][j];
#ifdef BC_ENCODE_7
            bool within = alpha_kept(v.w, p.w);
            if (separate && within) {
                float d = v.w - p.w;
                if (d * d < alpha_error) { alpha_error = d * d; alpha_index = j; }
            }
            if (!separate && !within) continue;
            if (separate) p.w = v.w;
#endif
            float e = color_error(v, p);
            if (e < error) { error = e; index = j; }
        }
        set_index(fit, i, index);
        if (separate) set_index(fit, i, alpha_index, 1);
        fit.distortion += error + (separate ? alpha_error : 0);
    }
    if (fixed_endpoints) return;
    if (index_at(fit, 0) >= count / 2) reverse_subset(fit, partition, 0, width, false);
    if (partition != 0 && index_at(fit, partition >> 16) >= count / 2) {
        reverse_subset(fit, partition, 1, width, false);
    }
    if (separate && index_at(fit, 0, 1) >= 2) reverse_subset(fit, partition, 0, 2, true);
    if (!legal_endpoints(fit)) fit.distortion = INVALID_FIT;
}

float measure(Fit fit) {
    uint partition = partition_of(fit), width = index_width(fit);
    prepare_palette(fit, partition, width);
    float error = 0;
    for (uint i = 0; i < 16; ++i) {
        uint subset = subset_of(partition, i);
        float4 decoded = palette[subset][index_at(fit, i)];
#ifdef BC_ENCODE_7
        if (separate_alpha(fit)) decoded.w = palette[0][index_at(fit, i, 1)].w;
        if (!alpha_kept(pixels[i].w, decoded.w)) return INVALID_FIT;
#endif
        error += color_error(pixels[i], decoded);
    }
    return error;
}

Line refine_line(Fit fit, uint partition, uint subset) {
    LeastSquares color = {}, alpha = {};
    uint width = index_width(fit);
    bool separate = separate_alpha(fit);
    for (uint i = 0; i < 16; ++i) {
        if (subset_of(partition, i) != subset) continue;
        add_sample(color, float(weight(width, index_at(fit, i))) / 64, pixels[i]);
        if (separate) {
            add_sample(alpha, float(weight(2, index_at(fit, i, 1))) / 64, pixels[i].w);
        }
    }
    Line fallback = {decoded_endpoints(fit, subset * 2), decoded_endpoints(fit, subset * 2 + 1)};
    Line line = solve_line(color, fallback);
    if (separate) {
        Line limits = {fallback.a.w, fallback.b.w};
        Line opacity = solve_line(alpha, limits);
        line.a.w = opacity.a.w;
        line.b.w = opacity.b.w;
    }
    return line;
}

Fit fit_mode(uint mode, uint partition_id, uint rounds) {
    Fit best = {};
    best.mode = mode;
    best.partition = partition_id;
    best.distortion = INVALID_FIT;
    uint partition = partition_of(best);
#ifdef BC_ENCODE_7
    uint parities = mode == 6 ? 4 : 1;
    float4 channels = float4(1, 1, 1, float(mode == 6));
#else
    uint parities = 1;
    float4 channels = float4(1, 1, 1, 0);
#endif
    Line a = initial_line(partition, 0, channels), b = a;
    if (partition != 0) b = initial_line(partition, 1, channels);
    if (separate_alpha(best)) {
        a.a.w = 255;
        a.b.w = 0;
        for (uint i = 0; i < 16; ++i) {
            a.a.w = min(a.a.w, pixels[i].w);
            a.b.w = max(a.b.w, pixels[i].w);
        }
    }
    for (uint round = 0; round < rounds; ++round) {
        float previous = best.distortion;
        for (uint parity = 0; parity < parities; ++parity) {
            Fit fit = best;
            set_endpoints(fit, 0, a, parity);
            if (partition != 0) set_endpoints(fit, 2, b, 0);
            assign_indices(fit, false);
            choose(best, fit);
        }
        if (best.distortion >= previous || round + 1 == rounds) break;
        a = refine_line(best, partition, 0);
        if (partition != 0) b = refine_line(best, partition, 1);
    }
    return best;
}

// Rank splits by the sum of squared distances to their two subset means.
uint4 select_partitions(uint count, uint trials) {
    float4 errors = INVALID_FIT;
    uint4 best = 0;
    float4 total = 0;
    for (uint i = 0; i < 16; ++i) total += pixels[i];
    for (uint p = 0; p < count; ++p) {
        uint partition = partitions[p] & 65535;
        float4 sum = 0;
        float n = countbits(partition);
        for (uint i = 0; i < 16; ++i) if (subset_of(partition, i) != 0) sum += pixels[i];
        float4 rest = total - sum;
        float error = -dot(sum.xyz, sum.xyz) / n - dot(rest.xyz, rest.xyz) / (16 - n);
        uint trial = p;
        for (uint j = 0; j < trials; ++j) {
            if (error < errors[j]) {
                float saved_error = errors[j]; uint saved = best[j];
                errors[j] = error; best[j] = trial;
                error = saved_error; trial = saved;
            }
        }
    }
    return best;
}

void write_indices(inout uint4 bits, inout uint at, Fit fit) {
    uint partition = partition_of(fit), width = index_width(fit);
    for (uint i = 0; i < 16; ++i) {
        put_bits(bits, at, index_at(fit, i), width - uint(anchor_of(partition, i)));
    }
    if (separate_alpha(fit)) {
        for (uint i = 0; i < 16; ++i) {
            put_bits(bits, at, index_at(fit, i, 1), 2 - uint(i == 0));
        }
    }
}

#ifdef BC_ENCODE_6H
static const uint spans1[BC_COOK_SPAN_COUNT_1] = BC_COOK_SPANS_1;
static const uint spans2[BC_COOK_SPAN_COUNT_2] = BC_COOK_SPANS_2;
static const uint spans10[BC_COOK_SPAN_COUNT_10] = BC_COOK_SPANS_10;

Fit encode_block() {
    uint rounds = params.fast != 0 ? 2 : 3;
    Fit best = fit_mode(11, 0, rounds);
    if (best.distortion == 0) return best;
    uint trials = params.fast != 0 ? 1 : 4;
    uint4 pick = select_partitions(32, trials);
    for (uint i = 0; i < trials; ++i) {
        choose(best, fit_mode(10, pick[i], rounds));
        if (params.fast == 0) {
            choose(best, fit_mode(2, pick[i], rounds));
            choose(best, fit_mode(1, pick[i], rounds));
        }
    }
    return best;
}

void store_block(uint block, Fit fit) {
    uint4 bits = 0;
    uint at = 0;
    if (fit.mode == 11) {
        put_bits(bits, at, 3, 5);
        for (uint e = 0; e < 2; ++e) put_bits(bits, at, fit.endpoints[e], 30);
    } else {
        uint prefix = fit.mode == 10 ? 30 : fit.mode - 1;
        bits.x = prefix;
        uint delta = fit.mode == 1 ? 5 : 6;
        uint4 endpoints = fit.endpoints;
        if (fit.mode != 10) {
            for (uint e = 1; e < 4; ++e) {
                endpoints[e] = pack_hdr(hdr_delta(fit.mode, endpoints[e], endpoints[0]) &
                                        ((1u << delta) - 1));
            }
        }
        uint size = fit.mode == 1 ? BC_COOK_SPAN_COUNT_1 :
            (fit.mode == 2 ? BC_COOK_SPAN_COUNT_2 : BC_COOK_SPAN_COUNT_10);
        for (uint i = 0; i < size; ++i) {
            uint span = fit.mode == 1 ? spans1[i] : (fit.mode == 2 ? spans2[i] : spans10[i]);
            uint e = (span >> 2) & 3;
            uint c = span & 3;
            uint shift = (span >> 4) & 15;
            uint width = span >> 16;
            at = (span >> 8) & 255;
            put_bits(bits, at, (endpoints[e] >> (c * 10 + shift)) & ((1u << width) - 1), width);
        }
        at = 77;
        put_bits(bits, at, fit.partition, 5);
    }
    write_indices(bits, at, fit);
    output.Store4(block * 16, bits);
}

#else
Fit encode_block() {
    uint rounds = params.fast != 0 ? 2 : 3;
    Fit best = fit_mode(6, 0, rounds);
    if (best.distortion == 0) return best;
    bool opaque = true;
    for (uint i = 0; i < 16; ++i) opaque = opaque && pixels[i].w == 255;
    if (opaque) {
        uint trials = params.fast != 0 ? 2 : 4;
        uint4 pick = select_partitions(64, trials);
        for (uint i = 0; i < trials; ++i) choose(best, fit_mode(1, pick[i], rounds));
    }
    if (!opaque || params.fast == 0) choose(best, fit_mode(5, 0, rounds));
    return best;
}

void store_block(uint block, Fit fit) {
    uint4 bits = 0;
    uint at = 0;
    put_bits(bits, at, 1u << fit.mode, fit.mode + 1);
    uint endpoints = fit.mode == 1 ? 4 : 2;
    if (fit.mode == 1) put_bits(bits, at, fit.partition, 6);
    if (fit.mode == 5) put_bits(bits, at, 0, 2);
    uint components = fit.mode == 1 ? 3 : 4;
    for (uint c = 0; c < components; ++c) {
        uint width = fit.mode == 1 ? 6 : (fit.mode == 5 && c == 3 ? 8 : 7);
        uint pbit = uint(fit.mode != 5);
        for (uint e = 0; e < endpoints; ++e) {
            put_bits(bits, at, ((fit.endpoints[e] >> (c * 8)) & 255) >> pbit, width);
        }
    }
    if (fit.mode == 1) {
        put_bits(bits, at, fit.endpoints[0] & 1, 1);
        put_bits(bits, at, fit.endpoints[2] & 1, 1);
    } else if (fit.mode == 6) {
        put_bits(bits, at, fit.endpoints[0] & 1, 1);
        put_bits(bits, at, fit.endpoints[1] & 1, 1);
    }
    write_indices(bits, at, fit);
    output.Store4(block * 16, bits);
}
#endif
