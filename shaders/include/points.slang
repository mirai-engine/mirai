// Material points (render/points.odin): where a pass needs a Surface program
// evaluated. No stage of the engine runs a program: a pass that finds a point
// of a material with one appends it and leaves a head, which names the point
// and the owner the pass resumes for (a pixel, a ray of a probe). The points
// are counted and listed by program (points.comp), the stage of each program
// (surface_points__<program>.comp) evaluates its own and writes what the
// program gives, packed, in the record of the point; then the pass resumes
// over the heads and reads the records. A batch of a pass goes in rounds: a
// resume may append points again, which the next round evaluates.
//
// A ray that crosses glass with a program (a color filter) does not wait for
// it: it takes the mean filter of the instance (Instance.glass) and appends
// the crossing as a filter point, chained to the others of its owner. The
// owner adds, when it resumes, what the exact filters change of what the
// means gave (filters_correction). A crossing that does not fit keeps the mean.
//
// The buffer is words: the header, the bins of the programs (by program id:
// count, offset, cursor and dispatch of each), then the points, their records,
// the list of the window a resolve evaluates by bin, and the heads.
#ifndef MIRAI_POINTS_SLANG
#define MIRAI_POINTS_SLANG
#include "common.slang"
#include "mirai_material.slang"

// The words of the header (POINTS_*) and of a point, a record and a head are
// those of render/abi.
#define POINTS_GROUP 64u
// The resume of a pass goes over heads in groups of 32 threads or more: a
// thread of it takes head group.x * (its threads) + its index in the group.
#define POINTS_HEAD_GROUP 32u

// Material_Point.flags.
#define POINT_FILTER 1u // a glass crossing of a ray, whose filter its owner multiplies in
#define POINT_RUN 2u    // the first filter of a ray: weight is what its filters multiply
#define POINT_EXIT 4u   // a ray leaves a solid through it: the filter is what the face lets through
#define POINT_FACE 8u   // of the mean of its instance (glass_mean.comp): the filter of the face both ways

#ifdef POINTS_SLOT
[[vk::binding(POINTS_SLOT, 0)]] RWStructuredBuffer<uint> material_points : register(MIRAI_REGISTER(u, POINTS_SLOT), space0);

uint points_capacity() { return material_points[POINTS_CAPACITY]; }
uint points_programs() { return material_points[POINTS_PROGRAMS]; }
uint points_bin_count(uint program) { return POINTS_HEADER + program; }
uint points_bin_offset(uint program) { return POINTS_HEADER + points_programs() + program; }
uint points_bin_cursor(uint program) { return POINTS_HEADER + 2u * points_programs() + program; }
uint points_bin_args(uint program) { return POINTS_HEADER + 3u * points_programs() + 3u * program; }
uint points_base() { return POINTS_HEADER + 6u * points_programs(); }
uint points_records() { return points_base() + points_capacity() * POINT_WORDS; }
uint points_list() { return points_records() + points_capacity() * RECORD_WORDS; }
uint points_heads() { return points_list() + points_capacity(); }

// What a pass appends: the hit of a ray on a triangle of an instance, as wide
// as footprint, of a material of program. next: the point appended before it
// for the same owner, of a chain of filters.
struct Material_Point {
    uint instance;
    uint primitive;
    float2 bary;
    float footprint;
    uint program;
    uint flags;
    uint next;
};

// count slots of the counter at word, with one atomic for the lanes of a wave
// that ask: they take consecutive slots. The first of the lane's.
uint points_take(uint word, uint count) {
    uint total = WaveActiveSum(count);
    uint first = 0u;
    if (WaveIsFirstLane()) InterlockedAdd(material_points[word], total, first);
    return WaveReadLaneFirst(first) + WavePrefixSum(count);
}

// The index of the point appended; INVALID when its program has no bin or the
// batch is full: then the pass does without the program.
uint point_append(Material_Point point) {
    if (point.program == 0u || point.program >= points_programs()) return INVALID;
    uint index = points_take(POINTS_COUNT, 1u) + material_points[POINTS_BASE];
    if (index >= material_points[POINTS_LIMIT]) return INVALID;
    point_store(index, point);
    return index;
}

