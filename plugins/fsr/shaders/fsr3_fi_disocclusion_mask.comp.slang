// AMD FidelityFX FSR 3.1.4 (MIT): what the frame in between sees that the
// frame before or this one does not, of ffx_frameinterpolation_disocclusion_mask_pass.hlsl,
// with the slots of the plugin (framegen.odin).
#include "custom_slots.slang"
#define FFX_FRAMEINTERPOLATION_BIND_SRV_GAME_MOTION_VECTOR_FIELD_X CUSTOM_SLOT_2
#define FFX_FRAMEINTERPOLATION_BIND_SRV_GAME_MOTION_VECTOR_FIELD_Y CUSTOM_SLOT_3
#define FFX_FRAMEINTERPOLATION_BIND_SRV_RECONSTRUCTED_DEPTH_PREVIOUS_FRAME CUSTOM_SLOT_4
#define FFX_FRAMEINTERPOLATION_BIND_SRV_DILATED_DEPTH CUSTOM_SLOT_5
#define FFX_FRAMEINTERPOLATION_BIND_SRV_RECONSTRUCTED_DEPTH_INTERPOLATED_FRAME CUSTOM_SLOT_6
#define FFX_FRAMEINTERPOLATION_BIND_SRV_INPAINTING_PYRAMID CUSTOM_SLOT_7
#define FFX_FRAMEINTERPOLATION_BIND_SRV_DISTORTION_FIELD CUSTOM_SLOT_8
#define FFX_FRAMEINTERPOLATION_BIND_UAV_DISOCCLUSION_MASK CUSTOM_SLOT_9
#define FFX_FRAMEINTERPOLATION_BIND_CB_FRAMEINTERPOLATION CUSTOM_SLOT_0
#include "fsr3_framegen_mirai.slang"
#include "fsr3/frameinterpolation/ffx_frameinterpolation_callbacks_hlsl.h"
#include "fsr3/frameinterpolation/ffx_frameinterpolation_common.h"
#include "fsr3/frameinterpolation/ffx_frameinterpolation_disocclusion_mask.h"

[shader("compute")]
[numthreads(8, 8, 1)]
void main(int2 iPxPos : SV_DispatchThreadID) {
    computeDisocclusionMask(iPxPos);
}
