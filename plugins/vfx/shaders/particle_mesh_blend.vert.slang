#include "native.slang"
// Blended meshes share the sprite fragment shader and carry their cluster’s material.
#include "gbuffer_vertex.slang"
#include "particle_programs.slang"

struct Params_Block { uint emitter; uint pass; uint mesh; uint pad1; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);

// What particle_sprite.frag reads (particle_sprite.vert gives the same).
struct Stage_Output {
    float4 position : SV_Position;
    [[vk::location(0)]] float4 out_color : TEXCOORD0;
    [[vk::location(1)]] float3 out_light : TEXCOORD1;
    [[vk::location(2)]] float4 out_uv : TEXCOORD2;
    [[vk::location(3)]] float2 out_blend_depth : TEXCOORD3;
    [[vk::location(4)]] nointerpolation float out_seed : TEXCOORD4;
    [[vk::location(5)]] float3 out_world : TEXCOORD5;
    [[vk::location(6)]] nointerpolation float4 out_data0 : TEXCOORD6;
    [[vk::location(7)]] nointerpolation float4 out_data1 : TEXCOORD7;
    [[vk::location(8)]] nointerpolation float4 out_data2 : TEXCOORD8;
    [[vk::location(9)]] nointerpolation float4 out_data3 : TEXCOORD9;
    [[vk::location(10)]] nointerpolation uint out_given : TEXCOORD10;
    [[vk::location(12)]] nointerpolation uint material : TEXCOORD12;
    [[vk::location(11)]] nointerpolation float2 out_random_radius : TEXCOORD11;
    [[vk::location(13)]] float3 out_normal : TEXCOORD13;
};

[shader("vertex")]
Stage_Output main(uint vertex_id : SV_VulkanVertexID, uint instance_id : SV_VulkanInstanceID) {
    Stage_Output output = (Stage_Output)0;

    Mesh mesh = meshes[params.mesh];
    // Indexed as particle_mesh.vert.
    Cluster c;
    Mesh_Point v;
    if (!particle_mesh_point(mesh, vertex_id, c, v)) {
        output.position = float4(2.0, 2.0, 2.0, 1.0);
        return output;
    }
    uint override_material = particle_emitters[params.emitter].mesh.w;
    output.material = override_material != 0u ? override_material : (cluster_material(mesh, c) & 0xffffffu);
    Material row = material_row(output.material);
    if (!material_blended(row) || (params.pad1 != INVALID && row.program_id != params.pad1)) {
        output.position = float4(2.0, 2.0, 2.0, 1.0);
        return output;
    }
    // The first instance of the draw is where the run of its mesh starts in the list.
    uint index = particle_drawn(params.emitter, instance_id);
    Particle p = particles[index];
    Particle_Look look = particle_draw_look(params.emitter, index);
    float3x3 rotation = particle_mesh_rotation(params.emitter, p, particle_pose(params.emitter, index));
    float3 world = particle_world(params.emitter, p.position) + particle_mesh_vector(params.emitter, rotation, v.position * look.size * particle_scale(params.emitter));
    output.out_normal = particle_mesh_normal(params.emitter, rotation, v.normal);
    output.position = view_clip(world);
    // The color of the mesh tints it as it tints the mesh in the G-buffer.
    output.out_color = float4(material_vertex_tint(row, v.color.rgb), 1.0) * look.color;
    output.out_light = (particle_emitters[params.emitter].range.w & PARTICLE_FLAG_LIT) != 0u ? particle_light(p) : emission_render_units(float3(1.0), (particle_emitters[params.emitter].range.w & PARTICLE_FLAG_RELATIVE) != 0u);
    output.out_uv = float4(v.uv, v.uv1);
    output.out_blend_depth = float2(0.0, dot(world - frame.camera_position.xyz, frame.camera_forward.xyz));
    output.out_seed = float(p.seed & 1023u) * 0.37;
    output.out_world = world;
    output.out_data0 = look.data[0]; output.out_data1 = look.data[1]; output.out_data2 = look.data[2]; output.out_data3 = look.data[3];
    output.out_given = look.given;
    output.out_random_radius = float2(look.random, look.size * 0.5);
    return output;
}
