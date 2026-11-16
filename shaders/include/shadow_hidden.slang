// Whether the cache of the maps of the shadows hides a box of the world in a
// page of a map (shadow_hiz.comp): the nearest the box comes to the light lies
// past the farthest the cache holds over the blocks of the page it covers,
// read at the mip where it covers no more than 2x2 of them. What the cache
// holds there is then nearer than all of the box, which shows nowhere in it.
#ifndef MIRAI_SHADOW_HIDDEN_SLANG
#define MIRAI_SHADOW_HIDDEN_SLANG
bool shadow_box_hidden(Texture2D<float4> hiz, Shadow_Map m, uint2 page, uint pool, float3 low, float3 high) {
    float2 lo = float2(FLT_MAX, FLT_MAX), hi = -float2(FLT_MAX, FLT_MAX);
    float nearest = 0.0;
    for (uint corner = 0u; corner < 8u; corner++) {
        float3 p = float3((corner & 1u) != 0u ? high.x : low.x, (corner & 2u) != 0u ? high.y : low.y, (corner & 4u) != 0u ? high.z : low.z);
        float3 local = shadow_map_local(m, p);
        if (local.z <= m.near) return false;
        float4 clip = shadow_map_clip(m, local);
        // Reversed depth: the nearest is the greatest.
        nearest = max(nearest, clip.z / clip.w);
        float2 unit = clip.xy / clip.w;
        float2 at = float2(unit.x * 0.5 + 0.5, 0.5 - unit.y * 0.5) * float(m.rect.z);
        lo = min(lo, at);
        hi = max(hi, at);
    }
    // Its texels within the page, from the corner of the page.
    float2 corner = float2(page * SHADOW_PAGE);
    lo = clamp(lo - corner, 0.0, float(SHADOW_PAGE) - 1.0);
    hi = clamp(hi - corner, 0.0, float(SHADOW_PAGE) - 1.0);
    uint2 first = uint2(lo), last = uint2(hi);
    uint mip = 0u;
    while (mip + 1u < SHADOW_HIZ_MIPS && any((last >> (3u + mip)) - (first >> (3u + mip)) > 1u)) mip++;
    uint2 base = shadow_pool_corner(pool) / (SHADOW_HIZ_BLOCK << mip);
    float farthest = 1.0;
    for (uint y = first.y >> (3u + mip); y <= last.y >> (3u + mip); y++) {
        for (uint x = first.x >> (3u + mip); x <= last.x >> (3u + mip); x++) farthest = min(farthest, hiz.Load(int3(int2(base + uint2(x, y)), int(mip))).r);
    }
    return nearest < farthest;
}
#endif
