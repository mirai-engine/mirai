#ifndef MIRAI_NATIVE_SLANG
#define MIRAI_NATIVE_SLANG
#define MIRAI_REGISTER_INNER(kind, slot) kind ## slot
#define MIRAI_REGISTER(kind, slot) MIRAI_REGISTER_INNER(kind, slot)

// The constants of a stage: a `//! constant name DEFINE` line of its source
// makes DEFINE the next of these, a boolean each pipeline of the stage sets
// (rhi.Shader_Constants) and its driver folds, so `if (DEFINE)` costs nothing
// and one code serves every combination. A source shared with stages that do
// not declare it gives it `false` (#ifndef DEFINE / #define DEFINE false).
// As many as rhi.MAX_SHADER_CONSTANTS. A constant chooses code and what the
// code reads, never what the stage declares to the device: a capability, its
// outputs or the kind of a slot are a `//! variant`.
[vk::constant_id(0)] const bool mirai_constant_0 = false;
[vk::constant_id(1)] const bool mirai_constant_1 = false;
[vk::constant_id(2)] const bool mirai_constant_2 = false;
[vk::constant_id(3)] const bool mirai_constant_3 = false;
[vk::constant_id(4)] const bool mirai_constant_4 = false;
[vk::constant_id(5)] const bool mirai_constant_5 = false;
[vk::constant_id(6)] const bool mirai_constant_6 = false;
[vk::constant_id(7)] const bool mirai_constant_7 = false;

// The index of the texture table varies per pixel and per ray. The marker has
// to be written where the table is indexed: through a function it is lost.
#define mirai_nonuniform(index) NonUniformResourceIndex(index)

// Portable helpers shared by all stages. Resource access uses native Slang
// resources; matrices are column-major to match Odin's GPU data layout.
int2 texture_size(Texture2D<float4> texture, uint mip) {
    uint width, height, levels;
    texture.GetDimensions(mip, width, height, levels);
    return int2(width, height);
}
int2 texture_size(Texture2D<uint4> texture, uint mip) {
    uint width, height, levels;
    texture.GetDimensions(mip, width, height, levels);
    return int2(width, height);
}
int2 texture_size(RWTexture2D<float4> texture) {
    uint width, height;
    texture.GetDimensions(width, height);
    return int2(width, height);
}
int2 texture_size(RWTexture2D<uint4> texture) {
    uint width, height;
    texture.GetDimensions(width, height);
    return int2(width, height);
}
int2 texture_size(RWTexture2D<uint> texture) {
    uint width, height;
    texture.GetDimensions(width, height);
    return int2(width, height);
}
float mod(float x, float y) { return x - y * floor(x / y); }
float2 mod(float2 x, float y) { return x - y * floor(x / y); }
float3 mod(float3 x, float y) { return x - y * floor(x / y); }
float2 unpackSnorm2x16(uint packed) {
    int2 value = int2(int(packed << 16) >> 16, int(packed) >> 16);
    return max(float2(value) / 32767.0, -1.0);
}
float4 unpackUnorm4x8(uint packed) {
    return float4(packed & 255u, (packed >> 8u) & 255u, (packed >> 16u) & 255u, packed >> 24u) / 255.0;
}
#endif
