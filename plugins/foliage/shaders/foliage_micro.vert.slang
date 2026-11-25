// A vertex of a micro instance a view kept (foliage_micro_cull.comp), of the
// mesh of its look, into the G-buffer with the fragment of the engine and of
// the materials of the mesh: lit, shadowed and reflected like any surface,
// never in the structure of rays. The wind and the trampled field bend it as
// they bend the batches of foliage (foliage_vertex.slang).
#include "foliage_micro.slang"
#include "gbuffer_vertex.slang"
#include <extension_vertex.slang>

struct Micro_Draw {
    uint look;
    uint program; // the Surface program the pipeline draws; INVALID: every material of the mesh
    uint mesh;
    uint pad;
};

[[vk::binding(SLOT_PASS0, 0)]] StructuredBuffer<Micro_Instance> micro_instances : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS2, 0)]] StructuredBuffer<uint> micro_visible : register(MIRAI_REGISTER(t, SLOT_PASS2), space0);
[[vk::binding(SLOT_PASS4, 0)]] StructuredBuffer<Micro_Slot> micro_slots : register(MIRAI_REGISTER(t, SLOT_PASS4), space0);
[[vk::binding(SLOT_PASS5, 0)]] StructuredBuffer<Micro_Look> micro_looks : register(MIRAI_REGISTER(t, SLOT_PASS5), space0);
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Micro_Draw> draw : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);

float3 micro_unit_vector(float3 v, float3 fallback) {
    float squared = dot(v, v);
    return squared > 1e-12 ? v * rsqrt(squared) : fallback;
}

[shader("vertex")]
Gbuffer_Vertex main(uint vertex_id : SV_VulkanVertexID, uint instance_id : SV_VulkanInstanceID) {
    Gbuffer_Vertex output = (Gbuffer_Vertex)0;
    output.position = float4(2.0, 2.0, 2.0, 1.0);
    Mesh mesh = meshes[draw.mesh];
    Cluster c = mesh_cluster(mesh, vertex_id / CLUSTER_DRAW_VERTICES);
    uint corner = vertex_id % CLUSTER_DRAW_VERTICES;
    uint triangle = corner / 3u;
    if (triangle >= cluster_triangle_count(c) || !cluster_resident(mesh, c)) return output;
    Mesh_Point v = cluster_point(mesh, c, cluster_triangle(mesh, c, triangle)[corner % 3u]);
    uint material = cluster_material(mesh, c) & 0xffffffu;
    Material row = material_row(material);
    if (material_apart(row) || (draw.program != INVALID && row.program_id != draw.program)) return output;
    Micro_Look look = micro_looks[draw.look];
    Micro_Instance inst = micro_instances[micro_visible[look.mesh.z + instance_id]];
    Micro_Slot slot = micro_slots[inst.slot];
    Micro_Place m = micro_place(inst, slot, look);
    // Far away it shrinks into the ground where it stands.
    float3 rest = m.pivot + (transform_point(m.world, v.position) - m.pivot) * m.kept;
    float4 params = float4(look.offset.z, 1.0, look.offset.w, 0.0);
    float3 world = foliage_sway(rest, m.pivot, v.color, foliage_lean(m.pivot, params, frame.time.x));
    float3 previous = foliage_sway(rest, m.pivot, v.color, foliage_lean(m.pivot, params, frame.time.y));
    // Normals go by the inverse transpose: the axes divided by their squared scales.
    float3 axis_x = float3(m.world[0].x, m.world[1].x, m.world[2].x);
    float3 axis_y = float3(m.world[0].y, m.world[1].y, m.world[2].y);
    float3 axis_z = float3(m.world[0].z, m.world[1].z, m.world[2].z);
    float3 inverse_x = axis_x / max(dot(axis_x, axis_x), 1e-12), inverse_y = axis_y / max(dot(axis_y, axis_y), 1e-12), inverse_z = axis_z / max(dot(axis_z, axis_z), 1e-12);
    output.out_normal = micro_unit_vector(inverse_x * v.normal.x + inverse_y * v.normal.y + inverse_z * v.normal.z, v.normal);
    output.out_tangent = float4(micro_unit_vector(axis_x * v.tangent.x + axis_y * v.tangent.y + axis_z * v.tangent.z, v.tangent.xyz), v.tangent.w);
    output.out_color = material_vertex_tint(row, v.color.rgb);
    output.out_vertex_color = v.color;
    output.out_emission = float3(0.0);
    output.out_flags = 0u;
    output.out_material = material;
    output.out_instance = INVALID;
    output.out_uv = v.uv;
    output.out_uv1 = v.uv1;
    gbuffer_vertex_place(output, world, previous);
    return output;
}
