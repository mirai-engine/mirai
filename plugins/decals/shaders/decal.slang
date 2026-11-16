// What the stages of the decals share.
#ifndef DECAL_SLANG
#define DECAL_SLANG
#include "scene.slang"

// decals.Gpu_Decal.
struct Decal {
    float4 to_box[3];   // rows: the world to the box of the decal, whose sides are 1
    float4 to_world[3]; // rows: that box to the world
    float4 color;       // rgb multiplies the image, a is the opacity
    float4 emission;    // rgb: what the surface emits under it; a: the facing below which it fades (0: it never does)
    uint texture;       // of the texture table; INVALID: the plain color
    float density;      // texels of the image in a metre of the box
    uint pad0;
    uint pad1;
};
[[vk::binding(SLOT_PASS0, 0)]] StructuredBuffer<Decal> decals : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);

#endif
