//! variant bc5 BC_ENCODE_5
//! variant bc6h BC_ENCODE_6H
//! variant bc7 BC_ENCODE_7
#define BC_COOK_RDO
#include "bcn_blocks.slang"
#include "bcn_rdo.slang"

[shader("compute")]
[numthreads(BC_COOK_GROUP, BC_COOK_GROUP, 1)]
void main(uint3 id : SV_DispatchThreadID, uint3 local : SV_GroupThreadID) {
    uint2 blocks = (uint2(params.width, params.height) + 3) / 4;
    bool valid = all(id.xy < blocks);
    uint index = id.y * blocks.x + id.x;
    Fit seed = {};
    if (valid) seed = fits[index];
    tile[local.y * BC_COOK_GROUP + local.x] = seed;
    GroupMemoryBarrierWithGroupSync();
    if (!valid) return;

    load_block(id.xy);
    store_block(index, optimize_tile(id.xy, blocks, id.xy - local.xy, seed, rate_price(seed)));
}
