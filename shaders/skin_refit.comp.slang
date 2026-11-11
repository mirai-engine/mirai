#include "native.slang"
//! software rays
#include "common.slang"
#include "skin_jobs.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1
[[vk::binding(SLOT_BLAS_TRIANGLES,0)]] StructuredBuffer<Bvh_Triangle> triangles : register(MIRAI_REGISTER(t,SLOT_BLAS_TRIANGLES),space0);
[[vk::binding(SLOT_BLAS_NODES,0)]] RWStructuredBuffer<Bvh_Node> nodes : register(MIRAI_REGISTER(u,SLOT_BLAS_NODES),space0);
[shader("compute")]
[numthreads(MIRAI_GROUP_X,MIRAI_GROUP_Y,MIRAI_GROUP_Z)]
void main(uint3 tid:SV_DispatchThreadID) {
    if (tid.x>=params.total) return;
    Skin_Job job=skin_job(tid.x);
    uint at=job.x+job.z+tid.x-job.start;
    Bvh_Node node=nodes[at];
    if (node.count!=0u) {
        node.bounds_min=float3(FLT_MAX);node.bounds_max=float3(-FLT_MAX);
        for (uint i=0;i<node.count;++i) {
            Bvh_Triangle t=triangles[job.y+node.left_first+i];
            node.bounds_min=min(node.bounds_min,min(t.v0,min(t.v0+t.e1.xyz,t.v0+t.e2.xyz)));
            node.bounds_max=max(node.bounds_max,max(t.v0,max(t.v0+t.e1.xyz,t.v0+t.e2.xyz)));
        }
    } else {
        Bvh_Node left=nodes[job.x+node.left_first],right=nodes[job.x+node.left_first+1u];
        node.bounds_min=min(left.bounds_min,right.bounds_min);node.bounds_max=max(left.bounds_max,right.bounds_max);
    }
    nodes[at]=node;
}
