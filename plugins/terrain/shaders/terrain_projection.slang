#ifndef TERRAIN_PROJECTION_SLANG
#define TERRAIN_PROJECTION_SLANG
// How the layers of a terrain lie over the world: Terrain_Layers shades with
// it and terrain_displace.comp raises the vertices near the view by the same
// texels.
// The textures of a layer are laid over the world from the axes the surface
// faces most (biplanar mapping): flat ground reads them from above alone and
// a cliff from its sides, without the stretch of a single projection.
// PROJECTION_SHARPNESS 8 blends as wide as three projections whose weights
// are the eighth power of how much the surface faces each.
static const float PROJECTION_SHARPNESS = 8.0;
// How much a unit normal that faces the three axes alike faces each: at most
// two axes of a unit normal pass it.
static const float PROJECTION_DIAGONAL = 0.57735027;
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
// Each projection weighs by how far past PROJECTION_DIAGONAL the surface
// faces its axis, so two show at most, and the second comes in at nothing
// where it swaps with the third, which is never past it. Only a normal that
// faces the three alike passes none, and reads the one it faces most, as a
// ray does everywhere.
float3 projection_weights(float3 n, bool ray) {
    float3 a = abs(n) * rsqrt(max(dot(n, n), 1e-30));
    float3 most = a.x >= a.y && a.x >= a.z ? float3(1.0, 0.0, 0.0) : a.y >= a.z ? float3(0.0, 1.0, 0.0) : float3(0.0, 0.0, 1.0);
    if (ray) return most;
    float3 w = pow(saturate((a - PROJECTION_DIAGONAL) / (1.0 - PROJECTION_DIAGONAL)), float3(PROJECTION_SHARPNESS / 8.0));
    // The rounding of a normal near the diagonal may lift the least past it.
    w = select(a <= min(a.x, min(a.y, a.z)), float3(0.0), w);
    float sum = w.x + w.y + w.z;
    return sum > 0.0 ? w / sum : most;
}
#endif
