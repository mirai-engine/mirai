//! mirai surface Pieces
//! vertex reach reach
//! parameter progress {"default":1,"min":0,"max":1,"group":"Assembly"}
//! parameter pieces {"default":16,"min":1,"max":65536,"group":"Assembly"}
//! parameter spread {"default":0.6,"min":0,"max":0.99,"group":"Assembly"}
//! parameter direction {"default":[0,1,0],"min":-1,"max":1,"group":"Assembly"}
//! parameter distance {"default":2,"min":0,"max":100,"group":"Assembly"}
//! parameter turn {"default":3.1415927,"min":-31.4159,"max":31.4159,"group":"Assembly"}
//! parameter reach {"default":3,"min":0,"max":200,"group":"Assembly"}
//! parameter color {"default":[0.8,0.8,0.8],"min":0,"max":1,"color":true}
//! parameter roughness {"default":0.6,"min":0.045,"max":1}
// The pieces of a mesh fly into place as progress goes from 0 to 1, as a
// piece of a building forms: each from distance along direction, turning by
// turn around an axis of its own, one after another by its number. A vertex
// takes the number of its piece from uv1.x and the pivot of its piece from
// its color, a place in the bounds of the mesh from their low corner (0) to
// their high one (1), as Pivot Painter bakes it. reach covers distance and
// what the turn moves the farthest vertex from its pivot. The surface is a
// plain one of color and roughness: a program of a project moves its pieces
// the same way over the surface it evaluates.
namespace Pieces {
struct Parameters {float3 direction;float progress;float pieces;float spread;float distance;float turn;float reach;float3 color;float roughness;};
// v turned by angle around the unit axis k (Rodrigues).
float3 turned(float3 v, float3 k, float angle) {
    float c = cos(angle), s = sin(angle);
    return v * c + cross(k, v) * s + k * (dot(k, v) * (1.0 - c));
}
Mirai_Vertex vertex(Mirai_Vertex_Context ctx, Parameters p) {
    Mirai_Vertex v = mirai_vertex_default(ctx);
    float piece = floor(ctx.uv1.x + 0.5);
    float order = saturate(piece / max(p.pieces, 1.0));
    float t = saturate((p.progress - order * p.spread) / max(1.0 - p.spread, 1e-3));
    float away = (1.0 - t) * (1.0 - t) * (1.0 - t);
    if (away <= 0.0) return v;
    float3 axis = frac(sin(float3(piece * 12.9898, piece * 78.233, piece * 37.719)) * 43758.5453) * 2.0 - 1.0;
    axis = dot(axis, axis) > 1e-6 ? normalize(axis) : float3(0.0, 1.0, 0.0);
    float angle = p.turn * away;
    float3 pivot = lerp(ctx.object_low, ctx.object_high, saturate(ctx.vertex_color.rgb));
    float3 direction = dot(p.direction, p.direction) > 1e-12 ? normalize(p.direction) : float3(0.0);
    v.position = pivot + turned(ctx.position - pivot, axis, angle) + direction * (p.distance * away);
    v.normal = turned(ctx.normal, axis, angle);
    v.tangent = float4(turned(ctx.tangent.xyz, axis, angle), ctx.tangent.w);
    return v;
}
Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {
    Mirai_Surface s = mirai_surface_default(ctx);
    s.base_color = p.color;
    s.roughness = p.roughness;
    return s;
}
}
