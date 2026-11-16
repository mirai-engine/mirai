#include "native.slang"
// The surface of a mesh for the particles of a world: the area of each
// triangle of its level 0 added up in their order, which a birth searches for
// a share of the whole (particle_surface_sample). A triangle is a primitive
// (geometry.slang): CLUSTER_TRIANGLES a cluster, those past its own of no
// area. A group: each thread adds up a run of triangles, then the group adds
// up the runs.
#include "scene.slang"
#define MIRAI_GROUP_X 256
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

struct Params_Block { uint mesh; uint first; uint count; uint pad; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS6, 0)]] RWStructuredBuffer<float> surfaces : register(MIRAI_REGISTER(u, SLOT_PASS6), space0);

groupshared float runs[MIRAI_GROUP_X];

float triangle_area(Mesh m, uint primitive) {
    Cluster cluster = mesh_cluster(m, primitive_cluster(primitive));
    if (primitive_triangle(primitive) >= cluster_triangle_count(cluster) || !cluster_resident(m, cluster)) return 0.0;
    float3 a, b, c;
    uint material;
    mesh_triangle_positions(m, primitive, a, b, c, material);
    return 0.5 * length(cross(b - a, c - a));
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 local : SV_GroupThreadID) {
    Mesh m = meshes[params.mesh];
    uint count = min(params.count, mesh_level_clusters(m, 0u).y * CLUSTER_TRIANGLES);
    uint per = (count + MIRAI_GROUP_X - 1u) / MIRAI_GROUP_X;
    uint start = min(local.x * per, count), end = min(start + per, count);
    float sum = 0.0;
    for (uint t = start; t < end; t++) {
        sum += triangle_area(m, t);
        surfaces[params.first + t] = sum;
    }
    runs[local.x] = sum;
    GroupMemoryBarrierWithGroupSync();
    for (uint d = 1u; d < MIRAI_GROUP_X; d <<= 1u) {
        float before = local.x >= d ? runs[local.x - d] : 0.0;
        GroupMemoryBarrierWithGroupSync();
        runs[local.x] += before;
        GroupMemoryBarrierWithGroupSync();
    }
    float before = local.x > 0u ? runs[local.x - 1u] : 0.0;
    for (uint t = start; t < end; t++) surfaces[params.first + t] += before;
}
