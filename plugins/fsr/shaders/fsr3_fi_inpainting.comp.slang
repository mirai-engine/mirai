// AMD FidelityFX FSR 3.1.4 (MIT): the frame in between with its holes
// inpainted, of ffx_frameinterpolation_inpainting_pass.hlsl, with the slots of
// the plugin (framegen.odin). The groups of 8 cover the image whole: the lanes
// past it store nothing, as D3D12 drops them. The interpolation leaves the
// inpainting weight in the alpha of the image, which AMD's swapchain ignores:
// the image shown is opaque, as Ldr.
#include "custom_slots.slang"
#define FFX_FRAMEINTERPOLATION_BIND_SRV_OPTICAL_FLOW_SCENE_CHANGE_DETECTION CUSTOM_SLOT_2
#define FFX_FRAMEINTERPOLATION_BIND_SRV_INPAINTING_PYRAMID CUSTOM_SLOT_3
#define FFX_FRAMEINTERPOLATION_BIND_SRV_PRESENT_BACKBUFFER CUSTOM_SLOT_4
#define FFX_FRAMEINTERPOLATION_BIND_SRV_CURRENT_INTERPOLATION_SOURCE CUSTOM_SLOT_5
#define FFX_FRAMEINTERPOLATION_BIND_UAV_OUTPUT CUSTOM_SLOT_6
#define FFX_FRAMEINTERPOLATION_BIND_CB_FRAMEINTERPOLATION CUSTOM_SLOT_0
#include "fsr3_framegen_mirai.slang"
#include "fsr3/frameinterpolation/ffx_frameinterpolation_callbacks_hlsl.h"
#include "fsr3/frameinterpolation/ffx_frameinterpolation_common.h"
#include "fsr3/frameinterpolation/ffx_frameinterpolation_inpainting.h"

[shader("compute")]
[numthreads(8, 8, 1)]
void main(int2 iPxPos : SV_DispatchThreadID) {
    if (any(iPxPos >= DisplaySize())) return;
    computeInpainting(iPxPos);
    StoreFrameinterpolationOutput(iPxPos, FfxFloat32x4(RWLoadFrameinterpolationOutput(iPxPos).rgb, 1.0f));
}
