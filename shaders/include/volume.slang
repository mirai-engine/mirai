// The weight of a volume at a point, as engine/volume weight: what the
// shaders that combine values by zone (wind, fog) share.
#ifndef VOLUME_SLANG
#define VOLUME_SLANG
#include <shared_constants.slang>

// volume.Gpu_Volume.
struct Gpu_Volume {
    float4 to_local[3]; // rows: from the world to the volume, turned and moved, not scaled; of an outline, to the middle of its box
    float4 shape;       // xyz half its size along each axis, metres (x the radius of a sphere; of an outline, of its box); w its blend
    uint4 kind;         // x 0 unbounded, 1 box, 2 sphere, 3 plane (everything under its local y), 4 outline, 5 none; y 1 when it adds; of an outline z its first point, w how many
};

// Where the points of the outlines a shader weighs are: x and z from the middle of the box of each.
interface IVolume_Outlines {
    float2 outline_point(uint i);
};

// volume.Gpu_Outlines: those points, two to a row.
struct Gpu_Outlines : IVolume_Outlines {
    uint4 count;
    float4 rows[VOLUME_OUTLINE_POINTS / 2];
    float2 outline_point(uint i) { float4 r = rows[i >> 1]; return (i & 1u) != 0u ? r.zw : r.xy; }
};

// How far inside the loop of an outline a place of the middle of its box is, as mm.loop_depth: below 0 outside.
float volume_loop_depth<O : IVolume_Outlines>(Gpu_Volume v, float2 p, O outlines) {
    uint first = v.kind.z, count = v.kind.w;
    bool inside = false;
    float nearest = 1e30;
    float2 a = outlines.outline_point(first + count - 1u);
    for (uint i = 0u; i < count; i++) {
        float2 b = outlines.outline_point(first + i);
        if ((a.y > p.y) != (b.y > p.y) && p.x < a.x + (b.x - a.x) * (p.y - a.y) / (b.y - a.y)) inside = !inside;
        float2 d = b - a;
        float2 off = p - a - d * saturate(dot(p - a, d) / max(dot(d, d), 1e-30));
        nearest = min(nearest, dot(off, off));
        a = b;
    }
    return inside ? sqrt(nearest) : -sqrt(nearest);
}

// 1 inside, going to 0 over its blend before its border, 0 outside: the one weight every shader that
// combines values by zone takes, as engine/volume weight. An outline is its box first: the loop is looked
// at only inside it.
float volume_weight<O : IVolume_Outlines>(Gpu_Volume v, float3 p, O outlines) {
    if (v.kind.x == 0u) return 1.0;
    float3 local = float3(dot(v.to_local[0].xyz, p) + v.to_local[0].w, dot(v.to_local[1].xyz, p) + v.to_local[1].w, dot(v.to_local[2].xyz, p) + v.to_local[2].w);
    bool boxed = v.kind.x == 1u || v.kind.x == 4u;
    float depth = boxed ? min(v.shape.x - abs(local.x), min(v.shape.y - abs(local.y), v.shape.z - abs(local.z))) : v.kind.x == 2u ? v.shape.x - length(local) : v.kind.x == 3u ? -local.y : -1.0;
    if (depth < 0.0) return 0.0;
    if (v.kind.x == 4u) {
        depth = min(volume_loop_depth(v, local.xz, outlines), v.shape.y - abs(local.y));
        if (depth < 0.0) return 0.0;
    }
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
    Gpu_Outlines outlines;
};

// The wind at a point: xyz its velocity, w its gusts.
float4 wind_at(Gpu_Wind wind, float3 p) {
    float4 value = float4(0.0);
    for (uint i = 0u; i < min(wind.count.x, WIND_VOLUMES); i++) {
        float w = volume_weight(wind.volumes[i], p, wind.outlines);
        if (w > 0.0) value = volume_mix(value, wind.values[i], w, wind.volumes[i]);
    }
    return value;
}

#endif