// Room for `count` points one after another, which the caller stores
// (point_store) with programs that have bins: the first, INVALID when they do
// not fit. Those of them that fall in the room anyway are left without a
// program, which no stage evaluates.
uint points_reserve(uint count) {
    uint index = points_take(POINTS_COUNT, count) + material_points[POINTS_BASE];
    uint limit = material_points[POINTS_LIMIT];
    if (index + count <= limit) return index;
    for (uint i = index; i < limit; i++) material_points[points_base() + i * POINT_WORDS + 5u] = 0u;
    return INVALID;
}

void point_store(uint index, Material_Point point) {
    uint at = points_base() + index * POINT_WORDS;
    material_points[at] = point.instance;
    material_points[at + 1u] = point.primitive;
    material_points[at + 2u] = asuint(point.bary.x);
    material_points[at + 3u] = asuint(point.bary.y);
    material_points[at + 4u] = asuint(point.footprint);
    material_points[at + 5u] = point.program | (point.flags << 16u);
    material_points[at + 6u] = point.next;
    material_points[at + 7u] = 0u;
    material_points[at + 8u] = 0u;
    point_record_clear(index);
}

Material_Point point_load(uint index) {
    uint at = points_base() + index * POINT_WORDS;
    Material_Point point;
    point.instance = material_points[at];
    point.primitive = material_points[at + 1u];
    point.bary = float2(asfloat(material_points[at + 2u]), asfloat(material_points[at + 3u]));
    point.footprint = asfloat(material_points[at + 4u]);
    point.program = material_points[at + 5u] & 0xffffu;
    point.flags = material_points[at + 5u] >> 16u;
    point.next = material_points[at + 6u];
    return point;
}

uint record_half2(float a, float b) { return half_bits(a) | (half_bits(b) << 16u); }
float2 record_unhalf2(uint v) { return float2(half_value(v & 0xffffu), half_value(v >> 16u)); }

// What the filters of a run multiply (the first of them, POINT_RUN).
void point_weigh(uint index, float3 weight) {
    uint at = points_base() + index * POINT_WORDS;
    material_points[at + 7u] = record_half2(weight.r, weight.g);
    material_points[at + 8u] = half_bits(weight.b);
}
float3 point_weight(uint index) {
    uint at = points_base() + index * POINT_WORDS;
    return float3(record_unhalf2(material_points[at + 7u]), half_value(material_points[at + 8u] & 0xffffu));
}

// Two words a pass keeps with a point of a surface (not a filter one), which
// its resume reads back.
void point_keep(uint index, float2 kept) {
    uint at = points_base() + index * POINT_WORDS;
    material_points[at + 7u] = asuint(kept.x);
    material_points[at + 8u] = asuint(kept.y);
}
float2 point_kept(uint index) {
    uint at = points_base() + index * POINT_WORDS;
    return float2(asfloat(material_points[at + 7u]), asfloat(material_points[at + 8u]));
}

// A head: the point of the surface its owner waits for (INVALID: none), the
// newest filter point of its chain (INVALID: none), the owner and what the
// pass keeps with it.
#define HEAD_AUX 5u
struct Point_Head {
    uint point;
    uint chain;
    uint owner;
    uint aux[HEAD_AUX];
};
Point_Head point_head(uint point, uint chain, uint owner) {
    Point_Head head;
    head.point = point;
    head.chain = chain;
    head.owner = owner;
    for (uint i = 0u; i < HEAD_AUX; i++) head.aux[i] = 0u;
    return head;
}

