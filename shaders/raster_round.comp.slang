#include "native.slang"
// The start of a round of the raster of the visibility target
// (raster_lists.slang): it takes the entries of the visible list not listed
// yet, those the cull listed since the round before (cull_bins.comp) and
// those that found no room in it (raster_vertices.comp), as a run of groups
// for the passes of the round, and leaves the lists and what counts their
// triangles empty for it. One group.
#include "scene.slang"
#include "raster_lists.slang"
#define MIRAI_GROUP_X CULL_BINS_GROUP
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

[[vk::binding(SLOT_PASS0, 0)]] RWStructuredBuffer<uint> cull_state : register(MIRAI_REGISTER(u, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS4, 0)]] RWStructuredBuffer<uint> depth_buckets : register(MIRAI_REGISTER(u, SLOT_PASS4), space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 lane : SV_GroupThreadID) {
    // The triangles of each depth bucket of both tested bins, and where they start.
    for (uint word = lane.x; word < 2u * RASTER_DEPTH_STARTS; word += MIRAI_GROUP_X) depth_buckets[CULL_DEPTH_WORDS + word] = 0u;
    if (lane.x != 0u) return;
    uint first = cull_state[CULL_RASTER_PENDING], end = cull_state[CULL_RASTER_PENDING + 1u];
    uint count = end > first ? end - first : 0u;
    cull_state[CULL_RASTER_FIRST] = first;
    cull_state[CULL_RASTER_COUNT] = count;
    cull_state[CULL_RASTER_DISPATCH] = min(count, CULL_DISPATCH_X);
    cull_state[CULL_RASTER_DISPATCH + 1u] = (count + CULL_DISPATCH_X - 1u) / CULL_DISPATCH_X;
    cull_state[CULL_RASTER_DISPATCH + 2u] = 1u;
    cull_state[CULL_RASTER_PENDING] = INVALID;
    cull_state[CULL_RASTER_PENDING + 1u] = 0u;
    cull_state[CULL_RASTER_VERTICES] = 0u;
    cull_state[CULL_RASTER_TRIANGLES] = 0u;
    for (uint bin = 0u; bin < RASTER_BINS; bin++) {
        cull_state[CULL_RASTER_COUNTS + bin] = 0u;
        cull_state[CULL_RASTER_CURSORS + bin] = 0u;
    }
}
