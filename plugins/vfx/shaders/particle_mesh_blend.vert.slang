//! per vfx program
#include "native.slang"
// A mesh per particle of the list an emitter draws whose material blends
// (alpha mode Blend): over the lit scene with the fragment of the sprites
// (particle_sprite.frag), so its color, opacity and the curves of its life
// show and fade as a sprite's do, additive or covering by alpha as the
// effect says. It turns, grows and is placed as particle_mesh.vert places
// it, a draw for each of its meshes; the uv0 and uv1 of its vertices take the place of the two frames of
// the flipbook, and the fragment reads them through the material's map.
#include "gbuffer_vertex.slang"
#include "particle_programs.slang"

struct Params_Block { uint emitter; uint pass; uint choice; uint pad1; };
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
    [[vk::location(11)]] nointerpolation float2 out_random_radius : TEXCOORD11;
};

[shader("vertex")]
Stage_Output main(uint vertex_id : SV_VulkanVertexID, uint instance_id : SV_VulkanInstanceID) {
    Stage_Output output = (Stage_Output)0;
    Particle_Emitter e = particle_emitters[params.emitter];
    uint index = particle_drawn(params.emitter, instance_id);
    Particle p = particles[index];
    Mesh mesh = meshes[particle_mesh_of(params.emitter, params.choice)];
    Cluster c = mesh_cluster(mesh, vertex_id / CLUSTER_DRAW_VERTICES);
    uint corner = vertex_id % CLUSTER_DRAW_VERTICES;
    if (particle_mesh_choice(params.emitter, p) != params.choice || corner >= cluster_triangle_count(c) * 3u || !cluster_resident(mesh, c)) {
        output.position = float4(2.0, 2.0, 2.0, 1.0);
        return output;
    }
    Mesh_Point v = cluster_point(mesh, c, cluster_corner(mesh, c, corner));
    Particle_Look look = particle_program_look(params.emitter, index, p);
    float3x3 rotation = particle_mesh_rotation(params.emitter, p);
    float3 world = particle_world(params.emitter, p.position) + particle_mesh_vector(params.emitter, rotation, v.position * look.size);
    output.position = view_clip(world);
    // The color of the mesh tints it as it tints the mesh in the G-buffer.
    output.out_color = float4(material_vertex_tint(material_row(e.mesh.w), v.color.rgb), 1.0) * look.color;
    output.out_light = (e.range.w & PARTICLE_FLAG_LIT) != 0u ? particle_light(p) : emission_render_units(float3(1.0), (e.range.w & PARTICLE_FLAG_RELATIVE) != 0u);
    output.out_uv = float4(v.uv, v.uv1);
    output.out_blend_depth = float2(0.0, dot(world - frame.camera_position.xyz, frame.camera_forward.xyz));
    output.out_seed = float(p.seed & 1023u) * 0.37;
    output.out_world = world;
    output.out_data0 = look.data[0]; output.out_data1 = look.data[1]; output.out_data2 = look.data[2]; output.out_data3 = look.data[3];
    output.out_given = look.given;
    output.out_random_radius = float2(look.random, look.size * 0.5);
    return output;
}
