#include "native.slang"
// The light the probe volume gives each point of contact.comp, around its
// normal and the specular lobe of its roughness, which contact_pixels.comp
// takes to the pixels. Apart from the rays of contact.comp, which would leave
// it fewer registers.
#include "probe_light.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

// scale: the pixels across a point, 1 or 2.
struct Params_Block { uint scale; uint pad0; uint pad1; uint pad2; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
#define GBUFFER_NORMAL SLOT_PASS0
#include "gbuffer.slang"
#include "pixel.slang"
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
// rgb: the irradiance around the normal / the light around the specular lobe.
[[vk::binding(SLOT_PASS3, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> out_irradiance : register(MIRAI_REGISTER(u, SLOT_PASS3), space0);
[[vk::binding(SLOT_PASS5, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> out_specular : register(MIRAI_REGISTER(u, SLOT_PASS5), space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    int2 q = int2(dispatch_id.xy);
    int scale = int(params.scale);
    if (any(q >= (int2(frame.resolution) + scale - 1) / scale)) return;
    int2 p = q * scale;
    float depth = g_depth.Load(int3(p, 0)).r;
    if (depth_empty(depth)) {
        out_irradiance[q] = float4(0.0);
        out_specular[q] = float4(0.0);
        return;
    }
    Pixel pixel = pixel_at(p, (float2(p) + 0.5) * frame.inv_resolution, depth);
    float4 normal = gbuffer_normal_roughness(p);
    Shading s = shading_surface(pixel.position, normal.xyz, -pixel.view, float3(0.0), 0.0, normal.w);
    Indirect light = indirect_lobes(pixel.position, normal.xyz, -pixel.view, s, INDIRECT_DIFFUSE | INDIRECT_SPECULAR, 1.0);
    out_irradiance[q] = float4(light.irradiance, 1.0);
    out_specular[q] = float4(light.radiance, 1.0);
}
