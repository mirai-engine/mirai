// AMD FidelityFX FSR 3.1.4 (MIT): the pass that follows the luma of the last
// frames and flags what changes, of ffx_fsr3upscaler_luma_instability_pass.hlsl,
// with the slots of the plugin (fsr.odin).
#include "custom_slots.slang"
#define FSR3UPSCALER_BIND_SRV_INPUT_EXPOSURE CUSTOM_SLOT_2
#define FSR3UPSCALER_BIND_SRV_DILATED_REACTIVE_MASKS CUSTOM_SLOT_3
#define FSR3UPSCALER_BIND_SRV_DILATED_MOTION_VECTORS CUSTOM_SLOT_4
#define FSR3UPSCALER_BIND_SRV_FRAME_INFO CUSTOM_SLOT_5
#define FSR3UPSCALER_BIND_SRV_LUMA_HISTORY CUSTOM_SLOT_6
#define FSR3UPSCALER_BIND_SRV_FARTHEST_DEPTH_MIP1 CUSTOM_SLOT_7
#define FSR3UPSCALER_BIND_SRV_CURRENT_LUMA CUSTOM_SLOT_8
#define FSR3UPSCALER_BIND_UAV_LUMA_HISTORY CUSTOM_SLOT_9
#define FSR3UPSCALER_BIND_UAV_LUMA_INSTABILITY CUSTOM_SLOT_10
#define FSR3UPSCALER_BIND_CB_FSR3UPSCALER CUSTOM_SLOT_0
#include "fsr3_mirai.slang"
#include "fsr3/fsr3upscaler/ffx_fsr3upscaler_callbacks_hlsl.h"
#include "fsr3/fsr3upscaler/ffx_fsr3upscaler_common.h"
#include "fsr3/fsr3upscaler/ffx_fsr3upscaler_luma_instability.h"

[shader("compute")]
[numthreads(8, 8, 1)]
void main(int2 iDispatchThreadId : SV_DispatchThreadID) {
    LumaInstability(iDispatchThreadId);
}
