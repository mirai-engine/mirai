// What the raster of the visibility target draws of the visible clusters of a
// view (cull_bins.comp): raster_vertices.comp places each vertex of a cluster
// once, as gbuffer_build.slang places it, finds the triangles of the cluster
// that show and writes the vertices they use; raster_starts.comp gives the
// triangles of each raster bin, and of each depth bucket of a tested one, their
// range; raster_triangles.comp writes there the three indices of each
// triangle and the word the visibility target names it by. A bin is then one
// indexed draw (vis_raster.vert), whose primitives are those triangles in
// order (vis_raster.frag). The vertices and the triangles of phase 1 follow
// those of phase 0.
#ifndef MIRAI_RASTER_LISTS_SLANG
#define MIRAI_RASTER_LISTS_SLANG
#include "cut.slang"
#include "cull_bins.slang"

// A vertex the raster draws: where it is in the world, and its entry of the
// visible list << 8 | which vertex of its cluster it is.
struct Raster_Vertex {
    float3 world;
    uint source;
};
uint raster_source(uint entry, uint local) { return (entry << 8u) | local; }
uint raster_source_entry(uint source) { return source >> 8u; }
uint raster_source_local(uint source) { return source & 0xffu; }

// The cluster of a group among those of its phase: the passes that take a
// cluster a group run in rows of CULL_DISPATCH_X groups.
uint raster_group(uint3 group) { return group.y * CULL_DISPATCH_X + group.x; }

// The word of the buffer of the depth buckets that counts the triangles
// listed of a depth bucket of a phase and a tested bin (two-sided or not),
// past the words of its clusters; RASTER_DEPTH_STARTS words on, where they
// start, which they take their places from.
uint raster_depth_word(uint phase, uint sided, uint bucket) { return CULL_DEPTH_WORDS + cull_depth_word(phase, sided, bucket); }
#define RASTER_DEPTH_STARTS CULL_DEPTH_COUNTS

// The bits of word `index` of a mask that come before bit `at` of the mask:
// all of a word before its own, none of one after.
uint raster_bits_before(uint word, uint index, uint at) {
    uint own = at >> 5u;
    return index < own ? word : index == own ? word & ((1u << (at & 31u)) - 1u) : 0u;
}

// Whether the raster may give a pixel to a triangle, from the clip positions
// of its corners as the draw has them: false only for one it gives none
// whatever the device, so leaving it out changes no pixel. A triangle all
// past one side of the view shows nothing. Of one all in front of the eye,
// neither does one whose box holds no pixel center, nor one seen from behind
// where back faces are not drawn. margin: how far, in pixels, a device may
// move a corner as it places it on its grid, and a little more for the
// rounding of the positions here.
bool raster_triangle_shows(float4 a, float4 b, float4 c, bool two_sided, float2 resolution, float margin) {
    const float SLACK = 1e-4;
    float3 x = float3(a.x, b.x, c.x), y = float3(a.y, b.y, c.y), w = float3(a.w, b.w, c.w);
    float3 reach_x = SLACK * (abs(x) + abs(w)), reach_y = SLACK * (abs(y) + abs(w));
    if (all(x + w < -reach_x) || all(w - x < -reach_x) || all(y + w < -reach_y) || all(w - y < -reach_y)) return false;
    if (any(w <= 1e-6)) return true;
    // Pixels from the lower left corner of the view: the winding is that of clip space.
    float3 px = (x / w * 0.5 + 0.5) * resolution.x, py = (y / w * 0.5 + 0.5) * resolution.y;
    float2 low = float2(min(px.x, min(px.y, px.z)), min(py.x, min(py.y, py.z)));
    float2 high = float2(max(px.x, max(px.y, px.z)), max(py.x, max(py.y, py.z)));
    // A box so far out that its pixels have no fraction left is kept.
    if (any(abs(low) > 1e6) || any(abs(high) > 1e6)) return true;
    float2 first = ceil(max(low - margin, float2(0.0)) - 0.5), last = floor(min(high + margin, resolution) - 0.5);
    if (any(last < first)) return false;
    if (two_sided) return true;
    float2 size = high - low;
    float area = (px.y - px.x) * (py.z - py.x) - (py.y - py.x) * (px.z - px.x);
    // Twice the area of the triangle changes by no more than this when each corner moves by the margin.
    float turn = 4.0 * margin * (size.x + size.y) + 8.0 * margin * margin;
    return area >= -turn;
}
#endif
