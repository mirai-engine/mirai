#include "native.slang"
// What each pixel of the layer sees through the aperture: a disc of rings of
// samples, evenly over its area, as wide as its own circle of confusion or as
// the widest one in front of the focus in its tile and those around it. A
// sample nearer than the pixel (its circle is smaller, signed) reaches it as
// far as its own circle and covers it by the share of the disc of that circle
// it stands for: what is in front blurs over what is behind it, also when
// both are in front of the focus. One that is not nearer reaches it as far as
// the smaller of the two circles, so what is behind does not spread over what
// is sharp in front of it. The near layer goes over the rest by what it covers.
#include "lens.slang"

#define LENS_RINGS 4

[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> layer : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> bokeh : register(MIRAI_REGISTER(u, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] Texture2D<float4> tiles : register(MIRAI_REGISTER(t, SLOT_PASS2), space0);

// How much a circle of radius reach covers a sample at distance, softened
// over the space between two rings (margin).
float covers(float reach, float distance, float margin) { return saturate((reach - distance) / margin + 0.5); }

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    int2 p = int2(id.xy);
    if (any(p >= int2(lens.target.xy))) return;
    float4 center = layer.Load(int3(p, 0));
    int2 tile = p / LENS_DOF_TILE;
    int2 tile_count = texture_size(tiles, 0);
    float front_reach = 0.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) front_reach = max(front_reach, tiles.Load(int3(clamp(tile + int2(x, y), int2(0), tile_count - 1), 0)).r);
    }
    float own = abs(center.a);
    float radius = max(own, front_reach);
    if (radius < 0.5) {
        bokeh[p] = float4(center.rgb, 0.0);
        return;
    }
    float margin = max(radius / float(LENS_RINGS), 0.5);
    float4 behind = float4(0.0), front = float4(0.0);
    float count = 0.0;
    for (int ring = 0; ring <= LENS_RINGS; ring++) {
        int samples = max(ring * 7, 1);
        float distance = radius * float(ring) / float(LENS_RINGS);
        for (int i = 0; i < samples; i++) {
            float angle = (float(i) + 0.5 * float(ring & 1)) * (2.0 * PI / float(samples));
            float2 offset = distance * float2(cos(angle), sin(angle));
            float4 s = layer.SampleLevel(linear_sampler, (float2(p) + 0.5 + offset) * lens.target.zw, 0.0);
            float reach = max(abs(s.a), 0.5);
            float nearer = saturate(center.a - s.a);
            // What is nearly sharp covers nothing around it: the image keeps it at its own size.
            float w_front = covers(reach, distance, margin) * min(radius * radius / (reach * reach), 64.0) * nearer * smoothstep(0.75, 1.25, reach);
            float w_behind = covers(min(reach, max(own, 0.5)), distance, margin) * (1.0 - nearer);
            behind += float4(s.rgb, 1.0) * w_behind;
            front += float4(s.rgb, 1.0) * w_front;
            count += 1.0;
        }
    }
    behind.rgb /= max(behind.a, 1e-4);
    front.rgb /= max(front.a, 1e-4);
    float alpha = saturate(front.a / count);
    bokeh[p] = float4(lerp(behind.rgb, front.rgb, alpha), alpha);
}
