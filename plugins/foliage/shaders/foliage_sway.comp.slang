// The vertices of a variant of the wind of a type (foliage.Wind_Set): its
// shape at rest bent in the space of its mesh by the wind the frame gives
// it, at the phase of the variant. Its levels of detail sway too; rays meet
// the first.
#include "native.slang"
#include "common.slang"
#include "foliage_sway.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

struct Params_Block {
    uint written; // the vertices of the variant, which this writes (words of the vertex pool, Posed_Vertex each)
    uint rest;    // those of its shape at rest
    uint count;
    uint mesh;    // its row of the mesh table, whose vertex colors weigh the sway
    float4 wind;  // xyz in the space of the mesh, m/s; w its gusts, cycles per second
    float4 sway;  // x: radians per m/s; y: the phase of the variant, radians; z: seconds of the world
};
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_MESHES, 0)]] StructuredBuffer<Mesh> meshes : register(MIRAI_REGISTER(t, SLOT_MESHES), space0);
[[vk::binding(SLOT_VERTICES, 0)]] RWStructuredBuffer<uint> vertex_words : register(MIRAI_REGISTER(u, SLOT_VERTICES), space0);
[[vk::binding(SLOT_INDICES, 0)]] StructuredBuffer<uint> indices : register(MIRAI_REGISTER(t, SLOT_INDICES), space0);
#define MIRAI_POSED_STORE
#include "geometry.slang"

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    if (id.x >= params.count) return;
    Posed_Vertex v = posed_load(params.rest, id.x);
    float weight = mesh_vertex_color(meshes[params.mesh], id.x).r;
    v.position = foliage_bend(v.position, foliage_wind_lean(params.wind.xyz, params.wind.w, weight, params.sway.x, params.sway.y, params.sway.z));
    posed_store(params.written, id.x, v);
}
