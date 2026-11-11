#include "native.slang"
//! software rays
#include "common.slang"
#include "skin_jobs.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1
// The triangles of the tree of each pose that changed take its posed
// vertices: a job is a pose, x its mesh and z its first triangle.
[[vk::binding(SLOT_MESHES,0)]] StructuredBuffer<Mesh> meshes : register(MIRAI_REGISTER(t,SLOT_MESHES),space0);
[[vk::binding(SLOT_VERTICES,0)]] StructuredBuffer<uint> vertex_words : register(MIRAI_REGISTER(t,SLOT_VERTICES),space0);
[[vk::binding(SLOT_INDICES,0)]] StructuredBuffer<uint> indices : register(MIRAI_REGISTER(t,SLOT_INDICES),space0);
#include "geometry.slang"
[[vk::binding(SLOT_BLAS_TRIANGLES,0)]] RWStructuredBuffer<Bvh_Triangle> triangles : register(MIRAI_REGISTER(u,SLOT_BLAS_TRIANGLES),space0);
[shader("compute")]
[numthreads(MIRAI_GROUP_X,MIRAI_GROUP_Y,MIRAI_GROUP_Z)]
void main(uint3 tid:SV_DispatchThreadID) {
    if (tid.x>=params.total) return;
    Skin_Job job=skin_job(tid.x);
    uint at=job.z+tid.x-job.start;
    Bvh_Triangle triangle=triangles[at];
    float3 a,b,c;
    uint material;
    mesh_triangle_positions(meshes[job.x],triangle.primitive,a,b,c,material);
    triangle.v0=a;triangle.v1=float4(b,0);triangle.v2=float4(c,0);
    triangles[at]=triangle;
}
