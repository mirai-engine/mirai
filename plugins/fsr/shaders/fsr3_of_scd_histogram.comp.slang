// AMD FidelityFX FSR 3.1.4 (MIT): the histograms of the luma the scene change
// detection compares, of ffx_opticalflow_generate_scd_histogram_pass.hlsl,
// with the slots of the plugin (framegen.odin).
#include "custom_slots.slang"
#define FFX_OPTICALFLOW_BIND_SRV_OPTICAL_FLOW_INPUT CUSTOM_SLOT_2
#define FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_SCD_HISTOGRAM CUSTOM_SLOT_3
#define FFX_OPTICALFLOW_BIND_CB_COMMON CUSTOM_SLOT_0
#include "fsr3_framegen_mirai.slang"
#include "fsr3/opticalflow/ffx_opticalflow_callbacks_hlsl.h"
#include "fsr3/opticalflow/ffx_opticalflow_generate_scd_histogram.h"

[shader("compute")]
[numthreads(32, 8, 1)]
void main(int3 iGlobalId : SV_DispatchThreadID, int2 iLocalId : SV_GroupThreadID, int2 iGroupId : SV_GroupID, int iLocalIndex : SV_GroupIndex) {
    GenerateSceneChangeDetectionHistogram(iGlobalId, iLocalId, iLocalIndex, iGroupId, int2(32, 8));
}
