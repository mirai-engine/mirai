#include "native.slang"
// world: the points of a panel placed in the scene.
//! constant world MIRAI_UI_WORLD
#include "scene.slang"
// UI geometry in points: 40 byte vertices written by the engine. On the
// screen the points are those of the window; in the world they are the
// points of a panel placed in the scene (Ui_Vertex of common.slang).
[[vk::binding(SLOT_PASS0, 0)]] StructuredBuffer<Ui_Vertex> ui_vertices : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
struct Params_Block {
    float2 viewport;
    uint shape_base, shape_count;
    // Of a panel in the world.
    float4 origin; // world position of the pivot of the panel; w = 1 to hide it behind the scene
    float4 right;  // world vector of one point along x; w = x of the pivot
    float4 down;   // world vector of one point along y; w = y of the pivot
};
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);

struct Stage_Output {
    float4 position : SV_Position;
    [[vk::location(0)]] float4 out_color : TEXCOORD0;
    [[vk::location(1)]] float2 out_uv : TEXCOORD1;
    [[vk::location(2)]] nointerpolation uint out_material : TEXCOORD2;
    [[vk::location(3)]] float out_depth : TEXCOORD3; // of a panel in the world
};
[shader("vertex")]
Stage_Output main(uint vertex_id : SV_VulkanVertexID) {
    Stage_Output output;
    Ui_Vertex v = ui_vertices[vertex_id];
    output.out_color = v.color;
    output.out_uv = v.uv;
    output.out_material = v.material;
    if (MIRAI_UI_WORLD) {
        float3 world = params.origin.xyz + params.right.xyz * (v.position.x - params.right.w) + params.down.xyz * (v.position.y - params.down.w);
        output.position = view_clip_unjittered(world);
        output.out_depth = dot(world - frame.camera_position.xyz, frame.camera_forward.xyz);
    } else {
        output.position = float4(v.position.x / params.viewport.x * 2.0 - 1.0, 1.0 - v.position.y / params.viewport.y * 2.0, 0.0, 1.0);
        output.out_depth = 0.0;
    }
    return output;
}
