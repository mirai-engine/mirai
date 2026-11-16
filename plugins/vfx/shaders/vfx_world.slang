//! mirai frame Vfx_World_Frame vfx_world
// The textures of the world of the vfx plugin in the constants of each view
// (vfx.Gpu_World_Frame); vfx_world_texture.slang reads them.
#ifndef VFX_WORLD_SLANG
#define VFX_WORLD_SLANG
struct Vfx_World_Frame {
    uint4 names;       // of each, as getStringHash gives the name of its grid; 0: none
    uint4 textures;    // their places in the texture table
    float4 starts[2];  // the uv of the lowest corner of the region of each, two in a row
    float4 bounds[4];  // the region of each, relative to the origin of the frame: lowest x and z, then highest
};
#endif
