//! mirai frame Foliage_Wind_Frame foliage_wind
// The winds of the world in the constants of each view (volume.Gpu_Wind), and
// the field of trampled foliage (foliage.Gpu_Wind_Frame).
#ifndef FOLIAGE_WIND_SLANG
#define FOLIAGE_WIND_SLANG
#include "volume.slang"
#define FOLIAGE_BEND_RADIUS_MAX 4.0 // foliage.BEND_RADIUS_MAX
struct Foliage_Wind_Frame {
    Gpu_Wind wind;
    float4 trample;  // xy: the centre of the field along x and z, z: the height its texels are from, relative to the origin; w: metres a side
    uint4 textures;  // x: of the field, y: of the frame before; 0xffffffff none
};
#endif
