#ifndef MIRAI_HALVES_SLANG
#define MIRAI_HALVES_SLANG

// Half floats as the bits of a uint, without 16-bit types: f16tof32 and
// f32tof16 make SPIR-V declare the Float16 and Int16 capabilities, which the
// device need not have.

// The value of the bits of a half float.
float half_value(uint bits) {
    uint sign = (bits & 0x8000u) << 16u;
    uint exponent = (bits >> 10u) & 0x1Fu;
    uint mantissa = bits & 0x3FFu;
    if (exponent == 0u) return asfloat(sign | asuint(float(mantissa) * 5.9604645e-8));
    if (exponent == 31u) return asfloat(sign | 0x7F800000u | (mantissa << 13u));
    return asfloat(sign | ((exponent + 112u) << 23u) | (mantissa << 13u));
}

// The bits of the half float nearest a finite value of magnitude at most
// 65504, ties to even as f32tof16 rounds.
uint half_nearest(float value) {
    uint bits = asuint(value);
    uint sign = (bits >> 16u) & 0x8000u;
    uint exponent = (bits >> 23u) & 0xFFu;
    uint mantissa = (bits & 0x7FFFFFu) | (exponent != 0u ? 0x800000u : 0u);
    // Below 2^-14 the half is subnormal: one more bit goes per exponent less.
    bool normal = exponent >= 113u;
    uint shift = normal ? 13u : min(126u - exponent, 25u);
    uint half = normal ? ((exponent - 112u) << 10u) + ((mantissa >> 13u) & 0x3FFu) :
                         mantissa >> shift;
    uint rest = mantissa & ((1u << shift) - 1u), middle = 1u << (shift - 1u);
    if (rest > middle || rest == middle && (half & 1u) != 0u) half += 1u;
    return sign | half;
}

#endif
