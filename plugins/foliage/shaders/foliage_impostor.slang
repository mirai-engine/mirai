// The far foliage drawn as octahedral impostors (foliage.Impostor_Row and
// Impostor_Instance; render.impostor_capture made their frames), in the
// Gbuffer stage. An instance is drawn on a quad that faces the eye and holds
// the sphere of its type; the fragment blends the three frames nearest the
// direction it is seen from, each moved by the depth it keeps (Ryan Brucks,
// shaderbits 2018), and writes the surface it finds where the leaves are.
#ifndef FOLIAGE_IMPOSTOR_SLANG
#define FOLIAGE_IMPOSTOR_SLANG
#include "native.slang"
#include "scene.slang"

// A type of foliage of a Foliage seen as an impostor: its frames and where
// its mesh gives way to them, which fades them in with the pattern of the
// batches (box_faded over the same box), and where they fade out.
struct Impostor_Row {
    float4 sphere; // the centre of the frames in the space of the type, and their radius
    float4 low;    // xyz: the box of its mesh; w: from the eye, where its mesh starts to fade out
    float4 high;   // xyz; w: where its mesh is gone
    uint4 frames;  // x: the texture of color and coverage, y: of normal and depth (texture_index); z: frames a side; w: pixels a side of a frame
    float4 far;    // x: where the impostor starts to fade out, y: where it is gone (0: never)
};

// An instance, as a Batch_Instance holds it, relative to the anchor of the
// instances, and the row of its type.
struct Impostor_Instance {
    float3 position;
    uint rotation;
    uint2 scale;
    uint row;
};

struct Impostor_Params {
    float4 anchor; // xyz: where the positions of the instances are from, relative to the origin
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
[[vk::binding(SLOT_PASS1, 0)]] StructuredBuffer<Impostor_Row> impostor_rows : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Impostor_Params> impostor_params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);

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
