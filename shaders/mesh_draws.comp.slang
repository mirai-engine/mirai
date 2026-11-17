#include "native.slang"
// The indices a mesh drawn whole this frame is drawn by (render/mesh_draws.odin),
// a group a cluster, in rows of params.row groups: of its cluster c,
// CLUSTER_DRAW_VERTICES from params.first + c * CLUSTER_DRAW_VERTICES, the
// three vertices of each of its triangles as c << DRAW_VERTEX_BITS | the
// vertex in it, then its first vertex three times, which gives no pixel; all
// of them so for a cluster whose page is not in the pools.
#include "scene.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

struct Params_Block { uint mesh; uint first; uint row; uint pad; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] RWStructuredBuffer<uint> draws : register(MIRAI_REGISTER(u, SLOT_PASS0), space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 group : SV_GroupID, uint3 lane : SV_GroupThreadID) {
    Mesh mesh = meshes[params.mesh];
    uint ordinal = group.y * params.row + group.x;
    if (ordinal >= mesh.cluster_count) return;
    Cluster c = mesh_cluster(mesh, ordinal);
    bool resident = cluster_resident(mesh, c);
    uint count = resident ? cluster_triangle_count(c) : 0u;
    uint word = ordinal << DRAW_VERTEX_BITS;
    uint at = params.first + ordinal * CLUSTER_DRAW_VERTICES;
    for (uint t = lane.x; t < CLUSTER_DRAW_VERTICES / 3u; t += MIRAI_GROUP_X) {
        uint3 corners = uint3(0u);
        if (t < count) corners = block_triangle(cluster_block(mesh, c), t);
        draws[at + t * 3u] = word | corners.x;
        draws[at + t * 3u + 1u] = word | corners.y;
        draws[at + t * 3u + 2u] = word | corners.z;
    }
}
