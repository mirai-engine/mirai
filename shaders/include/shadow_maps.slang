// The maps of the shadows of the lights that light much of the view
// (render.shadow_maps_pass): a light rasterized has a map for each face of
// the cube around it through which it lights what the view sees, fitted to
// that, and the sun one for each of its levels around the eye; each lies in
// a slot, its pages where the table of the pages says (shadow_pages.slang). The samples of the direct light read them
// first (direct_samples.comp): where the taps around a point agree it is lit
// or hidden; where they disagree, at a penumbra, it takes the hard shadow of
// the map, which direct_spread.comp averages over the width of the penumbra.
// The lights without maps trace rays.
#ifndef MIRAI_SHADOW_MAPS_SLANG
#define MIRAI_SHADOW_MAPS_SLANG
#include "scene.slang"
#include "shadow_pages.slang"

// SHADOW_MAP_ROWS, SHADOW_LIGHT_FACES: the buffer of the maps (render/abi);
// the clusters they draw, shadow_cull.slang. The side of the atlas, texels,
// is Frame.sun_maps.z.
// The width of what a ray reads of a material over how far it came
// (hit_covers): a fragment of a map reads its material as coarsely as a texel.
#define SHADOW_TESTED_FOOTPRINT 0.004

struct Shadow_Map {
    float3 origin;
    float near;
    float3 right;
    float far;
    float3 up;
    uint kind;     // SHADOW_MAP_ORTHOGRAPHIC, or 0 for a perspective from origin
    float3 forward;
    float skip;    // nearer than this along it lies the body of the light, metres
    float4 span;   // perspective: x / z and y / z, low then high; orthographic: x and y, metres
    uint4 rect;    // its slot; the column and row of the table of its first page (shadow_page_entry) and its mip << 16; its side at that mip, texels; its light (INVALID: the sun)
};

// A map from its SHADOW_MAP_ROWS rows.
Shadow_Map shadow_map_from(uint4 a, uint4 b, uint4 c, uint4 d, uint4 e, uint4 f) {
    Shadow_Map m;
    m.origin = asfloat(a.xyz);
    m.near = asfloat(a.w);
    m.right = asfloat(b.xyz);
    m.far = asfloat(b.w);
    m.up = asfloat(c.xyz);
    m.kind = c.w;
    m.forward = asfloat(d.xyz);
    m.skip = asfloat(d.w);
    m.span = asfloat(e);
    m.rect = f;
    return m;
}

Shadow_Map shadow_map_at(StructuredBuffer<uint4> data, uint rows, uint map) {
    uint at = rows + map * SHADOW_MAP_ROWS;
    return shadow_map_from(data[at], data[at + 1u], data[at + 2u], data[at + 3u], data[at + 4u], data[at + 5u]);
}

uint shadow_light_word(StructuredBuffer<uint4> data, uint light) {
    return data[light >> 2u][light & 3u];
}

// A map at another of its mips: its side, texels, halves with each.
Shadow_Map shadow_map_mip(Shadow_Map m, uint mip) {
    m.rect.y = (m.rect.y & 0xFFFFu) | (mip << 16u);
    m.rect.z = SHADOW_MAP_SIDE >> mip;
    return m;
}

bool shadow_map_orthographic(Shadow_Map m) { return m.kind == SHADOW_MAP_ORTHOGRAPHIC; }

// A point of the world on the axes of a map: x right, y up, z along it.
float3 shadow_map_local(Shadow_Map m, float3 world) {
    float3 v = world - m.origin;
    return float3(dot(v, m.right), dot(v, m.up), dot(v, m.forward));
}

// Where a point on the axes of a map falls on its span, from -1 to 1.
float2 shadow_map_unit(Shadow_Map m, float3 local) {
    float2 at = shadow_map_orthographic(m) ? local.xy : local.xy / max(local.z, 1e-6);
    return (2.0 * at - (m.span.xy + m.span.zw)) / (m.span.zw - m.span.xy);
}

