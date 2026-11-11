// The light of the probe volume around a point, through the probe gates of
// the extensions. A source that reads it includes this, so only its stages
// change with a probe hook.
#ifndef MIRAI_PROBE_LIGHT_SLANG
#define MIRAI_PROBE_LIGHT_SLANG
#include "scene.slang"
#ifdef MIRAI_HOOK_PROBES
#include <extension_probes.slang>
#endif

// `surface` false: a point that is not on a surface (a particle of the vfx plugin), whose
// normal is only a direction to read around. w: the share of each light that
// comes from the sky (probe_specular).
void sample_probes_around(float3 position, float3 normal, float3 view_dir, Probe_Directions directions, out float4 light[PROBE_READS], float viewer_distance = -1.0, bool surface = true) {
    [ForceUnroll]
    for (int d = 0; d < PROBE_READS; d++) light[d] = float4(0.0);
    if (frame.volume_atlas.w == 0u || directions.wants == 0u) return;
    if (viewer_distance < 0.0) viewer_distance = eye_distance(position);
    probe_volume_light(position, normal, view_dir, viewer_distance, directions, surface, light);
#ifdef MIRAI_HOOK_PROBES
    // Each direction looks through the gate that gives it the most, one after
    // another (picked by value, not by index, to keep the light in registers).
    [loop]
    for (uint d = 0u; d < uint(PROBE_READS); d++) {
        if ((directions.wants & (1u << d)) == 0u) continue;
        float3 direction = d == 0u ? directions.at[0] : (d == 1u ? directions.at[1] : directions.at[2]);
        float3 beyond, front;
        float4 through[3];
        float share = mirai_probe_gate(position, direction, beyond, front, through);
        if (share <= 0.0) continue;
        float4 there[PROBE_READS];
        probe_volume_light(beyond, normalize(transform_vector(through, normal)), front, viewer_distance, probe_directions(normalize(transform_vector(through, direction))), surface, there);
        float4 here = d == 0u ? light[0] : (d == 1u ? light[1] : light[2]);
        float4 mixed = lerp(here, there[0], share);
        light[0] = d == 0u ? mixed : light[0];
        light[1] = d == 1u ? mixed : light[1];
        light[2] = d == 2u ? mixed : light[2];
    }
#endif
}
float3 sample_probes_towards(float3 position, float3 normal, float3 view_dir, float3 direction, float viewer_distance = -1.0, bool surface = true) {
    float4 light[PROBE_READS];
    sample_probes_around(position, normal, view_dir, probe_directions(direction), light, viewer_distance, surface);
    return light[0].rgb;
}
float3 sample_probes(float3 position, float3 normal, float3 view_dir, float viewer_distance = -1.0) {
    return sample_probes_towards(position, normal, view_dir, normal, viewer_distance);
}

// Whether the probe volume holds the light around: GI is on and its probes traced.
bool indirect_cached() { return (frame.flags & FRAME_FLAG_GI) != 0u && frame.volume_atlas.w != 0u; }

// The irradiance around the normal of a point that the view gets from what
// holds the light around: the probe volume, or without it the sky, which
// nothing then shadows but the ambient occlusion of the material.
float3 indirect_irradiance(float3 position, float3 normal, float3 view_dir, bool surface = true) {
    if (!indirect_cached()) return sky_irradiance(normal);
    return sample_probes_towards(position, normal, view_dir, normal, -1.0, surface) * frame.gi_strength;
}

// What a specular lobe of that roughness gathers around `direction` from what
// the probes hold there (`around`, w the share of it from the sky): the probes
// hold the sky blurred over a hemisphere, so that share is the sky itself as
// sharp as the lobe, as without the probes; a rough lobe keeps what they hold.
float3 probe_specular(float4 around, float3 direction, float roughness) {
    float sky = around.w * (1.0 - roughness);
    return sky > 0.0 ? lerp(around.rgb, sky_radiance(direction, roughness), sky) : around.rgb;
}

// What indirect_lobes reads: the light around the normal, and around the
// dominant directions of the specular lobe and of the coat.
#define INDIRECT_DIFFUSE (1u << PROBE_DIFFUSE)
#define INDIRECT_SPECULAR (1u << PROBE_SPECULAR)
#define INDIRECT_COAT (1u << PROBE_COAT)

// The light around a point of shading `s` for the lobes in `wants`, from one
// read of the probe volume, or without it from the sky; zero for the others.
// A point that lets light through also gets the irradiance around its other
// side.
Indirect indirect_lobes(float3 position, float3 normal, float3 view_dir, Shading s, uint wants, float occlusion) {
    Indirect light = indirect_make(float3(0.0), float3(0.0), occlusion);
    light.coat_radiance = float3(0.0);
    if (shading_transmits(s)) light.back_irradiance = indirect_irradiance(position, -normal, view_dir);
    if (wants == 0u) return light;
    Probe_Directions directions;
    directions.at[PROBE_DIFFUSE] = normal;
    directions.at[PROBE_SPECULAR] = (wants & INDIRECT_SPECULAR) != 0u ? dominant_direction(s) : normal;
    directions.at[PROBE_COAT] = (wants & INDIRECT_COAT) != 0u ? coat_dominant_direction(s) : normal;
    directions.wants = wants;
    if (!indirect_cached()) {
        if ((wants & INDIRECT_DIFFUSE) != 0u) light.irradiance = sky_irradiance(normal);
        if ((wants & INDIRECT_SPECULAR) != 0u) light.radiance = sky_radiance(directions.at[PROBE_SPECULAR], s.roughness);
        if ((wants & INDIRECT_COAT) != 0u) light.coat_radiance = sky_radiance(directions.at[PROBE_COAT], s.coat_roughness);
        return light;
    }
    float4 around[PROBE_READS];
    sample_probes_around(position, normal, view_dir, directions, around);
    light.irradiance = around[PROBE_DIFFUSE].rgb * frame.gi_strength;
    light.radiance = probe_specular(around[PROBE_SPECULAR], directions.at[PROBE_SPECULAR], s.roughness) * frame.gi_strength;
    light.coat_radiance = probe_specular(around[PROBE_COAT], directions.at[PROBE_COAT], s.coat_roughness) * frame.gi_strength;
    return light;
}

// A light in the bits of one float: 8 bits of each channel under an exponent
// they share, of 5 bits over the range of a half float, and bit 29 set with
// bit 30 clear, so that the float is a normal one, which a texture keeps as it
// is (contact_pixels.comp takes two to the composition in one texel).
float light_pack(float3 light) {
    light = clamp(finite_or_zero(light), 0.0, 65000.0);
    float most = max(light.r, max(light.g, light.b));
    int e = clamp(int(floor(log2(max(most, 1e-30)))) + 1, -15, 16);
    uint3 q = min(uint3(light * exp2(float(8 - e)) + 0.5), uint3(255u));
    return asfloat((1u << 29) | (uint(e + 15) << 24) | (q.r << 16) | (q.g << 8) | q.b);
}
float3 light_unpack(float packed) {
    uint bits = asuint(packed);
    float3 q = float3(float((bits >> 16) & 255u), float((bits >> 8) & 255u), float(bits & 255u));
    return q * exp2(float(int((bits >> 24) & 31u) - 23));
}
#endif
