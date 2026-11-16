// AMD FidelityFX FSR 3.1.4 frame generation (MIT), vendored in fsr3/: the
// options its optical flow (fsr3_of_*) and frame interpolation (fsr3_fi_*)
// passes are compiled with. Each entry names the slot of the pass
// (CUSTOM_SLOT_n, custom_slots.slang) each resource takes, as framegen.odin
// binds them; the constants go at slot 0 and the second block at slot 1.
//
// The headers are reduced to the configuration Mirai compiles: HLSL on the
// GPU at 32 bits, the depth reversed (1 nearest), the motion vectors offsets
// in UV at the render size without the jitter, and SPD over shared memory
// instead of quad intrinsics. The image interpolated is the final one, sRGB
// encoded. The sampler is the renderer's (SLOT_LINEAR_SAMPLER).
#ifndef MIRAI_FSR3_FRAMEGEN_SLANG
#define MIRAI_FSR3_FRAMEGEN_SLANG

// HLSL qualifiers that have no meaning in SPIR-V, as in fsr3_mirai.slang.
#define unorm
#define globallycoherent
// FfxFloat16 and FfxUInt16 are min16 types even without FFX_HALF, which Slang
// makes 16-bit: the passes stay at 32 bits, as the device enables no 16-bit types.
#define min16float float
#define min16float2 float2
#define min16float3 float3
#define min16float4 float4
#define min16uint uint
#define min16uint2 uint2
#define min16uint3 uint3
#define min16uint4 uint4
#define min16int int
#define min16int2 int2
#define min16int3 int3
#define min16int4 int4
// Slang converts f32tof16 and f16tof32 through 16-bit types: the bits of a
// half float in 32-bit integers instead, rounded to the nearest even.
#define f32tof16 mirai_f32tof16
#define f16tof32 mirai_f16tof32
uint mirai_f32tof16(float value) {
    uint f = asuint(value);
    uint sign = (f >> 16) & 0x8000u;
    uint a = f & 0x7fffffffu;
    if (a >= 0x7f800000u) return sign | (a > 0x7f800000u ? 0x7e00u : 0x7c00u);
    if (a >= 0x477ff000u) return sign | 0x7c00u;
    uint h, rest, halfway;
    if (a < 0x38800000u) {
        if (a < 0x33000000u) return sign;
        uint shift = 126u - (a >> 23);
        uint m = (a & 0x7fffffu) | 0x800000u;
        h = m >> shift;
        rest = m & ((1u << shift) - 1u);
        halfway = 1u << (shift - 1u);
    } else {
        h = (a - 0x38000000u) >> 13;
        rest = a & 0x1fffu;
        halfway = 0x1000u;
    }
    if (rest > halfway || (rest == halfway && (h & 1u) != 0u)) h += 1u;
    return sign | h;
}
uint2 mirai_f32tof16(float2 value) {return uint2(mirai_f32tof16(value.x), mirai_f32tof16(value.y));}
float mirai_f16tof32(uint value) {
    uint sign = (value & 0x8000u) << 16;
    uint e = (value >> 10) & 0x1fu;
    uint m = value & 0x3ffu;
    if (e == 0u) {
        float small = float(m) * 5.9604644775390625e-8;
        return sign != 0u ? -small : small;
    }
    if (e == 31u) return asfloat(sign | 0x7f800000u | (m << 13));
    return asfloat(sign | ((e + 112u) << 23) | (m << 13));
}
float2 mirai_f16tof32(uint2 value) {return float2(mirai_f16tof32(value.x), mirai_f16tof32(value.y));}

#endif
