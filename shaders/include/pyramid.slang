// The test of a box against a depth pyramid of the view (hiz.comp): the
// culls of the scene (cull_common.slang) and the passes of extensions in the
// Gbuffer stage (render.pass_depth_pyramid) take it.
#ifndef MIRAI_PYRAMID_SLANG
#define MIRAI_PYRAMID_SLANG
#include "scene.slang"

// The finest level of the pyramid at which `texels` (of level 0, inclusive)
// span at most `footprint` texels along each axis: two texels of level k
// cover 2^(k+1) of level 0, and where the footprint straddles the edges of
// the texels of that level one level coarser always holds it.
int pyramid_level_for(int4 texels, int footprint) {
    int2 span = texels.zw - texels.xy;
    int level = max(max(int(firstbithigh(uint(span.x))), int(firstbithigh(uint(span.y)))) - (int(firstbithigh(uint(footprint))) - 1), 0);
    if (any((texels.zw >> level) - (texels.xy >> level) > footprint - 1)) level++;
    return level;
}

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
    // At the level where it spans at most 4x4 texels: texel j of level L
    // covers pixels j * 2^(L+1) to (j + 1) * 2^(L+1), the last one those of
    // the view that are left (hiz.comp).
    int4 texels = int4(int2(px_lo), int2(px_hi)) >> 1;
    int level = min(pyramid_level_for(texels, 4), int(levels) - 1);
    int2 level_size = (int2(frame.resolution) + ((2 << level) - 1)) >> (level + 1);
    int2 a = min(texels.xy >> level, level_size - 1);
    int2 b = min(texels.zw >> level, level_size - 1);
    float farthest = 0.0;
    for (int y = a.y; y <= b.y; y++) {
        for (int x = a.x; x <= b.x; x++) {
            farthest = max(farthest, pyramid.Load(int3(int2(x, y), level)).r);
        }
    }
    return nearest > farthest;
}
#endif