// False when the batch is full: then the owner does without what it waited
// for (its program, the exact filters).
bool head_append(Point_Head head) {
    uint index = head_reserve();
    if (index == INVALID) return false;
    head_store(index, head);
    return true;
}
// Room for a head the caller stores later in the same round (head_store):
// INVALID when the batch is full.
uint head_reserve() {
    uint index = points_take(POINTS_HEADS, 1u) + material_points[POINTS_HEADS_BASE];
    return index < material_points[POINTS_HEADS_LIMIT] ? index : INVALID;
}
void head_store(uint index, Point_Head head) {
    uint at = points_heads() + index * HEAD_WORDS;
    material_points[at] = head.point;
    material_points[at + 1u] = head.chain;
    material_points[at + 2u] = head.owner;
    for (uint i = 0u; i < HEAD_AUX; i++) material_points[at + 3u + i] = head.aux[i];
}
// The head of thread i of a resume, false past those of the round.
bool head_of_round(uint i, out Point_Head head) {
    head = point_head(INVALID, INVALID, 0u);
    uint index = material_points[POINTS_HEADS_FROM] + i;
    if (index >= material_points[POINTS_HEADS_TO]) return false;
    uint at = points_heads() + index * HEAD_WORDS;
    head.point = material_points[at];
    head.chain = material_points[at + 1u];
    head.owner = material_points[at + 2u];
    for (uint k = 0u; k < HEAD_AUX; k++) head.aux[k] = material_points[at + 3u + k];
    return true;
}

uint record_oct(float3 n) {
    if (!(dot(n, n) > 0.0)) n = float3(0.0, 0.0, 1.0);
    int2 q = int2(round(clamp(oct_encode(n), -1.0, 1.0) * 32767.0));
    return (uint(q.x) & 0xffffu) | (uint(q.y) << 16u);
}
uint record_unorm16x2(float a, float b) { return uint(round(saturate(a) * 65535.0)) | (uint(round(saturate(b) * 65535.0)) << 16u); }
float2 record_ununorm16x2(uint v) { return float2(float(v & 0xffffu), float(v >> 16u)) / 65535.0; }
uint record_unorm8x4(float4 v) {
    uint4 q = uint4(round(saturate(v) * 255.0));
    return q.x | (q.y << 8u) | (q.z << 16u) | (q.w << 24u);
}

// What the program gave at the point, written by its stage. Its last byte
// says it was written: storing the point clears it (point_record_clear), and
// a point whose program has no pipeline yet keeps it clear, so what reads it
// takes the row of the material instead (point_record_given).
void point_record_store(uint index, Mirai_Surface s) {
    uint at = points_records() + index * RECORD_WORDS;
    material_points[at] = record_half2(s.base_color.r, s.base_color.g);
    material_points[at + 1u] = record_half2(s.base_color.b, s.alpha);
    material_points[at + 2u] = record_oct(s.normal);
    material_points[at + 3u] = record_unorm16x2(s.metallic, s.roughness);
    material_points[at + 4u] = record_unorm16x2(s.occlusion, s.unlit ? 1.0 : 0.0);
    material_points[at + 5u] = asuint(s.emission.r);
    material_points[at + 6u] = asuint(s.emission.g);
    material_points[at + 7u] = asuint(s.emission.b);
    material_points[at + 8u] = record_half2(s.specular_color.r, s.specular_color.g);
    material_points[at + 9u] = record_half2(s.specular_color.b, s.specular_factor);
    material_points[at + 10u] = record_half2(s.specular_ior, s.specular_anisotropy);
    material_points[at + 11u] = record_oct(s.specular_tangent);
    material_points[at + 12u] = record_unorm8x4(float4(s.coat_color, s.coat_weight));
    material_points[at + 13u] = record_half2(s.coat_roughness, s.coat_ior);
    material_points[at + 14u] = record_oct(s.coat_normal);
    material_points[at + 15u] = record_unorm8x4(float4(s.fuzz_color, s.fuzz_weight));
    material_points[at + 16u] = record_half2(s.fuzz_roughness, s.diffuse_transmission_weight);
    material_points[at + 17u] = record_unorm8x4(float4(s.diffuse_transmission_color, 1.0));
}