// The clip coordinates of a point on the axes of a map: reversed depth, 1 at
// near and 0 at far.
float4 shadow_map_clip(Shadow_Map m, float3 local) {
    if (shadow_map_orthographic(m)) {
        float2 xy = (2.0 * local.xy - (m.span.xy + m.span.zw)) / (m.span.zw - m.span.xy);
        return float4(xy, (m.far - local.z) / (m.far - m.near), 1.0);
    }
    float x = (2.0 * local.x - (m.span.x + m.span.z) * local.z) / (m.span.z - m.span.x);
    float y = (2.0 * local.y - (m.span.y + m.span.w) * local.z) / (m.span.w - m.span.y);
    return float4(x, y, (m.far - local.z) * m.near / (m.far - m.near), local.z);
}

// How far along a map the depth it holds is.
float shadow_map_distance(Shadow_Map m, float depth) {
    if (shadow_map_orthographic(m)) return m.far - depth * (m.far - m.near);
    return m.near * m.far / (depth * (m.far - m.near) + m.near);
}

// How wide a texel of a map is `z` along it, metres.
float shadow_map_texel(Shadow_Map m, float z) {
    float across = (m.span.z - m.span.x) / float(max(m.rect.z, 1u));
    return shadow_map_orthographic(m) ? across : across * z;
}

// Whether a box of the world reaches into the frustum of a map.
bool shadow_box_side(float3 low, float3 high, float3 n, float offset) {
    return dot(n, select(n >= 0.0, high, low)) + offset >= 0.0;
}
bool shadow_map_reaches(Shadow_Map m, float3 low, float3 high) {
    // The box on the axes of the map, about its center.
    float3 center = 0.5 * (low + high) - m.origin;
    float3 half = 0.5 * (high - low);
    float3 c = float3(dot(center, m.right), dot(center, m.up), dot(center, m.forward));
    float3 e = float3(dot(half, abs(m.right)), dot(half, abs(m.up)), dot(half, abs(m.forward)));
    float3 lo = c - e, hi = c + e;
    if (hi.z < m.near || lo.z > m.far) return false;
    if (shadow_map_orthographic(m)) return hi.x >= m.span.x && lo.x <= m.span.z && hi.y >= m.span.y && lo.y <= m.span.w;
    // The four sides of the pyramid, on the axes of the map.
    return shadow_box_side(lo, hi, float3(1.0, 0.0, -m.span.x), 0.0) && shadow_box_side(lo, hi, float3(-1.0, 0.0, m.span.z), 0.0)
        && shadow_box_side(lo, hi, float3(0.0, 1.0, -m.span.y), 0.0) && shadow_box_side(lo, hi, float3(0.0, -1.0, m.span.w), 0.0);
}

// The pages of a map a box of the world covers from the light, the first
// column and row then the last (render.shadow_page_rect); false where it
// covers none. A box that reaches the plane of a perspective one covers all.
bool shadow_page_rect(Shadow_Map m, float3 low, float3 high, out uint4 rect) {
    uint last = m.rect.z / SHADOW_PAGE - 1u;
    rect = uint4(0u, 0u, last, last);
    float2 lo = float2(FLT_MAX, FLT_MAX), hi = -float2(FLT_MAX, FLT_MAX);
    for (uint corner = 0u; corner < 8u; corner++) {
        float3 p = float3((corner & 1u) != 0u ? high.x : low.x, (corner & 2u) != 0u ? high.y : low.y, (corner & 4u) != 0u ? high.z : low.z);
        float3 local = shadow_map_local(m, p);
        float2 at = local.xy;
        if (!shadow_map_orthographic(m)) {
            if (local.z <= m.near * 0.5) return true;
            at /= local.z;
        }
        lo = min(lo, at);
        hi = max(hi, at);
    }
    float side = float(m.rect.z);
    float x0 = (lo.x - m.span.x) / (m.span.z - m.span.x) * side, x1 = (hi.x - m.span.x) / (m.span.z - m.span.x) * side;
    float y0 = (m.span.w - hi.y) / (m.span.w - m.span.y) * side, y1 = (m.span.w - lo.y) / (m.span.w - m.span.y) * side;
    if (x1 < 0.0 || y1 < 0.0 || x0 >= side || y0 >= side) return false;
    float end = float((last + 1u) * SHADOW_PAGE) - 1.0;
    rect = uint4(uint(clamp(x0, 0.0, end)), uint(clamp(y0, 0.0, end)), uint(clamp(x1, 0.0, end)), uint(clamp(y1, 0.0, end))) / SHADOW_PAGE;
    return true;
}

