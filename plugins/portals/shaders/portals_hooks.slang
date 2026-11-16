//! mirai hook ray portal_ray
//! mirai hook lights portal_light_count portal_light
// What the portals ask of every ray and add to every lit point: a ray that
// goes into the opening of a gate from its front goes on from its exit, and
// the lights of the place behind a gate reach what is in front of it through
// its opening alone.
#ifndef PORTALS_HOOKS_SLANG
#define PORTALS_HOOKS_SLANG
#include "portal.slang"

bool portal_ray(float3 origin, float3 direction, float t_max, out float t, out float3 next_origin, out float3 next_direction) {
    t = t_max;
    next_origin = origin;
    next_direction = direction;
    bool found = false;
    for (uint i = 0u; i < frame.portals.count; i++) {
        Portal_Gate gate = frame.portals.gates[i];
        float height = portal_height(gate, origin);
        float approach = dot(gate.to_local[2].xyz, direction);
        if (height <= 0.0 || approach >= 0.0) continue;
        float reach = -height / approach;
        if (reach >= t) continue;
        float3 crossing = origin + direction * reach;
        if (!portal_open(gate, portal_point(gate, crossing))) continue;
        t = reach;
        next_origin = transform_point(gate.through, crossing);
        next_direction = transform_vector(gate.through, direction);
        found = true;
    }
    return found;
}

uint portal_light_count() { return frame.portals.light_count; }

// The share of a disc of light the opening leaves in sight: `at` is where the
// center of the disc shows in the plane of the gate, `spread` its radius there.
float portal_share(Portal_Gate gate, float2 at, float2 spread) {
    float2 width = max(spread, float2(1e-5));
    if (gate.shape.x > 0.5) {
        float soft = max(width.x, width.y);
        return smoothstep(-soft, soft, 0.5 - length(at));
    }
    float2 inside = 0.5 - abs(at);
    return smoothstep(-width.x, width.x, inside.x) * smoothstep(-width.y, width.y, inside.y);
}

bool portal_light(uint index, float3 position, float3 normal, float2 point, out Extension_Light light) {
    light = (Extension_Light)0;
    Portal_Light source = frame.portals.lights[index];
    // Most points are out of the reach of a light, or face away from it: they ask nothing of its gate.
    bool sun = source.position_range.w <= 0.0;
    float3 direction = source.position_range.xyz;
    float distance = 1e4;
    float3 irradiance;
    Light local;
    local.position_range = source.position_range;
    local.color_intensity = source.color_intensity;
    local.direction_cone = source.direction_cone;
    local.size = source.size;
    local.axis = source.axis;
    // In render units, as the scene turns its own lights (gpu_light, frame_sun_sky).
    float power = source.color_intensity.w / PI * light_scale();
    if (!sun && light_is_rect(local)) power *= 4.0 * source.size.y * source.size.z;
    local.color_intensity.w = power;
    if (sun) {
        float cosine = dot(normal, direction);
        if (cosine <= 0.0) return false;
        irradiance = source.color_intensity.rgb * (power * cosine);
    } else {
        float3 away = source.position_range.xyz - position;
        if (dot(away, away) >= source.position_range.w * source.position_range.w || dot(away, normal) <= 0.0) return false;
    }
    Portal_Gate gate = frame.portals.gates[uint(source.extra.y)];
    float height = portal_height(gate, position);
    if (height <= 0.0) return false;
    float2 scale = float2(length(gate.to_local[0].xyz), length(gate.to_local[1].xyz));
    if (!sun) {
        // The way to the middle of the light, against the opening widened by
        // twice what the light spans there: what misses it sees none of the
        // light through the opening, and asks nothing more.
        float3 away = source.position_range.xyz - position;
        float middle = length(away);
        float middle_approach = dot(gate.to_local[2].xyz, away) / max(middle, 1e-6);
        if (middle_approach >= -1e-5) return false;
        float middle_reach = -height / middle_approach;
        float spread = 2.0 * source.extra.x * (middle_reach / max(middle, 1e-4)) / max(-middle_approach, 0.2);
        if (portal_share(gate, portal_point(gate, position + away * (middle_reach / max(middle, 1e-6))), spread * scale) <= 0.0) return false;
        irradiance = light_contribution(local, position, normal, direction, distance);
        if (luminance(irradiance) <= 0.0) return false;
    }
    // The light is behind the opening: the way to it crosses the plane of the gate.
    float approach = dot(gate.to_local[2].xyz, direction);
    if (approach >= -1e-5) return false;
    float reach = -height / approach;
    if (reach >= distance) return false;
    float3 crossing = position + direction * reach;
    // The radius the disc of the light has where the way to it crosses the plane, wider the more the way leans.
    float radius = source.extra.x * (sun ? reach : reach / max(distance, 1e-4)) / max(-approach, 0.2);
    float share = portal_share(gate, portal_point(gate, crossing), radius * scale);
    if (share <= 0.0) return false;
    light.irradiance = irradiance * share;
    light.radius = source.extra.x * (sun ? distance : 1.0);
    light.shaped = !sun;
    light.shape = local;
    light.share = share;
    // The shadow ray to the point asked for, while it goes through the opening:
    // the share already softens the edge of the opening.
    if (point.x >= 0.0) {
        float3 aim;
        float aim_distance = distance;
        if (sun) {
            float3 across, up;
            make_basis(direction, across, up);
            float angle = point.y + floor(point.x) * 2.3999632;
            float2 disc = sqrt(point.x / 16.0) * float2(cos(angle), sin(angle)) * source.extra.x;
            aim = normalize(direction + across * disc.x + up * disc.y);
        } else {
            float3 toward = light_point(local, position, point.x, point.y);
            if (dot(normal, toward) <= 0.0 && (light_is_rect(local) || light_is_capsule(local))) toward = light_point(local, position, 16.0 - point.x, point.y);
            aim_distance = length(toward);
            aim = toward / max(aim_distance, 1e-6);
        }
        float aim_approach = dot(gate.to_local[2].xyz, aim);
        float aim_reach = aim_approach < -1e-5 ? -height / aim_approach : -1.0;
        float3 aim_crossing = position + aim * aim_reach;
        if (aim_reach > 0.0 && aim_reach < aim_distance && portal_open(gate, portal_point(gate, aim_crossing))) {
            direction = aim;
            reach = aim_reach;
            crossing = aim_crossing;
            distance = aim_distance;
        }
    }
    light.direction = direction;
    light.reach = reach;
    light.beyond_origin = transform_point(gate.through, crossing);
    light.beyond_direction = transform_vector(gate.through, direction);
    // Short of the lamp a light is in, as its rays on its own side stop.
    light.beyond_reach = max((sun ? distance - 0.02 : light_reach(local, distance)) - reach, 1e-3);
    return true;
}

#endif
