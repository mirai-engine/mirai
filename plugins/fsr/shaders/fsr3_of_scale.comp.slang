// AMD FidelityFX FSR 3.1.4 (MIT): the motion of a level carried to the finer
// one, of ffx_opticalflow_scale_optical_flow_advanced_pass_v5.hlsl, with the
// slots of the plugin (framegen.odin).
#include "custom_slots.slang"
#define FFX_OPTICALFLOW_BIND_SRV_OPTICAL_FLOW_INPUT CUSTOM_SLOT_2
#define FFX_OPTICALFLOW_BIND_SRV_OPTICAL_FLOW_PREVIOUS_INPUT CUSTOM_SLOT_3
#define FFX_OPTICALFLOW_BIND_SRV_OPTICAL_FLOW CUSTOM_SLOT_4
#define FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_NEXT_LEVEL CUSTOM_SLOT_5
#define FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_SCD_OUTPUT CUSTOM_SLOT_6
#define FFX_OPTICALFLOW_BIND_CB_COMMON CUSTOM_SLOT_0
#define FFX_OPTICALFLOW_THREAD_GROUP_WIDTH 4
#define FFX_OPTICALFLOW_THREAD_GROUP_HEIGHT 4
#define FFX_OPTICALFLOW_THREAD_GROUP_DEPTH 4
#include "fsr3_framegen_mirai.slang"
#include "fsr3/opticalflow/ffx_opticalflow_callbacks_hlsl.h"
#include "fsr3/opticalflow/ffx_opticalflow_scale_optical_flow_advanced_v5.h"

[shader("compute")]
[numthreads(4, 4, 4)]
void main(int3 iGlobalId : SV_DispatchThreadID, int3 iLocalId : SV_GroupThreadID) {
    ScaleOpticalFlowAdvanced(iGlobalId, iLocalId);
}
