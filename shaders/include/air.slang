// The air of an atmosphere, after Hillaire, "A Scalable and Production Ready
// Sky and Atmosphere Rendering Technique" (EGSR 2020): a spherical planet
// whose air scatters by Rayleigh and Mie and absorbs by Mie and ozone. Its
// tables (render/air.odin) are entries of the texture table: the
// transmittance to the top of the air, the light of every order of
// scattering past the first with an isotropic phase, and the sky around the
// eye of each view, a row each. Every value is for a sun of illuminance 1 above
// the air. A place of the planet is relative to its center, the eye straight
// above it: the world is flat and level at the eye, y up.
#ifndef MIRAI_AIR_SLANG
#define MIRAI_AIR_SLANG
#include <shared_constants.slang>

// The entries and the sizes of the tables are AIR_* of render/abi; AIR_SKY_SIZE is of one row.
static const float AIR_AERIAL_DISTANCE = 32000.0; // metres the volume of the aerial perspective reaches
// What a place below the ground is lifted to, metres above it.
static const float AIR_GROUND_MARGIN = 1.0;

// What a metre of air at an altitude scatters and stops.
struct Air_Medium {
    float3 rayleigh;
    float3 mie;
    float3 extinction;
};

Air_Medium air_medium(Air_Data a, float altitude) {
    float h = max(altitude, 0.0);
    float mie = exp(-h / a.mie.w);
    Air_Medium m;
    m.rayleigh = a.rayleigh.rgb * exp(-h / a.rayleigh.w);
    m.mie = a.mie.rgb * mie;
    float ozone = max(1.0 - abs(h - a.ozone.w) / a.planet.z, 0.0);
    m.extinction = m.rayleigh + m.mie + a.mie_absorption.rgb * mie + a.ozone.rgb * ozone;
    return m;
}

float air_rayleigh_phase(float cosine) { return 3.0 / (16.0 * PI) * (1.0 + cosine * cosine); }

// Cornette-Shanks, as the paper.
float air_mie_phase(float cosine, float g) {
    float g2 = g * g;
    return 3.0 / (8.0 * PI) * ((1.0 - g2) * (1.0 + cosine * cosine)) / ((2.0 + g2) * pow(max(1.0 + g2 - 2.0 * g * cosine, 1e-4), 1.5));
}

// Along a ray from radius r whose direction has cosine mu with the up of its
// start: how far it goes to the top of the air, whether it meets the ground,
// and how far it goes to it.
float air_to_top(Air_Data a, float r, float mu) {
    return max(-r * mu + sqrt(max(r * r * (mu * mu - 1.0) + a.planet.y * a.planet.y, 0.0)), 0.0);
}
bool air_meets_ground(Air_Data a, float r, float mu) {
    return mu < 0.0 && r * r * (mu * mu - 1.0) + a.planet.x * a.planet.x >= 0.0;
}
float air_to_ground(Air_Data a, float r, float mu) {
    return max(-r * mu - sqrt(max(r * r * (mu * mu - 1.0) + a.planet.x * a.planet.x, 0.0)), 0.0);
}

// A coordinate from 0 to 1 onto the centers of the first and last texels of a size, and back.
float2 air_texels(float2 unit, float2 size) { return 0.5 / size + unit * (1.0 - 1.0 / size); }
float2 air_unit(float2 uv, float2 size) { return (uv - 0.5 / size) / (1.0 - 1.0 / size); }

// The transmittance table (Bruneton 2017): u the distance to the top between
// its least and most at the radius, v the distance to the horizon.
float2 air_transmittance_uv(Air_Data a, float r, float mu) {
    float top = sqrt(a.planet.y * a.planet.y - a.planet.x * a.planet.x);
    float rho = sqrt(max(r * r - a.planet.x * a.planet.x, 0.0));
    float d = air_to_top(a, r, mu);
    float d_min = a.planet.y - r;
    float d_max = rho + top;
    return air_texels(float2((d - d_min) / max(d_max - d_min, 1e-3), rho / top), AIR_TRANSMITTANCE_SIZE);
}
void air_transmittance_at(Air_Data a, float2 uv, out float r, out float mu) {
    float2 unit = air_unit(uv, AIR_TRANSMITTANCE_SIZE);
    float top = sqrt(a.planet.y * a.planet.y - a.planet.x * a.planet.x);
    float rho = top * unit.y;
    r = sqrt(rho * rho + a.planet.x * a.planet.x);
    float d_min = a.planet.y - r;
    float d_max = rho + top;
    float d = d_min + unit.x * (d_max - d_min);
    mu = d == 0.0 ? 1.0 : clamp((top * top - rho * rho - d * d) / (2.0 * r * d), -1.0, 1.0);
}

