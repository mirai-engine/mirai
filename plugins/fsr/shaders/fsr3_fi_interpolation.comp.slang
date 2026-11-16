// AMD FidelityFX FSR 3.1.4 (MIT): the frame in between the frame before and
// this one, of ffx_frameinterpolation_pass.hlsl, with the slots of the plugin
// (framegen.odin). The groups of 8 cover the image whole: the lanes past it
// store nothing, as D3D12 drops them.
#include "custom_slots.slang"
#define FFX_FRAMEINTERPOLATION_BIND_SRV_GAME_MOTION_VECTOR_FIELD_X CUSTOM_SLOT_2
#define FFX_FRAMEINTERPOLATION_BIND_SRV_GAME_MOTION_VECTOR_FIELD_Y CUSTOM_SLOT_3
#define FFX_FRAMEINTERPOLATION_BIND_SRV_OPTICAL_FLOW_MOTION_VECTOR_FIELD_X CUSTOM_SLOT_4
#define FFX_FRAMEINTERPOLATION_BIND_SRV_OPTICAL_FLOW_MOTION_VECTOR_FIELD_Y CUSTOM_SLOT_5
#define FFX_FRAMEINTERPOLATION_BIND_SRV_PREVIOUS_INTERPOLATION_SOURCE CUSTOM_SLOT_6
#define FFX_FRAMEINTERPOLATION_BIND_SRV_CURRENT_INTERPOLATION_SOURCE CUSTOM_SLOT_7
#define FFX_FRAMEINTERPOLATION_BIND_SRV_DISOCCLUSION_MASK CUSTOM_SLOT_8
#define FFX_FRAMEINTERPOLATION_BIND_SRV_INPAINTING_PYRAMID CUSTOM_SLOT_9
#define FFX_FRAMEINTERPOLATION_BIND_SRV_COUNTERS CUSTOM_SLOT_10
#define FFX_FRAMEINTERPOLATION_BIND_UAV_OUTPUT CUSTOM_SLOT_11
#define FFX_FRAMEINTERPOLATION_BIND_CB_FRAMEINTERPOLATION CUSTOM_SLOT_0
#include "fsr3_framegen_mirai.slang"
#include "fsr3/frameinterpolation/ffx_frameinterpolation_callbacks_hlsl.h"
#include "fsr3/frameinterpolation/ffx_frameinterpolation_common.h"
#include "fsr3/frameinterpolation/ffx_frameinterpolation.h"

[shader("compute")]
[numthreads(8, 8, 1)]
void main(int2 iPxPos : SV_DispatchThreadID) {
    if (any(iPxPos >= DisplaySize())) return;
    computeFrameinterpolation(iPxPos);
}
