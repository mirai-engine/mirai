// The volumes of the frame, at the slot FOG_VOLUMES_SLOT of the stage that
// includes this, and what is read of them along a ray.
#ifndef FOG_VOLUMES_SLANG
#define FOG_VOLUMES_SLANG
#include "fog.slang"
#include "fog_dry.slang"

[[vk::binding(FOG_VOLUMES_SLOT, 0)]] StructuredBuffer<Fog_Volume> fog_volumes : register(MIRAI_REGISTER(t, FOG_VOLUMES_SLOT), space0);

struct Fog_Dry_Boxes : IDry_Boxes {
    uint dry_count() { return fog.grid.w; }
    float dry_priority_of(uint i) { Fog_Volume v = fog_volumes[i]; return fog_carve(v, FOG_CARVE_DRY) ? v.carve.x : DRY_NONE; }
    bool dry_holds(uint i, float3 position) { return fog_volume_share(fog_volumes[i], position) > 0.0; }
};

// The priority of the dry boxes a point is in (dry_priority): what fog_taken reads.
float fog_dry_at(float3 position) {
    if (fog.dry == 0u) return DRY_NONE;
    Fog_Dry_Boxes boxes;
    return dry_priority(boxes, position);
}

bool fog_taken(Fog_Volume v, float taken) { return fog_carve(v, FOG_CARVE_CARVED) && dry_takes(taken, v.carve.x); }

// The share of the light along direction that the volumes that take the
// light of the sun let reach a point, from where it enters them; 1 in
// a dry box over them. taken: fog_dry_at of the point.
float fog_shade(float3 position, float3 direction, float taken) {
    if (fog.shade == 0u) return 1.0;
    float depth = 0.0;
    for (uint i = 0u; i < fog.grid.w; i++) {
        Fog_Volume v = fog_volumes[i];
        if (!(v.carve.z > 0.0) || fog_taken(v, taken) || !(fog_volume_share(v, position) > 0.0)) continue;
        depth += v.carve.z * fog_volume_exit(v, position, direction);
    }
    return exp(-depth);
}

#endif