// The taps of a map around a point that find its blockers; the most texels
// they reach, as wide as the penumbrae of large lights near what they light;
// and the least half width of a penumbra, texels, so that the edge of what
// hides itself, where it turns from the light, does not show the texels of
// the map. Each is of the texel of the level or mip a point takes, and grows
// with where the point lies in it (Shadow_Taps.grow).
#define SHADOW_TAPS 12u
#define SHADOW_SEARCH_MAX 64.0
// A point stretched wider than its penumbra: the taps over its ellipse, and
// how far along its long axis it reaches, texels, over the point and the
// jitter of the view around it (SHADOW_WIDE_COVER points).
#define SHADOW_WIDE_TAPS 24u
#define SHADOW_WIDE_MAX 256.0
#define SHADOW_WIDE_COVER 1.5
#define SHADOW_PENUMBRA_MIN 1.5
// How far off its surface a point is read, texels, so that it does not hide itself.
#define SHADOW_NORMAL_OFFSET 1.5
// The least cosine between a surface and the view the stretch of a point takes.
#define SHADOW_FACING_MIN 0.002
// The least cosine between a surface and the light the slope of its plane takes.
#define SHADOW_SLOPE_FACING 0.05
// How far from the border of a level of the sun a point it holds lies, texels.
#define SHADOW_LEVEL_MARGIN SHADOW_SEARCH_MAX
// The top of each octave of the levels of the sun over which a point blends
// its level with the next, so that no line shows where they meet.
#define SHADOW_LEVEL_BAND 0.2

