#include "native.slang"
// Each indirect draw covers a mesh level and one run of the emitter’s draw list.
#include "gbuffer_vertex.slang"
#include "particle_programs.slang"
struct Params_Block { uint emitter; uint program; uint mesh; uint pad1; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);

[shader("vertex")]
Gbuffer_Vertex main(uint vertex_id : SV_VulkanVertexID, uint instance_id : SV_VulkanInstanceID) {
    Gbuffer_Vertex output = (Gbuffer_Vertex)0;

    Mesh mesh = meshes[params.mesh];
    Cluster c;
    Mesh_Point v;
    if (!particle_mesh_point(mesh, vertex_id, c, v)) {
        output.position = float4(2.0, 2.0, 2.0, 1.0);
        return output;
    }
    uint material = particle_emitters[params.emitter].mesh.w;
    if (material == 0u) material = cluster_material(mesh, c) & 0xffffffu;
    Material row = material_row(material);
    if (row.alpha_mode == ALPHA_BLEND || (params.program != INVALID && row.program_id != params.program)) {
        output.position = float4(2.0, 2.0, 2.0, 1.0);
        return output;
    }
    // The first instance of the draw is where the run of its mesh starts in the list.
    uint index = particle_drawn(params.emitter, instance_id);
    Particle p = particles[index];
    Particle_Look look = particle_draw_look(params.emitter, index);
    float3x3 rotation = particle_mesh_rotation(params.emitter, p);
    float3 world = particle_world(params.emitter, p.position) + particle_mesh_vector(params.emitter, rotation, v.position * look.size);
    float3 prev_world = world - particle_world_vector(params.emitter, p.velocity) * particle_frame_step().x;
    output.out_normal = particle_unit(particle_mesh_vector(params.emitter, rotation, v.normal), v.normal);
    output.out_tangent = float4(particle_unit(particle_mesh_vector(params.emitter, rotation, v.tangent.xyz), v.tangent.xyz), v.tangent.w);
    output.out_color = material_vertex_tint(row, v.color.rgb) * look.color.rgb;
    output.out_vertex_color = v.color;
    output.out_emission = float3(0.0);
    output.out_flags = 0u;
    output.out_material = material;
    output.out_instance = INVALID;
    output.out_uv = v.uv;
    output.out_uv1 = v.uv1;
    gbuffer_vertex_place(output, world, prev_world);
    return output;
}
