#include "native.slang"
#include "decal.slang"

[[vk::binding(SLOT_PASS1, 0)]]
Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
#define GBUFFER_NORMAL SLOT_PASS2
#include "gbuffer.slang"
#include "pixel.slang"

struct Stage_Input {
    [[vk::location(0)]] nointerpolation uint in_decal : TEXCOORD0;
    [[vk::location(1)]] float3 in_local : TEXCOORD1;
};
struct Stage_Output {
    [[vk::location(0)]] float4 out_albedo : SV_Target0;
    [[vk::location(1)]] float4 out_emission : SV_Target1;
};
[shader("fragment")]
Stage_Output main(Stage_Input input, float4 pixel : SV_Position) {
    Decal d = decals[input.in_decal];
    int2 p = int2(pixel.xy);
    float depth = g_depth.Load(int3(p, 0)).r;
    // A nested view shows another place than the one the box was drawn in.
    if (depth_empty(depth) || depth_nested(depth)) discard;
    float2 uv = (float2(p) + 0.5) * frame.inv_resolution;
    // A pixel sees two faces of the box and one of them draws it: the far
    // one, which is there with the eye inside the box too.
    float3 face = sign(input.in_local) * step(0.4999, abs(input.in_local));
    if (dot(transform_vector(d.to_world, face), view_direction(uv)) <= 0.0) discard;
    Pixel surface = pixel_at(p, uv, depth);
    float3 local = transform_point(d.to_box, surface.position);
    if (any(abs(local) > float3(0.5))) discard;
    float footprint = frame.footprint.x + frame.footprint.y * depth;
    float4 color = decal_color(d, local.xz + 0.5, footprint, gbuffer_normal(p));
    Stage_Output output;
    output.out_albedo = color;
    output.out_emission = float4(render_units(d.emission.rgb), color.a);
    return output;
}
