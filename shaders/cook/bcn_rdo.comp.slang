//! variant bc5 BC_ENCODE_5
//! variant bc6h BC_ENCODE_6H
//! variant bc7 BC_ENCODE_7
#define BC_COOK_RDO
#include "bcn_blocks.slang"
#include "bcn_rdo.slang"

[shader("compute")]
[numthreads(BC_COOK_GROUP, BC_COOK_GROUP, 1)]
void main(uint3 id : SV_DispatchThreadID) {
    uint2 blocks = (uint2(params.width, params.height) + 3) / 4;
    if (any(id.xy >= blocks)) return;
    uint index = id.y * blocks.x + id.x;
    load_block(id.xy);
    store_block(index, optimize_tile(id.xy, blocks, fits[index]));
}
