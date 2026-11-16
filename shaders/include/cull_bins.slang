// The visible clusters of a view are placed in their raster bins
// (cull_bins.comp) a group of CULL_BINS_GROUP at a time: the cull of the
// clusters (cull_clusters.comp) counts the groups of each phase.
#ifndef MIRAI_CULL_BINS_SLANG
#define MIRAI_CULL_BINS_SLANG
#define CULL_BINS_GROUP 64u
#endif
