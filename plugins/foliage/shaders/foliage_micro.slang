//! mirai constant MICRO_THIN_KEPT float ../runtime/micro.odin
//! mirai constant MICRO_THIN_BAND float ../runtime/micro.odin
//! mirai constant MICRO_THIN_WIDEN float ../runtime/micro.odin
// The micro foliage of a world (foliage.Foliage_Micro): what the Micro layers
// of the graphs place on the ground, scattered on the GPU. A tile is a cell
// of a graph and a layer; when it changes, foliage_micro_gen.comp writes the
// instances that stand into its slot of the buffer of the world, once, and
// each view writes those it keeps into the batch of their layer
// (foliage_micro_fill.comp), which the cull and the visibility buffer of the
// scene draw like any other.
#ifndef FOLIAGE_MICRO_SLANG
#define FOLIAGE_MICRO_SLANG
#include "native.slang"
#include "scene.slang"
#include <constants/plugins/foliage.slang>

// An instance (foliage.Micro_Instance), in the space of its cell: the frame
// of its graph from the corner of the cell.
struct Micro_Instance {
    uint place;  // x | z << 16, unorm16 across the cell
    float height;
    uint normal; // of the ground under it, octahedral, snorm16 x | z << 16
    uint slot;
};

// A slot of the buffer (foliage.Micro_Slot): where its tile is and what it holds.
struct Micro_Slot {
    float4 world[3]; // from the space of its cell into the world, relative to the origin
    uint4 info;      // x: its first instance, y: how many it holds at most, z: its look, w: 1 once generated
    float4 cell;     // x: metres across its cell; y: the seed of its instances
};

// A look (foliage.Micro_Look_Row): how the instances of a layer are placed.
struct Micro_Look {
    float4 sphere;   // the centre of its mesh and its radius
    float4 scale;    // across, lowest and highest; along y times across, lowest and highest
    float4 turn;     // x: a turn around y of up to this, y: a lean of up to this, z: how much it leans with the ground, w: the scale of the frame of its graph
    float4 offset;   // along its y, lowest and highest
    float4 distance; // from the eye: x where it starts to shrink away, y where it is gone (0: never), z where it starts to thin out in this view (0: never)
    float4 frame;    // the rotation of the frame of its graph (x, y, z, w)
    uint4 target;    // of its batch in this view (render.Batch_Target): its first word, the word of its count, its room; 0 room: none
    float4 anchor;   // of its batch, relative to the origin
};

#define MICRO_NOT_GENERATED 0u

uint micro_hash(uint x) {
    x ^= x >> 16u;
    x *= 0x7feb352du;
    x ^= x >> 15u;
    x *= 0x846ca68bu;
    x ^= x >> 16u;
    return x;
}

float micro_unit(uint h) { return float(h >> 8u) * (1.0 / 16777216.0); }

uint micro_snorm16(float v) { return uint(int(round(clamp(v, -1.0, 1.0) * 32767.0)) & 0xffff); }
float micro_snorm16_value(uint v) { return clamp(float(int(v << 16u) >> 16) / 32767.0, -1.0, 1.0); }

uint micro_normal_pack(float3 n) {
    float2 p = n.xz / (abs(n.x) + abs(n.y) + abs(n.z));
    if (n.y < 0.0) p = (1.0 - abs(p.yx)) * select(p >= 0.0, float2(1.0), float2(-1.0));
    return micro_snorm16(p.x) | micro_snorm16(p.y) << 16u;
}

float3 micro_normal_unpack(uint v) {
    float2 p = float2(micro_snorm16_value(v & 0xffffu), micro_snorm16_value(v >> 16u));
    float3 n = float3(p.x, 1.0 - abs(p.x) - abs(p.y), p.y);
    if (n.y < 0.0) n.xz = (1.0 - abs(n.zx)) * select(n.xz >= 0.0, float2(1.0), float2(-1.0));
    return normalize(n);
}

// The product of two rotations (x, y, z, w): b, then a.
float4 micro_rotate(float4 a, float4 b) {
    return float4(a.w * b.xyz + b.w * a.xyz + cross(a.xyz, b.xyz), a.w * b.w - dot(a.xyz, b.xyz));
}

