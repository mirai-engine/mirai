// AMD FidelityFX FSR 3.1.4 (MIT): the pass that dilates the reactivity masks,
// computes disocclusion and updates the accumulation, of
// ffx_fsr3upscaler_prepare_reactivity_pass.hlsl, with the slots of the plugin (fsr.odin).
#include "custom_slots.slang"
#define FSR3UPSCALER_BIND_SRV_RECONSTRUCTED_PREV_NEAREST_DEPTH CUSTOM_SLOT_2
#define FSR3UPSCALER_BIND_SRV_DILATED_MOTION_VECTORS CUSTOM_SLOT_3
#define FSR3UPSCALER_BIND_SRV_DILATED_DEPTH CUSTOM_SLOT_4
#define FSR3UPSCALER_BIND_SRV_REACTIVE_MASK CUSTOM_SLOT_5
#define FSR3UPSCALER_BIND_SRV_TRANSPARENCY_AND_COMPOSITION_MASK CUSTOM_SLOT_6
#define FSR3UPSCALER_BIND_SRV_ACCUMULATION CUSTOM_SLOT_7
#define FSR3UPSCALER_BIND_SRV_SHADING_CHANGE CUSTOM_SLOT_8
#define FSR3UPSCALER_BIND_SRV_CURRENT_LUMA CUSTOM_SLOT_9
#define FSR3UPSCALER_BIND_SRV_INPUT_EXPOSURE CUSTOM_SLOT_10
#define FSR3UPSCALER_BIND_UAV_DILATED_REACTIVE_MASKS CUSTOM_SLOT_11
#define FSR3UPSCALER_BIND_UAV_NEW_LOCKS CUSTOM_SLOT_12
#define FSR3UPSCALER_BIND_UAV_ACCUMULATION CUSTOM_SLOT_13
#define FSR3UPSCALER_BIND_CB_FSR3UPSCALER CUSTOM_SLOT_0
#include "fsr3_mirai.slang"
#include "fsr3/fsr3upscaler/ffx_fsr3upscaler_callbacks_hlsl.h"
#include "fsr3/fsr3upscaler/ffx_fsr3upscaler_common.h"
#include "fsr3/fsr3upscaler/ffx_fsr3upscaler_prepare_reactivity.h"

[shader("compute")]
[numthreads(8, 8, 1)]
void main(int2 iDispatchThreadId : SV_DispatchThreadID) {
    PrepareReactivity(iDispatchThreadId);
}
