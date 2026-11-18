// What the two cull passes share (cull.comp by instance, cull_clusters.comp by
// cluster): their parameters, the state of the view they count in
// (render.Gpu_Cull_State), the chunks one hands the other, and the tests of a
// box against the frustum and the depth pyramid.
#ifndef MIRAI_CULL_COMMON_SLANG
#define MIRAI_CULL_COMMON_SLANG

struct Params_Block {
    uint phase;
    uint occlusion;          // 1: depth pyramid test enabled for this phase
    uint hiz_levels;
    uint programs;           // bins of the clusters of Surface programs: the largest program id, plus one (0: none)
    uint4 glass_groups;      // dispatch size of the glass passes: xy at render resolution, zw at half
    uint chunk_capacity;
    uint visible_capacity;   // of the visible list, both phases together
    uint candidate_capacity; // of the clusters phase 0 found hidden
    uint program_capacity;   // of the clusters of Surface programs, both phases together
    // The slots of the pages of streamed meshes (render.Pages_State): x their
    // first word in the vertex pool, y how many (0: none), z the stamp of the
    // frame, w the capacity of the list of requests (0: none).
    uint4 pages;
};
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);

// Words of render.Gpu_Cull_State.
#define CULL_DRAW0 0u               // the draw of phase 0: vertices, instances (its visible clusters), first vertex, first instance
#define CULL_DRAW1 4u               // that of phase 1, whose first instance follows those of phase 0
#define CULL_CHUNK_DISPATCH 8u
#define CULL_CHUNK_COUNT 11u
#define CULL_CANDIDATE_DISPATCH 12u
#define CULL_CANDIDATE_COUNT 15u
#define CULL_VISIBLE_COUNT 16u      // of each phase, before its capacity
#define CULL_DROPPED 18u            // chunks, visible clusters, candidates and clusters of programs past their capacities
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

// True when the box is entirely behind the farthest depth stored in the
// pyramid over its screen footprint. Conservative: anything touching the
// near plane or the screen border counts as visible. depth_plane gives the
// linear depth of a point for the camera of view_proj, which takes a point
// from eye.
bool occluded(float3 bmin, float3 bmax, float4x4 view_proj, float3 eye, float4 depth_plane) {
    float2 lo = float2(1.0), hi = float2(0.0);
    float nearest = FLT_MAX;
    for (int i = 0; i < 8; i++) {
        float3 corner = float3((i & 1) != 0 ? bmax.x : bmin.x, (i & 2) != 0 ? bmax.y : bmin.y, (i & 4) != 0 ? bmax.z : bmin.z);
        float4 clip = mul(view_proj, float4(corner - eye, 1.0));
        float depth = dot(depth_plane.xyz, corner) + depth_plane.w;
        if (depth <= frame.camera_position.w || clip.w <= 0.0) return false;
        float2 ndc = clip.xy / clip.w;
        float2 uv = float2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
        lo = min(lo, uv);
        hi = max(hi, uv);
        nearest = min(nearest, depth);
    }
    lo = clamp(lo, float2(0.0), float2(1.0));
    hi = clamp(hi, float2(0.0), float2(1.0));
    if (any(((lo) >= (hi)))) return false;
    // Footprint in render pixels, widened by one pixel because the pyramid
    // was rasterized with TAA jitter while this test projects without it.
    float2 px_lo = max(lo * frame.resolution - 1.0, float2(0.0));
    float2 px_hi = min(hi * frame.resolution + 1.0, frame.resolution - 1.0);
    int2 base_size = texture_size(hiz, 0);
    float2 extent = (px_hi - px_lo) * 0.5; // level 0 is half resolution
    int level = clamp(int(ceil(log2(max(max(extent.x, extent.y), 1.0)))), 0, int(params.hiz_levels) - 1);
    // Sizes derive from level 0 (dynamic-LOD size queries are unreliable on
    // some drivers). Texel j of level L covers pixels [j, j+1) * 2^(L+1); the
    // last texel also folds in the odd remainder, so map pixels, not UVs.
    int2 level_size = max(base_size >> level, int2(1));
    int2 a = min(int2(px_lo) >> (level + 1), level_size - 1);
    int2 b = min(int2(px_hi) >> (level + 1), level_size - 1);
    float farthest = 0.0;
    for (int y = a.y; y <= b.y; y++) {
        for (int x = a.x; x <= b.x; x++) {
            farthest = max(farthest, hiz.Load(int3(int2(x, y), level)).r);
        }
    }
    return nearest > farthest;
}
#endif
