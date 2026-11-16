// AMD FidelityFX FSR 3.1.4 (MIT): the compute luminance pyramid (SPD) of
// ffx_fsr3upscaler_luma_pyramid_pass.hlsl, with the slots of the plugin (fsr.odin).
#include "custom_slots.slang"
#define FSR3UPSCALER_BIND_SRV_CURRENT_LUMA CUSTOM_SLOT_2
#define FSR3UPSCALER_BIND_SRV_FARTHEST_DEPTH CUSTOM_SLOT_3
#define FSR3UPSCALER_BIND_UAV_SPD_GLOBAL_ATOMIC CUSTOM_SLOT_4
#define FSR3UPSCALER_BIND_UAV_FRAME_INFO CUSTOM_SLOT_5
#define FSR3UPSCALER_BIND_UAV_SPD_MIPS_LEVEL_0 CUSTOM_SLOT_6
#define FSR3UPSCALER_BIND_UAV_SPD_MIPS_LEVEL_1 CUSTOM_SLOT_7
#define FSR3UPSCALER_BIND_UAV_SPD_MIPS_LEVEL_2 CUSTOM_SLOT_8
#define FSR3UPSCALER_BIND_UAV_SPD_MIPS_LEVEL_3 CUSTOM_SLOT_9
#define FSR3UPSCALER_BIND_UAV_SPD_MIPS_LEVEL_4 CUSTOM_SLOT_10
#define FSR3UPSCALER_BIND_UAV_SPD_MIPS_LEVEL_5 CUSTOM_SLOT_11
#define FSR3UPSCALER_BIND_UAV_FARTHEST_DEPTH_MIP1 CUSTOM_SLOT_12
#define FSR3UPSCALER_BIND_CB_FSR3UPSCALER CUSTOM_SLOT_0
#define FSR3UPSCALER_BIND_CB_SPD CUSTOM_SLOT_1
#include "fsr3_mirai.slang"
#include "fsr3/fsr3upscaler/ffx_fsr3upscaler_callbacks_hlsl.h"
#include "fsr3/fsr3upscaler/ffx_fsr3upscaler_common.h"

#include "fsr3/fsr3upscaler/ffx_fsr3upscaler_luma_pyramid.h"

[shader("compute")]
[numthreads(256, 1, 1)]
void main(uint3 WorkGroupId : SV_GroupID, uint LocalThreadIndex : SV_GroupIndex) {
    ComputeAutoExposure(WorkGroupId, LocalThreadIndex);
}
