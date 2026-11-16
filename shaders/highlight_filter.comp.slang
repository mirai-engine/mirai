#include "native.slang"
#include "scene.slang"
#include "highlight.slang"
// Spatial filter of the outlines, once per window point. The unjittered mask
// has no history: camera motion, TAA and render downscaling cannot move its edge.
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1
#define OUTLINE_LEVELS (HIGHLIGHT_LEVELS + OUTLINE_STYLES)
[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> highlight_mask : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> scene_depth : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] [[vk::image_format("rgba8")]] RWTexture2D<float4> filtered : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);
struct Params_Block {
    float4 colors[32]; // of each level (rgb, a = opacity)
    float4 fill[8];    // opacity of a flat coat of each level (0: it is outlined)
    float4 behind[8];  // what of each level shows behind other surfaces
    float4 widths;     // glow radius in window points: x of the editor's levels, y of the game's (0: not drawn); z the highest outlined rank
    uint4 region;      // offset xy and size zw; no work outside conservative bounds
};
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
uint editor_rank(uint level) { return level == 3u ? 15u : (level == 1u ? 14u : (level == 2u ? 13u : (level == 4u ? 1u : (level >= 5u && level <= 15u ? 17u - level : 0u)))); }
uint editor_level(uint r) { return r == 15u ? 3u : (r == 14u ? 1u : (r == 13u ? 2u : (r == 1u ? 4u : (r >= 2u && r <= 12u ? 17u - r : 0u)))); }
// The game's styles rank below every level of the editor (render.highlight_rank).
uint rank(uint level) { return level > HIGHLIGHT_LEVELS ? (level <= OUTLINE_LEVELS ? OUTLINE_LEVELS + 1u - level : 0u) : (level > 0u ? editor_rank(level) + OUTLINE_STYLES : 0u); }
uint level(uint r) { return r > OUTLINE_STYLES ? editor_level(r - OUTLINE_STYLES) : (r > 0u ? OUTLINE_LEVELS + 1u - r : 0u); }
bool is_game(uint r) { return r > 0u && r <= OUTLINE_STYLES; }
float fill(uint l) { uint i = l - 1u; return params.fill[i / 4u][i % 4u]; }
float width(uint l) { return l > HIGHLIGHT_LEVELS ? params.widths.y : params.widths.x; }
float2 mask_at(float2 p) {
    int2 size = texture_size(highlight_mask, 0);
    return highlight_mask.Load(int3(clamp(int2(floor(p)), int2(0), size - 1), 0)).xy;
}
// The level at p, 0 where none or where its style is not drawn.
uint drawn_level(float2 p) {
    uint l = uint(mask_at(p).x + 0.5);
    return l == 0u || l > OUTLINE_LEVELS || width(l) <= 0.0 ? 0u : l;
}
uint outline_rank(float2 p) {
    uint l = drawn_level(p);
    return l == 0u || fill(l) > 0.0 ? 0u : rank(l);
}
float visibility(float2 p, float depth, uint l) {
    float2 mask_size = float2(texture_size(highlight_mask, 0));
    if (!highlight_behind(depth, highlight_seen_depth(scene_depth, p, mask_size))) return 1.0;
    uint i = l - 1u;
    return params.behind[i / 4u][i % 4u];
}
static const float2 DIRECTIONS[8] = {float2(1,0),float2(0.707107,0.707107),float2(0,1),float2(-0.707107,0.707107),float2(-1,0),float2(-0.707107,-0.707107),float2(0,-1),float2(0.707107,-0.707107)};
float4 coat(float2 p) {
    float2 m = mask_at(p);
    uint own_level = drawn_level(p);
    if (own_level > 0u && fill(own_level) > 0.0) {
        float a = fill(own_level) * visibility(p, m.y, own_level);
        return float4(params.colors[own_level - 1u].rgb * a, a);
    }
    uint own = rank(own_level);
    if (own > 0u) {
        for (int k=0; k<8; ++k) {
            if (outline_rank(p + DIRECTIONS[k]) < own) {
                float4 c = params.colors[own_level - 1u];
                float a = c.a * visibility(p, m.y, own_level);
                return float4(c.rgb * a, a);
            }
        }
        if (own >= uint(params.widths.z + 0.5)) return float4(0);
    }
    uint best = 0u;
    float glow = 0.0;
    float2 nearest = p;
    // Two eight-direction rings at the radius of each style; one read serves
    // both when their radii match. Once an interior pixel finds no higher
    // rank, no depth reads are needed.
    bool shared = params.widths.x == params.widths.y;
    for (int ring=1; ring<=2; ++ring) {
        float weight = ring == 1 ? 0.8 : 0.2;
        for (int k=0; k<8; ++k) {
            for (int side=0; side<2; ++side) {
                float radius = side == 0 ? params.widths.x : params.widths.y;
                if (radius <= 0.0 || (side == 1 && shared)) continue;
                float2 q = p + DIRECTIONS[k] * radius * float(ring) * 0.5;
                uint r = outline_rank(q);
                if (!shared && is_game(r) != (side == 1)) continue;
                if (r > own && (r > best || (r == best && weight > glow))) {best=r; glow=weight; nearest=q;}
            }
        }
    }
    if (best == 0u) return float4(0);
    uint l = level(best);
    float4 c = params.colors[l - 1u];
    float a = c.a * glow * visibility(nearest, mask_at(nearest).y, l);
    return float4(c.rgb * a, a);
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    uint2 local = dispatch_id.xy;
    if (any(((local) >= (params.region.zw)))) return;
    int2 p = int2(local + params.region.xy);
    filtered[p] = coat(float2(p) + 0.5);
}
