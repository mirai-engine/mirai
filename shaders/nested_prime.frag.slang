#include "native.slang"
// The depth buffer of a nested view before its G-buffer is drawn: the farthest
// depth in the pixels its mask named, so that its surfaces pass the test
// there, and the nearest everywhere else (what the pass clears to), so that
// nothing of it is drawn in a pixel of another view.
#include "common.slang"

struct Params_Block { uint index; uint pad0; uint pad1; uint pad2; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> g_motion : register(MIRAI_REGISTER(t, SLOT_PASS0), space0); // a: 1 + the nested view of the pixel

[shader("fragment")]
float main(float4 pixel : SV_Position) : SV_Depth {
    if (abs(g_motion.Load(int3(int2(pixel.xy), 0)).a - 1.0 - float(params.index)) > 0.25) discard;
    return 0.0;
}
