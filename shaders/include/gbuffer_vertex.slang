// What a vertex of the G-buffer gives its fragment (gbuffer.frag). The stage
// of the engine (gbuffer.vert) and those an extension draws into the
// G-buffer with (render.pass_gbuffer_pipeline) fill it and place it with
// gbuffer_vertex_place.
#ifndef MIRAI_GBUFFER_VERTEX_SLANG
#define MIRAI_GBUFFER_VERTEX_SLANG
#include "scene.slang"

struct Gbuffer_Vertex {
    float4 position : SV_Position;
    [[vk::location(0)]] float3 out_normal : TEXCOORD0;
    [[vk::location(1)]] float3 out_color : TEXCOORD1;
    [[vk::location(2)]] nointerpolation float3 out_emission : TEXCOORD2;
    [[vk::location(3)]] float4 out_clip : TEXCOORD3;
    [[vk::location(4)]] float4 out_prev_clip : TEXCOORD4;
    [[vk::location(5)]] float3 out_world : TEXCOORD5;
    [[vk::location(6)]] nointerpolation uint out_flags : TEXCOORD6;
    [[vk::location(7)]] float2 out_uv : TEXCOORD7;
    [[vk::location(8)]] nointerpolation uint out_material : TEXCOORD8;
    [[vk::location(9)]] nointerpolation uint out_instance : TEXCOORD9; // INVALID: drawn by an extension
    [[vk::location(10)]] float2 out_uv1 : TEXCOORD10;
    [[vk::location(11)]] float4 out_tangent : TEXCOORD11; // xyz in the world, w the sign of the bitangent there
    [[vk::location(12)]] nointerpolation uint out_surface : TEXCOORD12; // of a far mesh (Mesh_Point.surface.x); 0 for the others
    [[vk::location(13)]] float4 out_vertex_color : TEXCOORD13; // of the mesh, white without one: a program reads it as data
#ifdef MIRAI_CLIP_PLANE
    float clip : SV_ClipDistance0;
#endif
};

// A vertex at world in this frame and at prev_world in the frame before: its
// motion vectors compare unjittered positions, and it is rasterized jittered.
void gbuffer_vertex_place(inout Gbuffer_Vertex output, float3 world, float3 prev_world) {
    output.out_world = world;
#ifdef MIRAI_CLIP_PLANE
    output.clip = dot(frame.clip_plane.xyz, world) + frame.clip_plane.w;
#endif
    output.out_clip = view_clip_unjittered(world);
    output.out_prev_clip = view_clip_previous(prev_world);
    output.position = view_clip(world);
#ifdef MIRAI_EDITOR_HIGHLIGHT
    if (MIRAI_EDITOR_HIGHLIGHT) output.position = output.out_clip;
#endif
}
#endif