Mirai_Surface point_record_load(uint index) {
    uint at = points_records() + index * RECORD_WORDS;
    Mirai_Surface s;
    float2 rg = record_unhalf2(material_points[at]);
    float2 ba = record_unhalf2(material_points[at + 1u]);
    s.base_color = float3(rg, ba.x);
    s.alpha = ba.y;
    s.normal = unpack_normal(material_points[at + 2u]);
    float2 mr = record_ununorm16x2(material_points[at + 3u]);
    s.metallic = mr.x;
    s.roughness = mr.y;
    float2 ou = record_ununorm16x2(material_points[at + 4u]);
    s.occlusion = ou.x;
    s.unlit = ou.y > 0.5;
    s.emission = float3(asfloat(material_points[at + 5u]), asfloat(material_points[at + 6u]), asfloat(material_points[at + 7u]));
    float2 sc = record_unhalf2(material_points[at + 8u]);
    float2 sf = record_unhalf2(material_points[at + 9u]);
    s.specular_color = float3(sc, sf.x);
    s.specular_factor = sf.y;
    float2 ia = record_unhalf2(material_points[at + 10u]);
    s.specular_ior = ia.x;
    s.specular_anisotropy = ia.y;
    s.specular_tangent = unpack_normal(material_points[at + 11u]);
    float4 coat = unpackUnorm4x8(material_points[at + 12u]);
    s.coat_color = coat.rgb;
    s.coat_weight = coat.a;
    float2 cr = record_unhalf2(material_points[at + 13u]);
    s.coat_roughness = cr.x;
    s.coat_ior = cr.y;
    s.coat_normal = unpack_normal(material_points[at + 14u]);
    float4 fuzz = unpackUnorm4x8(material_points[at + 15u]);
    s.fuzz_color = fuzz.rgb;
    s.fuzz_weight = fuzz.a;
    float2 fd = record_unhalf2(material_points[at + 16u]);
    s.fuzz_roughness = fd.x;
    s.diffuse_transmission_weight = fd.y;
    s.diffuse_transmission_color = unpackUnorm4x8(material_points[at + 17u]).rgb;
    return s;
}
void point_record_clear(uint index) { material_points[points_records() + index * RECORD_WORDS + 17u] = 0u; }
bool point_record_given(uint index) { return (material_points[points_records() + index * RECORD_WORDS + 17u] >> 24u) != 0u; }

// The record of a filter point is the filter its owner multiplies in, which
// the stage of its program works out in place of the surface: the owner reads
// three halves and not the hit.
void point_filter_store(uint index, float3 filter) {
    uint at = points_records() + index * RECORD_WORDS;
    material_points[at] = record_half2(filter.r, filter.g);
    material_points[at + 1u] = half_bits(filter.b);
    material_points[at + 17u] = 0xffu << 24u;
}
float3 point_filter_record(uint index) {
    uint at = points_records() + index * RECORD_WORDS;
    return float3(record_unhalf2(material_points[at]), half_value(material_points[at + 1u] & 0xffffu));
}

#ifdef MIRAI_SCENE_SLANG
// The filter of a filter point at its hit h, from what its program gave
// there (given, program) or else from the row of its material.
float3 point_filter_at(Material_Point point, Hit_Point h, bool given, Mirai_Surface program) {
    float3 normal = h.normal;
    Material_Sample values = material_sample_given(h.m, h.ctx, instance_color(h.inst, h.m, h.color.rgb), h.inst.emission.rgb, normal, given, program);
    float3 through;
    float3 tint = blend_filter_of(h.m, values, through);
    if ((point.flags & POINT_FACE) != 0u) return blend_face_filter(h.m, tint, through);
    if (!material_solid(h.m)) return tint * through;
    return (point.flags & POINT_EXIT) != 0u ? through : tint * material_absorption(h.m, h.m.thickness) * through;
}

// The filter of a filter point: its record, or the row of its material while
// its program has no pipeline.
float3 point_filter(uint index, Material_Point point) {
    if (point_record_given(index)) return point_filter_record(index);
    return point_filter_at(point, hit_point(point.instance, point.primitive, point.bary, point.footprint), false, (Mirai_Surface)0);
}
#endif
#endif
#endif