// What crosses the air from radius r along mu to its top, per channel, by
// its table; a ray that meets the ground goes on through it.
float3 air_transmittance(Air_Data a, float r, float mu) {
    return material_textures[AIR_TRANSMITTANCE_TEXTURE].SampleLevel(linear_sampler, air_transmittance_uv(a, r, mu), 0.0).rgb;
}

// How much of the disc of the sun at mu shows over the horizon of radius r.
float air_sun_shown(Air_Data a, float r, float mu) {
    float horizon = -sqrt(max(1.0 - a.planet.x * a.planet.x / (r * r), 0.0));
    float above = asin(clamp(mu, -1.0, 1.0)) - asin(horizon);
    return saturate(0.5 + 0.5 * above / max(a.ground.w, 1e-4));
}

// The light of the sun that reaches radius r, when it stands at mu there.
float3 air_sun(Air_Data a, float r, float mu) {
    return air_transmittance(a, r, mu) * air_sun_shown(a, r, mu);
}

// The table of the scattering past the first order: u the cosine of the sun at the place, v its altitude.
float2 air_scattering_uv(Air_Data a, float r, float mu_sun) {
    return air_texels(float2(0.5 + 0.5 * mu_sun, saturate((r - a.planet.x) / (a.planet.y - a.planet.x))), float2(AIR_SCATTERING_SIZE));
}
float3 air_scattering(Air_Data a, float r, float mu_sun) {
    return material_textures[AIR_SCATTERING_TEXTURE].SampleLevel(linear_sampler, air_scattering_uv(a, r, mu_sun), 0.0).rgb;
}

// The light a metre of air at a place sends along dir: what it scatters of
// the sun, once and past the first order.
float3 air_inscattering(Air_Data a, Air_Medium m, float3 place, float3 dir, float3 sun) {
    float r = length(place);
    float mu_sun = dot(place, sun) / r;
    float cosine = dot(dir, sun);
    float3 once = air_sun(a, r, mu_sun) * (m.rayleigh * air_rayleigh_phase(cosine) + m.mie * air_mie_phase(cosine, a.mie_absorption.w));
    return once + air_scattering(a, r, mu_sun) * (m.rayleigh + m.mie);
}

// Where along a ray from a place the air begins and ends, the ground or the
// top of the air ending it; no air: end <= start.
void air_segment(Air_Data a, float r, float mu, out float start, out float end) {
    start = 0.0;
    end = 0.0;
    if (r > a.planet.y) {
        float discriminant = r * r * (mu * mu - 1.0) + a.planet.y * a.planet.y;
        if (mu >= 0.0 || discriminant < 0.0) return;
        start = -r * mu - sqrt(discriminant);
    }
    end = air_meets_ground(a, r, mu) ? air_to_ground(a, r, mu) : air_to_top(a, r, mu);
}

// Fixed steps along each segment of a march, a share into it: no step
// changes between frames.
static const float AIR_STEP_AT = 0.3;

