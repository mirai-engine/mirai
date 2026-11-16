#include "native.slang"
// Meters the light of the image of a view before its temporal resolve, not
// what its surfaces reflect: the pixels of a grid of about EXPOSURE_SAMPLES
// over the image, params.step apart, so that the cost does not follow the
// resolution, count the luminance a middle gray card would show there, what the pixel shows less its emission
// over the reflectance of its surface (its base color: the diffuse one of a
// dielectric, the specular one of a metal), times 0.18. What glows in nits
// counts by the light it gives: a white surface that faces a light as bright
// shows its luminance. By bins of log2 in nits, in shared memory first, then
// into the histogram of the view, which exposure_adapt.comp reads and clears.
// The sky is not lit: its pixels count apart (EXPOSURE_SKY of the histogram),
// and exposure_adapt.comp takes each of them as the card under the open sky
// and sun. A backdrop (Sky.use_background) is not what the camera sees; the
// sky of a parallel projection is one direction in every pixel, and how many
// of them there are follows the framing, not the light; a pixel without
// light, or whose surface reflects next to nothing and does not glow, says
// nothing of the light: none of them is counted. An
// emission relative to the exposure (GBUFFER_EMISSION_RELATIVE) follows the
// exposure instead of setting it: it is neither light nor surface, and it is
// taken away first.
#define GBUFFER_ALBEDO SLOT_PASS3
#define GBUFFER_EMISSION SLOT_PASS4
#define GBUFFER_NORMAL SLOT_PASS5
#include "gbuffer.slang"
#include "exposure.slang"
#include "depth.slang"
#define MIRAI_GROUP_X 16
#define MIRAI_GROUP_Y 16
#define MIRAI_GROUP_Z 1

struct Params_Block { float light_scale; float step; uint2 grid; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> image : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS2, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS2), space0);
[[vk::binding(SLOT_PASS1, 0)]] RWStructuredBuffer<uint> histogram : register(MIRAI_REGISTER(u, SLOT_PASS1), space0);

groupshared uint counts[EXPOSURE_BINS + 1u];

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID, uint index : SV_GroupIndex) {
    if (index <= EXPOSURE_SKY) counts[index] = 0u;
    GroupMemoryBarrierWithGroupSync();
    int2 p = int2((float2(dispatch_id.xy) + 0.5) * params.step);
    float nits = 0.0;
    if (all(dispatch_id.xy < params.grid) && all(p < texture_size(image, 0))) {
        bool sky = depth_empty(g_depth.Load(int3(p, 0)).r);
        if (sky && frame.background.w <= 0.5 && frame.eye.w > 0.5) InterlockedAdd(counts[EXPOSURE_SKY], 1u);
        if (!sky) {
            float3 shown = image.Load(int3(p, 0)).rgb;
            Gbuffer_Pixel g = gbuffer_read(p);
            float3 relative = gbuffer_relative_emission(g);
            float emitted = luminance(g.emission - relative);
            // What the surface reflects: its diffuse color, and as it turns metal its specular one.
            float reflectance = (g.layers.bits & MATERIAL_LAYER_UNLIT) != 0u ? 0.0 : luminance(lerp(g.base_color, g.f0, g.metallic));
            float lit = max(luminance(shown - relative) - emitted, 0.0);
            nits = MIDDLE_GRAY * (emitted + (reflectance >= 0.01 ? lit / reflectance : 0.0));
        }
        nits /= params.light_scale;
    }
    if (nits > 0.0) InterlockedAdd(counts[exposure_bin(nits)], 1u);
    GroupMemoryBarrierWithGroupSync();
    if (index <= EXPOSURE_SKY && counts[index] != 0u) InterlockedAdd(histogram[index], counts[index]);
}
