// AMD FidelityFX FSR 3.1.4 (MIT): RCAS over the image the accumulation left,
// of ffx_fsr3upscaler_rcas_pass.hlsl, into the resolved image of the view.
#include "custom_slots.slang"
#define FSR3UPSCALER_BIND_SRV_INPUT_EXPOSURE CUSTOM_SLOT_2
#define FSR3UPSCALER_BIND_SRV_RCAS_INPUT CUSTOM_SLOT_3
#define FSR3UPSCALER_BIND_UAV_UPSCALED_OUTPUT CUSTOM_SLOT_4
#define FSR3UPSCALER_BIND_CB_FSR3UPSCALER CUSTOM_SLOT_0
#define FSR3UPSCALER_BIND_CB_RCAS CUSTOM_SLOT_1
#include "fsr3_mirai.slang"
#include "fsr3/fsr3upscaler/ffx_fsr3upscaler_callbacks_hlsl.h"
#include "fsr3/fsr3upscaler/ffx_fsr3upscaler_common.h"
#include "fsr3/fsr3upscaler/ffx_fsr3upscaler_rcas.h"

[shader("compute")]
[numthreads(64, 1, 1)]
void main(uint3 LocalThreadId : SV_GroupThreadID, uint3 WorkGroupId : SV_GroupID, uint3 Dtid : SV_DispatchThreadID) {
    RCAS(LocalThreadId, WorkGroupId, Dtid);
}
