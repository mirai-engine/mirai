// The visibility target: of each pixel of a view, the triangle of the visible
// clusters the cull listed that is nearest there, by the hardware depth test,
// as one word: its entry of the visible list times CLUSTER_TRIANGLES, plus the
// triangle, plus one. 0: no such triangle. vis_raster.frag writes it,
// vis_classify.frag gives each pixel the depth of its Surface program and
// vis_resolve.frag runs the material of each pixel once.
#ifndef MIRAI_VISIBILITY_SLANG
#define MIRAI_VISIBILITY_SLANG
#include "scene.slang"

uint visibility_id(uint entry, uint triangle) { return entry * CLUSTER_TRIANGLES + triangle + 1u; }
uint visibility_entry(uint id) { return (id - 1u) / CLUSTER_TRIANGLES; }
uint visibility_triangle(uint id) { return (id - 1u) % CLUSTER_TRIANGLES; }

// The depth a pixel of a Surface program (0: of none) is classified at, in
// the program depth target, which the resolve of that program tests for
// equality: a value f32 holds exactly, and 0 where nothing is.
float visibility_program_depth(uint program) { return float(program + 1u) * (1.0 / 65536.0); }

// The vertex of the raster of the visibility target that is not tested.
struct Visibility_Vertex {
    float4 position : SV_Position;
    [[vk::location(0)]] nointerpolation uint out_id : TEXCOORD0;
#ifdef MIRAI_CLIP_PLANE
    float clip : SV_ClipDistance0;
#endif
};
#endif
