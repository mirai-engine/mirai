// What the cull passes count in a frame (render.Gpu_Cull_Stats): kinds:
// instances, clusters and triangles drawn of each CULL_KIND_*; late: those
// phase 1 drew; dropped: what passed the capacity of each list of the cull
// (render.Cull_List), which the renderer grows from it; raster: the vertices
// written and the triangles listed for the raster of the visibility target,
// and the clusters a round left to the next (raster_lists.slang); resolved:
// what the resolve of the G-buffer shaded (vis_resolve.frag): pixels, the
// helpers of their quads, and the quads it evaluated again; probe_rays: what the probes
// traced and lit, which the renderer copies in; lists: what the lists of the
// lights without shadows of the view held (render.Light_List_Stats);
// raster_need: the most vertices and triangles the view would hold in a round
// of its raster; most: of dropped and raster_need, the most any view of the
// frame counted (cull_stats_fold.comp), which the lists grow from. All but
// most count a view: the next clears them.
#ifndef MIRAI_CULL_STATS_SLANG
#define MIRAI_CULL_STATS_SLANG
#define CULL_LIST_CHUNKS 0u
#define CULL_LIST_VISIBLE 1u
#define CULL_LIST_CANDIDATES 2u
#define CULL_LIST_SHADOW_CHUNKS 3u
#define CULL_LIST_SHADOW_ENTRIES 4u
#define CULL_LIST_RASTER_VERTICES 5u
#define CULL_LIST_RASTER_TRIANGLES 6u
#define CULL_LISTS 7u
struct Stats_Block { uint visible_instances; uint visible_triangles; uint culled_instances; uint occluded_instances; uint probes_traced; uint visible_clusters; uint kinds[9]; uint late[3]; uint dropped[7]; uint raster[3]; uint resolved[3]; uint probe_rays[2]; uint lists[4]; uint raster_need[2]; uint most_dropped[7]; uint most_raster_need[2]; };
#endif
