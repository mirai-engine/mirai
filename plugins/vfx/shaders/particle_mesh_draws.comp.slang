#include "native.slang"
#define PARTICLES_WRITABLE
#include "particles.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

struct Params_Block { uint count; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS7, 0)]] StructuredBuffer<uint> slots : register(MIRAI_REGISTER(t, SLOT_PASS7), space0);

uint particle_mesh_level(Mesh mesh, uint slot) {
    // The streamed root is resident even when there are no scene instances of this mesh.
    if ((mesh.flags & MESH_FLAG_STREAMED) != 0u) return max(mesh.level_count, 1u) - 1u;
    if ((mesh.flags & MESH_FLAG_LEVEL0) != 0u || particle_emitters[slot].program.x != 0u) return 0u;
    float3 center = transform_point(particle_emitters[slot].world, float3(0.0));
    float size = max(particle_emitters[slot].size_rotation.x, particle_emitters[slot].size_rotation.y);
    float4 sizes0 = particle_emitters[slot].size_curve[0], sizes1 = particle_emitters[slot].size_curve[1];
    float4 sizes = max(sizes0, sizes1);
    size *= max(max(sizes.x, sizes.y), max(sizes.z, sizes.w));
    if ((particle_emitters[slot].range.w & PARTICLE_FLAG_LOCAL) != 0u) {
        size *= max(length(particle_emitters[slot].world[0].xyz),
            max(length(particle_emitters[slot].world[1].xyz), length(particle_emitters[slot].world[2].xyz)));
    }
    float worlds_per_pixel = 2.0 * abs(view_clip(center).w) / max(abs(frame.view_proj[1][1]) * frame.resolution.y, 1.0);
    float error = frame.cut.x * worlds_per_pixel / max(size, 1e-5);
    uint level = 0u;
    while (level + 1u < mesh.level_count && mesh_level_errors(mesh, level).y <= error) level++;
    return level;
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    if (id.x >= params.count) return;
    uint slot = slots[id.x];
    uint count = particle_emitters[slot].mesh.x;
    for (uint choice = 0u; choice < count; choice++) {
        Mesh mesh = meshes[particle_emitters[slot].mesh_handles[choice]];
        uint2 clusters = mesh.level_count > 0u ? mesh_level_clusters(mesh, particle_mesh_level(mesh, slot)) : uint2(0u);
        uint words = PARTICLE_MESH_DRAWS_AT + (slot * PARTICLE_MESHES + choice) * PARTICLE_MESH_DRAW_WORDS;
        particle_queue[words] = clusters.y * CLUSTER_DRAW_VERTICES;
        particle_queue[words + 2u] = clusters.x * CLUSTER_DRAW_VERTICES;
    }
}
