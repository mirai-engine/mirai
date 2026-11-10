// An instance of a batch as the pool holds it (render.Batch_Instance),
// BATCH_WORDS words: its position, its rotation (quat_pack of std/math, 10
// bits) and its scale across (x and z) and along y, two half floats. Decoded
// here alone: by the scene, and by the instances of the native TLAS.
#ifndef MIRAI_BATCH_INSTANCE_SLANG
#define MIRAI_BATCH_INSTANCE_SLANG
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
// packed rotation and its packed scales; and its inverse.
void batch_instance_placement(float3 p, uint rotation, uint packed, out float4 world[3], out float4 inverse[3]) {
    float4 q = batch_rotation(rotation);
    // Positive half floats, without the 16-bit types a device may lack: the
    // bits of the half moved into those of a float, times 2^112.
    float2 halves = float2(asfloat((packed & 0x7fffu) << 13u), asfloat(((packed >> 16u) & 0x7fffu) << 13u)) * asfloat(0x77800000u);
    float3 scale = halves.xyx;
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
#endif
