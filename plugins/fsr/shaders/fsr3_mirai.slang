// AMD FidelityFX Super Resolution 3.1.4 (MIT), vendored in fsr3/: the options
// its passes are compiled with. Each fsr3_*.comp.slang names the slot of the
// pass (CUSTOM_SLOT_n, custom_slots.slang) each resource takes, as fsr.odin
// binds them; the constants go at slot 0 and the second block at slot 1.
//
// The headers are reduced to the configuration Mirai compiles: HLSL on the
// GPU at 32 bits, the depth reversed (1 nearest), the input color HDR in
// render units, the motion vectors offsets in UV at the render size without
// the jitter, and SPD over shared memory instead of wave intrinsics. The
// samplers are the renderer's (SLOT_POINT_SAMPLER and SLOT_LINEAR_SAMPLER).
#ifndef MIRAI_FSR3_SLANG
#define MIRAI_FSR3_SLANG

#ifndef FFX_FSR3UPSCALER_OPTION_APPLY_SHARPENING
#define FFX_FSR3UPSCALER_OPTION_APPLY_SHARPENING 0
#endif

// HLSL qualifiers that have no meaning in SPIR-V: the shader clamps the values
// it stores and the atomics are device-scope already.
#define unorm
#define globallycoherent

#endif
