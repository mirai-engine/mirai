// AMD FidelityFX FSR 3.1.4 (MIT): the depth of the frame in between, as half
// the motion reprojects it, of ffx_frameinterpolation_reconstruct_previous_depth_pass.hlsl,
// with the slots of the plugin (framegen.odin).
#include "custom_slots.slang"
#define FFX_FRAMEINTERPOLATION_BIND_SRV_DILATED_MOTION_VECTORS CUSTOM_SLOT_2
#define FFX_FRAMEINTERPOLATION_BIND_SRV_DILATED_DEPTH CUSTOM_SLOT_3
#define FFX_FRAMEINTERPOLATION_BIND_SRV_CURRENT_INTERPOLATION_SOURCE CUSTOM_SLOT_4
#define FFX_FRAMEINTERPOLATION_BIND_SRV_DISTORTION_FIELD CUSTOM_SLOT_5
#define FFX_FRAMEINTERPOLATION_BIND_UAV_RECONSTRUCTED_DEPTH_INTERPOLATED_FRAME CUSTOM_SLOT_6
#define FFX_FRAMEINTERPOLATION_BIND_CB_FRAMEINTERPOLATION CUSTOM_SLOT_0
#include "fsr3_framegen_mirai.slang"
#include "fsr3/frameinterpolation/ffx_frameinterpolation_callbacks_hlsl.h"
#include "fsr3/frameinterpolation/ffx_frameinterpolation_common.h"
#include "fsr3/frameinterpolation/ffx_frameinterpolation_reconstruct_previous_depth.h"

[shader("compute")]
[numthreads(8, 8, 1)]
void main(int2 iPxPos : SV_DispatchThreadID) {
    reconstructPreviousDepth(iPxPos);
}
