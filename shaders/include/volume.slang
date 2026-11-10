// The weight of a volume at a point, as engine/volume weight: what the
// shaders that combine values by zone (wind, fog) share.
#ifndef VOLUME_SLANG
#define VOLUME_SLANG
#include <shared_constants.slang>

// volume.Gpu_Volume.
struct Gpu_Volume {
    float4 to_local[3]; // rows: from the world to the volume, turned and moved, not scaled
    float4 shape;       // xyz half its size along each axis, metres (x the radius of a sphere); w its blend
    uint4 kind;         // x 0 unbounded, 1 box, 2 sphere, 3 plane (everything under its local y); y 1 when it adds
};

// 1 inside, going to 0 over its blend before its border, 0 outside.
float volume_weight(Gpu_Volume v, float3 p) {
    if (v.kind.x == 0u) return 1.0;
    float3 local = float3(dot(v.to_local[0].xyz, p) + v.to_local[0].w, dot(v.to_local[1].xyz, p) + v.to_local[1].w, dot(v.to_local[2].xyz, p) + v.to_local[2].w);
    float depth = v.kind.x == 1u ? min(v.shape.x - abs(local.x), min(v.shape.y - abs(local.y), v.shape.z - abs(local.z))) : v.kind.x == 2u ? v.shape.x - length(local) : v.kind.x == 3u ? -local.y : -1.0;
    if (depth < 0.0) return 0.0;
    return v.shape.w > 0.0 ? min(depth / v.shape.w, 1.0) : 1.0;
}

// value after a volume of weight w whose own value is by: replaced by it, or added.
float4 volume_mix(float4 value, float4 by, float w, Gpu_Volume v) {
    return v.kind.y != 0u ? value + by * w : lerp(value, by, w);
}

// volume.Gpu_Wind: every wind of the world in the order they apply.
struct Gpu_Wind {
    uint4 count;
    Gpu_Volume volumes[WIND_VOLUMES];
    float4 values[WIND_VOLUMES]; // xyz its velocity, m/s; w its gusts, cycles per second
};

// The wind at a point: xyz its velocity, w its gusts.
float4 wind_at(Gpu_Wind wind, float3 p) {
    float4 value = float4(0.0);
    for (uint i = 0u; i < min(wind.count.x, WIND_VOLUMES); i++) {
        float w = volume_weight(wind.volumes[i], p);
        if (w > 0.0) value = volume_mix(value, wind.values[i], w, wind.volumes[i]);
    }
    return value;
}

#endif