// Where a point at position with normal n reads map m of a light (the sun
// for sun), towards the light along `toward` (shadow_map_seen of
// direct_maps.comp): its texel, the depth along the map of its surface and
// how that goes over the texels around it by its plane, and the radii of the
// ellipse its taps cover, texels, its first along axis. radius: of the light,
// metres, or the angle of the sun; across: the width of the point across the
// view, metres; grow: how many of its texels each texel-based constant
// takes, from 1 at the finest end of its level to 2 at the coarsest
// (sun_pick). False where the point turns from the light, or lies past the
// square of a map of the sun: no tap reads it.
struct Shadow_Taps {
    float2 texel;
    float2 radii;
    float2 axis;
    float d, step, bias, skip, covered, c, grow;
    float2 slope;
};
bool shadow_map_point(Shadow_Map m, bool sun, float3 toward, float3 position, float3 n, float radius, float grow, out Shadow_Taps t) {
    t = (Shadow_Taps)0;
    t.grow = grow;
    t.c = dot(n, toward);
    if (!(t.c > 0.0) && any(n != 0.0)) return false;
    t.step = shadow_map_texel(m, shadow_map_local(m, position).z);
    // Off the surface, so that it does not hide itself; where that leaves the
    // face of the cube of a light, at the border of the face.
    float3 local = shadow_map_local(m, position + n * (SHADOW_NORMAL_OFFSET * grow * t.step));
    t.d = local.z;
    float2 unit = shadow_map_unit(m, local);
    if (any(abs(unit) >= 1.0)) {
        if (sun) return false;
        unit = clamp(unit, -0.9999, 0.9999);
    }
    t.texel = float2(unit.x * 0.5 + 0.5, 0.5 - unit.y * 0.5) * float(m.rect.z);
    // The plane of the surface on the axes of the map, along the ray of the
    // light through the point: how far its depth goes with a texel, in texels.
    float3 normal = float3(dot(n, m.right), dot(n, m.up), dot(n, m.forward));
    float3 ray = shadow_map_orthographic(m) ? float3(0.0, 0.0, 1.0) : float3(local.xy / max(local.z, 1e-6), 1.0);
    t.slope = float2(normal.x, -normal.y) / max(-dot(normal, ray), SHADOW_SLOPE_FACING * length(ray));
    // The depth of the map holds itself only by its precision, the farther the more.
    t.bias = 0.001 * t.d;
    // What lies nearer the light than this is its body, not what it shines past.
    t.skip = sun ? m.near : max(m.near, min(3.0 * radius, radius + 0.3));
    return true;
}
bool shadow_map_taps(Shadow_Map m, bool sun, float3 toward, float3 position, float3 n, float radius, float across, float grow, out Shadow_Taps t) {
    if (!shadow_map_point(m, sun, toward, position, n, radius, grow, t)) return false;
    // How far around the point a blocker may stand and still hide a part of
    // the light: at the nearest it may be.
    float reach = sun ? radius * max(t.d - t.skip, 0.0) : radius * max(t.d - t.skip, 0.0) / max(t.skip, 1e-3);
    float search = clamp(reach / t.step, (SHADOW_PENUMBRA_MIN + 1.0) * grow, SHADOW_SEARCH_MAX * grow);
    // The ellipse of the point in texels: its long axis along the way the view goes over the surface.
    float3 eye = normalize(frame.camera_position.xyz - position);
    float facing = abs(dot(n, eye));
    float3 along = eye - n * dot(eye, n);
    t.axis = float2(dot(along, m.right), -dot(along, m.up));
    t.axis = dot(t.axis, t.axis) > 1e-8 ? normalize(t.axis) : float2(1.0, 0.0);
    t.covered = min(SHADOW_WIDE_COVER * 0.5 * across / max(facing, SHADOW_FACING_MIN) / t.step, SHADOW_WIDE_MAX * grow);
    t.radii = float2(max(search, t.covered), max(search, min(0.5 * across / t.step, SHADOW_SEARCH_MAX * grow)));
    return true;
}

// The depth along the map of the surface of a point at an offset from its
// texel, texels, by its plane.
float shadow_surface(Shadow_Taps t, float2 off) { return t.d + dot(off, t.slope) * t.step; }

// Whether a blocker `b` along a map hides the surface of a point read at an
// offset from its texel, from a texel `coarser` levels or mips coarser than
// the point's: the depth the map holds of the surface at the middle of a
// texel is the plane there, nearer than where the offset falls by as much as
// the plane rises to it, which the bias takes twice, scaled to the texel.
bool shadow_blocks(Shadow_Taps t, float b, float2 off, uint coarser) {
    float2 middle = floor(t.texel + off) + 0.5 - t.texel;
    float rise = 2.0 * max(dot(off - middle, t.slope), 0.0) * t.step * float(1u << coarser);
    return b > t.skip && b < shadow_surface(t, off) - rise - t.bias;
}

// The farthest from its texel the taps around a point read, texels, the
// texels around each that a hard shadow blends included.
float shadow_taps_reach(Shadow_Taps t) {
    return max(max(t.radii.x, t.radii.y), max(SHADOW_WIDE_COVER * 0.5 * t.radii.y, t.covered)) + 2.0;
}


// Level k of the sun (Frame.sun_maps.x of them, the finest first).
Shadow_Map sun_level(uint k) {
    uint row = k * SHADOW_MAP_ROWS;
    return shadow_map_from(frame.sun_map_rows[row], frame.sun_map_rows[row + 1u], frame.sun_map_rows[row + 2u],
                           frame.sun_map_rows[row + 3u], frame.sun_map_rows[row + 4u], frame.sun_map_rows[row + 5u]);
}
uint sun_levels() { return min(frame.sun_maps.x, uint(SHADOW_SUN_MAPS)); }

