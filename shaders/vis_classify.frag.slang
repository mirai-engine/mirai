#include "native.slang"
// The depth of the Surface program of each pixel of the visibility target
// (visibility_program_depth; 0 for a material without one), as the cull
// listed it with its cluster: the resolve of each program draws where this
// depth is its own, so the pixels of the others are rejected before its
// fragments run. A pixel without a triangle keeps the depth the pass clears
// to, which no program has.
#include "visibility.slang"

// The visible clusters (cull_bins.comp).
[[vk::binding(SLOT_PASS0, 0)]] StructuredBuffer<Visible_Cluster> visible : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<uint> visibility : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);

[shader("fragment")]
float main(float4 pixel : SV_Position) : SV_Depth {
    uint id = visibility.Load(int3(int2(pixel.xy), 0));
    if (id == 0u) discard;
    return visibility_program_depth(visible[visibility_entry(id)].program);
}
