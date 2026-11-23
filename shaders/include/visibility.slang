// The visibility target: of each pixel of a view, the triangle of the visible
// clusters the cull listed that is nearest there, by the hardware depth test,
// as one word: its entry of the visible list times CLUSTER_TRIANGLES, plus the
// triangle, plus one. 0: no such triangle. The passes of raster_lists.slang
// list the triangles of those clusters that show, vis_raster.frag writes the
// word of each, vis_classify.frag gives each pixel the depth of its Surface
// program and vis_resolve.frag runs the material of each pixel once.
#ifndef MIRAI_VISIBILITY_SLANG
#define MIRAI_VISIBILITY_SLANG
#include "scene.slang"

// An entry of the visible list (cull_bins.comp): the instance, the cluster as
// a word of the index pool, the Surface program it is resolved by and its
// material row; then where its vertices and its triangles start in the
// vertex pool, the word of its page entry, and how far its islands are on
// their way to the next level (cluster_along). What a cluster gives each of
// its vertices and pixels alike is found once, by the cull, and not by each
// of them through the instance, the mesh and the page.
struct Visible_Cluster {
    uint instance;
    uint cluster;
    uint program;
    uint material;
    uint vertices;
    uint triangles;
    uint page;
    float along;
};

// Where the streams of a visible cluster start in the vertex pool.
Cluster_Block visible_block(Mesh mesh, Cluster c, Visible_Cluster v) {
    Cluster_Block b = page_block(mesh, c, page_at_word(v.page));
    b.vertices = v.vertices;
    b.triangles = v.triangles;
    return b;
}

uint visibility_id(uint entry, uint triangle) { return entry * CLUSTER_TRIANGLES + triangle + 1u; }
uint visibility_entry(uint id) { return (id - 1u) / CLUSTER_TRIANGLES; }
uint visibility_triangle(uint id) { return (id - 1u) % CLUSTER_TRIANGLES; }

// The edge functions of a triangle a pixel shows, from the clip positions of
// its corners as the raster had them: what gives the weights whose sum of the
// corners projects to a point of the screen, which hold for corners behind
// the eye too (homogeneous rasterization, Olano and Greer 1997), and for a
// point off the triangle, along its plane.
struct Visibility_Edges {
    float3 a, b, c;
};
Visibility_Edges visibility_edges(float4 a, float4 b, float4 c) {
    float3 ra = a.xyw, rb = b.xyw, rc = c.xyw;
    Visibility_Edges e;
    e.a = cross(rb, rc);
    e.b = cross(rc, ra);
    e.c = cross(ra, rb);
    return e;
}
// The weights of the corners at a point of the screen, in pixels.
float3 visibility_barycentrics(Visibility_Edges e, float2 pixel) {
    float3 p = float3(pixel.x * frame.inv_resolution.x * 2.0 - 1.0, 1.0 - pixel.y * frame.inv_resolution.y * 2.0, 1.0);
    float3 w = float3(dot(e.a, p), dot(e.b, p), dot(e.c, p));
    float sum = w.x + w.y + w.z;
    return abs(sum) > 1e-30 ? w / sum : float3(1.0, 0.0, 0.0);
}
// Whether the triangle whose first corner is at `a` is counter-clockwise on
// the screen: the sign of the homogeneous determinant, which holds behind
// the eye too.
bool visibility_counterclockwise(Visibility_Edges e, float4 a) { return dot(a.xyw, e.a) > 0.0; }

// The depth a pixel of a Surface program (0: of none) is classified at, in
// the 16-bit program depth target, which the resolve of that program tests
// for equality; 0 where nothing is. A quarter of a step past the step of the
// program: a device that rounds to the nearest step and one that truncates
// store the same one, from the depth the classify writes and from the one
// the resolve interpolates, whatever the last bit of either.
float visibility_program_depth(uint program) { return (float(program + 1u) + 0.25) * (1.0 / 65535.0); }

// The vertex of the raster of the visibility target that is not tested.
struct Visibility_Vertex {
    float4 position : SV_Position;
    [[vk::location(0)]] nointerpolation uint out_first : TEXCOORD0; // the first triangle of the draw among those listed
#ifdef MIRAI_CLIP_PLANE
    float clip : SV_ClipDistance0;
#endif
};

// The vertex of the raster of the visibility target that is tested: what the
// fade of its instance and the mask map of its material read, and nothing of
// its light, which the resolve builds.
struct Coverage_Vertex {
    float4 position : SV_Position;
    [[vk::location(0)]] nointerpolation uint out_first : TEXCOORD0;
    [[vk::location(1)]] nointerpolation uint2 out_material : TEXCOORD1; // its row and the values of its instance (material_row)
    [[vk::location(2)]] nointerpolation uint out_fade : TEXCOORD2;      // what its instance fades out, unorm16; 0: nothing
    [[vk::location(3)]] float2 out_uv : TEXCOORD3;                      // of the set its mask map reads (mask_uv_set)
#ifdef MIRAI_CLIP_PLANE
    float clip : SV_ClipDistance0;
#endif
};
#endif