// Whether level k of the sun holds a point with room for the taps around it.
bool sun_map_at(uint k, float3 position, out Shadow_Map m) {
    m = sun_level(k);
    float3 local = shadow_map_local(m, position);
    float2 unit = shadow_map_unit(m, local);
    float2 at = float2(unit.x * 0.5 + 0.5, 0.5 - unit.y * 0.5) * float(m.rect.z);
    return all(at >= SHADOW_LEVEL_MARGIN) && all(at < float(m.rect.z) - SHADOW_LEVEL_MARGIN) && local.z < m.far;
}

// The level of the sun a point takes, the finest that holds it with room
// for its taps, which the marks of the points draw; false where none does,
// or the view drew none.
bool sun_map_of(float3 position, out Shadow_Map m) {
    uint count = sun_levels();
    for (uint k = 0u; k < count; k++) {
        if (sun_map_at(k, position, m)) return true;
    }
    m = (Shadow_Map)0;
    return false;
}

// The level of the sun a point takes, and the next it blends with, by its
// width across the view: the one whose texel is about as wide, between its
// width and twice it, else the finest that holds it with room for its taps.
// Over the top SHADOW_LEVEL_BAND of each octave the point blends into the
// next level, by blend; grow: how the texel-based constants of its level
// grow over it, so that they meet those of the next where it begins. across
// 0: the finest level that holds the point.
struct Sun_Pick {
    uint level;
    float blend, grow;
};
bool sun_pick(float3 position, float across, out Sun_Pick pick) {
    pick = (Sun_Pick)0;
    pick.grow = 1.0;
    uint count = sun_levels();
    if (count == 0u) return false;
    float level = log2(max(across, 1e-9) / shadow_map_texel(sun_level(0u), 0.0)) + 1.0;
    uint k = uint(clamp(floor(level), 0.0, float(count - 1u)));
    float within = saturate(level - float(k));
    Shadow_Map m;
    bool held = sun_map_at(k, position, m);
    for (; k + 1u < count && !held; k++) held = sun_map_at(k + 1u, position, m);
    if (!held) return false;
    pick.level = k;
    if (k != uint(clamp(floor(level), 0.0, float(count - 1u)))) return true;
    pick.grow = exp2(within);
    if (k + 1u < count && sun_map_at(k + 1u, position, m)) pick.blend = saturate((within - (1.0 - SHADOW_LEVEL_BAND)) / SHADOW_LEVEL_BAND);
    return true;
}

// Whether the maps give a point the light of the sun: its level holds it,
// or a coarser one drawn where its page is not (shadow_map_held); else rays do.
bool sun_map_given(float3 position, float across) {
    Sun_Pick pick;
    if (!sun_pick(position, across, pick)) return false;
    Shadow_Map m = sun_level(pick.level);
    return shadow_map_held(m, position);
}

// The map that holds a texel of map m a number of levels of the sun or mips
// coarser, and the texel there: the levels of the sun lie on one grid of the
// world, each page of one four of the one before, so the texel follows by
// whole numbers.
Shadow_Map shadow_map_coarser(Shadow_Map m, uint coarser, inout int2 texel) {
    if (m.rect.w != INVALID) {
        texel >>= int(coarser);
        return shadow_map_mip(m, shadow_rect_mip(m.rect) + coarser);
    }
    Shadow_Map c = sun_level(m.rect.x + coarser);
    float page = (m.span.z - m.span.x) / float(SHADOW_MAP_PAGES), wide = (c.span.z - c.span.x) / float(SHADOW_MAP_PAGES);
    int2 first = int2(round(m.span.xw / page)) * int(SHADOW_PAGE), held = int2(round(c.span.xw / wide)) * int(SHADOW_PAGE);
    // From the corner of the grid of the world: columns right, rows up.
    int2 world = int2(first.x + texel.x, first.y - 1 - texel.y) >> int(coarser);
    texel = int2(world.x - held.x, held.y - 1 - world.y);
    return c;
}

