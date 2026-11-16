// The opening of a gate, for the stages and the hooks of the portals.
#ifndef PORTAL_SLANG
#define PORTAL_SLANG

// How far in front of the plane of a gate a point of the world is, in metres.
float portal_height(Portal_Gate gate, float3 world) { return dot(gate.to_local[2].xyz, world) + gate.to_local[2].w; }

// A point of the plane of a gate in its space, where the opening is 1 wide.
float2 portal_point(Portal_Gate gate, float3 world) {
    return float2(dot(gate.to_local[0].xyz, world) + gate.to_local[0].w, dot(gate.to_local[1].xyz, world) + gate.to_local[1].w);
}

bool portal_open(Portal_Gate gate, float2 at) {
    return gate.shape.x > 0.5 ? dot(at, at) <= 0.25 : all(abs(at) <= float2(0.5));
}

#endif
