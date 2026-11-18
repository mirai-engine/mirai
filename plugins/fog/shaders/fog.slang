// What the stages of the fog share: the grid of a view and its volumes.
#ifndef FOG_SLANG
#define FOG_SLANG
#include "scene.slang"
#include "volume.slang"
#include "media_grid.slang"

// fog.Gpu_Params.
struct Fog_Params {
    uint4 grid;     // columns, rows, slices, volumes
    uint kept;      // the light of the frame before is there
    float distance; // metres along the view the grid reaches
    float scale;    // metres: about where slices start growing with the distance
    float history;  // the weight of what the frames before found
    uint hidden;    // a cell behind everything its column sees is lit one frame in this many
    uint dry;       // some volume is a dry box
    uint shade;     // some volume takes the light of the sun
    uint far;       // slices past the grid
    float reach;    // metres along the view where the last of them begins
    uint side;      // FOG_SIDE_*: of the nearest layer of glass, where fog_apply lays the fog
    uint pad0, pad1;
    Gpu_Outlines outlines; // of the volumes
};
// render.Glass_Side.
#define FOG_SIDE_ALL 0u
#define FOG_SIDE_BEHIND 1u
#define FOG_SIDE_FRONT 2u
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Fog_Params> fog : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);

// The outlines of the volumes, read where they are.
struct Fog_Outlines : IVolume_Outlines {
    float2 outline_point(uint i) { return fog.outlines.outline_point(i); }
};

// fog.WISP_OCTAVES.
#define FOG_WISP_OCTAVES 3u

// fog.Gpu_Volume, in the order they apply.
struct Fog_Volume {
    Gpu_Volume volume;
    float4 medium; // rgb what it scatters in a metre, a what it stops; of a variable one, the mean
    float4 params; // x 1 over its wisp size (0: it does not vary), y anisotropy, z falloff, w the height of its base
    float4 carve;  // x priority, y FOG_CARVE_* bits, z 1/m it takes of the light of the sun that crosses it
    int4 cells[FOG_WISP_OCTAVES];    // xyz the cell of each layer of its wisps at the origin of the render now
    float4 within[FOG_WISP_OCTAVES]; // xyz where in that cell, 0 to 1
};
#define FOG_CARVE_DRY 1u
#define FOG_CARVE_CARVED 2u
#define FOG_CARVE_SUN_ONLY 4u
// The glass of its surface takes what it stops of the view (fog.Medium.glass).
#define FOG_CARVE_GLASS 8u
bool fog_carve(Fog_Volume v, uint bit) { return (uint(v.carve.y) & bit) != 0u; }

// The grid of the view: the media of the view it integrates (media_grid.slang).
Media_Grid fog_grid() {
    Media_Grid g;
    g.cells = uint4(fog.grid.xyz, fog.far);
    g.distance = fog.distance;
    g.scale = fog.scale;
    g.reach = fog.reach;
    g.valid = 1u;
    return g;
}
float fog_slice_depth(float s) { return media_slice_depth(fog_grid(), s); }
float fog_depth_slice(float depth) { return media_depth_slice(fog_grid(), depth); }
float fog_far_depth(uint j) { return media_far_depth(fog_grid(), j); }

// fog.WISP_SIZES; what each layer adds to the wisps, which sum to 1.
static const float FOG_WISP_SIZES[FOG_WISP_OCTAVES] = { 1.0, 0.47, 0.22 };
static const float FOG_WISP_SHARES[FOG_WISP_OCTAVES] = { 0.55, 0.3, 0.15 };
// How far from their middle the wisps are pushed: clear between them, thick in them.
static const float FOG_WISP_CONTRAST = 3.0;

float fog_hash(int3 cell, uint layer) {
    uint3 u = uint3(cell);
    uint h = u.x * 0x8da6b343u ^ u.y * 0xd8163841u ^ u.z * 0xcb1ab31fu ^ layer * 0x165667b1u;
    h ^= h >> 15u;
    h *= 0x2c1b3c6du;
    h ^= h >> 12u;
    h *= 0x297a2d39u;
    h ^= h >> 15u;
    return float(h >> 8u) * (1.0 / 16777215.0);
}

// Value noise of a layer, 0 to 1, whose mean is 1/2 and whose values are as
// often above it as below.
float fog_noise(int3 cell, float3 within, uint layer) {
    float3 f = within * within * within * (within * (within * 6.0 - 15.0) + 10.0);
    float x00 = lerp(fog_hash(cell, layer), fog_hash(cell + int3(1, 0, 0), layer), f.x);
    float x10 = lerp(fog_hash(cell + int3(0, 1, 0), layer), fog_hash(cell + int3(1, 1, 0), layer), f.x);
    float x01 = lerp(fog_hash(cell + int3(0, 0, 1), layer), fog_hash(cell + int3(1, 0, 1), layer), f.x);
    float x11 = lerp(fog_hash(cell + int3(0, 1, 1), layer), fog_hash(cell + int3(1, 1, 1), layer), f.x);
    return lerp(lerp(x00, x10, f.y), lerp(x01, x11, f.y), f.z);
}

