// What a preview lit as a scene shows behind its triangles: the background or
// the sky of the frame, with the ground grid, by the exposure of the frame.
#include "native.slang"
#include "scene.slang"
#include "grid.slang"
#include "display.slang"

struct Stage_Input {
    [[vk::location(0)]] float2 in_uv : TEXCOORD0;
};

[shader("fragment")]
float4 main(Stage_Input input) : SV_Target0 {
    float3 sky = frame.background.w > 0.5 ? frame.background.rgb : sky_seen(view_direction(input.in_uv));
    return float4(preview_encode(ground_grid_background(sky, input.in_uv) * frame.exposure), 1.0);
}
