#include "native.slang"
//! per sky program
// The image of the sky a Sky program gives (render/sky_program.odin), as an
// image of the sky is laid out (sky_image of scene.slang): the whole turn
// across, the zenith at the top. Level 0: a thread per texel evaluates the
// program in the direction of its center; a level above 0: a thread per texel
// of it, the mean of the four of the level before it covers. What the program
// gives that is not a finite color of no less than zero is black.
#include "scene.slang"
#include <sky_programs.slang>
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

struct Params_Block {
    float4 packed[16]; // the parameters of the program
    float4 sun;        // xyz towards the sun in the space of the sky, w 1 while a Sun is on
    uint level;
    uint3 pad;
};
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
// The texels of the levels as half floats, level after level, which render copies into the image.
[[vk::binding(SLOT_PASS0, 0)]] RWStructuredBuffer<uint2> texels : register(MIRAI_REGISTER(u, SLOT_PASS0), space0);

uint2 level_size(uint level) { return max(uint2(SKY_BAKE_WIDTH, SKY_BAKE_WIDTH / 2u) >> level, uint2(1u)); }
uint level_first(uint level) {
    uint first = 0u;
    for (uint l = 0u; l < level; l++) { uint2 size = level_size(l); first += size.x * size.y; }
    return first;
}
float4 texel_value(uint2 bits) {
    return float4(half_value(bits.x & 0xffffu), half_value(bits.x >> 16u), half_value(bits.y & 0xffffu), half_value(bits.y >> 16u));
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    uint texel = dispatch_id.x;
    uint2 size = level_size(params.level);
    if (texel >= size.x * size.y) return;
    uint2 at = uint2(texel % size.x, texel / size.x);
    if (params.level != 0u) {
        uint2 before = level_size(params.level - 1u);
        uint from = level_first(params.level - 1u);
        float4 sum = float4(0.0);
        for (uint k = 0u; k < 4u; k++) {
            uint2 q = min(at * 2u + uint2(k & 1u, k >> 1u), before - 1u);
            sum += texel_value(texels[from + q.y * before.x + q.x]);
        }
        texels[level_first(params.level) + texel] = half_bits(sum * 0.25);
        return;
    }
    float2 uv = (float2(at) + 0.5) / float2(size);
    float around = (uv.x - 0.5) * 2.0 * PI, down = uv.y * PI;
    Mirai_Sky_Context ctx;
    ctx.direction = float3(sin(down) * cos(around), cos(down), sin(down) * sin(around));
    ctx.sun = params.sun.w > 0.5 ? 1.0 : 0.0;
    ctx.sun_direction = ctx.sun > 0.5 ? params.sun.xyz : float3(0.0, 1.0, 0.0);
    ctx.texel = PI / float(size.y);
    float3 color = max(finite_or_zero(mirai_sky_program(params.packed, ctx)), float3(0.0));
    texels[texel] = half_bits(float4(color, 1.0));
}
