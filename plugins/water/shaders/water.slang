// What the stages of the water share: its fluids of the frame and the small
// waves of its surfaces, which its material bends the light with and its
// caustics follow.
#ifndef WATER_SLANG
#define WATER_SLANG

// The trains of small waves over a surface of water: each runs along a
// direction of whole turns across WATER_DETAIL_SIZE metres, so what they make
// repeats across that size, at the speed of waves of its length in deep water.
static const float WATER_DETAIL_SIZE = 8.0;
static const int WATER_TRAINS = 8;
static const float4 WATER_TRAIN[WATER_TRAINS] = {
    // x, y: turns across WATER_DETAIL_SIZE along x and z; z: height, metres
    float4(3.0, 1.0, 0.012, 0.0), float4(-2.0, 3.0, 0.010, 0.0), float4(1.0, -4.0, 0.008, 0.0), float4(5.0, 2.0, 0.006, 0.0),
    float4(-4.0, -5.0, 0.004, 0.0), float4(7.0, -3.0, 0.003, 0.0), float4(-6.0, 7.0, 0.0025, 0.0), float4(2.0, 9.0, 0.002, 0.0),
};

// The slope of the small waves at a point of a surface, metres a metre along x and z.
float2 water_detail_slope(float2 xz, float time) {
    float2 slope = float2(0.0);
    for (int i = 0; i < WATER_TRAINS; i++) {
        float4 train = WATER_TRAIN[i];
        float2 k = train.xy * (6.2831853 / WATER_DETAIL_SIZE);
        float speed = sqrt(9.81 * length(k));
        slope += train.z * k * cos(dot(k, xz) - speed * time + float(i) * 1.7);
    }
    return slope;
}

// A place of the world relative to the origin of the render (frame.origin,
// ctx.origin, in steps) on the repeat of the small waves: what the origin adds
// to it (origin.slang).
float2 water_detail_place(float2 xz, int3 origin) {
    return xz + origin_wrap(origin, float3(WATER_DETAIL_SIZE)).xz;
}

#endif

#ifdef WATER_STAGE
#include "fog_dry.slang"
#include "water_waves.slang"

// water.Gpu_Params.
struct Water_Params {
    uint count;  // bodies
    uint texels; // across the caustic pattern
    float lens;  // m over and under the near plane where the line of the surface shows on the lens
    float ior;   // of the surface the caustic pattern is made for
};
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Water_Params> water : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);

[[vk::binding(SLOT_PASS4, 0)]] StructuredBuffer<Water_Body> bodies : register(MIRAI_REGISTER(t, SLOT_PASS4), space0);

bool water_inside(Water_Body b, float3 position) {
    if (b.surface.y > 0.5) {
        float reach = water_wave_reach(b);
        if (position.y <= b.surface.x - reach || position.y > b.surface.x + reach) return position.y <= b.surface.x;
        return position.y <= water_surface_at(b, position.xz);
    }
    return all(abs(transform_point(b.to_box, position)) <= 0.5);
}

struct Water_Dry_Boxes : IDry_Boxes {
    uint dry_count() { return water.count; }
    float dry_priority_of(uint i) { Water_Body b = bodies[i]; return b.surface.z > 0.5 ? b.surface.w : DRY_NONE; }
    bool dry_holds(uint i, float3 position) { return water_inside(bodies[i], position); }
};

// The fluid a point is in under its surface, out of the dry boxes of higher
// priority it is in; -1 in none.
int water_at(float3 position) {
    int found = -1;
    for (uint i = 0u; i < water.count; i++) {
        Water_Body b = bodies[i];
        if (b.surface.z > 0.5 || !water_inside(b, position)) continue;
        if (found < 0 || b.surface.w > bodies[found].surface.w) found = int(i);
    }
    Water_Dry_Boxes boxes;
    return found >= 0 && dry_takes(dry_priority(boxes, position), bodies[found].surface.w) ? -1 : found;
}

// The direction the light of the sun goes in under a flat surface of an index of refraction.
float3 water_sun_under(float ior) {
    return refract(-frame.sun_direction.xyz, float3(0.0, 1.0, 0.0), 1.0 / ior);
}
#endif
