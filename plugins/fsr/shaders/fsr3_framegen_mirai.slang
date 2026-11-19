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
// Slang converts f32tof16 and f16tof32 through 16-bit types: the conversions
// of the device between two floats and the halves in a 32-bit integer instead.
#define f32tof16 mirai_f32tof16
#define f16tof32 mirai_f16tof32
uint mirai_pack_half2(float2 value) {
    return spirv_asm {
        result:$$uint = OpExtInst glsl450 PackHalf2x16 $value
    };
}
float2 mirai_unpack_half2(uint halves) {
    return spirv_asm {
        result:$$float2 = OpExtInst glsl450 UnpackHalf2x16 $halves
    };
}
uint mirai_f32tof16(float value) {return mirai_pack_half2(float2(value, 0));}
uint2 mirai_f32tof16(float2 value) {
    uint halves = mirai_pack_half2(value);
    return uint2(halves & 0xffffu, halves >> 16);
}
float mirai_f16tof32(uint value) {return mirai_unpack_half2(value & 0xffffu).x;}
float2 mirai_f16tof32(uint2 value) {return mirai_unpack_half2((value.x & 0xffffu) | (value.y << 16));}

#endif
