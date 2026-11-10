#include "native.slang"
// The surface of a plane of water (water.sheet_record), a deformable copy of
// its grid around the camera: each vertex where the water that rests there is
// on the waves of the plane, and the waves a ring of the grid is too coarse to
// show fade out. Where a dry box of more priority holds the surface, its floor
// is the surface: the vertices inside it go down to its floor, and those
// within a cell or so of its walls go onto them, so the sheet ends at them.
#include "common.slang"
#include "water_waves.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

// water.Gpu_Sheet.
struct Sheet_Params {
    uint rest;    // words of the vertex pool where the vertices at rest are, and where those of now go
    uint written;
    uint count;
    uint bodies;  // the plane, then the dry boxes
    float2 eye;   // x and z of the camera from the middle of the grid
    float cell;   // m, of the finest cells
    float half_cells; // cells of a level from its middle to its edge
};
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Sheet_Params> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_VERTICES, 0)]] RWStructuredBuffer<uint> vertex_words : register(MIRAI_REGISTER(u, SLOT_VERTICES), space0);
#define MIRAI_POSED_STORE
#include "posed.slang"
// Relative to the middle of the grid on the still surface.
[[vk::binding(SLOT_PASS4, 0)]] StructuredBuffer<Water_Body> bodies : register(MIRAI_REGISTER(t, SLOT_PASS4), space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    if (id.x >= params.count) return;
    Posed_Vertex rest = posed_load(params.rest, id.x);
    float3 p = rest.position;
    Water_Body plane = bodies[0];
    if (plane.surface.y < 0.5) {
        // A lake ends at its walls: the vertices past them go onto them.
        float3 l = transform_point(plane.to_box, p);
        float sx = length(plane.to_box[0].xyz), sz = length(plane.to_box[2].xyz);
        float2 to = clamp(l.xz, -0.5, 0.5);
        p += plane.to_box[0].xyz * ((to.x - l.x) / (sx * sx)) + plane.to_box[2].xyz * ((to.y - l.z) / (sz * sz));
    }
    // A wave shows on cells of a quarter of its length; the cells double in each ring out from the camera.
    float far = max(abs(p.x - params.eye.x), abs(p.z - params.eye.y));
    float coarse = params.cell * max(1.0, 2.0 * far / (params.cell * params.half_cells));
    float weights[WATER_WAVES];
    for (uint i = 0u; i < WATER_WAVES; i++) {
        float number = i < water_wave_count(plane) ? length(plane.waves[i].xy) : 1.0;
        weights[i] = saturate(6.2831853 / max(number, 1e-6) / (4.0 * coarse) - 1.0);
    }
    Water_Point w = water_wave_point(plane, p.xz, weights);
    float3 moved = p + w.offset;
    float3 n = w.normal;
    // The cell of the ring of the vertex, whose triangles reach that far from it.
    float ring = params.cell * exp2(max(0.0, ceil(log2(max(max(abs(p.x), abs(p.z)), 1e-6) / (params.cell * params.half_cells)))));
    float reach = 1.5 * ring;
    for (uint i = 1u; i < params.bodies; i++) {
        Water_Body dry = bodies[i];
        if (!(dry.surface.w > plane.surface.w)) continue;
        float3 l = transform_point(dry.to_box, moved);
        if (!(abs(l.y) < 0.5)) continue;
        float sx = length(dry.to_box[0].xyz), sz = length(dry.to_box[2].xyz);
        if (abs(l.x) > 0.5 + reach * sx || abs(l.z) > 0.5 + reach * sz) continue;
        bool inside = abs(l.x) < 0.5 && abs(l.z) < 0.5;
        float2 to = clamp(l.xz, -0.5, 0.5);
        if (inside) {
            float wall_x = (0.5 - abs(l.x)) / sx, wall_z = (0.5 - abs(l.z)) / sz;
            if (min(wall_x, wall_z) <= reach) {
                if (wall_x <= wall_z) to.x = l.x >= 0.0 ? 0.5 : -0.5;
                else to.y = l.z >= 0.0 ? 0.5 : -0.5;
            }
        }
        moved += dry.to_box[0].xyz * ((to.x - l.x) / (sx * sx)) + dry.to_box[2].xyz * ((to.y - l.z) / (sz * sz));
        if (inside) {
            float4 up = dry.to_box[1];
            moved.y = (-0.5 - up.w - up.x * moved.x - up.z * moved.z) / up.y;
            n = float3(0.0, 1.0, 0.0);
        }
        break;
    }
    float4 tangent = unpack_tangent(rest.tangent);
    float3 along = float3(1.0, 0.0, 0.0) - n * n.x;
    if (dot(along, along) > 1e-12) tangent.xyz = normalize(along);
    Posed_Vertex now;
    now.position = moved;
    now.normal = packSnorm2x16(oct_encode(n));
    now.tangent = pack_tangent(tangent.xyz, tangent.w);
    posed_store(params.written, id.x, now);
}
