// An instance of a batch as the pool holds it (render.Batch_Instance),
// BATCH_WORDS words: its position, its rotation (quat_pack of std/math, 10
// bits) and its scale along its x, y and z, half floats in two words.
// Decoded here alone: by the scene, and by the instances of the native TLAS;
// encoded on the GPU here alone, by the extensions that fill a batch
// (batch_instance_write), as render.batch_instance encodes it on the CPU.
#ifndef MIRAI_BATCH_INSTANCE_SLANG
#define MIRAI_BATCH_INSTANCE_SLANG
#include "halves.slang"
#include <shared_constants.slang>

// A rotation of quat_pack (std/math) with 10 bits a component: the index of
// the largest one, and the other three in order.
float4 batch_rotation(uint packed) {
    float3 three = (float3(float((packed >> 20u) & 1023u), float((packed >> 10u) & 1023u), float(packed & 1023u)) - 511.0) * (0.70710678 / 511.0);
    float sum = dot(three, three);
    float largest = sqrt(max(1.0 - sum, 0.0));
    uint at = packed >> 30u;
    float4 q = at == 0u ? float4(largest, three) : at == 1u ? float4(three.x, largest, three.yz) : at == 2u ? float4(three.xy, largest, three.z) : float4(three, largest);
    return sum > 1.0 ? normalize(q) : q;
}

// The transform of an instance as a Batch_Instance holds it: its place, its
// packed rotation and its packed scales (x | y << 16, then z); and its inverse.
void batch_instance_placement(float3 p, uint rotation, uint2 packed, out float4 world[3], out float4 inverse[3]) {
    float4 q = batch_rotation(rotation);
    // Positive half floats, without the 16-bit types a device may lack: the
    // bits of the half moved into those of a float, times 2^112.
    float3 scale = float3(asfloat((packed.x & 0x7fffu) << 13u), asfloat(((packed.x >> 16u) & 0x7fffu) << 13u), asfloat((packed.y & 0x7fffu) << 13u)) * asfloat(0x77800000u);
    float3 x = float3(1.0 - 2.0 * (q.y * q.y + q.z * q.z), 2.0 * (q.x * q.y + q.w * q.z), 2.0 * (q.x * q.z - q.w * q.y));
    float3 y = float3(2.0 * (q.x * q.y - q.w * q.z), 1.0 - 2.0 * (q.x * q.x + q.z * q.z), 2.0 * (q.y * q.z + q.w * q.x));
    float3 z = float3(2.0 * (q.x * q.z + q.w * q.y), 2.0 * (q.y * q.z - q.w * q.x), 1.0 - 2.0 * (q.x * q.x + q.y * q.y));
    world[0] = float4(x.x * scale.x, y.x * scale.y, z.x * scale.z, p.x);
    world[1] = float4(x.y * scale.x, y.y * scale.y, z.y * scale.z, p.y);
    world[2] = float4(x.z * scale.x, y.z * scale.y, z.z * scale.z, p.z);
    inverse[0] = float4(x / scale.x, -dot(x, p) / scale.x);
    inverse[1] = float4(y / scale.y, -dot(y, p) / scale.y);
    inverse[2] = float4(z / scale.z, -dot(z, p) / scale.z);
}

// The transform of an instance at p with a basis of its batch in place of
// its own rotation and scale (render.Batch_Desc.basis): the rows of the
// basis, w of the first 1 while the batch has one, and its inverse.
void batch_basis_placement(float3 p, float4 basis[3], inout float4 world[3], inout float4 inverse[3]) {
    if (basis[0].w == 0.0) return;
    float3 a = basis[0].xyz, b = basis[1].xyz, c = basis[2].xyz;
    float3 x = cross(b, c), y = cross(c, a), z = cross(a, b);
    float inv = 1.0 / dot(a, x);
    // The columns of the inverse are the cross products of the rows over the determinant.
    float3 r0 = float3(x.x, y.x, z.x) * inv, r1 = float3(x.y, y.y, z.y) * inv, r2 = float3(x.z, y.z, z.z) * inv;
    world[0] = float4(a, p.x);
    world[1] = float4(b, p.y);
    world[2] = float4(c, p.z);
    inverse[0] = float4(r0, -dot(r0, p));
    inverse[1] = float4(r1, -dot(r1, p));
    inverse[2] = float4(r2, -dot(r2, p));
}
// A unit rotation (x, y, z, w) as quat_pack of std/math packs it with 10
// bits a component: the index of the largest one, the first of those as
// large, and the other three in order, as that one makes them positive.
uint batch_rotation_pack(float4 q) {
    float4 a = abs(q);
    uint at = a.x >= a.y && a.x >= a.z && a.x >= a.w ? 0u : a.y >= a.z && a.y >= a.w ? 1u : a.z >= a.w ? 2u : 3u;
    float largest = at == 0u ? q.x : at == 1u ? q.y : at == 2u ? q.z : q.w;
    float3 three = at == 0u ? q.yzw : at == 1u ? q.xzw : at == 2u ? q.xyw : q.xyz;
    uint3 level = uint3(round(clamp(three * (largest < 0.0 ? -1.0 : 1.0) * 1.41421356, -1.0, 1.0) * 511.0) + 511.0);
    return at << 30u | level.x << 20u | level.y << 10u | level.z;
}

// Writes the BATCH_WORDS words of an instance from `at` of the u32 pool: at
// p from the anchor of its batch, turned by the unit rotation q and scaled
// along its x, y and z by scale, above 0 and below 65504.
void batch_instance_write(RWStructuredBuffer<uint> pool, uint at, float3 p, float4 q, float3 scale) {
    pool[at] = asuint(p.x);
    pool[at + 1u] = asuint(p.y);
    pool[at + 2u] = asuint(p.z);
    pool[at + 3u] = batch_rotation_pack(q);
    pool[at + 4u] = half_nearest(scale.x) | half_nearest(scale.y) << 16u;
    pool[at + 5u] = half_nearest(scale.z);
}
#endif
