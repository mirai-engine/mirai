// AMD FidelityFX FSR 3.1.4 (MIT): the median of the motion around each block,
// of ffx_opticalflow_filter_optical_flow_pass_v5.hlsl, with the slots of the
// plugin (framegen.odin). The lanes past the blocks of the level, the size
// ffx_opticalflow.cpp gives it, store nothing, as D3D12 drops them.
#include "custom_slots.slang"
#define FFX_OPTICALFLOW_BIND_SRV_OPTICAL_FLOW_PREVIOUS CUSTOM_SLOT_2
#define FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW CUSTOM_SLOT_3
#define FFX_OPTICALFLOW_BIND_CB_COMMON CUSTOM_SLOT_0
#include "fsr3_framegen_mirai.slang"
#include "fsr3/opticalflow/ffx_opticalflow_callbacks_hlsl.h"
#include "fsr3/opticalflow/ffx_opticalflow_filter_optical_flow_v5.h"

[shader("compute")]
[numthreads(16, 4, 1)]
void main(int2 iGlobalId : SV_DispatchThreadID, int2 iLocalId : SV_GroupThreadID, int2 iGroupId : SV_GroupID, int iLocalIndex : SV_GroupIndex) {
    int2 size = (DisplaySize() + FFX_OPTICALFLOW_BLOCK_SIZE - 1) / FFX_OPTICALFLOW_BLOCK_SIZE;
    for (uint level = 0; level < OpticalFlowPyramidLevel(); level++) size = (size + 1) / 2;
    if (any(iGlobalId >= size)) return;
    FilterOpticalFlow(iGlobalId, iLocalId, iGroupId, iLocalIndex);
}
