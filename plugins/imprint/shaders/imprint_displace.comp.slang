// The vertices of a mesh under an Imprint_Ground, moved along the up of the
// world by the imprints where they rest (layer 0 x of the grid imprint, as
// its texture of the world holds it), and the normal of each one that of the
// displaced surface around it: the raster and every ray see the footprints.
#include "native.slang"
#include "common.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

// imprint.Gpu_Params.
struct Params_Block {
    uint rest;          // words of the vertex pool where the vertices at rest are (render.Gpu_Posed_Vertex)
    uint written;       // and where the displaced ones go
    uint count;
    uint texture;       // the place of the texture of the world of the grid in the texture table
    float4 place[3];    // rows: from the space of the mesh to metres from the lowest corner of the region
    float3 up;          // the up of the world in the space of the mesh, as long as a metre of the world
    float cell_size;
    int2 start;         // the texel of the lowest corner of the region: the cell c of the world is at c modulo cells
    int2 cells;
    float depth_max;
    float rise_max;
    float spacing;      // metres between the vertices of the mesh
    float pad;
};
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_VERTICES, 0)]] RWStructuredBuffer<uint> vertex_words : register(MIRAI_REGISTER(u, SLOT_VERTICES), space0);
[[vk::binding(MATERIAL_TEXTURE_SLOT, 1)]] Texture2D<float4> material_textures[] : register(MIRAI_REGISTER(t, MATERIAL_TEXTURE_SLOT), space1);
#define MIRAI_POSED_STORE
#include "posed.slang"

static const float IMPRINT_EDGE_CELLS = 4.0; // over which the imprints fade to rest at the edges of the region
static const float IMPRINT_TENT_SPACINGS = 2.0; // the half width of the tent of the heights, in spacings of the vertices
static const float IMPRINT_TENT_CELLS = 8.0;    // and at most, in cells
static const float IMPRINT_SLOPE_TENTS = 2.0;   // the tent of the normals, in tents of the heights

// A cell of the region, counted from its lowest corner; out of it the ground is at rest.
float imprint_texel(int2 cell) {
    if (any(cell < 0) || any(cell >= params.cells)) return 0.0;
    int2 at = (params.start + cell) % params.cells;
    return material_textures[params.texture].Load(int3(at, 0)).x;
}

// The height over the rest of the ground at a point, metres from the lowest
// corner of the region along x and z, and the slope there along x and z,
// metres a metre, for its normal: the cells under a tent IMPRINT_TENT_SPACINGS
// spacings of the vertices wide on each side for the height, held to the
// reach of the ground and going to rest at the edges of the region, and under
// one IMPRINT_SLOPE_TENTS times as wide for the slope. A print narrower than
// the tent sinks the vertices around it a share of its depth: one vertex sunk
// all of it would be a pit with the shape of its triangles that jumps from
// vertex to vertex as the print moves, and the wall of a rut steeper than two
// of them a saw along its triangles. The normals are drawn linear between the
// vertices: one that turns across a wall of a rut in a few triangles stops
// facing the sun along their diagonals, in a saw, and the wider tent spreads
// the turn over more of them.
float3 imprint_field(float2 q) {
    float2 n = float2(params.cells);
    float cell_size = max(params.cell_size, 1e-6);
    float2 c = q / cell_size;
    if (any(c < 0.0) || any(c > n)) return float3(0.0);
    float r = clamp(IMPRINT_TENT_SPACINGS * params.spacing / cell_size, 1.0, IMPRINT_TENT_CELLS);
    float rs = IMPRINT_SLOPE_TENTS * r;
    float2 st = c - 0.5;
    int2 low = int2(floor(st - rs)) + 1, high = int2(ceil(st + rs)) - 1;
    // The weights of the cells for the height, and for the slope with their change as the point moves.
    float sum = 0.0, weights = 0.0, smooth = 0.0, smooth_weights = 0.0;
    float2 dsum = float2(0.0), dweights = float2(0.0);
    for (int j = low.y; j <= high.y; j++) {
        float dz = float(j) - st.y;
        float hz = max(1.0 - abs(dz) / r, 0.0);
        float wz = max(1.0 - abs(dz) / rs, 0.0), gz = sign(dz) / rs;
        for (int i = low.x; i <= high.x; i++) {
            float dx = float(i) - st.x;
            float hx = max(1.0 - abs(dx) / r, 0.0);
            float wx = max(1.0 - abs(dx) / rs, 0.0), gx = sign(dx) / rs;
            float h = imprint_texel(int2(i, j));
            sum += hx * hz * h; weights += hx * hz;
            float w = wx * wz;
            float2 dw = float2(gx * wz, wx * gz);
            smooth += w * h; smooth_weights += w;
            dsum += dw * h; dweights += dw;
        }
    }
    float height = sum / max(weights, 1e-6);
    smooth_weights = max(smooth_weights, 1e-6);
    float2 slope = (dsum - smooth / smooth_weights * dweights) / (smooth_weights * cell_size);
    if (height <= -params.depth_max || height >= params.rise_max) slope = float2(0.0);
    float edge = saturate(min(min(c.x, c.y), min(n.x - c.x, n.y - c.y)) / IMPRINT_EDGE_CELLS);
    return float3(clamp(height, -params.depth_max, params.rise_max), slope) * edge;
}

// How far along x and z of the world a step in the space of the mesh goes, in metres.
float2 imprint_across(float3 d) {
    return float2(dot(params.place[0].xyz, d), dot(params.place[2].xyz, d));
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    if (id.x >= params.count) return;
    Posed_Vertex rest = posed_load(params.rest, id.x);
    float3 position = rest.position;
    float3 n = unpack_normal(rest.normal);
    float3 field = imprint_field(imprint_across(position) + float2(params.place[0].w, params.place[2].w));
    float3 moved = position + params.up * field.x;
    // The surface at rest along its tangent and across it, displaced: their
    // cross product is its normal now, and the first one its tangent. The
    // bitangent keeps its side.
    float4 tangent = unpack_tangent(rest.tangent);
    float3 along = tangent.xyz - n * dot(n, tangent.xyz);
    if (dot(along, along) < 1e-8) along = cross(abs(n.y) < 0.9 ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0), n);
    along = normalize(along);
    float3 across = cross(n, along);
    float3 u = along + params.up * dot(field.yz, imprint_across(along));
    float3 normal = cross(u, across + params.up * dot(field.yz, imprint_across(across)));
    if (dot(normal, normal) > 1e-24) {
        normal = normalize(normal);
        n = dot(normal, n) < 0.0 ? -normal : normal;
    }
    float3 t = u - n * dot(n, u);
    if (dot(t, t) > 1e-24) tangent.xyz = normalize(t);
    Posed_Vertex now;
    now.position = moved;
    now.normal = packSnorm2x16(oct_encode(n));
    now.tangent = pack_tangent(tangent.xyz, tangent.w);
    posed_store(params.written, id.x, now);
}
