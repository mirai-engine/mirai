// The rule of the dry boxes, the one of the physics (fluid_column): a dry box
// takes out of where it is the media of lower priority. The fog and the water
// read their own boxes through it.
#ifndef FOG_DRY_SLANG
#define FOG_DRY_SLANG

static const float DRY_NONE = -1e30;

interface IDry_Boxes {
    uint dry_count();
    // The priority of box i if it is a dry box; DRY_NONE otherwise.
    float dry_priority_of(uint i);
    bool dry_holds(uint i, float3 position);
}

// The priority of the dry boxes a point is in; DRY_NONE in none.
float dry_priority<B : IDry_Boxes>(B boxes, float3 position) {
    float dry = DRY_NONE;
    for (uint i = 0u; i < boxes.dry_count(); i++) {
        float priority = boxes.dry_priority_of(i);
        if (priority > dry && boxes.dry_holds(i, position)) dry = priority;
    }
    return dry;
}

// Whether the dry boxes of a point (dry_priority) take out a medium of a priority.
bool dry_takes(float dry, float priority) { return priority < dry; }

#endif