// The entry of the table a texel of map m lies at; false past its square.
bool shadow_texel_entry(Shadow_Map m, int2 texel, out uint e) {
    e = 0u;
    if (any(texel < 0) || any(texel >= int(m.rect.z))) return false;
    e = shadow_table_entry(m.rect.x, shadow_page_entry(m.rect, uint2(texel) / SHADOW_PAGE));
    return true;
}

// Where a texel of map m lies in the pool, by the table of the pages: in its
// own page drawn this frame, else in the nearest coarser one drawn
// (SHADOW_ENTRY_COARSER); held is the map that holds it, coarser how many
// levels or mips coarser it is. False where no page holds it.
bool shadow_texel(Shadow_Map m, int2 texel, out int2 at, out Shadow_Map held, out uint coarser) {
    at = int2(0);
    held = m;
    coarser = 0u;
    uint e;
    if (!shadow_texel_entry(m, texel, e)) return false;
    if (!shadow_entry_ready(e)) {
        coarser = (e >> SHADOW_ENTRY_COARSER) & 0xFu;
        if (coarser == 0u) return false;
        held = shadow_map_coarser(m, coarser, texel);
        if (!shadow_texel_entry(held, texel, e) || !shadow_entry_ready(e)) return false;
    }
    at = int2(shadow_pool_corner((e & SHADOW_ENTRY_POOL) - 1u)) + (texel & int(SHADOW_PAGE - 1u));
    return true;
}

// The map that holds a point at its texel: m where its page is drawn this
// frame, else the coarser one the table names; false where none is, and the
// light of the point is then traced.
bool shadow_map_held(inout Shadow_Map m, float3 position) {
    float2 unit = clamp(shadow_map_unit(m, shadow_map_local(m, position)), -0.9999, 0.9999);
    int2 texel = int2(floor(float2(unit.x * 0.5 + 0.5, 0.5 - unit.y * 0.5) * float(m.rect.z)));
    int2 at;
    Shadow_Map held;
    uint coarser;
    if (!shadow_texel(m, texel, at, held, coarser)) return false;
    m = held;
    return true;
}

#ifdef SUN_SHADOW_SLOT
// The atlas of the maps of the view (render.Surface_Source.Shadow_Atlas), for
// a pass that takes the shadows of the lights from it and not from rays.
[[vk::binding(SUN_SHADOW_SLOT, 0)]] Texture2D<float4> view_shadow_atlas : register(MIRAI_REGISTER(t, SUN_SHADOW_SLOT), space0);

// How far along map m the blocker a texel of it holds lies, through the page
// that holds it (shadow_texel); coarser: how many levels or mips coarser that
// page is. False where no page holds it: the texel tells nothing.
bool shadow_blocker(Shadow_Map m, int2 texel, out float b, out uint coarser) {
    b = 0.0;
    int2 at;
    Shadow_Map held;
    if (!shadow_texel(m, texel, at, held, coarser)) return false;
    b = shadow_map_distance(held, view_shadow_atlas.Load(int3(at, 0)).r) + dot(held.origin - m.origin, m.forward);
    return true;
}

// Whether the center of the light sees a point past what the 2x2 texels
// around its texel hold (shadow_map_point), blended between those a page holds.
float shadow_hard_seen(Shadow_Map m, Shadow_Taps t) {
    float2 corner = t.texel - 0.5;
    float2 first = floor(corner), f = corner - first;
    float seen = 0.0, total = 0.0;
    for (uint i = 0u; i < 4u; i++) {
        float2 at = first + float2(i & 1u, i >> 1u);
        float b;
        uint coarser;
        if (!shadow_blocker(m, int2(at), b, coarser)) continue;
        float weight = ((i & 1u) != 0u ? f.x : 1.0 - f.x) * ((i >> 1u) != 0u ? f.y : 1.0 - f.y);
        // Read at the middle of the texel, where the map holds the surface.
        seen += shadow_blocks(t, b, at + 0.5 - t.texel, coarser) ? 0.0 : weight;
        total += weight;
    }
    return total > 0.0 ? seen / total : 1.0;
}

