// The aerial perspective of a view (air_aerial.comp, render/air.odin): what
// the air between the eye and a place keeps of the light that place sends and
// what it sends towards the eye itself, for every surface the image shows:
// the opaque scene (composite.comp), glass (glass.comp) and forward blends
// (translucent.frag) take it alike. Without an atmosphere it keeps all and
// sends nothing.
#ifndef MIRAI_AERIAL_SLANG
#define MIRAI_AERIAL_SLANG
#include "scene.slang"

// A volume over the view: xy across it, z the distance out to AIR_AERIAL_DISTANCE
// in AIR_AERIAL_SLICES slices; rgb what the air sends towards the eye to the
// end of each, a what it keeps.
[[vk::binding(SLOT_AERIAL, 0)]] Texture3D<float4> aerial_volume : register(MIRAI_REGISTER(t, SLOT_AERIAL), space0);

struct Air_Between {
    float3 sent; // the light the air sends towards the eye, render units
    float kept;  // the share it keeps of the light from behind it
};

// The air between the eye and what lies `distance` metres along the ray of uv.
Air_Between air_between(float2 uv, float distance) {
    Air_Between a;
    a.sent = float3(0.0);
    a.kept = 1.0;
    if (!(frame.sky_map.y > 0.5 && frame.sun_direction.w > 0.5)) return a;
    float slices = float(AIR_AERIAL_SLICES);
    // A texel holds the air to the end of its slice; nearer than the first, a share of it.
    float w = saturate(distance / AIR_AERIAL_DISTANCE - 0.5 / slices);
    float4 air = aerial_volume.SampleLevel(linear_sampler, float3(uv, w), 0.0);
    float near = saturate(distance * slices / AIR_AERIAL_DISTANCE);
    a.sent = air.rgb * near * sun_above_air();
    a.kept = lerp(1.0, air.a, near);
    return a;
}

// What lies `distance` metres along the ray of uv seen through the air: its
// light times what crosses, plus what the air sends.
float3 aerial_perspective(float3 color, float2 uv, float distance) {
    Air_Between a = air_between(uv, distance);
    return color * a.kept + a.sent;
}

#endif