// A turn of `angle` radians about a unit axis.
float4 micro_turn(float3 axis, float angle) {
    float s, c;
    sincos(angle * 0.5, s, c);
    return float4(axis * s, c);
}

// Where the instance stands, in the space of its cell (on the ground, before
// its offset).
float3 micro_local(Micro_Instance inst, Micro_Slot slot) {
    float across = slot.cell.x;
    return float3(float(inst.place & 0xffffu) / 65535.0 * across, inst.height, float(inst.place >> 16u) / 65535.0 * across);
}

// How an instance far from the eye is thinned (micro_thin_onset of
// micro.odin): past the onset of its look it is kept by the chance
// (onset / distance)^2 of the chance near, at least MICRO_THIN_KEPT, by a
// hash of its place alone (unit), so the same ones stay however the view
// turns. Those within MICRO_THIN_BAND of the chance of being dropped grow from
// the ground across it, never popping; near, the chance keeps every one
// whole. Those kept widen along the ground by one over the square root of the
// chance, at most MICRO_THIN_WIDEN, so the ground they cover stays.
// grow 0: it is not kept.
struct Micro_Thin {
    float grow;
    float widen;
};

Micro_Thin micro_thin(float distance, float onset, float unit) {
    Micro_Thin t;
    float near = 1.0 / (1.0 - MICRO_THIN_BAND);
    float chance = onset > 0.0 && distance > onset ? max(near * (onset / distance) * (onset / distance), MICRO_THIN_KEPT) : near;
    t.grow = saturate((chance - unit) / (MICRO_THIN_BAND * chance));
    t.widen = clamp(rsqrt(min(chance, 1.0)), 1.0, MICRO_THIN_WIDEN);
    return t;
}

// The unit the thinning keeps an instance by: of its place and its tile alone.
float micro_thin_unit(Micro_Instance inst, Micro_Slot slot) {
    return micro_unit(micro_hash(inst.place ^ asuint(slot.cell.y) ^ 0x68e31da4u));
}

// How an instance is placed in the world, as the pcg layers place theirs
// (pcg.placed_of): a turn about y, a lean, then the slope of the ground, with
// its size and its offset along its own y, from where it stands; then the
// frame of its graph. place: relative to the origin.
struct Micro_Place {
    float3 place;
    float4 rotation;
    float3 size;
};

Micro_Place micro_place(Micro_Instance inst, Micro_Slot slot, Micro_Look look, float3 local) {
    Micro_Place m;
    uint h0 = micro_hash(inst.place ^ asuint(slot.cell.y));
    uint h1 = micro_hash(h0), h2 = micro_hash(h1), h3 = micro_hash(h2), h4 = micro_hash(h3), h5 = micro_hash(h4);
    float3 normal = micro_normal_unpack(inst.normal);
    float4 yaw = micro_turn(float3(0.0, 1.0, 0.0), micro_unit(h0) * look.turn.x);
    float side, along;
    sincos(micro_unit(h1) * 6.2831853, side, along);
    float4 lean = micro_turn(float3(along, 0.0, side), micro_unit(h2) * look.turn.y);
    // From up to the ground leaned toward, which never points down.
    float3 toward = normalize(lerp(float3(0.0, 1.0, 0.0), normal, saturate(look.turn.z)));
    float4 slope = normalize(float4(toward.z, 0.0, -toward.x, 1.0 + toward.y));
    float4 r = micro_rotate(slope, micro_rotate(lean, yaw));
    float s = lerp(look.scale.x, look.scale.y, micro_unit(h3));
    m.size = float3(s, s * lerp(look.scale.z, look.scale.w, micro_unit(h4)), s) * look.turn.w;
    float y = lerp(look.offset.x, look.offset.y, micro_unit(h5));
    // Its own y, turned (the second column of the rotation).
    float3 up = float3(2.0 * (r.x * r.y - r.w * r.z), 1.0 - 2.0 * (r.x * r.x + r.z * r.z), 2.0 * (r.y * r.z + r.w * r.x));
    m.place = transform_point(slot.world, local + up * y);
    m.rotation = normalize(micro_rotate(look.frame, r));
    return m;
}
#endif
