// What the two cull passes share (cull.comp by instance, cull_clusters.comp by
// cluster): their parameters, the state of the view they count in
// (render.Gpu_Cull_State), the chunks one hands the other, and the tests of a
// box against the frustum and the depth pyramid.
#ifndef MIRAI_CULL_COMMON_SLANG
#define MIRAI_CULL_COMMON_SLANG
#include "pyramid.slang"

struct Params_Block {
    uint phase;
    uint occlusion;          // 1: depth pyramid test enabled for this phase
    uint hiz_levels;
    uint programs;           // the Surface programs whose resolve draws a cluster turns on: the largest program id, plus one (0: none)
    uint4 glass_groups;      // dispatch size of the glass passes: xy at render resolution, zw at half
    uint chunk_capacity;
    uint visible_capacity;   // of the visible list, both phases together
    uint candidate_capacity; // of the clusters phase 0 found hidden
    uint pad;
    // The slots of the pages of streamed meshes (render.Pages_State): x their
    // first word in the vertex pool, y how many (0: none), z the stamp of the
    // frame, w the capacity of the list of requests (0: none).
    uint4 pages;
};
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);

// The words of render.Gpu_Cull_State: CULL_* of the shared constants.
#include "cull_bins.slang"
[[vk::binding(SLOT_PASS0, 0)]] RWStructuredBuffer<uint> cull_state : register(MIRAI_REGISTER(u, SLOT_PASS0), space0);
#include "cull_stats.slang"
// What an instance is, for the counts of the frame: of the scene with a mesh
// of levels, of the scene with a mesh of one (terrain pieces and other meshes
// made at run time), or of a batch.
#define CULL_KIND_LEVELS 0u
#define CULL_KIND_SINGLE 1u
#define CULL_KIND_BATCH 2u
uint cull_kind(bool batched, Mesh mesh) { return batched ? CULL_KIND_BATCH : mesh.level_count > 1u ? CULL_KIND_LEVELS : CULL_KIND_SINGLE; }
[[vk::binding(SLOT_PASS1, 0)]] RWStructuredBuffer<Stats_Block> stats : register(MIRAI_REGISTER(u, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] Texture2D<float4> hiz : register(MIRAI_REGISTER(t, SLOT_PASS2), space0);
// Up to CULL_CHUNK clusters of an instance: x the instance, y its first cluster << 6 | how many - 1.
[[vk::binding(SLOT_PASS5, 0)]] RWStructuredBuffer<uint2> chunks : register(MIRAI_REGISTER(u, SLOT_PASS5), space0);

bool frustum_visible(float3 bmin, float3 bmax) {
    for (int i = 0; i < 6; i++) {
        float4 plane = frame.frustum[i];
        float3 positive = lerp(bmin, bmax, step(float3(0.0), plane.xyz));
        if (dot(plane.xyz, positive) + plane.w < 0.0) return false;
    }
    return true;
}

// True when the box is entirely behind the farthest depth the pyramid of the
// pass holds over its footprint (pyramid.slang).
bool occluded(float3 bmin, float3 bmax, float4x4 view_proj, float3 eye, float4 depth_plane) {
    return pyramid_hides(hiz, params.hiz_levels, bmin, bmax, view_proj, eye, depth_plane);
}
#endif
