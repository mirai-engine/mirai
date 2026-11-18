// What the cull passes count in a frame (render.Gpu_Cull_Stats): kinds:
// instances, clusters and triangles drawn of each CULL_KIND_*; late: those
// phase 1 drew; dropped: what passed the capacity of each list of the cull
// (render.Cull_List), which the renderer grows from it.
#ifndef MIRAI_CULL_STATS_SLANG
#define MIRAI_CULL_STATS_SLANG
#define CULL_LIST_CHUNKS 0u
#define CULL_LIST_VISIBLE 1u
#define CULL_LIST_CANDIDATES 2u
#define CULL_LIST_PROGRAMS 3u
#define CULL_LIST_SHADOW_CHUNKS 4u
#define CULL_LIST_SHADOW_ENTRIES 5u
struct Stats_Block { uint visible_instances; uint visible_triangles; uint culled_instances; uint occluded_instances; uint probes_traced; uint visible_clusters; uint kinds[9]; uint late[3]; uint dropped[6]; };
#endif
