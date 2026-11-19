// The light of a participating medium at a point, for the passes that light
// one (the fog plugin, the volumes of the vfx plugin): what reaches it from
// around, from the sun through the scene and from the local lights. A medium
// takes light from every side: its phase function, not the cosine of a
// surface, says how much of it goes towards the eye. Of each light it takes
// the share media scatter (light_shares, frame.sun_shares), and of the light
// around what frame.indirect gives.
#ifndef MIRAI_MEDIA_SLANG
#define MIRAI_MEDIA_SLANG
#include "lighting.slang"
#include "probe_light.slang"
#ifdef SUN_SHADOW_SLOT
#include "shadow_maps.slang"
#endif
// How wide the place of a medium the pass lights is, metres: it reads the
// level of the sun and the mip of a light whose texel is about as wide.
static float media_across = 0.0;

// The most nodes of the tree of the lights with shadows a point of a medium
// takes through a shadow ray each (light_cut): past it, groups stand for
// their lights.
#define MEDIA_LIGHT_BUDGET 4u

// What the local lights give a point of a medium towards the eye, of the
// share of their light media scatter, as direct_lighting gives a surface the
// same in every frame: those with shadows through their maps or a ray each
// while they fit in MEDIA_LIGHT_BUDGET and groups that stand for them past
// it, those without by the walks of their trees. changed: also whether a
// light that reaches the point moved, or what casts shadows changed on the
// way of a ray, since the frame before (occluder_changed of trace.slang).
float3 media_local_light(float3 position, float3 eye_ray, float g, inout bool changed) {
    if (frame.light_nodes == 0u) return float3(0.0);
    return direct_lighting(shading_medium(position, -eye_ray, g, media_across), 0.0, MEDIA_LIGHT_BUDGET, LIGHTS_LOCAL | LIGHTS_SCATTERED | LIGHTS_CHANGES, float2(-1.0, 0.0), changed);
}
float3 media_local_light(float3 position, float3 eye_ray, float g) {
    bool changed = false;
    return media_local_light(position, eye_ray, g, changed);
}

// Whether what media_local_light gives a point may have changed since the
// frame before, without taking it.
bool media_local_changed(float3 position) {
    return frame.light_nodes != 0u && lights_changed(position, float3(0.0), 0.0, MEDIA_LIGHT_BUDGET, LIGHTS_LOCAL | LIGHTS_SCATTERED);
}

// The light around a point of a medium: the mean of what reaches a surface
// facing up and one facing down.
float3 media_ambient(float3 position, float3 to_eye_ray) {
    float3 up = float3(0.0, 1.0, 0.0);
    if (!indirect_cached()) return (0.5 * frame.indirect) * (sky_irradiance(up) + sky_irradiance(-up));
    // A point of a medium is on no surface: every probe around it gives it light.
    return (0.5 * frame.indirect) * (sample_probes_towards(position, up, to_eye_ray, up, -1.0, false) + sample_probes_towards(position, -up, to_eye_ray, -up, -1.0, false));
}

// The light of the sun at a point that media scatter: its share of sun_light.
float3 media_sun_light(float3 position) {
    return sun_light(position) * frame.sun_shares.y;
}

// Whether what of the sun reaches a point of a medium (media_sun_through)
// may have changed since the frame before.
bool media_sun_changed(float3 position) {
    return (frame.moved.z & MOVED_SUN) != 0u || occluder_changed(position, frame.sun_direction.xyz, sun_reach(position, frame.sun_direction.xyz), INVALID, FLT_MAX);
}

// What of the sun reaches a point of a medium through the scene: 1 where
// nothing stops it. A pass with the maps of the view (SUN_SHADOW_SLOT) takes
// from them what stops the sun, and a ray where no cascade holds the point.
// changed: as for media_local_light.
float media_sun_through(float3 position, inout bool changed) {
    float reach = sun_reach(position, frame.sun_direction.xyz);
#ifdef SUN_SHADOW_SLOT
    float known = sun_shadow_seen(position, float3(0.0), media_across);
    float through = known < 0.0 ? float(trace_visible(position, frame.sun_direction.xyz, reach)) : known;
#else
    float through = float(trace_visible(position, frame.sun_direction.xyz, reach));
#endif
    changed = changed || media_sun_changed(position);
    return through;
}

// What reaches a point of a medium from the sun through the scene
// (media_sun_through), times sun_kept, what the medium itself lets through,
// and the phase towards the eye; none without a sun.
float3 media_sun(float3 position, float3 eye_ray, float g, float3 sun_kept, inout bool changed) {
    if (frame.sun_direction.w < 0.5 || !(frame.sun_shares.y > 0.0)) return float3(0.0);
    float3 through = media_sun_through(position, changed);
    return media_sun_light(position) * through * sun_kept * media_phase(dot(eye_ray, frame.sun_direction.xyz), g);
}
float3 media_sun(float3 position, float3 eye_ray, float g, float3 sun_kept) {
    bool changed = false;
    return media_sun(position, eye_ray, g, sun_kept, changed);
}
#endif
