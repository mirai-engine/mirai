#include "native.slang"
// The tags of the pixels of the viewmodel of a view, after its visibility and
// before its resolve (render/foreground.odin): VIEWS_FOREGROUND where it drew,
// with the share of the way to its true place its light is taken at, the one
// of the view (foreground_kept.comp). 0 elsewhere.
#include "common.slang"

[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> depth : register(MIRAI_REGISTER(t, SLOT_PASS0), space0); // the depth target
[[vk::binding(SLOT_PASS1, 0)]] StructuredBuffer<uint> kept : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);

[shader("fragment")]
uint main(float4 pixel : SV_Position) : SV_Target0 {
    if (depth.Load(int3(int2(pixel.xy), 0)).r <= FOREGROUND_DEPTH) return 0u;
    return VIEWS_FOREGROUND | min(kept[0], VIEWS_KEPT);
}
