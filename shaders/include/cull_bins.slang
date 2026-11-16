// The visible clusters of a view are placed in their raster bins
// (cull_bins.comp) a group of CULL_BINS_GROUP at a time: the cull of the
// clusters (cull_clusters.comp) counts the groups of each phase, and the
// clusters of the tested bins of each phase by depth bucket.
#ifndef MIRAI_CULL_BINS_SLANG
#define MIRAI_CULL_BINS_SLANG
#define CULL_BINS_GROUP 64u
// The word of the buckets of a phase and a tested bin (two-sided or not) a bucket counts in.
uint cull_depth_word(uint phase, uint sided, uint bucket) { return (phase * 2u + sided) * RASTER_DEPTH_BUCKETS + bucket; }
// The bin and the depth bucket a listed cluster has, in one word.
uint cull_listed_word(uint bin, uint bucket) { return bin | (bucket << 8u); }
uint cull_listed_bin(uint word) { return word & 0xffu; }
uint cull_listed_bucket(uint word) { return word >> 8u; }
#endif
