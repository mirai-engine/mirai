#include "native.slang"
// The translation of the RHI from the instances of a TLAS as callers write
// them (rhi.Tlas_Instance, 16 words) to the native ones of the backend: what
// differs between backends is data its table gives (rhi.Tlas_Table_Header),
// not code. A native instance is the transform by rows (Vulkan) or by
// columns (Metal) in its first 12 words, then the custom index, the mask, the
// flags and the value of its BLAS where its layout puts them. An instance of
// a BLAS without a value is never met: mask 0.
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1
#include <shared_constants.slang>

// Header: count, layout, stride (words of a native instance), first (of the
// source), ids, the flags of an opaque instance and of a tested one; then
// two words by BLAS id.
[[vk::binding(0, 0)]] StructuredBuffer<uint> table : register(t0, space0);
[[vk::binding(1, 0)]] StructuredBuffer<uint> source : register(t1, space0);
[[vk::binding(2, 0)]] RWStructuredBuffer<uint> native : register(u2, space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    uint i = id.x + id.y * TLAS_DISPATCH_X * MIRAI_GROUP_X;
    if (i >= table[0]) return;
    uint layout = table[1], stride = table[2], ids = table[4];
    uint from = (table[3] + i) * 16u, to = i * stride;
    uint blas = source[from + 13u];
    uint2 value = blas < ids ? uint2(table[TLAS_TABLE_HEADER + blas * 2u], table[TLAS_TABLE_HEADER + blas * 2u + 1u]) : uint2(0u, 0u);
    bool met = blas != 0u && (value.x | value.y) != 0u;
    uint mask_flags = source[from + 14u];
    uint mask = met ? (mask_flags & 255u) : 0u;
    uint flags = (mask_flags & TLAS_ALPHA_TESTED) != 0u ? table[6] : table[5];
    uint custom = source[from + 12u] & 0xFFFFFFu;
    if (layout == TLAS_LAYOUT_ROWS) {
        for (uint k = 0u; k < 12u; k++) native[to + k] = source[from + k];
        native[to + 12u] = custom | (mask << 24u);
        native[to + 13u] = flags;
        native[to + 14u] = met ? value.x : 0u;
        native[to + 15u] = met ? value.y : 0u;
    } else {
        for (uint column = 0u; column < 4u; column++) {
            for (uint row = 0u; row < 3u; row++) native[to + column * 3u + row] = source[from + row * 4u + column];
        }
        native[to + 12u] = flags;
        native[to + 13u] = mask;
        native[to + 14u] = 0u;
        native[to + 15u] = met ? value.x - 1u : 0u;
        native[to + 16u] = custom;
    }
}
