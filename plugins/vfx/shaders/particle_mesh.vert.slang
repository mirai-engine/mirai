//! per vfx program
#include "native.slang"
// A mesh per particle of the list an emitter draws (vfx.particles_record), in
// the G-buffer with the fragment of the engine: lit, shadowed and reflected
// like the scene. It turns about an axis of its own and moves by its velocity.
// The draw gives each cluster of level 0 of the mesh CLUSTER_DRAW_VERTICES
// vertices: those past its triangles are collapsed, and those of materials
// of another Surface program than params.program (INVALID: any), which a
// draw of their own takes (render.pass_mesh_programs).
#include "gbuffer_vertex.slang"
#include "particle_programs.slang"
struct Params_Block { uint emitter; uint program; uint pad0; uint pad1; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);

[shader("vertex")]
Gbuffer_Vertex main(uint vertex_id : SV_VulkanVertexID, uint instance_id : SV_VulkanInstanceID) {
    Gbuffer_Vertex output = (Gbuffer_Vertex)0;
    Particle_Emitter e = particle_emitters[params.emitter];
    Mesh mesh = meshes[e.mesh.y];
    Cluster c = mesh_cluster(mesh, vertex_id / CLUSTER_DRAW_VERTICES);
    uint corner = vertex_id % CLUSTER_DRAW_VERTICES;
    uint material = e.mesh.w != 0u ? e.mesh.w : (cluster_material(mesh, c) & 0xffffffu);
    bool shown = params.program == INVALID || material_row(material).program_id == params.program;
    if (corner >= cluster_triangle_count(c) * 3u || !cluster_resident(mesh, c) || !shown) {
        output.position = float4(2.0, 2.0, 2.0, 1.0);
        return output;
    }
    Mesh_Point v = cluster_point(mesh, c, cluster_corner(mesh, c, corner));
    uint index = particle_drawn(params.emitter, instance_id);
    Particle p = particles[index];
    Particle_Look look = particle_program_look(params.emitter, index, p);
    float3x3 rotation = particle_rotation(p.seed, p.rotation);
    float3 world = particle_world(params.emitter, p.position) + particle_world_vector(params.emitter, mul(rotation, v.position * look.size));
    float3 prev_world = world - particle_world_vector(params.emitter, p.velocity) * e.step.x;
    output.out_normal = normalize(particle_world_vector(params.emitter, mul(rotation, v.normal)));
    output.out_tangent = float4(normalize(particle_world_vector(params.emitter, mul(rotation, v.tangent.xyz))), v.tangent.w);
    output.out_color = material_vertex_tint(material_row(material), v.color.rgb) * look.color.rgb;
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
