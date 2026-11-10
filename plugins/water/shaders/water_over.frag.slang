#include "native.slang"
// What the water draws over its glass (water.over_record): the line of the
// surface on the lens where the near plane crosses it. Radiance with its
// alpha; the second target is the share of the pixel it covers.
#define WATER_STAGE
#include "scene.slang"
#include "water.slang"

static const float3 LENS_COLOR = float3(0.02, 0.05, 0.06);

struct Stage_Output {
    [[vk::location(0)]] float4 out_color : SV_Target0;
    [[vk::location(1)]] float4 out_coverage : SV_Target1;
};

[shader("fragment")]
Stage_Output main(float4 pixel_position : SV_Position) {
    Stage_Output output;
    float2 uv = pixel_position.xy * frame.inv_resolution;
    float3 origin = view_origin(uv), ray = view_ray(uv);
    float near = frame.camera_position.w;
    float3 lens = origin + ray * near;
    float4 color = float4(0.0);
    for (uint i = 0u; i < water.count; i++) {
        Water_Body b = bodies[i];
        if (b.surface.z > 0.5) continue;
        float top = water_surface_at(b, lens.xz);
        bool over_column = b.surface.y > 0.5 || all(abs(transform_point(b.to_box, lens).xz) <= 0.5);
        // The surface across the near plane: a dark line, thinner away from where it is.
        float line = abs(lens.y - top);
        if (over_column && line < water.lens) {
            float a = 0.7 * (1.0 - line / water.lens);
            if (a > color.a) color = float4(LENS_COLOR, a);
        }
    }
    if (!(color.a > 0.0)) discard;
    output.out_color = float4(color.rgb, color.a);
    output.out_coverage = float4(color.a, 0.0, 0.0, 0.0);
    return output;
}
