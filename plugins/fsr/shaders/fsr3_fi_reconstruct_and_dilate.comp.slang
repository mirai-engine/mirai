// AMD FidelityFX FSR 3.1.4 (MIT): the depth and motion dilated to the nearest
// sample and the depth of the frame before as the motion reprojects it, of
// ffx_frameinterpolation_reconstruct_and_dilate_pass.hlsl (the prepare of the
// frame), with the slots of the plugin (framegen.odin).
#include "custom_slots.slang"
#define FFX_FRAMEINTERPOLATION_BIND_SRV_INPUT_MOTION_VECTORS CUSTOM_SLOT_2
#define FFX_FRAMEINTERPOLATION_BIND_SRV_INPUT_DEPTH CUSTOM_SLOT_3
#define FFX_FRAMEINTERPOLATION_BIND_UAV_RECONSTRUCTED_DEPTH_PREVIOUS_FRAME CUSTOM_SLOT_4
#define FFX_FRAMEINTERPOLATION_BIND_UAV_DILATED_MOTION_VECTORS CUSTOM_SLOT_5
#define FFX_FRAMEINTERPOLATION_BIND_UAV_DILATED_DEPTH CUSTOM_SLOT_6
#define FFX_FRAMEINTERPOLATION_BIND_CB_FRAMEINTERPOLATION CUSTOM_SLOT_0
#include "fsr3_framegen_mirai.slang"
#include "fsr3/frameinterpolation/ffx_frameinterpolation_callbacks_hlsl.h"
#include "fsr3/frameinterpolation/ffx_frameinterpolation_common.h"
#include "fsr3/frameinterpolation/ffx_frameinterpolation_reconstruct_dilated_velocity_and_previous_depth.h"

[shader("compute")]
[numthreads(8, 8, 1)]
void main(int2 iDispatchThreadId : SV_DispatchThreadID) {
    ReconstructAndDilate(iDispatchThreadId);
}
