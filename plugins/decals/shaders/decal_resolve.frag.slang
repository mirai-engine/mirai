#include "native.slang"
//! variant reflectance MIRAI_DECAL_REFLECTANCE=1
#include "shared_constants.slang"

[[vk::binding(SLOT_PASS5, 0)]]
Texture2DArray<float4> scratch : register(MIRAI_REGISTER(t, SLOT_PASS5), space0);

struct Stage_Output {
    [[vk::location(0)]] float4 albedo : SV_Target0;
    [[vk::location(1)]] float4 normal : SV_Target1;
    [[vk::location(2)]] float4 emission : SV_Target2;
#ifdef MIRAI_DECAL_REFLECTANCE
    [[vk::location(3)]] float4 reflectance : SV_Target3;
#endif
};

[shader("fragment")]
Stage_Output main(float4 pixel : SV_Position) {
    int2 p = int2(pixel.xy);
    Stage_Output output;
    output.normal = scratch.Load(int4(p, 1, 0));
    if (output.normal.w < 0.0) discard;
    output.albedo = scratch.Load(int4(p, 0, 0));
    output.emission = scratch.Load(int4(p, 2, 0));
#ifdef MIRAI_DECAL_REFLECTANCE
    output.reflectance = scratch.Load(int4(p, 3, 0));
#endif
    return output;
}
