// AMD FidelityFX FSR 3.1.4 (MIT): the search of the motion of each block of a
// level of the luma, of ffx_opticalflow_compute_optical_flow_advanced_pass_v5.hlsl,
// with the slots of the plugin (framegen.odin). Its sums take the waves of a
// group of 64 lanes, which are one of 64 or two of 32.
#define FFX_WAVE 1
#include "custom_slots.slang"
#define FFX_OPTICALFLOW_BIND_SRV_OPTICAL_FLOW_INPUT CUSTOM_SLOT_2
#define FFX_OPTICALFLOW_BIND_SRV_OPTICAL_FLOW_PREVIOUS_INPUT CUSTOM_SLOT_3
#define FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW CUSTOM_SLOT_4
#define FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_SCD_OUTPUT CUSTOM_SLOT_5
#define FFX_OPTICALFLOW_BIND_CB_COMMON CUSTOM_SLOT_0
#include "fsr3_framegen_mirai.slang"
#include "fsr3/opticalflow/ffx_opticalflow_callbacks_hlsl.h"
#include "fsr3/opticalflow/ffx_opticalflow_compute_optical_flow_v5.h"

[shader("compute")]
[numthreads(64, 1, 1)]
void main(int2 iGlobalId : SV_DispatchThreadID, int2 iLocalId : SV_GroupThreadID, int2 iGroupId : SV_GroupID, int iLocalIndex : SV_GroupIndex) {
    ComputeOpticalFlowAdvanced(iGlobalId, iLocalId, iGroupId, iLocalIndex);
}
