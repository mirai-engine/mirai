#ifndef TERRAIN_PROJECTION_SLANG
#define TERRAIN_PROJECTION_SLANG
// How the layers of a terrain lie over the world: Terrain_Layers shades with
// it and terrain_displace.comp raises the vertices near the view by the same
// texels.
// The textures of a layer are laid over the world from the three axes, each
// by how much the surface faces it, sharpened: flat ground reads them from
// above alone and a cliff from its sides, without the stretch of a single
// projection. A projection that weighs less than PROJECTION_MIN, or a layer
// without weight, is not read.
static const float PROJECTION_SHARPNESS = 8.0;
static const float PROJECTION_MIN = 0.02;
// A projection: u and v over the world, where the green of a normal map
// points (the top of the image) and the axis it faces.
struct Projection {float3 u; float3 v; float3 up; float3 axis;};
Projection projection(int which, float3 n) {
    Projection p;
    float side = which == 0 ? n.x : which == 1 ? n.y : n.z;
    side = side < 0.0 ? -1.0 : 1.0;
    // u, up and axis turn as the tangent, bitangent and normal of a surface
    // do, so no side shows its textures mirrored.
    if (which == 0) {p.u = float3(0.0, 0.0, -side); p.v = float3(0.0, -1.0, 0.0); p.up = float3(0.0, 1.0, 0.0); p.axis = float3(side, 0.0, 0.0);}
    else if (which == 1) {p.u = float3(side, 0.0, 0.0); p.v = float3(0.0, 0.0, 1.0); p.up = float3(0.0, 0.0, -1.0); p.axis = float3(0.0, side, 0.0);}
    else {p.u = float3(side, 0.0, 0.0); p.v = float3(0.0, -1.0, 0.0); p.up = float3(0.0, 1.0, 0.0); p.axis = float3(0.0, 0.0, side);}
    return p;
}
// A ray reads the projection the surface faces most.
float3 projection_weights(float3 n, bool ray) {
    float3 w = pow(abs(n), float3(PROJECTION_SHARPNESS));
    w /= max(w.x + w.y + w.z, 1e-6);
    float top = max(w.x, max(w.y, w.z));
    w = select(w < (ray ? top : PROJECTION_MIN), float3(0.0), w);
    return w / max(w.x + w.y + w.z, 1e-6);
}
#endif