// The light the air sends to a place along dir from as far as reach, with
// what crosses it, marched in a fixed number of steps; ground adds the light
// of the planet's ground where the ray meets it.
float3 air_march(Air_Data a, float3 place, float3 dir, float3 sun, float reach, uint steps, bool ground, out float3 through) {
    float r = length(place);
    float mu = dot(place, dir) / r;
    float start, end;
    air_segment(a, r, mu, start, end);
    bool hits = air_meets_ground(a, r, mu) && end <= reach;
    end = min(end, reach);
    through = float3(1.0);
    float3 light = float3(0.0);
    if (end <= start) return light;
    float before = start;
    for (uint i = 0u; i < steps; i++) {
        float t = start + (end - start) * (float(i) + AIR_STEP_AT) / float(steps);
        float dt = t - before;
        before = t;
        float3 at = place + dir * t;
        Air_Medium m = air_medium(a, length(at) - a.planet.x);
        float3 step = exp(-m.extinction * dt);
        // The light of the step, integrated over what it stops.
        light += through * (air_inscattering(a, m, at, dir, sun) * (1.0 - step) / max(m.extinction, 1e-12));
        through *= step;
    }
    // The last share of the segment past its last step.
    float tail = end - before;
    if (tail > 0.0) {
        float3 at = place + dir * end;
        Air_Medium m = air_medium(a, length(at) - a.planet.x);
        float3 step = exp(-m.extinction * tail);
        light += through * (air_inscattering(a, m, at, dir, sun) * (1.0 - step) / max(m.extinction, 1e-12));
        through *= step;
    }
    if (ground && hits) {
        float3 at = place + dir * end;
        float mu_sun = dot(normalize(at), sun);
        light += through * a.ground.rgb / PI * air_sun(a, a.planet.x, mu_sun) * max(mu_sun, 0.0);
    }
    return light;
}

// The eye of a frame of the air: its radius, never under the ground.
float air_eye_radius(Air_Data a) { return a.planet.x + max(a.planet.w, AIR_GROUND_MARGIN); }

// The sky table (Hillaire): u the cosine of the angle around the up between
// a direction and the sun, with more texels toward the sun; v the angle from
// the zenith, the horizon at its middle, with more texels toward it.
float2 air_sky_uv(Air_Data a, float r, float mu, float around) {
    float horizon_cos = sqrt(max(r * r - a.planet.x * a.planet.x, 0.0)) / r;
    float beta = acos(horizon_cos);
    float zenith_horizon = PI - beta;
    float zenith = acos(clamp(mu, -1.0, 1.0));
    float v = zenith < zenith_horizon
        ? 0.5 * (1.0 - sqrt(max(1.0 - zenith / zenith_horizon, 0.0)))
        : 0.5 + 0.5 * sqrt(saturate((zenith - zenith_horizon) / max(beta, 1e-5)));
    float u = sqrt(saturate(0.5 - 0.5 * around));
    return air_texels(float2(u, v), AIR_SKY_SIZE);
}
void air_sky_at(Air_Data a, float r, float2 uv, out float mu, out float around) {
    float2 unit = saturate(air_unit(uv, AIR_SKY_SIZE));
    float horizon_cos = sqrt(max(r * r - a.planet.x * a.planet.x, 0.0)) / r;
    float beta = acos(horizon_cos);
    float zenith_horizon = PI - beta;
    float zenith;
    if (unit.y < 0.5) {
        float c = 1.0 - 2.0 * unit.y;
        zenith = zenith_horizon * (1.0 - c * c);
    } else {
        float c = 2.0 * unit.y - 1.0;
        zenith = zenith_horizon + beta * c * c;
    }
    mu = cos(zenith);
    around = 1.0 - 2.0 * unit.x * unit.x;
}

// The cosine of the angle around the up between a direction of the world and the sun.
float air_around(float3 dir, float3 sun) {
    float2 d = dir.xz, s = sun.xz;
    float lengths = length(d) * length(s);
    return lengths > 1e-6 ? clamp(dot(d, s) / lengths, -1.0, 1.0) : 1.0;
}

// The sky the eye of the frame sees in a direction of the world, from its row of the table.
float3 air_sky(Air_Data a, float3 dir, float3 sun) {
    float2 uv = air_sky_uv(a, air_eye_radius(a), dir.y, air_around(dir, sun));
    uv.y = (uv.y + a.rows.x) / float(AIR_SKY_ROWS);
    return material_textures[AIR_SKY_TEXTURE].SampleLevel(linear_sampler, uv, 0.0).rgb;
}

#endif