// How much of the sun reaches a point past what the maps of the view hold;
// -1 where no level drawn holds the point, or the view drew none: a ray
// tells. n: the normal of its surface, zero for a point of a medium; across:
// its width, metres, which picks its level (sun_pick). blended: between the
// texels around the point, the border of a shadow as fine as the map; else
// by the texel it falls in alone, as the samples of the direct light tell a
// point lit (shadow_map_seen of direct_samples.comp).
float sun_shadow_seen(float3 position, float3 n, float across, bool blended = true) {
    Sun_Pick pick;
    if (!sun_pick(position, across, pick)) return -1.0;
    Shadow_Map m = sun_level(pick.level);
    Shadow_Taps t;
    if (!shadow_map_held(m, position)) return -1.0;
    if (!shadow_map_point(m, true, frame.sun_direction.xyz, position, n, 0.0, m.rect.x == pick.level ? pick.grow : 1.0, t)) return 1.0;
    if (blended) return shadow_hard_seen(m, t);
    float b;
    uint coarser;
    if (!shadow_blocker(m, int2(floor(t.texel)), b, coarser)) return -1.0;
    return shadow_blocks(t, b, float2(0.0), coarser) ? 0.0 : 1.0;
}
#endif

// The face of the cube around a light a direction from it falls on.
uint shadow_face_of(float3 v) {
    float3 a = abs(v);
    if (a.x >= a.y && a.x >= a.z) return v.x >= 0.0 ? 0u : 1u;
    if (a.y >= a.z) return v.y >= 0.0 ? 2u : 3u;
    return v.z >= 0.0 ? 4u : 5u;
}

#ifdef SHADOW_DATA_SLOT
// The buffer of the maps of the view (render.pass_shadow_data): the words of
// the lights, then the rows of the map of each slot from Frame.sun_maps.y.
[[vk::binding(SHADOW_DATA_SLOT, 0)]] StructuredBuffer<uint4> view_shadow_data : register(MIRAI_REGISTER(t, SHADOW_DATA_SLOT), space0);

// The map of local light `light` a point falls in, at the mip its face is
// read at; false where it has none on that side, or the point lies off the
// part of the face it was fitted to or past its depths, where its texels hold
// what lies elsewhere: rays tell there. A spot with one map along its cone
// (SHADOW_SPOT_FACE) has it for every point in its cone.
bool light_map_of(uint light, float3 position, out Shadow_Map m) {
    m = (Shadow_Map)0;
    if (frame.sun_maps.z == 0u) return false;
    uint word = shadow_light_word(view_shadow_data, light);
    if (word == 0u) return false;
    uint faces = word >> SHADOW_LIGHT_FACES;
    uint face = (faces & (1u << SHADOW_SPOT_FACE)) != 0u ? SHADOW_SPOT_FACE : shadow_face_of(position - lights[light].position_range.xyz);
    if ((faces & (1u << face)) == 0u) return false;
    m = shadow_map_at(view_shadow_data, frame.sun_maps.y, (word & 0xFFFFu) - 1u + face);
    float3 local = shadow_map_local(m, position);
    return local.z > m.near && local.z < m.far && all(abs(shadow_map_unit(m, local)) < 1.0);
}

#ifdef SUN_SHADOW_SLOT
// How much of local light `light` reaches a point past what its map holds, as
// sun_shadow_seen; -1 where no map of it holds the point drawn. radius: of
// the light, metres: about that near it lies its body, not what it shines past.
float light_shadow_seen(uint light, float3 position, float3 n, float radius) {
    Shadow_Map m;
    if (!light_map_of(light, position, m) || !shadow_map_held(m, position)) return -1.0;
    Shadow_Taps t;
    if (!shadow_map_point(m, false, normalize(lights[light].position_range.xyz - position), position, n, radius, 1.0, t)) return 1.0;
    // Past its far plane a map holds nothing: an empty texel would read as a blocker there.
    if (any(t.texel <= 0.0) || any(t.texel >= float(m.rect.z)) || t.d <= m.near || t.d >= m.far) return -1.0;
    return shadow_hard_seen(m, t);
}
#endif
#endif

