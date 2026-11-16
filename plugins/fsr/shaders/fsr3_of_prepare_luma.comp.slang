// AMD FidelityFX FSR 3.1.4 (MIT): the luma the optical flow compares, of
// ffx_opticalflow_prepare_luma_pass.hlsl, with the slots of the plugin (framegen.odin).
#include "custom_slots.slang"
#define FFX_OPTICALFLOW_BIND_SRV_INPUT_COLOR CUSTOM_SLOT_2
#define FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_INPUT CUSTOM_SLOT_3
#define FFX_OPTICALFLOW_BIND_CB_COMMON CUSTOM_SLOT_0
#include "fsr3_framegen_mirai.slang"
#include "fsr3/opticalflow/ffx_opticalflow_callbacks_hlsl.h"
#include "fsr3/opticalflow/ffx_opticalflow_prepare_luma.h"

[shader("compute")]
[numthreads(16, 16, 1)]
void main(int2 iGlobalId : SV_DispatchThreadID, int iLocalIndex : SV_GroupIndex) {
    PrepareLuma(iGlobalId, iLocalIndex);
}
