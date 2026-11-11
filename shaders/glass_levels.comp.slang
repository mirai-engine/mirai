#include "native.slang"
// The levels of the copy of what lies behind a layer of glass
// (render.Targets.glass_scene), over which glass_pass.slang blurs it: level 0
// holds the scene, and in alpha 1 where the layer stands in front of it
// (glass.comp, params.snapshot); each level after it the mean of 2x2 texels of
// the one before, weighed by that alpha and multiplied by it, so that what
// stands in front of the layer does not spread into what the layer shows. Odd
// sizes fold the extra row and column in.
#include "common.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

// first: 1 for level 1, whose source, level 0, is not multiplied by its alpha.
struct Params_Block { int2 source_size; uint first; uint pad; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> source : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> target : register(MIRAI_REGISTER(u, SLOT_PASS1), space0);

float4 fetch(int2 p) {
    float4 c = source.Load(int3(clamp(p, int2(0), params.source_size - 1), 0));
    float a = saturate(c.a);
    if (!(a > 0.0)) return float4(0.0);
    return float4(finite_or_zero(params.first != 0u ? c.rgb * a : c.rgb), a);
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    int2 p = int2(dispatch_id.xy);
    int2 size = texture_size(target);
    if (any(p >= size)) return;
    int2 s = p * 2;
    int2 far = int2((params.source_size.x & 1) != 0 && p.x == size.x - 1 ? 2 : 1, (params.source_size.y & 1) != 0 && p.y == size.y - 1 ? 2 : 1);
    float4 sum = float4(0.0);
    for (int y = 0; y <= far.y; y++) {
        for (int x = 0; x <= far.x; x++) sum += fetch(s + int2(x, y));
    }
    target[p] = sum / float((far.x + 1) * (far.y + 1));
}
