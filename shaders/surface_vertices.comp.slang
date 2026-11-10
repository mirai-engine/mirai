#include "native.slang"
//! per vertex program
// Moves the vertices of the pose of one instance by the function vertex of
// one Surface program (`//! vertex`, render/displace.odin): a group a cluster
// of those it poses, a thread a vertex of it. Only the clusters whose
// material in the instance has this program move; the others keep what they
// have. A vertex comes from its rest (input INVALID) or from where its skin
// posed it, and goes to output; before says what it writes at output_before:
// nothing (0), the same (1, a pose written for the first time), or the
// vertex of input_before at the time and place of the frame before (2, the
// previous vertices its skin wrote).
#define VERTICES_WRITABLE
#define MIRAI_POSED_STORE
#include "scene.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

struct Params_Block {
    uint mesh; uint clusters; uint instance; uint program;
    uint input; uint output; uint input_before; uint output_before;
    uint before; float time; float previous_time; uint pad;
    int4 origin;
};
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);

Mirai_Vertex vertex_moved(Mesh mesh, Mesh_Point rest, Posed_Vertex at, bool posed, float4 world[3], float time, float4 parameters[16]) {
    Mirai_Vertex_Context ctx;
    ctx.position = posed ? at.position : rest.position;
    ctx.normal = posed ? unpack_normal(at.normal) : rest.normal;
    ctx.tangent = posed ? unpack_tangent(at.tangent) : rest.tangent;
    ctx.uv0 = rest.uv; ctx.uv1 = rest.uv1; ctx.vertex_color = rest.color;
    ctx.world_position = transform_point(world, ctx.position);
    ctx.origin = params.origin.xyz;
    ctx.object_position = float3(world[0].w, world[1].w, world[2].w);
    ctx.object_x = float3(world[0].x, world[1].x, world[2].x);
    ctx.object_y = float3(world[0].y, world[1].y, world[2].y);
    ctx.object_z = float3(world[0].z, world[1].z, world[2].z);
    ctx.object_low = mesh.bounds_min.xyz; ctx.object_high = mesh.bounds_max.xyz;
    ctx.time = time; ctx.previous_time = params.previous_time;
    Mirai_Vertex moved = mirai_vertex_default(ctx);
    mirai_vertex_program(params.program, parameters, ctx, moved);
    return moved;
}

Posed_Vertex vertex_packed(Mirai_Vertex v, Mesh_Point rest) {
    Posed_Vertex p;
    bool finite = all(isfinite(v.position)) && all(isfinite(v.normal)) && all(isfinite(v.tangent));
    float3 n = finite && dot(v.normal, v.normal) > 1e-20 ? normalize(v.normal) : rest.normal;
    float3 t = finite && dot(v.tangent.xyz, v.tangent.xyz) > 1e-20 ? normalize(v.tangent.xyz) : rest.tangent.xyz;
    p.position = finite ? v.position : rest.position;
    p.normal = packSnorm2x16(oct_encode(n));
    p.tangent = pack_tangent(t, (finite ? v.tangent.w : rest.tangent.w) < 0.0 ? -1.0 : 1.0);
    return p;
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 group : SV_GroupID, uint3 lane : SV_GroupThreadID) {
    if (group.x >= params.clusters) return;
    Mesh mesh = meshes[params.mesh];
    Cluster c = mesh_cluster(mesh, group.x);
    Instance inst = instances[params.instance];
    uint row = material_of(inst, cluster_material(mesh, c));
    if (materials[row].shared.program_id != params.program) return;
    bool posed = params.input != INVALID;
    float4 parameters[16];
    material_parameters(row, inst.material_values, parameters);
    for (uint local = lane.x; local < cluster_vertex_count(c); local += MIRAI_GROUP_X) {
        uint index = c.vertex_first + local;
        Mesh_Point rest = cluster_point_at(mesh, c, local, INVALID);
        Posed_Vertex at = posed ? posed_load(params.input, index) : (Posed_Vertex)0;
        Posed_Vertex now = vertex_packed(vertex_moved(mesh, rest, at, posed, inst.world, params.time, parameters), rest);
        if (params.before == 2u) {
            Posed_Vertex then = posed_load(params.input_before, index);
            posed_store(params.output_before, index, vertex_packed(vertex_moved(mesh, rest, then, true, inst.prev_world, params.previous_time, parameters), rest));
        }
        posed_store(params.output, index, now);
        if (params.before == 1u) posed_store(params.output_before, index, now);
    }
}
