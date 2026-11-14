// The test of a box against a depth pyramid of the view (hiz.comp): the
// culls of the scene (cull_common.slang) and the passes of extensions in the
// Gbuffer stage (render.pass_depth_pyramid) take it.
#ifndef MIRAI_PYRAMID_SLANG
#define MIRAI_PYRAMID_SLANG
#include "scene.slang"

// True when the box is entirely behind the farthest depth stored in the
// pyramid over its screen footprint. Conservative: anything touching the
// near plane or the screen border counts as visible. depth_plane gives the
// linear depth of a point for the camera of view_proj, which takes a point
// from eye. levels: of the pyramid.
bool pyramid_hides(Texture2D<float4> pyramid, uint levels, float3 bmin, float3 bmax, float4x4 view_proj, float3 eye, float4 depth_plane) {
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
    int2 base_size = texture_size(pyramid, 0);
    float2 extent = (px_hi - px_lo) * 0.5; // level 0 is half resolution
    int level = clamp(int(ceil(log2(max(max(extent.x, extent.y), 1.0)))), 0, int(levels) - 1);
    // Sizes derive from level 0 (dynamic-LOD size queries are unreliable on
    // some drivers). Texel j of level L covers pixels [j, j+1) * 2^(L+1); the
    // last texel also folds in the odd remainder, so map pixels, not UVs.
    int2 level_size = max(base_size >> level, int2(1));
    int2 a = min(int2(px_lo) >> (level + 1), level_size - 1);
    int2 b = min(int2(px_hi) >> (level + 1), level_size - 1);
    float farthest = 0.0;
    for (int y = a.y; y <= b.y; y++) {
        for (int x = a.x; x <= b.x; x++) {
            farthest = max(farthest, pyramid.Load(int3(int2(x, y), level)).r);
        }
    }
    return nearest > farthest;
}
#endif
