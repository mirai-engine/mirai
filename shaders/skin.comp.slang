#include "native.slang"
#include "common.slang"
// Poses a skinned mesh: a group a cluster of the levels it poses, a thread a
// vertex of it. A vertex at rest is that of its cluster (geometry.slang) with
// what the morph targets add at their weights; the palette takes it where it
// is now and where it was in the frame before, as Posed_Vertex. Then the box
// of the cluster as posed now and the cone of the normals of its triangles
// (posed_bounds), for the passes that leave clusters out.
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1
struct Skin_Joint { float4 current[3]; float4 previous[3]; };
// clusters: those it poses, from its first; output, previous: where the vertices go, words of the vertex
// pool; morph_step: of the positions of the morph deltas; bounds: where the box and the cone of each
// cluster go (POSED_BOUNDS_WORDS each), INVALID for none; reach: how far programs move the vertices
// after the skin, in the space of the mesh: the boxes grow by it and keep no cone.
struct Params_Block { uint mesh; uint clusters; uint output; uint previous; uint morph_count; float morph_step; uint bounds; float reach; };
struct Morph_Range { uint first; uint count; };
[[vk::binding(SLOT_PARAMS,0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b,SLOT_PARAMS),space0);
// The influences of each vertex of the mesh (asset.Skin_Vertex): eight joints in four words, eight weights of 255ths in two.
[[vk::binding(SLOT_PASS0,0)]] StructuredBuffer<uint> influences : register(MIRAI_REGISTER(t,SLOT_PASS0),space0);
[[vk::binding(SLOT_PASS1,0)]] StructuredBuffer<Skin_Joint> joints : register(MIRAI_REGISTER(t,SLOT_PASS1),space0);
[[vk::binding(SLOT_PASS2,0)]] StructuredBuffer<Morph_Range> morph_ranges : register(MIRAI_REGISTER(t,SLOT_PASS2),space0);
// Five words a delta (render.Morph_Delta): its target; its position, then its normal, as six
// int16 two to a word, low first; its tangent as three signed 10-bit fields from bit 0.
[[vk::binding(SLOT_PASS3,0)]] StructuredBuffer<uint> morph_deltas : register(MIRAI_REGISTER(t,SLOT_PASS3),space0);
// Of each target, its weight now and in the frame before.
[[vk::binding(SLOT_PASS4,0)]] StructuredBuffer<float2> morph_weights : register(MIRAI_REGISTER(t,SLOT_PASS4),space0);
[[vk::binding(SLOT_MESHES,0)]] StructuredBuffer<Mesh> meshes : register(MIRAI_REGISTER(t,SLOT_MESHES),space0);
[[vk::binding(SLOT_VERTICES,0)]] RWStructuredBuffer<uint> vertex_words : register(MIRAI_REGISTER(u,SLOT_VERTICES),space0);
[[vk::binding(SLOT_INDICES,0)]] StructuredBuffer<uint> indices : register(MIRAI_REGISTER(t,SLOT_INDICES),space0);
#define MIRAI_POSED_STORE
#include "geometry.slang"

// The vertices of the cluster of the group as posed now.
groupshared float3 skin_positions[256];

[shader("compute")]
[numthreads(MIRAI_GROUP_X,MIRAI_GROUP_Y,MIRAI_GROUP_Z)]
void main(uint3 group:SV_GroupID,uint3 lane:SV_GroupThreadID) {
    if (group.x>=params.clusters) return;
    Mesh mesh=meshes[params.mesh];
    Cluster c=mesh_cluster(mesh,group.x);
    for (uint local=lane.x;local<cluster_vertex_count(c);local+=MIRAI_GROUP_X) {
        uint index=c.vertex_first+local;
        float4 rows[3]={float4(0),float4(0),float4(0)};
        float4 old_rows[3]={float4(0),float4(0),float4(0)};
        uint packed_weights[2]={influences[index*6u+4u],influences[index*6u+5u]};
        for (uint i=0;i<8u;++i) {
            float weight=float((packed_weights[i>>2u]>>((i&3u)*8u))&255u)/255.0;
            if (weight==0) continue;
            uint id=(influences[index*6u+(i>>1u)]>>((i&1u)*16u))&65535u;
            Skin_Joint joint=joints[id];
            for (uint row=0;row<3u;++row) {
                rows[row]+=joint.current[row]*weight;
                old_rows[row]+=joint.previous[row]*weight;
            }
        }
        Mesh_Point rest=cluster_point_at(mesh,c,local,INVALID);
        float3 position=rest.position;
        float3 old_position=rest.position;
        float3 n=rest.normal;
        float4 tangent=rest.tangent;
        // The targets move the bind shape: the skin poses what they made of it.
        if (params.morph_count>0) {
            Morph_Range range=morph_ranges[index];
            float3 t=tangent.xyz;
            for (uint d=0;d<range.count;++d) {
                uint at=(range.first+d)*5u;
                uint w1=morph_deltas[at+1u],w2=morph_deltas[at+2u],w3=morph_deltas[at+3u],w4=morph_deltas[at+4u];
                float2 weight=morph_weights[morph_deltas[at]];
                float3 moved=float3(asint(uint3(w1<<16u,w1,w2<<16u))>>16)*params.morph_step;
                float3 normal=float3(asint(uint3(w2,w3<<16u,w3))>>16)*(2.0/32767.0);
                float3 turned=float3(asint(uint3(w4<<22u,w4<<12u,w4<<2u))>>22)*(2.0/511.0);
                position+=moved*weight.x;
                n+=normal*weight.x;
                t+=turned*weight.x;
                old_position+=moved*weight.y;
            }
            n=dot(n,n)>1e-20?normalize(n):rest.normal;
            t-=n*dot(n,t);
            if (dot(t,t)>1e-20) tangent.xyz=normalize(t);
        }
        float3 cof0=cross(rows[1].xyz,rows[2].xyz);
        float3 cof1=cross(rows[2].xyz,rows[0].xyz);
        float3 cof2=cross(rows[0].xyz,rows[1].xyz);
        float determinant=dot(rows[0].xyz,cof0);
        float3 normal=float3(dot(cof0,n),dot(cof1,n),dot(cof2,n));
        if (dot(normal,normal)>1e-20) n=normalize(normal)*(determinant<0?-1.0:1.0);
        uint packed_normal=packSnorm2x16(oct_encode(n));
        // The tangent is a direction along the surface: it goes with the rows, and
        // a reflection turns the side its bitangent is on.
        float3 t=float3(dot(rows[0].xyz,tangent.xyz),dot(rows[1].xyz,tangent.xyz),dot(rows[2].xyz,tangent.xyz));
        uint packed_tangent=pack_tangent(dot(t,t)>1e-20?normalize(t):tangent.xyz,determinant<0?-tangent.w:tangent.w);
        Posed_Vertex now,before;
        now.position=transform_point(rows,position);now.normal=packed_normal;now.tangent=packed_tangent;
        before.position=transform_point(old_rows,old_position);before.normal=packed_normal;before.tangent=packed_tangent;
        posed_store(params.output,index,now);
        posed_store(params.previous,index,before);
        skin_positions[local]=now.position;
    }
    if (params.bounds==INVALID) return;
    GroupMemoryBarrierWithGroupSync();
    if (lane.x!=0u) return;
    float3 low=float3(FLT_MAX),high=float3(-FLT_MAX);
    for (uint v=0;v<cluster_vertex_count(c);++v) {low=min(low,skin_positions[v]);high=max(high,skin_positions[v]);}
    low-=params.reach;high+=params.reach;
    // The cone as the import makes it (asset.cluster_cone): the axis the sum
    // of the normals of the triangles, stored in snorm8, and the sine of how
    // far they spread from the stored axis, rounded up.
    float3 sum=float3(0);
    for (uint t=0;t<cluster_triangle_count(c);++t) {
        uint3 corners=cluster_triangle(mesh,c,t);
        float3 face=cross(skin_positions[corners.y]-skin_positions[corners.x],skin_positions[corners.z]-skin_positions[corners.x]);
        if (dot(face,face)>1e-40) sum+=normalize(face);
    }
    uint flags=1u;
    uint packed_axis=0u;
    if (params.reach==0.0 && dot(sum,sum)>1e-12) {
        int2 packed=int2(round(clamp(oct_encode(normalize(sum)),-1.0,1.0)*127.0));
        float3 stored=oct_decode(max(float2(packed)/127.0,float2(-1.0)));
        float least=1.0;
        for (uint t=0;t<cluster_triangle_count(c);++t) {
            uint3 corners=cluster_triangle(mesh,c,t);
            float3 face=cross(skin_positions[corners.y]-skin_positions[corners.x],skin_positions[corners.z]-skin_positions[corners.x]);
            if (dot(face,face)>1e-40) least=min(least,dot(stored,normalize(face)));
        }
        float cutoff=ceil(sqrt(max(1.0-least*least,0.0))*127.0);
        if (least>0.0 && cutoff<127.0) {
            flags|=2u|(uint(int(cutoff))&255u)<<8u;
            packed_axis=(uint(packed.x)&255u)|((uint(packed.y)&255u)<<8u);
        }
    }
    uint at=params.bounds+group.x*POSED_BOUNDS_WORDS;
    vertex_words[at]=asuint(low.x);vertex_words[at+1u]=asuint(low.y);vertex_words[at+2u]=asuint(low.z);vertex_words[at+3u]=flags;
    vertex_words[at+4u]=asuint(high.x);vertex_words[at+5u]=asuint(high.y);vertex_words[at+6u]=asuint(high.z);vertex_words[at+7u]=packed_axis;
}
