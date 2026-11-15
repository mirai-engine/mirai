// The visibility buffer: one 64-bit word per pixel of a view, the nearest
// surface of the clusters the cull listed. Above, the bits of its reverse-Z
// depth, so nearer is larger and an atomic maximum keeps it; below, its
// entry (visibility_entry). 0: no such surface. vis_raster.frag writes it,
// vis_depth.frag gives its depth to the depth targets and vis_resolve.frag
// runs the material of each pixel once.
#ifndef MIRAI_VISIBILITY_SLANG
#define MIRAI_VISIBILITY_SLANG
#include "scene.slang"

// The triangles of a cluster: an entry is the entry of the visible list
// times them, plus the triangle.
static const uint VISIBILITY_TRIANGLES = CLUSTER_DRAW_VERTICES / 3u;

uint visibility_entry(uint visible, uint triangle) { return visible * VISIBILITY_TRIANGLES + triangle; }
uint visibility_visible(uint entry) { return entry / VISIBILITY_TRIANGLES; }
uint visibility_triangle(uint entry) { return entry % VISIBILITY_TRIANGLES; }

uint visibility_pixel(uint2 pixel) { return pixel.y * uint(frame.resolution.x) + pixel.x; }
uint64_t visibility_pack(float depth, uint entry) { return (uint64_t(asuint(depth)) << 32) | uint64_t(entry); }
float visibility_depth(uint64_t word) { return asfloat(uint(word >> 32)); }
uint visibility_entry_of(uint64_t word) { return uint(word & 0xffffffffull); }
#endif
