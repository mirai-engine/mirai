#include "native.slang"
// The subsurface of the opaque scene (OpenPBR subsurface), separable in
// screen space (Jimenez et al. 2015, "Separable Subsurface Scattering"): the
// light a white Lambert reflector takes at each pixel with a subsurface
// (composite.comp), spread across the view (params.vertical 0) and then down
// it (1) by a Gaussian per channel as wide as the radius of that channel at
// the pixel, which the second dispatch adds to the image by the weight of the
// subsurface, the diffuse reflectance of the pixel and what its layers leave
// of it (subsurface_kept): the base color comes after the spread, so the
// detail of its texture stays sharp. A tap off the subsurface, or across a
// step of distance wider than the spread, stands for the pixel itself (the
// light does not cross an edge), so every tap keeps its weight and the light
// spread is the light taken: the passes neither add nor lose any. The rays
// and the probes never see the spread: they read the light of each point.
#define GBUFFER_ALBEDO SLOT_PASS0
#define GBUFFER_NORMAL SLOT_PASS1
#include "gbuffer.slang"
#include "pixel.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

struct Params_Block { uint vertical; uint pad0; uint pad1; uint pad2; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS2, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS2), space0);
// rgb the light to spread, a the distance of the pixel, below 0 off the subsurface.
[[vk::binding(SLOT_PASS3, 0)]] Texture2D<float4> spread_in : register(MIRAI_REGISTER(t, SLOT_PASS3), space0);
// Across: the light spread, a as spread_in. Down: the image, which takes what each pixel reflects of it.
[[vk::binding(SLOT_PASS4, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> spread_out : register(MIRAI_REGISTER(u, SLOT_PASS4), space0);

// Taps on each side of a pixel along the axis of a dispatch, and the widest
// Gaussian they stand for, pixels: a wider one is drawn as that one.
#define SUBSURFACE_TAPS 12
#define SUBSURFACE_WIDEST 48.0

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    int2 p = int2(dispatch_id.xy);
    int2 size = int2(frame.resolution);
    if (any(p >= size)) return;
    bool vertical = params.vertical != 0u;
    float4 center = spread_in.Load(int3(p, 0));
    if (!(center.a >= 0.0)) {
        if (!vertical) spread_out[p] = center;
        return;
    }
    Material_Layers l = gbuffer_layers(p, gbuffer_bits_unpack(gbuffer_normal_texel(p)));
    // Metres a pixel spans at its distance, and the radius of each channel in pixels.
    float footprint = max(frame.footprint.x + frame.footprint.y * center.a, 1e-6);
    float3 radius = l.subsurface_radius * l.subsurface_color;
    float3 sigma = clamp(0.5 * radius / footprint, float3(1e-3), float3(SUBSURFACE_WIDEST));
    float widest = max(sigma.r, max(sigma.g, sigma.b));
    float3 sum = center.rgb, weight = float3(1.0);
    if (widest > 0.25) {
        int2 axis = vertical ? int2(0, 1) : int2(1, 0);
        float step = max(1.0, 3.0 * widest / float(SUBSURFACE_TAPS));
        float reach = max(l.subsurface_radius, footprint);
        [loop]
        for (int i = 1; i <= SUBSURFACE_TAPS; i++) {
            int offset = int(round(float(i) * step));
            float3 w = exp(-0.5 * float(offset * offset) / (sigma * sigma));
            for (int side = -1; side <= 1; side += 2) {
                int2 q = p + axis * (offset * side);
                float4 tap = all(q >= int2(0)) && all(q < size) ? spread_in.Load(int3(q, 0)) : float4(0.0, 0.0, 0.0, -1.0);
                // What the surface may climb over the step from the pixel to the tap, and what of the step is an edge.
                float rise = abs(tap.a - center.a) - float(offset) * footprint;
                float apart = tap.a >= 0.0 ? saturate(rise / reach) : 1.0;
                sum += w * lerp(tap.rgb, center.rgb, apart);
                weight += w;
            }
        }
    }
    float3 spread = sum / weight;
    if (!vertical) {
        spread_out[p] = float4(spread, center.a);
        return;
    }
    float depth = g_depth.Load(int3(p, 0)).r;
    Pixel pixel = pixel_at(p, (float2(p) + 0.5) * frame.inv_resolution, depth);
    Shading s = gbuffer_shading(gbuffer_read(p), pixel);
    float3 reflected = l.subsurface * s.diffuse * subsurface_kept(s) * spread;
    spread_out[p] = float4(spread_out[p].rgb + finite_or_zero(reflected), 1.0);
}
