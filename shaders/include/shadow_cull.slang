// What the cull of the maps of the shadows (shadow_maps.comp by instance,
// shadow_clusters.comp by cluster) and the draws of their clusters
// (shadow_map.vert) share: their parameters, the words of
// render.Gpu_Shadow_State, and where in the list of the clusters the maps
// draw those of each draw lie: the clusters that hide whole from its start,
// those of masked or blended materials from its end, a quarter of it.
#ifndef MIRAI_SHADOW_CULL_SLANG
#define MIRAI_SHADOW_CULL_SLANG
// instances: of the scene and of the batches drawn; maps: drawn this frame;
// rows: of the words of the lights in the buffer of the maps; glass: 1 while
// the maps keep the tint of glass, and for the draws of the tint and of the
// nearest glass; chunk_capacity, entry_capacity: of the lists of the chunks
// and of the clusters (render.Cull_List).
struct Params_Block { uint instances; uint maps; uint rows; uint glass; uint chunk_capacity; uint entry_capacity; uint pad0; uint pad1; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
#define SHADOW_DRAW_COUNT 1u     // the instances of the draw of the clusters that hide whole; + 4 that of the others
#define SHADOW_CLUSTER_DISPATCH 8u
#define SHADOW_CHUNK_COUNT 11u
// How many clusters of a draw the list holds.
uint shadow_room(bool tested) { return tested ? params.entry_capacity / 4u : params.entry_capacity - params.entry_capacity / 4u; }
// Where in the list the cluster `slot` of a draw lies.
uint shadow_entry(bool tested, uint slot) { return tested ? params.entry_capacity - 1u - slot : slot; }
#endif
