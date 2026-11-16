// AMD FidelityFX FSR 3.1.4 (MIT): the divergence of the histograms from those
// of the frame before, which detects a change of scene, of
// ffx_opticalflow_compute_scd_divergence_pass.hlsl, with the slots of the plugin (framegen.odin).
#include "custom_slots.slang"
#define FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_SCD_HISTOGRAM CUSTOM_SLOT_2
#define FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_SCD_PREVIOUS_HISTOGRAM CUSTOM_SLOT_3
#define FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_SCD_TEMP CUSTOM_SLOT_4
#define FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_SCD_OUTPUT CUSTOM_SLOT_5
#define FFX_OPTICALFLOW_BIND_CB_COMMON CUSTOM_SLOT_0
#include "fsr3_framegen_mirai.slang"
#include "fsr3/opticalflow/ffx_opticalflow_callbacks_hlsl.h"
#include "fsr3/opticalflow/ffx_opticalflow_compute_scd_divergence.h"

[shader("compute")]
[numthreads(256, 1, 1)]
void main(int3 iGlobalId : SV_DispatchThreadID, int2 iLocalId : SV_GroupThreadID, int2 iGroupId : SV_GroupID, int iLocalIndex : SV_GroupIndex) {
    ComputeSCDHistogramsDivergence(iGlobalId, iLocalId, iLocalIndex, iGroupId, int2(256, 1));
}
