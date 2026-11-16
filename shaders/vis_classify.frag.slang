#include "native.slang"
// The depth of the Surface program of each pixel of the visibility target
// (visibility_program_depth; 0 for a material without one), as the cull
// listed it with its cluster: the resolve of each program draws where this
// depth is its own, so the pixels of the others are rejected before its
// fragments run. A pixel without a triangle keeps the depth the pass clears
// to, which no program has.
//
// It counts what the resolve will shade (Stats_Block.resolved): the pixels,
// and of each quad and program, the helpers the resolve of that program runs
// there, the pixels of the quad that are not of it; one atomic of each per
// wave. The resolve counts the quads it evaluates again.
#include "visibility.slang"

// The visible clusters (cull_bins.comp).
[[vk::binding(SLOT_PASS0, 0)]] StructuredBuffer<Visible_Cluster> visible : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<uint> visibility : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
#include "cull_stats.slang"
[[vk::binding(SLOT_PASS2, 0)]] RWStructuredBuffer<Stats_Block> resolve_stats : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);

[shader("fragment")]
float main(float4 pixel : SV_Position) : SV_Depth {
    bool helper = IsHelperLane();
    uint id = helper ? 0u : visibility.Load(int3(int2(pixel.xy), 0));
    uint program = id != 0u ? visible[visibility_entry(id)].program : INVALID;
    uint4 quad = uint4(QuadReadLaneAt(program, 0u), QuadReadLaneAt(program, 1u), QuadReadLaneAt(program, 2u), QuadReadLaneAt(program, 3u));
    uint lane = (uint(pixel.y) & 1u) * 2u + (uint(pixel.x) & 1u);
    uint4 same = uint4(quad == program);
    bool first = id != 0u && (lane == 0u || (lane == 1u ? same.x == 0u : lane == 2u ? same.x + same.y == 0u : same.x + same.y + same.z == 0u));
    // A helper writes nothing: those that are not count.
    if (!helper) {
        uint2 counted = WaveActiveSum(uint2(id != 0u ? 1u : 0u, first ? 4u - (same.x + same.y + same.z + same.w) : 0u));
        if (WaveIsFirstLane() && counted.x != 0u) {
            InterlockedAdd(resolve_stats[0].resolved[0], counted.x);
            if (counted.y != 0u) InterlockedAdd(resolve_stats[0].resolved[1], counted.y);
        }
    }
    if (id == 0u) discard;
    return visibility_program_depth(program);
}
