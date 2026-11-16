#ifndef MIRAI_DEFORM_SLANG
#define MIRAI_DEFORM_SLANG
#include "native.slang"
// What a stage that deforms meshes is made of: it includes this source and
// defines deform_shape, the equation that says where a vertex that rests at a
// point is now. The vertices of a deformable mesh are written from those of
// its rest shape, and the normal of each one is that of the deformed surface
// around it, found from the same equation: every shape lights right without
// a formula of its own.
#include "common.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

// deform.Gpu_Params.
struct Params_Block {
    uint rest;          // words of the vertex pool where the vertices at rest are (render.Gpu_Posed_Vertex), and where the deformed ones go
    uint written;
    uint count;
    uint kind;
    float3 axis;
    float amplitude;
    float3 direction;
    float wavelength;
    float3 bounds_min;
    float phase;
    float3 bounds_max;
    float pin;
    float4 values;
};
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_VERTICES, 0)]] RWStructuredBuffer<uint> vertex_words : register(MIRAI_REGISTER(u, SLOT_VERTICES), space0);
#define MIRAI_POSED_STORE
#include "posed.slang"

static const float DEFORM_TURN = 6.2831853;

// What an equation knows: the Deform of the mesh and the box of the mesh at rest.
struct Deform_Shape {
    uint kind;          // deform.Deform_Kind
    float3 axis;        // unit, in the space of the mesh
    float3 direction;   // unit
    float amplitude;
    float wavelength;
    float phase;        // cycles: the offset of the Deform and its speed by the seconds
    float pin;
    float4 values;      // of the Deform, for the equation to read as it likes
    float3 center;
    float3 size;        // never zero
};

// How far along the axis a point is from the middle of the mesh, in metres.
float deform_along(Deform_Shape shape, float3 p) {
    return dot(p - shape.center, shape.axis);
}

// How long the mesh is along the axis.
float deform_extent(Deform_Shape shape) {
    return max(dot(abs(shape.axis), shape.size), 1e-5);
}

// Where along the axis a point is: 0 at the end of the mesh the axis leaves from, 1 at the other.
float deform_height(Deform_Shape shape, float3 p) {
    return saturate(deform_along(shape, p) / deform_extent(shape) + 0.5);
}

// How much of the shape a point at that height takes: it eases in from still over the pinned share.
float deform_held(Deform_Shape shape, float height) {
    return shape.pin > 0.0 ? smoothstep(0.0, shape.pin, height) : 1.0;
}

// What a point is away from the axis through the middle of the mesh.
float3 deform_radial(Deform_Shape shape, float3 p) {
    float3 from_center = p - shape.center;
    return from_center - shape.axis * dot(from_center, shape.axis);
}

// Defined by the stage: where the vertex that rests at p is.
float3 deform_shape(float3 p, Deform_Shape shape);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    if (id.x >= params.count) return;
    Deform_Shape shape;
    shape.kind = params.kind;
    shape.axis = params.axis;
    shape.direction = params.direction;
    shape.amplitude = params.amplitude;
    shape.wavelength = params.wavelength;
    shape.phase = params.phase;
    shape.pin = params.pin;
    shape.values = params.values;
    shape.center = 0.5 * (params.bounds_min + params.bounds_max);
    shape.size = max(params.bounds_max - params.bounds_min, float3(1e-5));
    Posed_Vertex rest = posed_load(params.rest, id.x);
    float3 position = rest.position;
    float3 n = unpack_normal(rest.normal);
    float3 moved = deform_shape(position, shape);
    // Two steps across the surface at rest, along its tangent and across it,
    // deformed: their cross product is its normal now, and the first one its
    // tangent. A deformation does not mirror: the bitangent keeps its side.
    float4 tangent = unpack_tangent(rest.tangent);
    float3 along = tangent.xyz - n * dot(n, tangent.xyz);
    if (dot(along, along) < 1e-8) along = cross(abs(n.y) < 0.9 ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0), n);
    along = normalize(along);
    float step = max(1e-3 * max(shape.size.x, max(shape.size.y, shape.size.z)), 1e-5);
    float3 u = deform_shape(position + along * step, shape) - moved;
    float3 normal = cross(u, deform_shape(position + cross(n, along) * step, shape) - moved);
    if (dot(normal, normal) > 1e-24) n = normalize(normal);
    float3 t = u - n * dot(n, u);
    if (dot(t, t) > 1e-24) tangent.xyz = normalize(t);
    Posed_Vertex now;
    now.position = moved;
    now.normal = packSnorm2x16(oct_encode(n));
    now.tangent = pack_tangent(tangent.xyz, tangent.w);
    posed_store(params.written, id.x, now);
}
#endif
