// AMD FidelityFX FSR 3.1.4 (MIT): the pass that reconstructs the previous
// nearest depth, dilates motion and depth, and writes the luma of the frame,
// of ffx_fsr3upscaler_prepare_inputs_pass.hlsl, with the slots of the plugin (fsr.odin).
#include "custom_slots.slang"
#define FSR3UPSCALER_BIND_SRV_INPUT_MOTION_VECTORS CUSTOM_SLOT_2
#define FSR3UPSCALER_BIND_SRV_INPUT_DEPTH CUSTOM_SLOT_3
#define FSR3UPSCALER_BIND_SRV_INPUT_COLOR CUSTOM_SLOT_4
#define FSR3UPSCALER_BIND_UAV_DILATED_MOTION_VECTORS CUSTOM_SLOT_5
#define FSR3UPSCALER_BIND_UAV_DILATED_DEPTH CUSTOM_SLOT_6
#define FSR3UPSCALER_BIND_UAV_RECONSTRUCTED_PREV_NEAREST_DEPTH CUSTOM_SLOT_7
#define FSR3UPSCALER_BIND_UAV_FARTHEST_DEPTH CUSTOM_SLOT_8
#define FSR3UPSCALER_BIND_UAV_CURRENT_LUMA CUSTOM_SLOT_9
#define FSR3UPSCALER_BIND_CB_FSR3UPSCALER CUSTOM_SLOT_0
#include "fsr3_mirai.slang"
#include "fsr3/fsr3upscaler/ffx_fsr3upscaler_callbacks_hlsl.h"
#include "fsr3/fsr3upscaler/ffx_fsr3upscaler_common.h"
#include "fsr3/fsr3upscaler/ffx_fsr3upscaler_prepare_inputs.h"

[shader("compute")]
[numthreads(8, 8, 1)]
void main(int2 iDispatchThreadId : SV_DispatchThreadID) {
    PrepareInputs(iDispatchThreadId);
}
