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
// the clusters they draw, shadow_cull.slang. The height of the atlas, texels,
// is Frame.sun_maps.z.

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

// The narrowest and the widest texel of a map over a box of the world,
// metres: where the box comes nearest the light of a perspective one and
// where it goes farthest (render.shadow_map_finest).
float2 shadow_map_texels(Shadow_Map m, float3 low, float3 high) {
    float3 center = 0.5 * (low + high) - m.origin;
    float along = dot(center, m.forward), half = dot(0.5 * (high - low), abs(m.forward));
    return float2(shadow_map_texel(m, max(along - half, m.near)), shadow_map_texel(m, max(along + half, m.near)));
}

// Whether a map draws a caster within a box that sways `sway` metres as it
// sways, not at rest (render.shadow_map_sways): the texel of its layer
// `coarser` levels coarser is narrower there than the sway, and where its
// shadow falls, past the box from the light, its own texel is narrower than
// `reach`, the texel the view takes of a point at the reach of what sways in
// the maps (render.shadow_sway_texel).
bool shadow_map_sways(Shadow_Map m, float3 low, float3 high, float sway, float reach, uint coarser) {
    float2 texels = shadow_map_texels(m, low, high);
    return texels.x * float(1u << coarser) < sway && texels.y < reach;
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

// The texels of a map a box of the world covers from the light, the first
// column and row then the last, past its square too; false where it covers
// none of the square. A box that reaches the plane of a perspective one
// covers all.
bool shadow_box_texels(Shadow_Map m, float3 low, float3 high, out float4 texels) {
    float side = float(m.rect.z);
    texels = float4(0.0, 0.0, side, side);
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
    texels = float4((lo.x - m.span.x) / (m.span.z - m.span.x), (m.span.w - hi.y) / (m.span.w - m.span.y),
                    (hi.x - m.span.x) / (m.span.z - m.span.x), (m.span.w - lo.y) / (m.span.w - m.span.y)) * side;
    return !(texels.z < 0.0 || texels.w < 0.0 || texels.x >= side || texels.y >= side);
}

// The pages of a map those texels lie in, the first column and row then the last.
uint4 shadow_texel_pages(Shadow_Map m, float4 texels) {
    float end = float(m.rect.z / SHADOW_PAGE * SHADOW_PAGE) - 1.0;
    return uint4(clamp(texels, 0.0, end)) / SHADOW_PAGE;
}

// The taps of a map around a point that find its blockers; the most texels
// they reach, as wide as the penumbrae of large lights near what they light;
// and the least half width of a penumbra, texels, so that the edge of what
// hides itself, where it turns from the light, does not show the texels of
// the map. Each is of the texel of the level or mip a point takes, and grows
// with where the point lies in it (Shadow_Taps.grow).
#define SHADOW_TAPS 12u
#define SHADOW_SEARCH_MAX 64.0
// How far around a point its taps ask for pages of its own level or mip,
// texels: a tap farther off finds only a blocker far from the point, behind
// a penumbra as wide, which the level or mip whose texels are as many times
// wider tells as well; its pages are asked for there instead
// (shadow_mark.comp), and the taps read them where those of the point's own
// are not drawn (SHADOW_ENTRY_COARSER).
#define SHADOW_SEARCH_NEAR 8.0
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
// Where map m reads a point at `position` that the vertex hook moved by
// `swayed` from where it rests (pixel_rest of gbuffer.slang; 0 for one at
// rest): there, where the map is no wider than the texel of a point at the
// reach of what sways (Frame.sun_maps.w) and draws what sways as it sways;
// elsewhere where the point rests, as the map draws it. The functions below
// that read a map at a point take its `swayed` the same.
float3 shadow_place(Shadow_Map m, float3 position, float3 swayed) {
    if (all(swayed == 0.0)) return position;
    float3 rest = position - swayed;
    return shadow_map_texel(m, max(shadow_map_local(m, rest).z, m.near)) < asfloat(frame.sun_maps.w) ? position : rest;
}

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
bool shadow_map_point(Shadow_Map m, bool sun, float3 toward, float3 position, float3 n, float radius, float grow, out Shadow_Taps t, float3 swayed = float3(0.0)) {
    t = (Shadow_Taps)0;
    t.grow = grow;
    t.c = dot(n, toward);
    if (!(t.c > 0.0) && any(n != 0.0)) return false;
    position = shadow_place(m, position, swayed);
    t.step = shadow_map_texel(m, shadow_map_local(m, position).z);
    // Off the surface, so that it does not hide itself; where that leaves the
    // face of the cube of a light, at the border of the face.
    float3 local = shadow_map_local(m, position + n * (SHADOW_NORMAL_OFFSET * grow * t.step));
    t.d = local.z;
    float2 unit = shadow_map_unit(m, local);
    // Where the offset leaves the face of the cube of a light, at its border.
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
bool shadow_map_taps(Shadow_Map m, bool sun, float3 toward, float3 position, float3 n, float radius, float across, float grow, out Shadow_Taps t, float3 swayed = float3(0.0)) {
    if (!shadow_map_point(m, sun, toward, position, n, radius, grow, t, swayed)) return false;
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
bool sun_map_at(uint k, float3 position, out Shadow_Map m, float3 swayed = float3(0.0)) {
    m = sun_level(k);
    float3 local = shadow_map_local(m, shadow_place(m, position, swayed));
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

// The level of the sun a point takes, and the next it blends with, by the
// width of a pixel of the view there (across): the one whose texel spans up to
// SHADOW_TEXEL_PIXELS of them, else the finest that holds it with room for
// its taps.
// Over the top SHADOW_LEVEL_BAND of each octave the point blends into the
// next level, by blend; grow: how the texel-based constants of its level
// grow over it, so that they meet those of the next where it begins. across
// 0: the finest level that holds the point.
struct Sun_Pick {
    uint level;
    float blend, grow;
};
bool sun_pick(float3 position, float across, out Sun_Pick pick, float3 swayed = float3(0.0)) {
    pick = (Sun_Pick)0;
    pick.grow = 1.0;
    uint count = sun_levels();
    if (count == 0u) return false;
    float level = log2(max(across * SHADOW_TEXEL_PIXELS, 1e-9) / shadow_map_texel(sun_level(0u), 0.0));
    uint k = uint(clamp(floor(level), 0.0, float(count - 1u)));
    float within = saturate(level - float(k));
    Shadow_Map m;
    bool held = sun_map_at(k, position, m, swayed);
    for (; k + 1u < count && !held; k++) held = sun_map_at(k + 1u, position, m, swayed);
    if (!held) return false;
    pick.level = k;
    if (k != uint(clamp(floor(level), 0.0, float(count - 1u)))) return true;
    pick.grow = exp2(within);
    if (k + 1u < count && sun_map_at(k + 1u, position, m, swayed)) pick.blend = saturate((within - (1.0 - SHADOW_LEVEL_BAND)) / SHADOW_LEVEL_BAND);
    return true;
}

// The mip of a face of a local light a point takes, as its level the sun
// (sun_pick): the one whose texel spans up to SHADOW_TEXEL_PIXELS pixels of
// the view where the point lies, blended into the next over the top of its octave, and no finer
// than the widest penumbra the light of radius `radius` casts there over
// SHADOW_SEARCH_MAX of its texels, which its taps search. across 0: the
// finest the penumbra allows.
// The mip of a face of a local light a point at depth `z` along it takes.
Sun_Pick light_pick_z(Shadow_Map m, float z, float across, float radius) {
    Sun_Pick pick = (Sun_Pick)0;
    pick.grow = 1.0;
    z = max(z, m.near);
    float penumbra = radius * max(z - m.skip, 0.0) / max(m.skip, 1e-3);
    float mip = log2(max(max(across * SHADOW_TEXEL_PIXELS, penumbra / SHADOW_SEARCH_MAX), 1e-9) / shadow_map_texel(shadow_map_mip(m, 0u), z));
    pick.level = uint(clamp(floor(mip), 0.0, float(SHADOW_MIPS - 1u)));
    float within = saturate(mip - float(pick.level));
    pick.grow = exp2(within);
    if (pick.level + 1u < SHADOW_MIPS) pick.blend = saturate((within - (1.0 - SHADOW_LEVEL_BAND)) / SHADOW_LEVEL_BAND);
    return pick;
}

Sun_Pick light_pick(Shadow_Map m, float3 position, float across, float radius, float3 swayed = float3(0.0)) {
    return light_pick_z(m, shadow_map_local(m, shadow_place(m, position, swayed)).z, across, radius);
}

// Whether the maps give a point the light of the sun: its level holds it,
// or a coarser one drawn where its page is not (shadow_map_held); else rays do.
bool sun_map_given(float3 position, float across, float3 swayed = float3(0.0)) {
    Sun_Pick pick;
    if (!sun_pick(position, across, pick, swayed)) return false;
    Shadow_Map m = sun_level(pick.level);
    return shadow_map_held(m, position, swayed);
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

// A map of a viewmodel (FOREGROUND_MAP_SLOT, render/foreground.odin): a
// square of the atlas whose first texel is at the pages of rect.y, every
// texel of it drawn.
bool shadow_map_plain(Shadow_Map m) { return m.rect.x == FOREGROUND_MAP_SLOT; }

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
    if (shadow_map_plain(m)) {
        at = int2(m.rect.y & 0xFFu, (m.rect.y >> 8u) & 0xFFu) * int(SHADOW_PAGE) + texel;
        return all(texel >= 0) && all(texel < int(m.rect.z));
    }
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

// The entries of the table of the 2x2 pages of map m from the page of a texel
// less reach, looked up once for the taps of a point (shadow_texel_near).
struct Shadow_Near {
    int2 first; // the first page of the 2x2
    uint4 e;    // their entries, row by row; 0 past the square of the map
};
Shadow_Near shadow_near(Shadow_Map m, float2 texel, float reach) {
    Shadow_Near n = (Shadow_Near)0;
    if (shadow_map_plain(m)) return n;
    int pages = int(m.rect.z / SHADOW_PAGE);
    n.first = clamp(int2(floor(texel - reach)) / int(SHADOW_PAGE), 0, max(pages - 2, 0));
    uint e[4];
    for (uint i = 0u; i < 4u; i++) {
        int2 page = n.first + int2(int(i & 1u), int(i >> 1u));
        e[i] = all(page < pages) ? shadow_table_entry(m.rect.x, shadow_page_entry(m.rect, uint2(page))) : 0u;
    }
    n.e = uint4(e[0], e[1], e[2], e[3]);
    return n;
}

// shadow_texel through the entries of the pages around a point: a texel of
// one of them drawn this frame lies in its page at once; the others, as
// shadow_texel finds them.
bool shadow_texel_near(Shadow_Map m, Shadow_Near n, int2 texel, out int2 at, out Shadow_Map held, out uint coarser) {
    if (all(texel >= 0) && all(texel < int(m.rect.z))) {
        int2 k = texel / int(SHADOW_PAGE) - n.first;
        uint e = k.y == 0 ? (k.x == 0 ? n.e.x : n.e.y) : (k.x == 0 ? n.e.z : n.e.w);
        if (all(k >= 0) && all(k <= 1) && shadow_entry_ready(e)) {
            at = int2(shadow_pool_corner((e & SHADOW_ENTRY_POOL) - 1u)) + (texel & int(SHADOW_PAGE - 1u));
            held = m;
            coarser = 0u;
            return true;
        }
    }
    return shadow_texel(m, texel, at, held, coarser);
}

// The map that holds a point at its texel, as the table names it
// (SHADOW_ENTRY_HELD): m where its page is drawn this frame with the pages
// around it each drawn or held by a coarser one, so that every tap of the
// point reads a blocker, else the nearest coarser one so drawn; false where
// none is, and the light of the point is then traced.
bool shadow_map_held_unit(inout Shadow_Map m, float2 unit) {
    if (shadow_map_plain(m)) return true;
    unit = clamp(unit, -0.9999, 0.9999);
    int2 texel = int2(floor(float2(unit.x * 0.5 + 0.5, 0.5 - unit.y * 0.5) * float(m.rect.z)));
    uint e;
    if (!shadow_texel_entry(m, texel, e)) return false;
    uint held = (e >> SHADOW_ENTRY_HELD) & 0xFu;
    if (held == 0u) return false;
    if (held > 1u) m = shadow_map_coarser(m, held - 1u, texel);
    return true;
}
bool shadow_map_held(inout Shadow_Map m, float3 position, float3 swayed = float3(0.0)) {
    return shadow_map_held_unit(m, shadow_map_unit(m, shadow_map_local(m, shadow_place(m, position, swayed))));
}

#ifdef SHADOW_MARKS_SLOT
// The buffer of the pages of the view (render.pass_shadow_marks), for a pass
// after the maps to mark the pages it reads: the next frame draws them, and
// until then it reads the coarser pages drawn there or traces. A page newly
// marked that is not drawn asks the steps of the pages to run then.
[[vk::binding(SHADOW_MARKS_SLOT, 0)]] RWStructuredBuffer<uint> view_shadow_marks : register(MIRAI_REGISTER(u, SHADOW_MARKS_SLOT), space0);

// Marks the pages of map m at its mip that a point at unit reads: the 2x2
// texels around it when blended, else the single texel it falls in.
void shadow_mark_late_unit(Shadow_Map m, float2 unit, bool blended = true) {
    if (any(abs(unit) >= 1.0)) return;
    float2 texel = float2(unit.x * 0.5 + 0.5, 0.5 - unit.y * 0.5) * float(m.rect.z);
    int last = int(m.rect.z) - 1;
    uint2 first = uint2(clamp(int2(floor(blended ? texel - 0.5 : texel)), 0, last)) / SHADOW_PAGE;
    uint2 end = blended ? uint2(clamp(int2(floor(texel + 0.5)), 0, last)) / SHADOW_PAGE : first;
    for (uint y = first.y; y <= end.y; y++) {
        for (uint x = first.x; x <= end.x; x++) {
            uint entry = shadow_page_entry(m.rect, uint2(x, y));
            if (!shadow_place_valid(m.rect.x, entry)) continue;
            uint word = SHADOW_WORDS_LATE + m.rect.x * SHADOW_MASK_WORDS + (entry >> 5u), bit = 1u << (entry & 31u);
            if ((view_shadow_marks[word] & bit) != 0u) continue;
            uint before;
            InterlockedOr(view_shadow_marks[word], bit, before);
            // Atomic like the mark: the draws of a pass may all ask at once.
            if ((before & bit) == 0u && shadow_entry_asks(shadow_table_entry(m.rect.x, entry))) InterlockedOr(view_shadow_marks[SHADOW_STEP_NEW], 1u);
        }
    }
}
void shadow_mark_late(Shadow_Map m, float3 position, float3 swayed = float3(0.0), bool blended = true) {
    shadow_mark_late_unit(m, shadow_map_unit(m, shadow_map_local(m, shadow_place(m, position, swayed))), blended);
}
#endif

#ifdef SUN_SHADOW_SLOT
// The atlas of the maps of the view (render.Surface_Source.Shadow_Atlas), for
// a pass that takes the shadows of the lights from it and not from rays.
[[vk::binding(SUN_SHADOW_SLOT, 0)]] Texture2D<float4> view_shadow_atlas : register(MIRAI_REGISTER(t, SUN_SHADOW_SLOT), space0);

// How far along map m the blocker a texel of it holds lies, through the page
// that holds it (shadow_texel_near, n: the pages around the point); coarser:
// how many levels or mips coarser that page is. False where no page holds it:
// the texel tells nothing.
bool shadow_blocker(Shadow_Map m, Shadow_Near n, int2 texel, out float b, out uint coarser) {
    b = 0.0;
    int2 at;
    Shadow_Map held;
#ifdef SHADOW_DATA_SLOT
    // Past a face of the cube of a light, the face next to it holds the texel.
    if (m.rect.w != INVALID && (any(texel < 0) || any(texel >= int(m.rect.z)))) return shadow_beside(m, texel, b, coarser);
#endif
    if (!shadow_texel_near(m, n, texel, at, held, coarser)) return false;
    b = shadow_map_distance(held, view_shadow_atlas.Load(int3(at, 0)).r) + dot(held.origin - m.origin, m.forward);
    return true;
}

// Whether the center of the light sees a point past what the 2x2 texels
// around its texel hold (shadow_map_point), blended between those a page holds.
float shadow_hard_seen(Shadow_Map m, Shadow_Near n, Shadow_Taps t) {
    float2 corner = t.texel - 0.5;
    float2 first = floor(corner), f = corner - first;
    float seen = 0.0, total = 0.0;
    for (uint i = 0u; i < 4u; i++) {
        float2 at = first + float2(i & 1u, i >> 1u);
        float b;
        uint coarser;
        if (!shadow_blocker(m, n, int2(at), b, coarser)) continue;
        float weight = ((i & 1u) != 0u ? f.x : 1.0 - f.x) * ((i >> 1u) != 0u ? f.y : 1.0 - f.y);
        // Read at the middle of the texel, where the map holds the surface.
        seen += shadow_blocks(t, b, at + 0.5 - t.texel, coarser) ? 0.0 : weight;
        total += weight;
    }
    return total > 0.0 ? seen / total : 1.0;
}

// Whether the center of the light sees a point past what the texel it falls
// in holds (shadow_map_point); -1 where no page holds that texel.
float shadow_texel_seen(Shadow_Map m, Shadow_Taps t) {
    int2 at;
    Shadow_Map held;
    uint coarser;
    if (!shadow_texel(m, int2(floor(t.texel)), at, held, coarser)) return -1.0;
    float b = shadow_map_distance(held, view_shadow_atlas.Load(int3(at, 0)).r) + dot(held.origin - m.origin, m.forward);
    return shadow_blocks(t, b, float2(0.0), coarser) ? 0.0 : 1.0;
}

#ifdef MIRAI_VIEWMODEL
// A layer of the maps of the viewmodel of the view (Frame.viewmodel), of the
// sun (light 0) or of Frame.viewmodel.light (1), of the weapon or of the
// body; false where the view has none or it holds nothing of the point.
bool foreground_map(uint light, bool weapon, float3 position, out Shadow_Map m) {
    uint at = (light * 2u + (weapon ? 0u : 1u)) * SHADOW_MAP_ROWS;
    m = shadow_map_from(frame.viewmodel.maps[at], frame.viewmodel.maps[at + 1u], frame.viewmodel.maps[at + 2u],
        frame.viewmodel.maps[at + 3u], frame.viewmodel.maps[at + 4u], frame.viewmodel.maps[at + 5u]);
    if ((frame.flags & FRAME_FLAG_VIEWMODEL) == 0u || m.rect.z == 0u) return false;
    float3 local = shadow_map_local(m, position);
    return local.z > m.near && local.z < m.far && all(abs(shadow_map_unit(m, local)) < 1.0);
}

// How much of that light reaches a pixel of the weapon at its true place
// past what the layer of the weapon holds; 1 where it holds nothing of the
// point. toward: the light from the point.
float weapon_shadow_seen(uint light, float3 position, float3 n, float3 toward) {
    Shadow_Map m;
    Shadow_Taps t;
    if (!foreground_map(light, true, position, m) || !shadow_map_point(m, light == 0u, toward, position, n, 0.0, 1.0, t)) return 1.0;
    return shadow_hard_seen(m, shadow_near(m, t.texel, 1.0), t);
}
#endif

// How much of the sun reaches a point past what the maps of the view hold;
// -1 where no level drawn holds the point, or the view drew none: a ray
// tells. n: the normal of its surface, zero for a point of a medium; across:
// its width, metres, which picks its level (sun_pick). blended: between the
// texels around the point, the border of a shadow as fine as the map, where
// the pages around it are drawn (shadow_map_held); else by the texel it falls
// in alone, as the samples of the direct light tell a point lit
// (shadow_map_seen of direct_samples.comp), read in its page or the nearest
// coarser one drawn (shadow_texel), for a stage that traces no ray.
float sun_shadow_seen(float3 position, float3 n, float across, bool blended = true, float3 swayed = float3(0.0)) {
    Sun_Pick pick;
    if (!sun_pick(position, across, pick, swayed)) return -1.0;
    Shadow_Map m = sun_level(pick.level);
#ifdef SHADOW_MARKS_SLOT
    shadow_mark_late(m, position, swayed, blended);
#endif
    Shadow_Taps t;
    if (blended && !shadow_map_held(m, position, swayed)) return -1.0;
    if (!shadow_map_point(m, true, frame.sun_direction.xyz, position, n, 0.0, m.rect.x == pick.level ? pick.grow : 1.0, t, swayed)) return 1.0;
    return blended ? shadow_hard_seen(m, shadow_near(m, t.texel, 1.0), t) : shadow_texel_seen(m, t);
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

// The map of local light `light` a point falls in, at its finest mip; false
// where it has none on that side, or the point lies off the face or past its
// depths, where its texels hold what lies elsewhere: rays tell there. A spot
// with one map along its cone (SHADOW_SPOT_FACE) has it for every point in
// its cone.
bool light_map_of(uint light, float3 position, out Shadow_Map m, float3 swayed = float3(0.0)) {
    m = (Shadow_Map)0;
    if (frame.sun_maps.z == 0u) return false;
    uint word = shadow_light_word(view_shadow_data, light);
    if (word == 0u) return false;
    uint faces = word >> SHADOW_LIGHT_FACES;
    uint face = (faces & (1u << SHADOW_SPOT_FACE)) != 0u ? SHADOW_SPOT_FACE : shadow_face_of(position - lights[light].position_range.xyz);
    if ((faces & (1u << face)) == 0u) return false;
    m = shadow_map_at(view_shadow_data, frame.sun_maps.y, (word & 0xFFFFu) - 1u + face);
    float3 local = shadow_map_local(m, shadow_place(m, position, swayed));
    return local.z > m.near && local.z < m.far && all(abs(shadow_map_unit(m, local)) < 1.0);
}

// The map of the mip of local light `light` a point of width across takes,
// where a page holds it (shadow_map_held); false where none does: rays tell.
bool light_map_given(uint light, float3 position, float across, out Shadow_Map m, out Sun_Pick pick, float3 swayed = float3(0.0)) {
    pick = (Sun_Pick)0;
    if (!light_map_of(light, position, m, swayed)) return false;
    pick = light_pick(m, position, across, light_extent(lights[light]), swayed);
    m = shadow_map_mip(m, pick.level);
#ifdef SHADOW_MARKS_SLOT
    shadow_mark_late(m, position, swayed);
#endif
    return shadow_map_held(m, position, swayed);
}

#ifdef SUN_SHADOW_SLOT
// How far along face m of the cube of a light the blocker a texel past its
// square holds lies, read from the face its direction falls on, at the same
// mip; false where that face has no map or no page holds it.
bool shadow_beside(Shadow_Map m, int2 texel, out float b, out uint coarser) {
    b = 0.0;
    coarser = 0u;
    uint own = (m.rect.x - SHADOW_SUN_MAPS) % SHADOW_LIGHT_SLOTS;
    if (own >= SHADOW_SPOT_FACE) return false;
    float2 unit = (float2(texel) + 0.5) / float(m.rect.z) * float2(2.0, -2.0) + float2(-1.0, 1.0);
    float2 ratio = 0.5 * ((m.span.xy + m.span.zw) + unit * (m.span.zw - m.span.xy));
    float3 direction = m.right * ratio.x + m.up * ratio.y + m.forward;
    uint face = shadow_face_of(direction);
    if (face == own) return false;
    Shadow_Map n = shadow_map_at(view_shadow_data, frame.sun_maps.y, m.rect.x - own + face);
    if (n.rect.z == 0u) return false;
    n = shadow_map_mip(n, shadow_rect_mip(m.rect));
    float3 local = float3(dot(direction, n.right), dot(direction, n.up), dot(direction, n.forward));
    float2 there = shadow_map_unit(n, local);
    int2 at;
    Shadow_Map held;
    if (!shadow_texel(n, int2(floor(float2(there.x * 0.5 + 0.5, 0.5 - there.y * 0.5) * float(n.rect.z))), at, held, coarser)) return false;
    // Along the direction, from the depth along the face that holds it to the depth along m.
    b = shadow_map_distance(held, view_shadow_atlas.Load(int3(at, 0)).r) / local.z;
    return true;
}

// How much of local light `light` reaches a point past what its map holds, as
// sun_shadow_seen; -1 where no map of it holds the point drawn. radius: of
// the light, metres: about that near it lies its body, not what it shines past.
// blended: 2x2 texel blend where the pages around it are drawn; false: the
// texel it falls in, in its page or the nearest coarser one drawn.
float light_shadow_seen(uint light, float3 position, float3 n, float radius, float across, float3 swayed = float3(0.0), bool blended = true) {
    if (frame.sun_maps.z == 0u) return -1.0;
    uint word = shadow_light_word(view_shadow_data, light);
    if (word == 0u) return -1.0;
    uint faces = word >> SHADOW_LIGHT_FACES;
    float3 light_pos = lights[light].position_range.xyz;
    uint face = (faces & (1u << SHADOW_SPOT_FACE)) != 0u ? SHADOW_SPOT_FACE : shadow_face_of(position - light_pos);
    if ((faces & (1u << face)) == 0u) return -1.0;
    Shadow_Map m = shadow_map_at(view_shadow_data, frame.sun_maps.y, (word & 0xFFFFu) - 1u + face);
    float3 placed = shadow_place(m, position, swayed);
    float3 local = shadow_map_local(m, placed);
    if (!(local.z > m.near && local.z < m.far)) return -1.0;
    float2 unit = shadow_map_unit(m, local);
    if (any(abs(unit) >= 1.0)) return -1.0;
    Sun_Pick pick = light_pick_z(m, local.z, across, radius);
    m = shadow_map_mip(m, pick.level);
#ifdef SHADOW_MARKS_SLOT
    shadow_mark_late_unit(m, unit, blended);
#endif
    if (blended && !shadow_map_held_unit(m, unit)) return -1.0;
    Shadow_Taps t;
    if (!shadow_map_point(m, false, normalize(light_pos - placed), position, n, radius, shadow_rect_mip(m.rect) == pick.level ? pick.grow : 1.0, t, swayed)) return 1.0;
    // Past its far plane a map holds nothing: an empty texel would read as a blocker there.
    if (any(t.texel <= 0.0) || any(t.texel >= float(m.rect.z)) || t.d <= m.near || t.d >= m.far) return -1.0;
    return blended ? shadow_hard_seen(m, shadow_near(m, t.texel, 1.0), t) : shadow_texel_seen(m, t);
}
#endif
#endif

#endif
