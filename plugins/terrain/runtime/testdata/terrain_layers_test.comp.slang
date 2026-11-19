#include "native.slang"
// Terrain_Layers over a grid of points of a test of the plugin
// (layers_gpu_test.odin), its maps and table the rows of `texels`: what each
// point gives and how many maps it samples.
#define MIRAI_MATERIAL_REFLECTION 1
#include "mirai_material.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

// A test texture is TEST_SIDE texels a side, from row TEST_SIDE * TEST_SIDE * index.
#define TEST_SIDE 8
// The maps of the layers sample by index: colors from TEST_COLORS and their
// normal maps from TEST_NORMALS.
#define TEST_COLORS 100u
#define TEST_NORMALS 200u

struct Params_Block {
    uint side;     // points along x and along y
    uint kind;     // 0: a cell of a Heightfield over the control map; 1: a Volume turning its normal (sweep_normal);
                   // 2: a Volume of two layers whose weights cross along x
    float time;
    uint pad;
    float4 piece;
    float4 heights; // of the color maps of the layers
};
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] StructuredBuffer<float4> texels : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] RWStructuredBuffer<float4> results : register(MIRAI_REGISTER(u, SLOT_PASS1), space0);

static uint test_samples = 0u;
float4 test_sample(uint index) {
    test_samples += 1u;
    // A color map white at the height of its layer; a normal map that leans along its u.
    return index >= TEST_NORMALS ? float4(0.75, 0.5, 1.0, 1.0) : float4(1.0, 1.0, 1.0, params.heights[index - TEST_COLORS]);
}
#define TERRAIN_TEXEL(texture, texel) texels[(texture) * TEST_SIDE * TEST_SIDE + (texel).y * TEST_SIDE + (texel).x]
#define TERRAIN_SAMPLE(index, uv, dx, dy) test_sample(index)
#include "terrain_layers.slang"

// A degree of latitude (from the horizon up y) and of longitude (from x
// towards z) a point, from 3 below 0, so the points cross the borders of the
// eighth of the sphere they sweep.
float3 sweep_normal(float2 degrees) {
    float2 r = (degrees - 3.0) * (3.14159265 / 180.0);
    return float3(cos(r.x) * cos(r.y), sin(r.x), cos(r.x) * sin(r.y));
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    uint count = params.side * params.side;
    if (id.x >= count) return;
    float2 f = (float2(id.x % params.side, id.x / params.side) + 0.5) / float(params.side);
    Mirai_Surface_Context ctx = (Mirai_Surface_Context)0;
    ctx.world_position = float3(f.x, 0.0, f.y);
    ctx.position_dx = float3(0.01, 0.0, 0.0);
    ctx.position_dy = float3(0.0, 0.0, 0.01);
    ctx.object_x = float3(1.0, 0.0, 0.0);
    ctx.object_y = float3(0.0, 1.0, 0.0);
    ctx.object_z = float3(0.0, 0.0, 1.0);
    ctx.vertex_color = float4(1.0);
    ctx.time = params.time;
    ctx.previous_time = params.time;
    ctx.normal = float3(0.0, 1.0, 0.0);
    if (params.kind == 0u) {
        ctx.uv0 = f / max(params.piece.xy, float2(1.0));
    } else if (params.kind == 2u) {
        ctx.uv0 = float2(f.x, 1.0 - f.x);
    } else {
        ctx.uv0 = float2(1.0, 0.0) / max(params.piece.xy, float2(1.0));
        ctx.normal = sweep_normal(float2(float(id.x / params.side), float(id.x % params.side)));
    }
    ctx.vertex_normal = ctx.normal;
    Terrain_Layers::Parameters p;
    p.layers = 0u; p.control = 1u; p.normal = 2u; p.paint = 0xffffffffu;
    p.piece = params.piece;
    p.palette = float4(0.0, 1.0, 2.0, 3.0);
    test_samples = 0u;
    Mirai_Surface s = Terrain_Layers::evaluate(ctx, p);
    results[2u * id.x] = float4(s.base_color, float(test_samples));
    results[2u * id.x + 1u] = float4(s.normal, s.roughness);
    if (params.kind == 1u) {
        // The weights of the projections of its normal, and of the normal a
        // twentieth of a degree along each.
        results[2u * id.x] = float4(projection_weights(ctx.normal, false), float(test_samples));
        float3 next = sweep_normal(float2(float(id.x / params.side), float(id.x % params.side)) + 0.05);
        results[2u * id.x + 1u] = float4(projection_weights(next, false), 0.0);
    }
}
