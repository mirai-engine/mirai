//! mirai hook probes portal_probe_gate
// What the portals give the probe volume: the light that reaches a point in
// front of a gate through its opening is that of the place behind the gate.
#ifndef PORTALS_PROBES_SLANG
#define PORTALS_PROBES_SLANG
#include "portal.slang"

// Below this share a gate leaves the light of a point as it is.
static const float PORTAL_PROBE_SHARE_MIN = 1.0 / 256.0;
// The radius of the octagon that stands for an elliptic opening of diameter 1,
// of its same area.
static const float PORTAL_OCTAGON_RADIUS = 0.52695;

// The share of the light around `direction` at `position` that comes through
// the opening of a gate: the opening as the point sees it, each direction
// weighed by its cosine to `direction`; of the gate that gives the most.
// beyond is where that light is read: the point of the opening behind
// `position`, carried through. front is the side of the exit it reaches, and
// through carries directions.
float portal_probe_gate(float3 position, float3 direction, out float3 beyond, out float3 front, out float4 through[3]) {
    beyond = position;
    front = direction;
    through = frame.portals.gates[0].through;
    float best = 0.0;
    for (uint i = 0u; i < frame.portals.count; i++) {
        Portal_Gate gate = frame.portals.gates[i];
        float height = portal_height(gate, position);
        if (height <= 0.0) continue;
        // The opening in the world: its center and half its sides.
        float3 x = gate.to_local[0].xyz / dot(gate.to_local[0].xyz, gate.to_local[0].xyz);
        float3 y = gate.to_local[1].xyz / dot(gate.to_local[1].xyz, gate.to_local[1].xyz);
        float3 normal = gate.to_local[2].xyz;
        float3 center = -(gate.to_local[0].w * x + gate.to_local[1].w * y + gate.to_local[2].w * normal);
        // No more than the opening, at the distance of its nearest point, would give.
        float2 outside = max(abs(portal_point(gate, position)) - 0.5, float2(0.0)) * float2(length(x), length(y));
        float area = length(x) * length(y);
        if (area <= (PORTAL_PROBE_SHARE_MIN * PI) * (height * height + dot(outside, outside))) continue;
        float angle;
        if (gate.shape.x > 0.5) {
            float3 corners[8];
            for (uint k = 0u; k < 8u; k++) {
                float turn = float(k) * (PI * 0.25);
                corners[k] = center + (x * cos(turn) + y * sin(turn)) * PORTAL_OCTAGON_RADIUS - position;
            }
            angle = polygon_projected_angle(corners, direction);
        } else {
            float3 half_x = 0.5 * x, half_y = 0.5 * y;
            float3 corners[4] = {center - half_x - half_y - position, center + half_x - half_y - position, center + half_x + half_y - position, center - half_x + half_y - position};
            angle = polygon_projected_angle(corners, direction);
        }
        float share = saturate(angle / PI);
        if (share <= best) continue;
        best = share;
        beyond = transform_point(gate.through, position - normal * height);
        front = -transform_vector(gate.through, normal);
        through = gate.through;
    }
    return best > PORTAL_PROBE_SHARE_MIN ? best : 0.0;
}

#endif
