// AMD FidelityFX FSR 3.1.4 (MIT): the pass that reprojects the history, clips
// it and accumulates it, of ffx_fsr3upscaler_accumulate_pass.hlsl, with
// the slots of the plugin (fsr.odin). Its variant sharpen leaves the image to
// RCAS (fsr3_rcas) instead of writing the output.
//! variant sharpen FFX_FSR3UPSCALER_OPTION_APPLY_SHARPENING=1
#include "custom_slots.slang"
#define FSR3UPSCALER_BIND_SRV_INPUT_EXPOSURE CUSTOM_SLOT_2
#define FSR3UPSCALER_BIND_SRV_DILATED_REACTIVE_MASKS CUSTOM_SLOT_3
#define FSR3UPSCALER_BIND_SRV_DILATED_MOTION_VECTORS CUSTOM_SLOT_4
#define FSR3UPSCALER_BIND_SRV_INTERNAL_UPSCALED CUSTOM_SLOT_5
#define FSR3UPSCALER_BIND_SRV_FARTHEST_DEPTH_MIP1 CUSTOM_SLOT_7
#define FSR3UPSCALER_BIND_SRV_CURRENT_LUMA CUSTOM_SLOT_8
#define FSR3UPSCALER_BIND_SRV_LUMA_INSTABILITY CUSTOM_SLOT_9
#define FSR3UPSCALER_BIND_SRV_INPUT_COLOR CUSTOM_SLOT_10
#define FSR3UPSCALER_BIND_UAV_INTERNAL_UPSCALED CUSTOM_SLOT_11
#define FSR3UPSCALER_BIND_UAV_UPSCALED_OUTPUT CUSTOM_SLOT_12
#define FSR3UPSCALER_BIND_UAV_NEW_LOCKS CUSTOM_SLOT_13
#define FSR3UPSCALER_BIND_CB_FSR3UPSCALER CUSTOM_SLOT_0
#include "fsr3_mirai.slang"
#include "fsr3/fsr3upscaler/ffx_fsr3upscaler_callbacks_hlsl.h"
#include "fsr3/fsr3upscaler/ffx_fsr3upscaler_common.h"
#include "fsr3/fsr3upscaler/ffx_fsr3upscaler_sample.h"
#include "fsr3/fsr3upscaler/ffx_fsr3upscaler_upsample.h"
#include "fsr3/fsr3upscaler/ffx_fsr3upscaler_reproject.h"
#include "fsr3/fsr3upscaler/ffx_fsr3upscaler_accumulate.h"

[shader("compute")]
[numthreads(8, 8, 1)]
void main(uint2 uGroupId : SV_GroupID, uint2 uGroupThreadId : SV_GroupThreadID) {
    const uint GroupRows = (uint(UpscaleSize().y) + 8 - 1) / 8;
    uGroupId.y = GroupRows - uGroupId.y - 1;
    uint2 uDispatchThreadId = uGroupId * uint2(8, 8) + uGroupThreadId;
    Accumulate(uDispatchThreadId);
}
