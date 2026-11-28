#include "native.slang"
// Blended meshes share the sprite fragment shader and carry their cluster’s material.
#include "gbuffer_vertex.slang"
#include "particle_programs.slang"

struct Params_Block { uint emitter; uint pass; uint mesh; uint pad1; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);

[shader("vertex")]
Particle_Varyings main(uint vertex_id : SV_VulkanVertexID, uint instance_id : SV_VulkanInstanceID) {
    Particle_Varyings output = (Particle_Varyings)0;

    Mesh mesh = meshes[params.mesh];
    // Indexed as particle_mesh.vert.
    Cluster c;
    Mesh_Point v;
    if (!particle_mesh_point(mesh, vertex_id, c, v)) {
        output.position = float4(2.0, 2.0, 2.0, 1.0);
        return output;
    }
    uint override_material = particle_emitters[params.emitter].mesh.w;
    uint material = override_material != 0u ? override_material : (cluster_material(mesh, c) & 0xffffffu);
    Material row = material_row(material);
    if (!material_blended(row) || (params.pad1 != INVALID && row.program_id != params.pad1)) {
        output.position = float4(2.0, 2.0, 2.0, 1.0);
        return output;
    }
    // The first instance of the draw is where the run of its mesh starts in the list.
    uint index = particle_drawn(params.emitter, instance_id);
    Particle p = particles[index];
    Particle_Look look = particle_draw_look(params.emitter, index);
    bool turned = particle_look_turned(look);
    float3x3 rotation = particle_look_rotation(params.emitter, index, p, look);
    float3 scale = particle_look_scale(params.emitter, look);
    float3 world = particle_world(params.emitter, p.position) + particle_mesh_vector(params.emitter, rotation, v.position * look.size * scale, turned);
    output.normal = particle_mesh_normal(params.emitter, rotation, v.normal, scale, turned);
    // The tangent goes as the surface stretches; a mirroring scale turns the side of its bitangent.
    float3 along = particle_unit(particle_mesh_vector(params.emitter, rotation, v.tangent.xyz * scale, turned), float3(1.0, 0.0, 0.0));
    output.tangent = float4(along, scale.x * scale.y * scale.z < 0.0 ? -v.tangent.w : v.tangent.w);
    output.position = view_clip(world);
    // The color of the particle, and that of the mesh apart: a material without a
    // program tints by both, as the G-buffer does; a program reads each.
    output.color = look.color;
    output.vertex_color = v.color;
    // Lit, the light around it, and the sun the fragment shades by its normal where it reaches it.
    bool lit = (particle_emitters[params.emitter].range.w & PARTICLE_FLAG_LIT) != 0u;
    output.light = lit ? float4(particle_light(p), float((p.flags >> SUN_SHIFT) & 1u)) : float4(emission_render_units(float3(1.0), (particle_emitters[params.emitter].range.w & PARTICLE_FLAG_RELATIVE) != 0u), 0.0);
    output.uv = float4(v.uv, v.uv1);
    output.blend_depth_life = float3(0.0, dot(world - frame.camera_position.xyz, frame.camera_forward.xyz), particle_life(p));
    output.particle = float4(float(p.seed & 1023u) * 0.37, look.random, look.size * 0.5, 1.0);
    output.world = world;
    output.data0 = look.data[0]; output.data1 = look.data[1]; output.data2 = look.data[2]; output.data3 = look.data[3];
    output.given_material = uint2(look.given, material);
    return output;
}
