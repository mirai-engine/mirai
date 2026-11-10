// The light of a participating medium at a point, for the passes that light
// one (the fog plugin, the volumes of the vfx plugin): what reaches it from
// around, from the sun through the scene and from the local lights. A medium
// takes light from every side: its phase function, not the cosine of a
// surface, says how much of it goes towards the eye.
#ifndef MIRAI_MEDIA_SLANG
#define MIRAI_MEDIA_SLANG
#include "lighting.slang"
#include "probe_light.slang"
#ifdef SUN_SHADOW_SLOT
#include "shadow_maps.slang"
#endif

// Henyey-Greenstein times pi: what the Lambert-normalized light of the frame
// is multiplied by. cosine: between where the light goes and the eye; g, the
// anisotropy of the medium, forward above 0.
float media_phase(float cosine, float g) {
    float g2 = g * g;
    return 0.25 * (1.0 - g2) / pow(max(1.0 + g2 - 2.0 * g * cosine, 1e-4), 1.5);
}

// One local light, picked for what it gives the point, over the chance of
// picking it: over frames, what all of them give, with its shadow ray if it
// casts shadows. The tree of the lights without shadows takes its share of
// the picks by what its root gives. changed: also whether the light moved or
// its ray crossed what casts shadows and changed since the frame before
// (occluder_changed of trace.slang).
float3 media_local_light(float3 position, float3 eye_ray, float g, float pick, inout bool changed) {
    if (frame.light_nodes == 0u) return float3(0.0);
    uint root = 0u;
    float share = 1.0;
    uint shadowless = frame.shadowless_lights.x;
    if (shadowless != 0u) {
        float cast = node_weight(light_nodes[0], position, float3(0.0));
        float bare = node_weight(light_nodes[shadowless], position, float3(0.0));
        float chance = cast + bare > 0.0 ? cast / (cast + bare) : 0.5;
        if (pick < chance) {
            pick = pick / max(chance, 1e-6);
            share = chance;
        } else {
            pick = saturate((pick - chance) / max(1.0 - chance, 1e-6));
            share = 1.0 - chance;
            root = shadowless;
        }
    }
    float chance;
    Light_Node leaf = light_nodes[node_light(root, pick, position, float3(0.0), chance)];
    if ((leaf.flags & LIGHT_NODE_LEAF) == 0u) return float3(0.0);
    uint index = leaf.child;
    Light light = lights[index];
    chance *= share;
    if (!(chance > 0.0)) return float3(0.0);
    float3 towards = normalize(light.position_range.xyz - position);
    float3 direction;
    float distance;
    float3 incident = light_contribution(light, position, towards, direction, distance);
    if (!(luminance(incident) > light_cutoff())) return float3(0.0);
    float reach = light_reach(light, distance);
    float3 through = float3(1.0);
    if (root == 0u) {
#ifdef SHADOW_DATA_SLOT
        // From its maps; where none holds the point the light has no shadow there.
        Shadow_Map m;
        float seen = light_shadow_seen(index, position, float3(0.0), light_extent(light));
        if (seen >= 0.0) through = float3(seen);
#ifdef SHADOW_TINT_SLOT
        if (seen > 0.0 && light_map_of(index, position, m)) through *= shadow_tint(m, position);
#endif
#else
        through = trace_transmission(position, direction, reach);
#endif
        changed = changed || occluder_changed(position, direction, reach, INVALID, FLT_MAX);
    }
    changed = changed || light_moved(index);
    return incident * through * (media_phase(dot(eye_ray, direction), g) / chance);
}
float3 media_local_light(float3 position, float3 eye_ray, float g, float pick) {
    bool changed = false;
    return media_local_light(position, eye_ray, g, pick, changed);
}

// The light around a point of a medium: the mean of what reaches a surface
// facing up and one facing down.
float3 media_ambient(float3 position, float3 to_eye_ray) {
    float3 up = float3(0.0, 1.0, 0.0);
    if (!indirect_cached()) return 0.5 * (sky_irradiance(up) + sky_irradiance(-up));
    // A point of a medium is on no surface: every probe around it gives it light.
    return 0.5 * (sample_probes_towards(position, up, to_eye_ray, up, -1.0, false) + sample_probes_towards(position, -up, to_eye_ray, -up, -1.0, false));
}

// What reaches a point of a medium from the sun through the scene, times
// sun_kept, what the medium itself lets through, and the phase towards the
// eye; none without a sun. A pass with the maps of the view (SUN_SHADOW_SLOT)
// takes from them what stops the sun and, from their tint (SHADOW_TINT_SLOT),
// what the glass on its way lets through; past its cascades the sun has no
// shadow there. changed: as for media_local_light.
float3 media_sun(float3 position, float3 eye_ray, float g, float3 sun_kept, inout bool changed) {
    if (frame.sun_direction.w < 0.5) return float3(0.0);
    float reach = scene_reach(position, frame.sun_direction.xyz);
#ifdef SUN_SHADOW_SLOT
    float known = sun_shadow_seen(position, float3(0.0));
    float3 through = float3(known < 0.0 ? 1.0 : known);
#ifdef SHADOW_TINT_SLOT
    Shadow_Map m;
    if (known > 0.0 && sun_map_of(position, m)) through *= shadow_tint(m, position);
#endif
#else
    float3 through = trace_transmission(position, frame.sun_direction.xyz, reach);
#endif
    changed = changed || (frame.moved.z & MOVED_SUN) != 0u || occluder_changed(position, frame.sun_direction.xyz, reach, INVALID, FLT_MAX);
    return sun_light(position) * through * sun_kept * media_phase(dot(eye_ray, frame.sun_direction.xyz), g);
}
float3 media_sun(float3 position, float3 eye_ray, float g, float3 sun_kept) {
    bool changed = false;
    return media_sun(position, eye_ray, g, sun_kept, changed);
}
#endif
