// AMD FidelityFX FSR 3.1.4 (MIT): the shading change pass of
// ffx_fsr3upscaler_shading_change_pass.hlsl, with the slots of the plugin (fsr.odin).
#include "custom_slots.slang"
#define FSR3UPSCALER_BIND_SRV_SPD_MIPS CUSTOM_SLOT_2
#define FSR3UPSCALER_BIND_UAV_SHADING_CHANGE CUSTOM_SLOT_3
#define FSR3UPSCALER_BIND_CB_FSR3UPSCALER CUSTOM_SLOT_0
#include "fsr3_mirai.slang"
#include "fsr3/fsr3upscaler/ffx_fsr3upscaler_callbacks_hlsl.h"
#include "fsr3/fsr3upscaler/ffx_fsr3upscaler_common.h"
#include "fsr3/fsr3upscaler/ffx_fsr3upscaler_shading_change.h"

[shader("compute")]
[numthreads(8, 8, 1)]
void main(int2 iDispatchThreadId : SV_DispatchThreadID) {
    ShadingChange(iDispatchThreadId);
}
