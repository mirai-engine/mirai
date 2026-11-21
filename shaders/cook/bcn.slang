#include "shared_constants.slang"

struct Params {
    uint width, height, source_format, fast;
    float cutoff, lambda;
    uint srgb, pad;
};

struct Fit {
    uint4 endpoints;
    uint4 indices;
    uint mode, partition;
    float distortion, activity;
};

[[vk::binding(0, 0)]] ConstantBuffer<Params> params : register(b0);
[[vk::binding(1, 0)]] ByteAddressBuffer source : register(t1);
#ifdef BC_COOK_RDO
[[vk::binding(2, 0)]] StructuredBuffer<Fit> fits : register(t2);
#else
[[vk::binding(2, 0)]] RWStructuredBuffer<Fit> fits : register(u2);
#endif
[[vk::binding(3, 0)]] RWByteAddressBuffer output : register(u3);

static const float INVALID_FIT = 1e20;
static float4 pixels[16];
static float cutoff_byte;

uint4 unpack_bytes(uint word) {
    return (word >> uint4(0, 8, 16, 24)) & 255;
}

uint pack_bytes(uint4 value) {
    return value.x | (value.y << 8) | (value.z << 16) | (value.w << 24);
}

void load_block(uint2 block) {
    cutoff_byte = ceil(params.cutoff * 255);
    for (uint i = 0; i < 16; ++i) {
        uint2 p = min(4 * block + uint2(i & 3, i >> 2),
                      uint2(params.width, params.height) - 1);
        uint at = p.y * params.width + p.x;
        float4 value;
        if (params.source_format == BC_COOK_SOURCE_RGBA8) {
            value = float4(unpack_bytes(source.Load(4 * at))) / 255;
        } else if (params.source_format == BC_COOK_SOURCE_RGBA32F) {
            value = asfloat(source.Load4(16 * at));
        } else {
            uint2 pair = source.Load2(8 * at);
            uint4 v = uint4(pair.x, pair.x >> 16, pair.y, pair.y >> 16) & 65535;
            value = params.source_format == BC_COOK_SOURCE_RGBA16F ?
                float4(f16tof32(v.x), f16tof32(v.y), f16tof32(v.z), f16tof32(v.w)) :
                float4(v) / 65535;
        }
        value = float4(isnan(value.x) ? 0 : value.x, isnan(value.y) ? 0 : value.y,
                       isnan(value.z) ? 0 : value.z, isnan(value.w) ? 0 : value.w);
#ifdef BC_ENCODE_6H
        const float scale = 255.0 / 31743.0;
        value = clamp(value, 0, 65504);
        pixels[i] = float4(float3(f32tof16(value.x), f32tof16(value.y),
                                 f32tof16(value.z)) * scale, 255);
#else
        pixels[i] = floor(saturate(value) * 255 + 0.5);
#ifdef BC_ENCODE_7
        if (params.cutoff > 0) {
            pixels[i].w = value.w >= params.cutoff ? max(pixels[i].w, cutoff_byte) :
                min(pixels[i].w, cutoff_byte - 1);
        }
#endif
#endif
    }
}

uint index_at(Fit fit, uint texel, uint stream = 0) {
    return (fit.indices[stream * 2 + (texel >> 3)] >> (4 * (texel & 7))) & 15;
}

void set_index(inout Fit fit, uint texel, uint index, uint stream = 0) {
    uint word = stream * 2 + (texel >> 3);
    uint shift = 4 * (texel & 7);
    fit.indices[word] = (fit.indices[word] & ~(15u << shift)) | (index << shift);
}

void put_bits(inout uint4 value, inout uint at, uint bits, uint width) {
    uint word = at >> 5;
    uint shift = at & 31;
    value[word] |= bits << shift;
    if (shift + width > 32) value[word + 1] |= bits >> (32 - shift);
    at += width;
}

float activity_of_block() {
    float3 sum = 0;
    float square = 0;
    for (uint i = 0; i < 16; ++i) {
        float3 v = pixels[i].xyz;
        sum += v;
        square += dot(v, v);
    }
    float3 mean = sum / 16;
    return saturate(sqrt(max(square / 16 - dot(mean, mean), 0)) / 64);
}

#if defined(BC_ENCODE_6H) || defined(BC_ENCODE_7)
static const uint partitions[64] = BC_COOK_PARTITIONS;
static const uint weights2[4] = BC_COOK_WEIGHTS_2;
static const uint weights3[8] = BC_COOK_WEIGHTS_3;
static const uint weights4[16] = BC_COOK_WEIGHTS_4;

uint weight(uint bits, uint index) {
    if (bits == 2) return weights2[index];
    if (bits == 3) return weights3[index];
    return weights4[index];
}

uint subset_of(uint partition, uint texel) {
    return (partition >> texel) & 1;
}

bool anchor_of(uint partition, uint texel) {
    return texel == 0 || texel == (partition >> 16);
}
#endif

float4 channel_weights() {
#if defined(BC_ENCODE_7)
    if (params.srgb != 0) return float4(0.8, 1.5, 0.6, 1.0);
#endif
    return 1;
}

float color_error(float4 source_value, float4 decoded) {
    float4 d = source_value - decoded;
    return dot(d * d, channel_weights());
}

struct Line {
    float4 a, b;
};

Line initial_line(uint partition, uint subset, float4 channels) {
    float4 sum = 0, squares = 0;
    float count = 0;
    for (uint i = 0; i < 16; ++i) {
        if (((partition >> i) & 1) != subset) continue;
        float4 v = pixels[i] * channels;
        sum += v;
        squares += v * v;
        count += 1;
    }
    float4 mean = sum / count;
    float4 variance = squares / count - mean * mean;
    uint major = 0;
    for (uint c = 1; c < 4; ++c) {
        if (variance[c] > variance[major]) major = c;
    }
    if (variance[major] <= 0) {
        Line flat = {mean, mean};
        return flat;
    }
    float4 axis = 0;
    axis[major] = 1;
    for (uint step = 0; step < 3; ++step) {
        float4 next = 0;
        for (uint i = 0; i < 16; ++i) {
            if (((partition >> i) & 1) != subset) continue;
            float4 d = pixels[i] * channels - mean;
            next += d * dot(d, axis);
        }
        float length2 = dot(next, next);
        if (length2 <= 1e-8) break;
        axis = next * rsqrt(length2);
    }
    float lo = 1e10, hi = -1e10;
    for (uint i = 0; i < 16; ++i) {
        if (((partition >> i) & 1) != subset) continue;
        float t = dot(pixels[i] * channels - mean, axis);
        lo = min(lo, t);
        hi = max(hi, t);
    }
    Line line = {clamp(mean + lo * axis, 0, 255), clamp(mean + hi * axis, 0, 255)};
    return line;
}

struct LeastSquares {
    float aa, ab, bb;
    float4 av, bv;
};

void add_sample(inout LeastSquares fit, float t, float4 value) {
    float a = 1 - t;
    fit.aa += a * a;
    fit.ab += a * t;
    fit.bb += t * t;
    fit.av += a * value;
    fit.bv += t * value;
}

Line solve_line(LeastSquares fit, Line fallback) {
    float det = fit.aa * fit.bb - fit.ab * fit.ab;
    if (det < 1e-4) return fallback;
    Line line = {clamp((fit.bb * fit.av - fit.ab * fit.bv) / det, 0, 255),
                 clamp((fit.aa * fit.bv - fit.ab * fit.av) / det, 0, 255)};
    return line;
}

void choose(inout Fit best, Fit trial) {
    if (trial.distortion < best.distortion) best = trial;
}
