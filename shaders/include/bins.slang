// Binning a list by a key of at most BINS_MAX values
// (render.POINTS_PROGRAM_CAPACITY), in three passes over it: count each bin,
// give each bin its range, place each entry in the range of its bin. A group
// counts the keys of its threads in groupshared memory before it adds one
// atomic for each key it has. Its words (counts, cursors) live in a buffer
// of the caller.
#ifndef MIRAI_BINS_SLANG
#define MIRAI_BINS_SLANG
#define BINS_MAX 1024u

groupshared uint bins_group[BINS_MAX];
groupshared uint bins_first[BINS_MAX];

// The rank of the key of a thread among those of its group; bins_group then
// holds how many of each key the group has. bins: how many keys there are.
uint bins_rank(uint key, bool valid, uint bins, uint local, uint threads) {
    for (uint b = local; b < bins; b += threads) bins_group[b] = 0u;
    GroupMemoryBarrierWithGroupSync();
    uint rank = 0u;
    if (valid) InterlockedAdd(bins_group[key], 1u, rank);
    GroupMemoryBarrierWithGroupSync();
    return rank;
}

// Adds what the group has of each key to the count of its bin, words[counts + key].
void bins_count(RWStructuredBuffer<uint> words, uint counts, uint bins, uint local, uint threads) {
    for (uint b = local; b < bins; b += threads) {
        if (bins_group[b] != 0u) InterlockedAdd(words[counts + b], bins_group[b]);
    }
}

// Where the entry of a thread goes within the range of its bin: the group
// takes its room from the cursor of each bin, words[cursors + key].
uint bins_place(RWStructuredBuffer<uint> words, uint cursors, uint key, uint rank, uint bins, uint local, uint threads) {
    for (uint b = local; b < bins; b += threads) {
        if (bins_group[b] != 0u) InterlockedAdd(words[cursors + b], bins_group[b], bins_first[b]);
    }
    GroupMemoryBarrierWithGroupSync();
    return bins_first[key] + rank;
}
#endif
