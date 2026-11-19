#include "native.slang"
// What the lists of the cull grow from, kept as the most any view of the
// frame needed (Stats_Block.most_*), and what the maps of the shadows of the
// views drew, summed (Stats_Block.views_shadow): run after each view, before
// the next clears what it counts. One group.
#include "scene.slang"
#include "cull_stats.slang"
#define MIRAI_GROUP_X 32
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

[[vk::binding(SLOT_PASS0, 0)]] RWStructuredBuffer<Stats_Block> stats : register(MIRAI_REGISTER(u, SLOT_PASS0), space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 lane : SV_GroupThreadID) {
    uint t = lane.x;
    if (t < CULL_LISTS) InterlockedMax(stats[0].most_dropped[t], stats[0].dropped[t]);
    else if (t < CULL_LISTS + 2u) InterlockedMax(stats[0].most_raster_need[t - CULL_LISTS], stats[0].raster_need[t - CULL_LISTS]);
    else if (t < CULL_LISTS + 19u) InterlockedAdd(stats[0].views_shadow[t - CULL_LISTS - 2u], stats[0].shadow[t - CULL_LISTS - 2u]);
}
