// The vertices of a displaced Heightfield chunk (terrain.Terrain_Displacement):
// those of its mesh at rest moved along their normals by the height its
// layers blend there, as Terrain_Layers blends them, centred on the middle
// of each height. Towards a side it shares with a chunk that is not displaced
// it fades out within a cell, so the two meet where the samples are.
#include "native.slang"
#include "common.slang"
#include "origin.slang"
#include "terrain_projection.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

// terrain.Gpu_Displace_Layer
struct Layer {
    uint color;          // the base color texture of its material, its alpha the height; INVALID: none
    float tiling;        // metres of a repeat
    float blend;         // height_blend
    float displacement;  // metres from its lowest texel to its highest
};
// terrain.Gpu_Displace
struct Params_Block {
    uint written;  // the vertices of the copy (words of the vertex pool, Posed_Vertex each)
    uint rest;     // those of the mesh at rest
    uint count;
    uint mesh;     // the row of the mesh at rest in the mesh table: its weights are its uvs
    float4 row0;   // the chunk into the world, relative to the origin
    float4 row1;
    float4 row2;
    int4 origin;   // in steps of ORIGIN_STEP
    float2 size;   // of the chunk, in its space
    float fade;    // in its space: a cell
    uint pinned;   // the sides (-X, +X, -Z, +Z) it shares with a chunk that is not displaced
    float spacing; // metres between its vertices
    uint layer_count;
    uint2 pad;
    Layer layers[4];
};
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_MESHES, 0)]] StructuredBuffer<Mesh> meshes : register(MIRAI_REGISTER(t, SLOT_MESHES), space0);
[[vk::binding(SLOT_VERTICES, 0)]] RWStructuredBuffer<uint> vertex_words : register(MIRAI_REGISTER(u, SLOT_VERTICES), space0);
[[vk::binding(SLOT_INDICES, 0)]] StructuredBuffer<uint> indices : register(MIRAI_REGISTER(t, SLOT_INDICES), space0);
[[vk::binding(MATERIAL_TEXTURE_SLOT, 1)]] Texture2D<float4> material_textures[] : register(MIRAI_REGISTER(t, MATERIAL_TEXTURE_SLOT), space1);
#define MIRAI_POSED_STORE
#include "geometry.slang"

// The cluster of the first level that holds vertex: the last whose first
// vertex is not past it.
Cluster vertex_cluster(Mesh mesh, uint vertex) {
    uint2 level = mesh_level_clusters(mesh, 0u);
    uint low = level.x, high = level.x + level.y;
    while (high - low > 1u) {
        uint middle = (low + high) / 2u;
        if (mesh_cluster(mesh, middle).vertex_first <= vertex) low = middle;
        else high = middle;
    }
    return mesh_cluster(mesh, low);
}

// The alpha of an image at uv, repeating, between the texels of a level: the
// Geometry stage binds no sampler.
float texel_alpha(Texture2D<float4> image, float2 uv, uint level, uint2 size) {
    float2 at = frac(uv) * float2(size) - 0.5;
    int2 low = int2(floor(at));
    float2 f = at - float2(low);
    int2 wrap = int2(size);
    float a = image.Load(int3((low + wrap) % wrap, int(level))).a;
    float b = image.Load(int3((low + int2(1, 0) + wrap) % wrap, int(level))).a;
    float c = image.Load(int3((low + int2(0, 1) + wrap) % wrap, int(level))).a;
    float d = image.Load(int3((low + int2(1, 1) + wrap) % wrap, int(level))).a;
    return lerp(lerp(a, b, f.x), lerp(c, d, f.x), f.y);
}

// The height of a layer at a place, 0 to 1, read as layer_read reads its
// base color: from the projections the surface faces, at the level of the
// texture whose texels the spacing of the vertices covers.
float layer_height(Layer layer, float3 world, float3 normal) {
    if (layer.color == INVALID) return 0.5;
    Texture2D<float4> image = material_textures[mirai_nonuniform(layer.color)];
    uint width, height, levels;
    image.GetDimensions(0u, width, height, levels);
    float scale = 1.0 / max(layer.tiling, 1e-6);
    uint level = min(uint(max(log2(params.spacing * scale * float(max(width, height))), 0.0)), levels - 1u);
    uint2 size = max(uint2(width, height) >> level, uint2(1u));
    float3 weights = projection_weights(normal, false);
    float h = 0.0;
    for (int which = 0; which < 3; which++) {
        if (weights[which] <= 0.0) continue;
        Projection p = projection(which, normal);
        float2 shift = float2(origin_phase(params.origin.xyz, p.u * scale), origin_phase(params.origin.xyz, p.v * scale));
        float2 uv = shift + float2(dot(world, p.u), dot(world, p.v)) * scale;
        h += weights[which] * texel_alpha(image, uv, level, size);
    }
    return h;
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    if (id.x >= params.count) return;
    Posed_Vertex v = posed_load(params.rest, id.x);
    Mesh mesh = meshes[params.mesh];
    Cluster c = vertex_cluster(mesh, id.x);
    Mesh_Point point = cluster_point_at(mesh, c, id.x - c.vertex_first, INVALID);
    float4 w = max(float4(point.uv, point.uv1), float4(0.0));
    float total = w.x + w.y + w.z + w.w;
    w = total > 0.0 ? w / total : float4(1.0, 0.0, 0.0, 0.0);
    float3 local_normal = unpack_normal(v.normal);
    float3 world = float3(dot(params.row0.xyz, v.position) + params.row0.w, dot(params.row1.xyz, v.position) + params.row1.w, dot(params.row2.xyz, v.position) + params.row2.w);
    float3 normal = normalize(float3(dot(params.row0.xyz, local_normal), dot(params.row1.xyz, local_normal), dot(params.row2.xyz, local_normal)));
    float4 blend = float4(0.0);
    float4 heights = float4(0.0);
    for (uint i = 0u; i < params.layer_count && i < 4u; i++) {
        if (w[i] <= 0.0) continue;
        heights[i] = layer_height(params.layers[i], world, normal);
        blend[i] = w[i] * exp2(5.0 * params.layers[i].blend * heights[i]);
    }
    float sum = blend.x + blend.y + blend.z + blend.w;
    blend = sum > 0.0 ? blend / sum : w;
    float offset = 0.0;
    for (uint i = 0u; i < params.layer_count && i < 4u; i++) {offset += blend[i] * (heights[i] - 0.5) * params.layers[i].displacement;}
    float edge = 1e30;
    if ((params.pinned & 1u) != 0u) edge = min(edge, v.position.x);
    if ((params.pinned & 2u) != 0u) edge = min(edge, params.size.x - v.position.x);
    if ((params.pinned & 4u) != 0u) edge = min(edge, v.position.z);
    if ((params.pinned & 8u) != 0u) edge = min(edge, params.size.y - v.position.z);
    offset *= smoothstep(0.0, params.fade, edge);
    // The offset is in metres of the world; the mesh may be scaled.
    float stretch = length(float3(params.row0.y, params.row1.y, params.row2.y));
    v.position += local_normal * offset / max(stretch, 1e-6);
    posed_store(params.written, id.x, v);
}
