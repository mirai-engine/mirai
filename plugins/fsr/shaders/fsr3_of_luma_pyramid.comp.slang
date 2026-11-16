// AMD FidelityFX FSR 3.1.4 (MIT): the six levels of the luma under the first
// (SPD), of ffx_opticalflow_compute_luminance_pyramid_pass.hlsl, with the
// slots of the plugin (framegen.odin).
#include "custom_slots.slang"
#define FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_INPUT CUSTOM_SLOT_2
#define FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_INPUT_LEVEL_1 CUSTOM_SLOT_3
#define FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_INPUT_LEVEL_2 CUSTOM_SLOT_4
#define FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_INPUT_LEVEL_3 CUSTOM_SLOT_5
#define FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_INPUT_LEVEL_4 CUSTOM_SLOT_6
#define FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_INPUT_LEVEL_5 CUSTOM_SLOT_7
#define FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_INPUT_LEVEL_6 CUSTOM_SLOT_8
#define FFX_OPTICALFLOW_BIND_CB_COMMON CUSTOM_SLOT_0
#define FFX_OPTICALFLOW_BIND_CB_SPD CUSTOM_SLOT_1
#include "fsr3_framegen_mirai.slang"
#include "fsr3/opticalflow/ffx_opticalflow_callbacks_hlsl.h"
#include "fsr3/opticalflow/ffx_opticalflow_compute_luminance_pyramid.h"

[shader("compute")]
[numthreads(256, 1, 1)]
void main(int2 iGroupId : SV_GroupID, int iLocalIndex : SV_GroupIndex) {
    ComputeOpticalFlowInputPyramid(iGroupId, iLocalIndex);
}
