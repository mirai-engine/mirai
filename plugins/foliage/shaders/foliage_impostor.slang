//! mirai constant IMPOSTOR_NONE uint ../runtime/far.odin
// The far foliage drawn as octahedral impostors (foliage.Impostor_Row and
// Impostor_Instance; render.impostor_capture made their frames), in the
// Gbuffer stage. A dispatch keeps the instances a view sees
// (foliage_impostor_cull.comp), and one draw puts each on a quad that faces
// the eye and holds the sphere of its type; the fragment blends the three
// frames nearest the direction it is seen from, each moved by the depth it
// keeps (Ryan Brucks, shaderbits 2018), and writes the surface it finds
// where the leaves are.
#ifndef FOLIAGE_IMPOSTOR_SLANG
#define FOLIAGE_IMPOSTOR_SLANG
#include "native.slang"
#include "scene.slang"
#include <constants/plugins/foliage.slang>

// A type of foliage of a Foliage seen as an impostor: its frames and where
// its mesh gives way to them, which fades them in with the pattern of the
// batches (box_faded over the same box), and where they fade out.
struct Impostor_Row {
    float4 sphere;       // the centre of the frames in the space of the type, and their radius
    float4 low;          // xyz: the box of its mesh; w: from the eye, where its mesh starts to fade out
    float4 high;         // xyz; w: where its mesh is gone
    uint4 frames;        // the textures (texture_index) x: of color and coverage, y: of normal and depth, z: of roughness, metallic, occlusion and diffuse transmission; w: frames a side | pixels a side of a frame << 16
    float4 far;          // x: where the impostor starts to fade out, y: where it is gone (0: never)
    float4 transmission; // rgb: the color of the light its leaves let through
};

// An instance, as a Batch_Instance holds it, relative to the anchor of the
// instances, and its row: the slot of its Foliage << 16 | its type.
struct Impostor_Instance {
    float3 position;
    uint rotation;
    uint scale;
    uint row;
};

struct Impostor_Params {
    float4 anchor; // xyz: where the positions of the instances are from, relative to the origin
    uint4 count;   // x: the instances of the buffer
};

// What the vertices of an instance give its fragments, in the space of its type.
struct Impostor_Varyings {
    float4 position : SV_Position;
    [[vk::location(0)]] float3 local : TEXCOORD0;                   // the point of the quad
    [[vk::location(1)]] nointerpolation float4 eye : TEXCOORD1;     // w 1: the eye; w 0: the direction a parallel view looks along
    [[vk::location(2)]] nointerpolation uint4 frames : TEXCOORD2;   // xyz: the three frames, x | y << 16; w: the row
    [[vk::location(3)]] nointerpolation float4 weights : TEXCOORD3; // xyz: of each frame; w: the level of the textures
    [[vk::location(4)]] nointerpolation float2 fades : TEXCOORD4;   // x: how much of it shows where its mesh fades out; y: how much of it fades out far
    [[vk::location(5)]] nointerpolation float4 world0 : TEXCOORD5;  // its transform
    [[vk::location(6)]] nointerpolation float4 world1 : TEXCOORD6;
    [[vk::location(7)]] nointerpolation float4 world2 : TEXCOORD7;
};

[[vk::binding(SLOT_PASS0, 0)]] StructuredBuffer<Impostor_Instance> impostor_instances : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS3, 0)]] StructuredBuffer<Impostor_Row> impostor_rows : register(MIRAI_REGISTER(t, SLOT_PASS3), space0);
// The first row of each slot of a Foliage.
[[vk::binding(SLOT_PASS4, 0)]] StructuredBuffer<uint> impostor_bases : register(MIRAI_REGISTER(t, SLOT_PASS4), space0);
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Impostor_Params> impostor_params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);

uint impostor_row_index(uint row) { return impostor_bases[row >> 16u] + (row & 0xffffu); }

// Where an instance is drawn, and how much of it shows.
struct Impostor_Shape {
    float4 world[3];
    float4 inverse[3];
    float3 center; // of its sphere
    float radius;
    float appear;  // where its mesh fades out, by its distance or its size on the screen, as the mesh does
    float gone;    // where it fades out far
};

// The shape of an instance; false where nothing of it is drawn: its mesh is
// whole there, or it is gone, or its type has no frames.
bool impostor_shape(Impostor_Instance inst, Impostor_Row row, out Impostor_Shape s) {
    batch_instance_placement(inst.position + impostor_params.anchor.xyz, inst.rotation, inst.scale, s.world, s.inverse);
    float3 low, high;
    box_transformed(s.world, row.low.xyz, row.high.xyz, low, high);
    s.appear = max(box_faded(low, high, row.low.w, row.high.w), box_small_faded(low, high));
    s.gone = box_faded(low, high, row.far.x, row.far.y);
    s.center = transform_point(s.world, row.sphere.xyz);
    float scale = max(length(float3(s.world[0].x, s.world[1].x, s.world[2].x)), length(float3(s.world[0].y, s.world[1].y, s.world[2].y)));
    s.radius = row.sphere.w * scale;
    return (row.frames.w & 0xffffu) >= 2u && s.appear > 0.0 && s.gone < 1.0;
}

// The frames, as render.impostor_unfold, impostor_fold and impostor_axes
// make them: the square of the grid, corner to corner from -1 to 1, folded on
// the upper hemisphere (y up).
float3 impostor_unfold(float2 e) {
    float2 p = float2(e.x + e.y, e.x - e.y) * 0.5;
    return normalize(float3(p.x, 1.0 - abs(p.x) - abs(p.y), p.y));
}
float2 impostor_fold(float3 d) {
    d.y = max(d.y, 0.0);
    float sum = abs(d.x) + d.y + abs(d.z);
    if (sum < 1e-12) return float2(0.0);
    float2 p = d.xz / sum;
    return float2(p.x + p.y, p.x - p.y);
}
float3 impostor_direction(uint n, uint2 at) {
    float steps = float(max(n, 2u) - 1u);
    return impostor_unfold(float2(at) / steps * 2.0 - 1.0);
}
void impostor_axes(float3 d, out float3 right, out float3 up) {
    float3 reference = abs(d.y) > 0.999 ? float3(0.0, 0.0, -1.0) : float3(0.0, 1.0, 0.0);
    right = normalize(cross(reference, d));
    up = cross(d, right);
}
#endif