// What the density of a volume is times at a point, from 0 to 2 and 1 on
// the mean, for a cell of footprint metres across: the layers of its wisps
// smaller than the cell fade to their mean instead of flickering in it. 1
// for a volume that does not vary.
float fog_wisps(Fog_Volume v, float3 position, float footprint) {
    if (!(v.params.x > 0.0)) return 1.0;
    float n = 0.0;
    for (uint k = 0u; k < FOG_WISP_OCTAVES; k++) {
        float size = FOG_WISP_SIZES[k] / v.params.x;
        float shown = saturate(2.0 - 2.0 * footprint / size);
        if (!(shown > 0.0)) {
            n += FOG_WISP_SHARES[k] * 0.5;
            continue;
        }
        float3 at = position / size + v.within[k].xyz;
        float3 whole = floor(at);
        float value = fog_noise(v.cells[k].xyz + int3(whole), at - whole, k);
        n += FOG_WISP_SHARES[k] * lerp(0.5, value, shown);
    }
    // Pushed the same way above and below the middle, the mean stays 1.
    return 2.0 * saturate(0.5 + (n - 0.5) * FOG_WISP_CONTRAST);
}

// The shares of a segment from a to b inside a volume, by its shape without
// its blend: start >= end when it misses it.
void fog_volume_segment(Fog_Volume v, float3 a, float3 b, out float start, out float end) {
    start = 0.0;
    end = 1.0;
    Gpu_Volume g = v.volume;
    if (g.kind.x == 0u) return;
    float3 o = float3(dot(g.to_local[0].xyz, a) + g.to_local[0].w, dot(g.to_local[1].xyz, a) + g.to_local[1].w, dot(g.to_local[2].xyz, a) + g.to_local[2].w);
    float3 d = float3(dot(g.to_local[0].xyz, b - a), dot(g.to_local[1].xyz, b - a), dot(g.to_local[2].xyz, b - a));
    if (g.kind.x == 2u) {
        float dd = max(dot(d, d), 1e-20);
        float half_b = dot(o, d) / dd;
        float c = (dot(o, o) - g.shape.x * g.shape.x) / dd;
        float root = half_b * half_b - c;
        if (root < 0.0) {
            start = 1.0;
            end = 0.0;
            return;
        }
        root = sqrt(root);
        start = max(-half_b - root, 0.0);
        end = min(-half_b + root, 1.0);
        return;
    }
    float3 inverse = 1.0 / select(abs(d) > 1e-20, d, float3(1e-20));
    float3 t0 = (-g.shape.xyz - o) * inverse;
    float3 t1 = (g.shape.xyz - o) * inverse;
    float3 low = min(t0, t1), high = max(t0, t1);
    start = max(max(low.x, low.y), max(low.z, 0.0));
    end = min(min(high.x, high.y), min(high.z, 1.0));
}

// What a volume stops along length metres between heights ya and yb, by
// its mean density thinning with the height over its base: in closed form,
// constant under the base and exponential over it.
float fog_optical_depth(Fog_Volume v, float ya, float yb, float length) {
    if (!(length > 0.0)) return 0.0;
    float k = v.params.z;
    float low = min(ya, yb) - v.params.w, high = max(ya, yb) - v.params.w;
    if (!(k * (high - low) > 1e-4)) return v.medium.a * exp(-k * max(0.5 * (low + high), 0.0)) * length;
    float below = low < 0.0 ? length * (min(high, 0.0) - low) / (high - low) : 0.0;
    float x = k * (high - max(low, 0.0));
    float above = (length - below) * exp(-k * max(low, 0.0)) * (x > 1e-4 ? (1.0 - exp(-x)) / x : 1.0 - 0.5 * x);
    return v.medium.a * (below + above);
}

// How much of a volume there is at a point: its weight, thinner with the
// height over its base.
float fog_volume_share(Fog_Volume v, float3 position) {
    Fog_Outlines outlines;
    float w = volume_weight(v.volume, position, outlines);
    if (!(w > 0.0)) return 0.0;
    return w * exp(-v.params.z * max(position.y - v.params.w, 0.0));
}

// Metres from a point inside a volume to where a ray along a direction of
// length 1 leaves it; 0 for one without a border.
float fog_volume_exit(Fog_Volume v, float3 position, float3 direction) {
    Gpu_Volume g = v.volume;
    if (g.kind.x == 0u) return 0.0;
    float3 o = float3(dot(g.to_local[0].xyz, position) + g.to_local[0].w, dot(g.to_local[1].xyz, position) + g.to_local[1].w, dot(g.to_local[2].xyz, position) + g.to_local[2].w);
    float3 d = float3(dot(g.to_local[0].xyz, direction), dot(g.to_local[1].xyz, direction), dot(g.to_local[2].xyz, direction));
    if (g.kind.x == 2u) {
        float b = dot(o, d);
        return max(-b + sqrt(max(b * b - dot(o, o) + g.shape.x * g.shape.x, 0.0)), 0.0);
    }
    float3 t = (sign(d) * g.shape.xyz - o) / max(abs(d), 1e-12) * sign(d);
    float3 far = select(abs(d) > 1e-12, t, float3(1e30));
    return max(min(far.x, min(far.y, far.z)), 0.0);
}

#endif