#if defined(SHADOW_TINT_SLOT) && defined(SUN_SHADOW_SLOT)
// What the glass in front of the depth of each texel of the maps lets through
// of their light (render.Surface_Source.Shadow_Tint, shadow_map.frag), at
// the pages of the atlas: all of it lies between the light and a surface the
// maps light.
[[vk::binding(SHADOW_TINT_SLOT, 0)]] Texture2D<float4> view_shadow_tint : register(MIRAI_REGISTER(t, SHADOW_TINT_SLOT), space0);
#ifdef SHADOW_GLASS_SLOT
// The depth of the nearest of that glass (Surface_Source.Shadow_Glass), for a
// point that may lie in front of it: one of a medium.
[[vk::binding(SHADOW_GLASS_SLOT, 0)]] Texture2D<float4> view_shadow_glass : register(MIRAI_REGISTER(t, SHADOW_GLASS_SLOT), space0);
#endif

// The texel of map m a point lies in, from the corner of its square.
float2 shadow_tint_texel(Shadow_Map m, float3 position, out float3 local) {
    local = shadow_map_local(m, position);
    float2 unit = shadow_map_unit(m, local);
    float side = float(m.rect.z);
    return clamp(float2(unit.x * 0.5 + 0.5, 0.5 - unit.y * 0.5) * side, float2(0.5), float2(side - 0.5));
}

// Whether the nearest glass of a texel of the atlas lies before a point `z` along its map.
bool shadow_glass_before(Shadow_Map m, int2 at, float z) {
#ifdef SHADOW_GLASS_SLOT
    return shadow_map_distance(m, view_shadow_glass.Load(int3(at, 0)).r) < z;
#else
    return true;
#endif
}

// What the glass between the light of map m and a point lets through; 1 while
// the maps keep no tint (Frame.sun_maps.w), or where its page is not drawn.
float3 shadow_tint(Shadow_Map m, float3 position) {
    if (frame.sun_maps.w == 0u) return float3(1.0);
    float3 local;
    float2 texel = shadow_tint_texel(m, position, local);
    int2 at;
    Shadow_Map held;
    uint coarser;
    if (!shadow_texel(m, int2(floor(texel)), at, held, coarser) || !shadow_glass_before(held, at, local.z - dot(held.origin - m.origin, m.forward))) return float3(1.0);
    // Between the texels around it, each from its own page.
    float2 corner = texel - 0.5;
    float2 first = floor(corner), f = corner - first;
    float3 tint[4];
    for (uint i = 0u; i < 4u; i++) {
        int2 near_at;
        tint[i] = shadow_texel(m, int2(first) + int2(i & 1u, i >> 1u), near_at, held, coarser) ? view_shadow_tint.Load(int3(near_at, 0)).rgb : float3(1.0);
    }
    return lerp(lerp(tint[0], tint[1], f.x), lerp(tint[2], tint[3], f.x), f.y);
}

// Whether a glass whose program gives its color stands in the way of the
// light of map m to position: its tint keeps only the mean of the program,
// and the rays of the samples of the direct light run the program instead.
bool shadow_tint_programmed(Shadow_Map m, float3 position) {
    if (frame.sun_maps.w == 0u) return false;
    float3 local;
    float2 texel = shadow_tint_texel(m, position, local);
    int2 at;
    Shadow_Map held;
    uint coarser;
    if (!shadow_texel(m, int2(floor(texel)), at, held, coarser) || !shadow_glass_before(held, at, local.z - dot(held.origin - m.origin, m.forward))) return false;
    return view_shadow_tint.Load(int3(at, 0)).a < 0.5;
}
#endif
#endif
