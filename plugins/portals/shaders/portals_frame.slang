//! mirai frame Portals_Frame portals
//! mirai needs nested_views
//! mirai constant PORTAL_CAPACITY int ../runtime/portals.odin
//! mirai constant PORTAL_LIGHT_CAPACITY int ../runtime/gpu.odin
// What every stage knows of the portals of the scene (portals.Gpu_Portals):
// the gates a ray may leave through, and the lights that reach the front of
// one from the place behind it.
#ifndef PORTALS_FRAME_SLANG
#define PORTALS_FRAME_SLANG
#include <constants/plugins/portals.slang>

struct Portal_Gate {
    float4 to_local[3]; // rows: the world to the space of the portal, where its opening is the unit square at z = 0 seen from +z
    float4 through[3];  // rows: carries what is in front of the portal to behind its exit
    float4 shape;       // x: 1 when the opening is the ellipse inside the square
};

// A light of the place behind a gate, where it is seen from in front of the
// gate: behind its opening.
struct Portal_Light {
    float4 position_range;  // xyz, w range; w 0: the sun, and xyz the direction towards it
    float4 color_intensity; // rgb color, w intensity in the units of its component: lux for the sun, candela, nits for a rectangle
    float4 direction_cone;  // as in Light: a spot, a rectangle (w LIGHT_RECT) or w LIGHT_POINT
    float4 size;            // as in Light: the radius, half a capsule or half the sides of a rectangle
    float4 axis;            // as in Light: along a capsule, or across the width of a rectangle
    float4 extra;           // x: how far from its center the light comes from, metres, or radians for the sun; y: its gate
};

struct Portals_Frame {
    uint count;
    uint light_count;
    uint pad0;
    uint pad1;
    Portal_Gate gates[PORTAL_CAPACITY];
    Portal_Light lights[PORTAL_LIGHT_CAPACITY];
};

#endif
