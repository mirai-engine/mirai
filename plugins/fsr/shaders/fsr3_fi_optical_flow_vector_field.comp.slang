// AMD FidelityFX FSR 3.1.4 (MIT): the field of the optical flow at the frame
// in between, of ffx_frameinterpolation_optical_flow_vector_field_pass.hlsl,
// with the slots of the plugin (framegen.odin).
#include "custom_slots.slang"
#define FFX_FRAMEINTERPOLATION_BIND_SRV_OPTICAL_FLOW CUSTOM_SLOT_2
#define FFX_FRAMEINTERPOLATION_BIND_SRV_OPTICAL_FLOW_CONFIDENCE CUSTOM_SLOT_3
#define FFX_FRAMEINTERPOLATION_BIND_SRV_DILATED_DEPTH CUSTOM_SLOT_4
#define FFX_FRAMEINTERPOLATION_BIND_SRV_PREVIOUS_INTERPOLATION_SOURCE CUSTOM_SLOT_5
#define FFX_FRAMEINTERPOLATION_BIND_SRV_CURRENT_INTERPOLATION_SOURCE CUSTOM_SLOT_6
#define FFX_FRAMEINTERPOLATION_BIND_UAV_OPTICAL_FLOW_MOTION_VECTOR_FIELD_X CUSTOM_SLOT_7
#define FFX_FRAMEINTERPOLATION_BIND_UAV_OPTICAL_FLOW_MOTION_VECTOR_FIELD_Y CUSTOM_SLOT_8
#define FFX_FRAMEINTERPOLATION_BIND_CB_FRAMEINTERPOLATION CUSTOM_SLOT_0
#include "fsr3_framegen_mirai.slang"
#include "fsr3/frameinterpolation/ffx_frameinterpolation_callbacks_hlsl.h"
#include "fsr3/frameinterpolation/ffx_frameinterpolation_common.h"
#include "fsr3/frameinterpolation/ffx_frameinterpolation_optical_flow_vector_field.h"

[shader("compute")]
[numthreads(8, 8, 1)]
void main(int2 iPxPos : SV_DispatchThreadID) {
    computeOpticalFlowVectorField(iPxPos);
}
