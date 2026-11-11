// This file is part of the FidelityFX SDK.
//
// Copyright (C) 2024 Advanced Micro Devices, Inc.
// 
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files(the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and /or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions :
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

/// @defgroup HLSLCore HLSL Core
/// HLSL core defines and functions
///
/// @ingroup FfxHLSL

#define DECLARE_SRV_REGISTER(regIndex) t##regIndex
#define DECLARE_UAV_REGISTER(regIndex) u##regIndex
#define DECLARE_CB_REGISTER(regIndex)  b##regIndex
#define FFX_DECLARE_SRV(regIndex)   register(DECLARE_SRV_REGISTER(regIndex))
#define FFX_DECLARE_UAV(regIndex)   register(DECLARE_UAV_REGISTER(regIndex))
#define FFX_DECLARE_CB(regIndex)    register(DECLARE_CB_REGISTER(regIndex))

/// A define for abstracting shared memory between shading languages.
///
/// @ingroup HLSLCore
#define FFX_GROUPSHARED groupshared

/// A define for abstracting compute memory barriers between shading languages.
///
/// @ingroup HLSLCore
#define FFX_GROUP_MEMORY_BARRIER GroupMemoryBarrierWithGroupSync()

/// A define for abstracting compute atomic additions between shading languages.
///
/// @ingroup HLSLCore
#define FFX_ATOMIC_ADD(x, y) InterlockedAdd(x, y)

/// A define for abstracting compute atomic additions between shading languages.
///
/// @ingroup HLSLCore
#define FFX_ATOMIC_ADD_RETURN(x, y, r) InterlockedAdd(x, y, r)

/// A define for abstracting compute atomic OR between shading languages.
///
/// @ingroup HLSLCore
#define FFX_ATOMIC_OR(x, y) InterlockedOr(x, y)

/// A define for abstracting compute atomic min between shading languages.
///
/// @ingroup HLSLCore
#define FFX_ATOMIC_MIN(x, y) InterlockedMin(x, y)

/// A define for abstracting compute atomic max between shading languages.
///
/// @ingroup HLSLCore
#define FFX_ATOMIC_MAX(x, y) InterlockedMax(x, y)

/// A define added to accept static markup on functions to aid CPU/GPU portability of code.
///
/// @ingroup HLSLCore
#define FFX_STATIC static

/// A define for abstracting loop unrolling between shading languages.
///
/// @ingroup HLSLCore
#define FFX_UNROLL [unroll]

/// A define for abstracting a 'greater than' comparison operator between two types.
///
/// @ingroup HLSLCore
#define FFX_GREATER_THAN(x, y) x > y

/// A define for abstracting a 'greater than or equal' comparison operator between two types.
///
/// @ingroup HLSLCore
#define FFX_GREATER_THAN_EQUAL(x, y) x >= y

/// A define for abstracting a 'less than' comparison operator between two types.
///
/// @ingroup HLSLCore
#define FFX_LESS_THAN(x, y) x < y

/// A define for abstracting a 'less than or equal' comparison operator between two types.
///
/// @ingroup HLSLCore
#define FFX_LESS_THAN_EQUAL(x, y) x <= y

/// A define for abstracting an 'equal' comparison operator between two types.
///
/// @ingroup HLSLCore
#define FFX_EQUAL(x, y) x == y

/// A define for abstracting a 'not equal' comparison operator between two types.
///
/// @ingroup HLSLCore
#define FFX_NOT_EQUAL(x, y) x != y

/// A define for abstracting matrix multiply operations between shading languages.
///
/// @ingroup HLSLCore
#define FFX_MATRIX_MULTIPLY(a, b) mul(a, b)

/// A define for abstracting vector transformations between shading languages.
///
/// @ingroup HLSLCore
#define FFX_TRANSFORM_VECTOR(a, b) mul(a, b)

/// A define for abstracting modulo operations between shading languages.
///
/// @ingroup HLSLCore
#define FFX_MODULO(a, b) (fmod(a, b))

/// Broadcast a scalar value to a 1-dimensional floating point vector.
///
/// @ingroup HLSLCore
#define FFX_BROADCAST_FLOAT32(x) FfxFloat32(x)

/// Broadcast a scalar value to a 2-dimensional floating point vector.
///
/// @ingroup HLSLCore
#define FFX_BROADCAST_FLOAT32X2(x) FfxFloat32(x)

/// Broadcast a scalar value to a 3-dimensional floating point vector.
///
/// @ingroup HLSLCore
#define FFX_BROADCAST_FLOAT32X3(x) FfxFloat32(x)

/// Broadcast a scalar value to a 4-dimensional floating point vector.
///
/// @ingroup HLSLCore
#define FFX_BROADCAST_FLOAT32X4(x) FfxFloat32(x)

/// Broadcast a scalar value to a 1-dimensional unsigned integer vector.
///
/// @ingroup HLSLCore
#define FFX_BROADCAST_UINT32(x) FfxUInt32(x)

/// Broadcast a scalar value to a 2-dimensional unsigned integer vector.
///
/// @ingroup HLSLCore
#define FFX_BROADCAST_UINT32X2(x) FfxUInt32(x)

/// Broadcast a scalar value to a 4-dimensional unsigned integer vector.
///
/// @ingroup HLSLCore
#define FFX_BROADCAST_UINT32X3(x) FfxUInt32(x)

/// Broadcast a scalar value to a 4-dimensional unsigned integer vector.
///
/// @ingroup HLSLCore
#define FFX_BROADCAST_UINT32X4(x) FfxUInt32(x)

/// Broadcast a scalar value to a 1-dimensional signed integer vector.
///
/// @ingroup HLSLCore
#define FFX_BROADCAST_INT32(x) FfxInt32(x)

/// Broadcast a scalar value to a 2-dimensional signed integer vector.
///
/// @ingroup HLSLCore
#define FFX_BROADCAST_INT32X2(x) FfxInt32(x)

/// Broadcast a scalar value to a 3-dimensional signed integer vector.
///
/// @ingroup HLSLCore
#define FFX_BROADCAST_INT32X3(x) FfxInt32(x)

/// Broadcast a scalar value to a 4-dimensional signed integer vector.
///
/// @ingroup HLSLCore
#define FFX_BROADCAST_INT32X4(x) FfxInt32(x)

/// Broadcast a scalar value to a 1-dimensional half-precision floating point vector.
///
/// @ingroup HLSLCore
#define FFX_BROADCAST_MIN_FLOAT16(a)   FFX_MIN16_F(a)

/// Broadcast a scalar value to a 2-dimensional half-precision floating point vector.
///
/// @ingroup HLSLCore
#define FFX_BROADCAST_MIN_FLOAT16X2(a) FFX_MIN16_F(a)

/// Broadcast a scalar value to a 3-dimensional half-precision floating point vector.
///
/// @ingroup HLSLCore
#define FFX_BROADCAST_MIN_FLOAT16X3(a) FFX_MIN16_F(a)

/// Broadcast a scalar value to a 4-dimensional half-precision floating point vector.
///
/// @ingroup HLSLCore
#define FFX_BROADCAST_MIN_FLOAT16X4(a) FFX_MIN16_F(a)

/// Broadcast a scalar value to a 1-dimensional half-precision unsigned integer vector.
///
/// @ingroup HLSLCore
#define FFX_BROADCAST_MIN_UINT16(a)   FFX_MIN16_U(a)

/// Broadcast a scalar value to a 2-dimensional half-precision unsigned integer vector.
///
/// @ingroup HLSLCore
#define FFX_BROADCAST_MIN_UINT16X2(a) FFX_MIN16_U(a)

/// Broadcast a scalar value to a 3-dimensional half-precision unsigned integer vector.
///
/// @ingroup HLSLCore
#define FFX_BROADCAST_MIN_UINT16X3(a) FFX_MIN16_U(a)

/// Broadcast a scalar value to a 4-dimensional half-precision unsigned integer vector.
///
/// @ingroup HLSLCore
#define FFX_BROADCAST_MIN_UINT16X4(a) FFX_MIN16_U(a)

/// Broadcast a scalar value to a 1-dimensional half-precision signed integer vector.
///
/// @ingroup HLSLCore
#define FFX_BROADCAST_MIN_INT16(a)   FFX_MIN16_I(a)

/// Broadcast a scalar value to a 2-dimensional half-precision signed integer vector.
///
/// @ingroup HLSLCore
#define FFX_BROADCAST_MIN_INT16X2(a) FFX_MIN16_I(a)

/// Broadcast a scalar value to a 3-dimensional half-precision signed integer vector.
///
/// @ingroup HLSLCore
#define FFX_BROADCAST_MIN_INT16X3(a) FFX_MIN16_I(a)

/// Broadcast a scalar value to a 4-dimensional half-precision signed integer vector.
///
/// @ingroup HLSLCore
#define FFX_BROADCAST_MIN_INT16X4(a) FFX_MIN16_I(a)

/// Convert FfxFloat32 to half (in lower 16-bits of output).
/// 
/// This function implements the same fast technique that is documented here: ftp://ftp.fox-toolkit.org/pub/fasthalffloatconversion.pdf
/// 
/// The function supports denormals.
/// 
/// Some conversion rules are to make computations possibly "safer" on the GPU,
///  -INF & -NaN -> -65504
///  +INF & +NaN -> +65504
///
/// @param [in] f               The 32bit floating point value to convert.
/// 
/// @returns
/// The closest 16bit floating point value to <c><i>f</i></c>.
/// 
/// @ingroup HLSLCore
#define ffxF32ToF16 f32tof16

/// Pack 2x32-bit floating point values in a single 32bit value.
///
/// This function first converts each component of <c><i>value</i></c> into their nearest 16-bit floating
/// point representation, and then stores the X and Y components in the lower and upper 16 bits of the
/// 32bit unsigned integer respectively.
///
/// @param [in] value               A 2-dimensional floating point value to convert and pack.
///
/// @returns
/// A packed 32bit value containing 2 16bit floating point values.
///
/// @ingroup HLSLCore
FfxUInt32 ffxPackHalf2x16(FfxFloat32x2 value)
{
    return ffxF32ToF16(value.x) | (ffxF32ToF16(value.y) << 16);
}

/// Broadcast a scalar value to a 2-dimensional floating point vector.
///
/// @param [in] value               The value to to broadcast.
///
/// @returns
/// A 2-dimensional floating point vector with <c><i>value</i></c> in each component.
///
/// @ingroup HLSLCore
FfxFloat32x2 ffxBroadcast2(FfxFloat32 value)
{
    return FfxFloat32x2(value, value);
}

/// Broadcast a scalar value to a 3-dimensional floating point vector.
///
/// @param [in] value               The value to to broadcast.
///
/// @returns
/// A 3-dimensional floating point vector with <c><i>value</i></c> in each component.
///
/// @ingroup HLSLCore
FfxFloat32x3 ffxBroadcast3(FfxFloat32 value)
{
    return FfxFloat32x3(value, value, value);
}

/// Broadcast a scalar value to a 4-dimensional floating point vector.
///
/// @param [in] value               The value to to broadcast.
///
/// @returns
/// A 4-dimensional floating point vector with <c><i>value</i></c> in each component.
///
/// @ingroup HLSLCore
FfxFloat32x4 ffxBroadcast4(FfxFloat32 value)
{
    return FfxFloat32x4(value, value, value, value);
}

/// Broadcast a scalar value to a 2-dimensional signed integer vector.
///
/// @param [in] value               The value to to broadcast.
///
/// @returns
/// A 2-dimensional signed integer vector with <c><i>value</i></c> in each component.
///
/// @ingroup HLSLCore
FfxInt32x2 ffxBroadcast2(FfxInt32 value)
{
    return FfxInt32x2(value, value);
}

/// Broadcast a scalar value to a 3-dimensional signed integer vector.
///
/// @param [in] value               The value to to broadcast.
///
/// @returns
/// A 3-dimensional signed integer vector with <c><i>value</i></c> in each component.
///
/// @ingroup HLSLCore
FfxInt32x3 ffxBroadcast3(FfxInt32 value)
{
    return FfxInt32x3(value, value, value);
}

/// Broadcast a scalar value to a 4-dimensional signed integer vector.
///
/// @param [in] value               The value to to broadcast.
///
/// @returns
/// A 4-dimensional signed integer vector with <c><i>value</i></c> in each component.
///
/// @ingroup HLSLCore
FfxInt32x4 ffxBroadcast4(FfxInt32 value)
{
    return FfxInt32x4(value, value, value, value);
}

/// Broadcast a scalar value to a 2-dimensional unsigned integer vector.
///
/// @param [in] value               The value to to broadcast.
///
/// @returns
/// A 2-dimensional unsigned integer vector with <c><i>value</i></c> in each component.
///
/// @ingroup HLSLCore
FfxUInt32x2 ffxBroadcast2(FfxUInt32 value)
{
    return FfxUInt32x2(value, value);
}

/// Broadcast a scalar value to a 3-dimensional unsigned integer vector.
///
/// @param [in] value               The value to to broadcast.
///
/// @returns
/// A 3-dimensional unsigned integer vector with <c><i>value</i></c> in each component.
///
/// @ingroup HLSLCore
FfxUInt32x3 ffxBroadcast3(FfxUInt32 value)
{
    return FfxUInt32x3(value, value, value);
}

/// Broadcast a scalar value to a 4-dimensional unsigned integer vector.
///
/// @param [in] value               The value to to broadcast.
///
/// @returns
/// A 4-dimensional unsigned integer vector with <c><i>value</i></c> in each component.
///
/// @ingroup HLSLCore
FfxUInt32x4 ffxBroadcast4(FfxUInt32 value)
{
    return FfxUInt32x4(value, value, value, value);
}

FfxUInt32 ffxBitfieldExtract(FfxUInt32 src, FfxUInt32 off, FfxUInt32 bits)
{
    FfxUInt32 mask = (1u << bits) - 1;
    return (src >> off) & mask;
}

FfxUInt32 ffxBitfieldInsert(FfxUInt32 src, FfxUInt32 ins, FfxUInt32 mask)
{
    return (ins & mask) | (src & (~mask));
}

FfxUInt32 ffxBitfieldInsertMask(FfxUInt32 src, FfxUInt32 ins, FfxUInt32 bits)
{
    FfxUInt32 mask = (1u << bits) - 1;
    return (ins & mask) | (src & (~mask));
}

/// Interprets the bit pattern of x as an unsigned integer.
///
/// @param [in] x               The input value.
///
/// @returns
/// The input interpreted as an unsigned integer.
///
/// @ingroup HLSLCore
FfxUInt32 ffxAsUInt32(FfxFloat32 x)
{
    return asuint(x);
}

/// Interprets the bit pattern of x as an unsigned integer.
///
/// @param [in] x               The input value.
///
/// @returns
/// The input interpreted as an unsigned integer.
///
/// @ingroup HLSLCore
FfxUInt32x2 ffxAsUInt32(FfxFloat32x2 x)
{
    return asuint(x);
}

/// Interprets the bit pattern of x as an unsigned integer.
///
/// @param [in] x               The input value.
///
/// @returns
/// The input interpreted as an unsigned integer.
///
/// @ingroup HLSLCore
FfxUInt32x3 ffxAsUInt32(FfxFloat32x3 x)
{
    return asuint(x);
}

/// Interprets the bit pattern of x as an unsigned integer.
///
/// @param [in] x               The input value.
///
/// @returns
/// The input interpreted as an unsigned integer.
///
/// @ingroup HLSLCore
FfxUInt32x4 ffxAsUInt32(FfxFloat32x4 x)
{
    return asuint(x);
}

/// Interprets the bit pattern of x as a floating-point number.
///
/// @param [in] x               The input value.
///
/// @returns
/// The input interpreted as a floating-point number.
///
/// @ingroup HLSLCore
FfxFloat32 ffxAsFloat(FfxUInt32 x)
{
    return asfloat(x);
}

/// Interprets the bit pattern of x as a floating-point number.
///
/// @param [in] x               The input value.
///
/// @returns
/// The input interpreted as a floating-point number.
///
/// @ingroup HLSLCore
FfxFloat32x2 ffxAsFloat(FfxUInt32x2 x)
{
    return asfloat(x);
}

/// Interprets the bit pattern of x as a floating-point number.
///
/// @param [in] x               The input value.
///
/// @returns
/// The input interpreted as a floating-point number.
///
/// @ingroup HLSLCore
FfxFloat32x3 ffxAsFloat(FfxUInt32x3 x)
{
    return asfloat(x);
}

/// Interprets the bit pattern of x as a floating-point number.
///
/// @param [in] x               The input value.
///
/// @returns
/// The input interpreted as a floating-point number.
///
/// @ingroup HLSLCore
FfxFloat32x4 ffxAsFloat(FfxUInt32x4 x)
{
    return asfloat(x);
}

/// Compute the inverse of a value.
///
/// @param [in] x                   The value to calulate the inverse of.
///
/// @returns
/// The inverse of <c><i>x</i></c>.
///
/// @ingroup HLSLCore
FfxFloat32 ffxReciprocal(FfxFloat32 x)
{
    return rcp(x);
}

/// Compute the inverse of a value.
///
/// @param [in] x                   The value to calulate the inverse of.
///
/// @returns
/// The inverse of <c><i>x</i></c>.
///
/// @ingroup HLSLCore
FfxFloat32x2 ffxReciprocal(FfxFloat32x2 x)
{
    return rcp(x);
}

/// Compute the inverse of a value.
///
/// @param [in] x                   The value to calulate the inverse of.
///
/// @returns
/// The inverse of <c><i>x</i></c>.
///
/// @ingroup HLSLCore
FfxFloat32x3 ffxReciprocal(FfxFloat32x3 x)
{
    return rcp(x);
}

/// Compute the inverse of a value.
///
/// @param [in] x                   The value to calulate the inverse of.
///
/// @returns
/// The inverse of <c><i>x</i></c>.
///
/// @ingroup HLSLCore
FfxFloat32x4 ffxReciprocal(FfxFloat32x4 x)
{
    return rcp(x);
}

/// Compute the inverse square root of a value.
///
/// @param [in] x                   The value to calulate the inverse square root of.
///
/// @returns
/// The inverse square root of <c><i>x</i></c>.
///
/// @ingroup HLSLCore
FfxFloat32 ffxRsqrt(FfxFloat32 x)
{
    return rsqrt(x);
}

/// Compute the inverse square root of a value.
///
/// @param [in] x                   The value to calulate the inverse square root of.
///
/// @returns
/// The inverse square root of <c><i>x</i></c>.
///
/// @ingroup HLSLCore
FfxFloat32x2 ffxRsqrt(FfxFloat32x2 x)
{
    return rsqrt(x);
}

/// Compute the inverse square root of a value.
///
/// @param [in] x                   The value to calulate the inverse square root of.
///
/// @returns
/// The inverse square root of <c><i>x</i></c>.
///
/// @ingroup HLSLCore
FfxFloat32x3 ffxRsqrt(FfxFloat32x3 x)
{
    return rsqrt(x);
}

/// Compute the inverse square root of a value.
///
/// @param [in] x                   The value to calulate the inverse square root of.
///
/// @returns
/// The inverse square root of <c><i>x</i></c>.
///
/// @ingroup HLSLCore
FfxFloat32x4 ffxRsqrt(FfxFloat32x4 x)
{
    return rsqrt(x);
}

/// Compute the linear interopation between two values.
///
/// Implemented by calling the HLSL <c><i>mix</i></c> instrinsic function. Implements the
/// following math:
///
///     (1 - t) * x + t * y
///
/// @param [in] x               The first value to lerp between.
/// @param [in] y               The second value to lerp between.
/// @param [in] t               The value to determine how much of <c><i>x</i></c> and how much of <c><i>y</i></c>.
///
/// @returns
/// A linearly interpolated value between <c><i>x</i></c> and <c><i>y</i></c> according to <c><i>t</i></c>.
///
/// @ingroup HLSLCore
FfxFloat32 ffxLerp(FfxFloat32 x, FfxFloat32 y, FfxFloat32 t)
{
    return lerp(x, y, t);
}

/// Compute the linear interopation between two values.
///
/// Implemented by calling the HLSL <c><i>mix</i></c> instrinsic function. Implements the
/// following math:
///
///     (1 - t) * x + t * y
///
/// @param [in] x               The first value to lerp between.
/// @param [in] y               The second value to lerp between.
/// @param [in] t               The value to determine how much of <c><i>x</i></c> and how much of <c><i>y</i></c>.
///
/// @returns
/// A linearly interpolated value between <c><i>x</i></c> and <c><i>y</i></c> according to <c><i>t</i></c>.
///
/// @ingroup HLSLCore
FfxFloat32x2 ffxLerp(FfxFloat32x2 x, FfxFloat32x2 y, FfxFloat32 t)
{
    return lerp(x, y, t);
}

/// Compute the linear interopation between two values.
///
/// Implemented by calling the HLSL <c><i>mix</i></c> instrinsic function. Implements the
/// following math:
///
///     (1 - t) * x + t * y
///
/// @param [in] x               The first value to lerp between.
/// @param [in] y               The second value to lerp between.
/// @param [in] t               The value to determine how much of <c><i>x</i></c> and how much of <c><i>y</i></c>.
///
/// @returns
/// A linearly interpolated value between <c><i>x</i></c> and <c><i>y</i></c> according to <c><i>t</i></c>.
///
/// @ingroup HLSLCore
FfxFloat32x2 ffxLerp(FfxFloat32x2 x, FfxFloat32x2 y, FfxFloat32x2 t)
{
    return lerp(x, y, t);
}

/// Compute the linear interopation between two values.
///
/// Implemented by calling the HLSL <c><i>mix</i></c> instrinsic function. Implements the
/// following math:
///
///     (1 - t) * x + t * y
///
/// @param [in] x               The first value to lerp between.
/// @param [in] y               The second value to lerp between.
/// @param [in] t               The value to determine how much of <c><i>x</i></c> and how much of <c><i>y</i></c>.
///
/// @returns
/// A linearly interpolated value between <c><i>x</i></c> and <c><i>y</i></c> according to <c><i>t</i></c>.
///
/// @ingroup HLSLCore
FfxFloat32x3 ffxLerp(FfxFloat32x3 x, FfxFloat32x3 y, FfxFloat32 t)
{
    return lerp(x, y, t);
}

/// Compute the linear interopation between two values.
///
/// Implemented by calling the HLSL <c><i>mix</i></c> instrinsic function. Implements the
/// following math:
///
///     (1 - t) * x + t * y
///
/// @param [in] x               The first value to lerp between.
/// @param [in] y               The second value to lerp between.
/// @param [in] t               The value to determine how much of <c><i>x</i></c> and how much of <c><i>y</i></c>.
///
/// @returns
/// A linearly interpolated value between <c><i>x</i></c> and <c><i>y</i></c> according to <c><i>t</i></c>.
///
/// @ingroup HLSLCore
FfxFloat32x3 ffxLerp(FfxFloat32x3 x, FfxFloat32x3 y, FfxFloat32x3 t)
{
    return lerp(x, y, t);
}

/// Compute the linear interopation between two values.
///
/// Implemented by calling the HLSL <c><i>mix</i></c> instrinsic function. Implements the
/// following math:
///
///     (1 - t) * x + t * y
///
/// @param [in] x               The first value to lerp between.
/// @param [in] y               The second value to lerp between.
/// @param [in] t               The value to determine how much of <c><i>x</i></c> and how much of <c><i>y</i></c>.
///
/// @returns
/// A linearly interpolated value between <c><i>x</i></c> and <c><i>y</i></c> according to <c><i>t</i></c>.
///
/// @ingroup HLSLCore
FfxFloat32x4 ffxLerp(FfxFloat32x4 x, FfxFloat32x4 y, FfxFloat32 t)
{
    return lerp(x, y, t);
}

/// Compute the linear interopation between two values.
///
/// Implemented by calling the HLSL <c><i>mix</i></c> instrinsic function. Implements the
/// following math:
///
///     (1 - t) * x + t * y
///
/// @param [in] x               The first value to lerp between.
/// @param [in] y               The second value to lerp between.
/// @param [in] t               The value to determine how much of <c><i>x</i></c> and how much of <c><i>y</i></c>.
///
/// @returns
/// A linearly interpolated value between <c><i>x</i></c> and <c><i>y</i></c> according to <c><i>t</i></c>.
///
/// @ingroup HLSLCore
FfxFloat32x4 ffxLerp(FfxFloat32x4 x, FfxFloat32x4 y, FfxFloat32x4 t)
{
    return lerp(x, y, t);
}

/// Clamp a value to a [0..1] range.
///
/// @param [in] x               The value to clamp to [0..1] range.
///
/// @returns
/// The clamped version of <c><i>x</i></c>.
///
/// @ingroup HLSLCore
FfxFloat32 ffxSaturate(FfxFloat32 x)
{
    return saturate(x);
}

/// Clamp a value to a [0..1] range.
///
/// @param [in] x               The value to clamp to [0..1] range.
///
/// @returns
/// The clamped version of <c><i>x</i></c>.
///
/// @ingroup HLSLCore
FfxFloat32x2 ffxSaturate(FfxFloat32x2 x)
{
    return saturate(x);
}

/// Clamp a value to a [0..1] range.
///
/// @param [in] x               The value to clamp to [0..1] range.
///
/// @returns
/// The clamped version of <c><i>x</i></c>.
///
/// @ingroup HLSLCore
FfxFloat32x3 ffxSaturate(FfxFloat32x3 x)
{
    return saturate(x);
}

/// Clamp a value to a [0..1] range.
///
/// @param [in] x               The value to clamp to [0..1] range.
///
/// @returns
/// The clamped version of <c><i>x</i></c>.
///
/// @ingroup HLSLCore
FfxFloat32x4 ffxSaturate(FfxFloat32x4 x)
{
    return saturate(x);
}

/// Compute the factional part of a decimal value.
///
/// This function calculates <c><i>x - floor(x)</i></c>. Where <c><i>floor</i></c> is the intrinsic HLSL function.
///
/// NOTE: This function should compile down to a single <c><i>V_MAX3_F32</i></c> operation on GCN/RDNA hardware. It is
/// worth further noting that this function is intentionally distinct from the HLSL <c><i>frac</i></c> intrinsic
/// function.
///
/// @param [in] x               The value to compute the fractional part from.
///
/// @returns
/// The fractional part of <c><i>x</i></c>.
///
/// @ingroup HLSLCore
FfxFloat32 ffxFract(FfxFloat32 x)
{
    return x - floor(x);
}

/// Compute the factional part of a decimal value.
///
/// This function calculates <c><i>x - floor(x)</i></c>. Where <c><i>floor</i></c> is the intrinsic HLSL function.
///
/// NOTE: This function should compile down to a single <c><i>V_MAX3_F32</i></c> operation on GCN/RDNA hardware. It is
/// worth further noting that this function is intentionally distinct from the HLSL <c><i>frac</i></c> intrinsic
/// function.
///
/// @param [in] x               The value to compute the fractional part from.
///
/// @returns
/// The fractional part of <c><i>x</i></c>.
///
/// @ingroup HLSLCore
FfxFloat32x2 ffxFract(FfxFloat32x2 x)
{
    return x - floor(x);
}

/// Compute the factional part of a decimal value.
///
/// This function calculates <c><i>x - floor(x)</i></c>. Where <c><i>floor</i></c> is the intrinsic HLSL function.
///
/// NOTE: This function should compile down to a single <c><i>V_MAX3_F32</i></c> operation on GCN/RDNA hardware. It is
/// worth further noting that this function is intentionally distinct from the HLSL <c><i>frac</i></c> intrinsic
/// function.
///
/// @param [in] x               The value to compute the fractional part from.
///
/// @returns
/// The fractional part of <c><i>x</i></c>.
///
/// @ingroup HLSLCore
FfxFloat32x3 ffxFract(FfxFloat32x3 x)
{
    return x - floor(x);
}

/// Compute the factional part of a decimal value.
///
/// This function calculates <c><i>x - floor(x)</i></c>. Where <c><i>floor</i></c> is the intrinsic HLSL function.
///
/// NOTE: This function should compile down to a single <c><i>V_MAX3_F32</i></c> operation on GCN/RDNA hardware. It is
/// worth further noting that this function is intentionally distinct from the HLSL <c><i>frac</i></c> intrinsic
/// function.
///
/// @param [in] x               The value to compute the fractional part from.
///
/// @returns
/// The fractional part of <c><i>x</i></c>.
///
/// @ingroup HLSLCore
FfxFloat32x4 ffxFract(FfxFloat32x4 x)
{
    return x - floor(x);
}

/// Rounds to the nearest integer. In case the fractional part is 0.5, it will round to the nearest even integer.
///
/// @param [in] x               The value to be rounded.
///
/// @returns
/// The nearest integer from <c><i>x</i></c>. The nearest even integer from <c><i>x</i></c> if equidistant from 2 integer.
///
/// @ingroup HLSLCore
FfxFloat32 ffxRound(FfxFloat32 x)
{
    return round(x);
}

/// Rounds to the nearest integer. In case the fractional part is 0.5, it will round to the nearest even integer.
///
/// @param [in] x               The value to be rounded.
///
/// @returns
/// The nearest integer from <c><i>x</i></c>. The nearest even integer from <c><i>x</i></c> if equidistant from 2 integer.
///
/// @ingroup HLSLCore
FfxFloat32x2 ffxRound(FfxFloat32x2 x)
{
    return round(x);
}

/// Rounds to the nearest integer. In case the fractional part is 0.5, it will round to the nearest even integer.
///
/// @param [in] x               The value to be rounded.
///
/// @returns
/// The nearest integer from <c><i>x</i></c>. The nearest even integer from <c><i>x</i></c> if equidistant from 2 integer.
///
/// @ingroup HLSLCore
FfxFloat32x3 ffxRound(FfxFloat32x3 x)
{
    return round(x);
}

/// Rounds to the nearest integer. In case the fractional part is 0.5, it will round to the nearest even integer.
///
/// @param [in] x               The value to be rounded.
///
/// @returns
/// The nearest integer from <c><i>x</i></c>. The nearest even integer from <c><i>x</i></c> if equidistant from 2 integer.
///
/// @ingroup HLSLCore
FfxFloat32x4 ffxRound(FfxFloat32x4 x)
{
    return round(x);
}

/// Compute the maximum of three values.
///
/// NOTE: This function should compile down to a single <c><i>V_MAX3_F32</i></c> operation on GCN/RDNA hardware.
///
/// @param [in] x               The first value to include in the max calculation.
/// @param [in] y               The second value to include in the max calcuation.
/// @param [in] z               The third value to include in the max calcuation.
///
/// @returns
/// The maximum value of <c><i>x</i></c>, <c><i>y</i></c>, and <c><i>z</i></c>.
///
/// @ingroup HLSLCore
FfxFloat32 ffxMax3(FfxFloat32 x, FfxFloat32 y, FfxFloat32 z)
{
    return max(x, max(y, z));
}

/// Compute the maximum of three values.
///
/// NOTE: This function should compile down to a single <c><i>V_MAX3_F32</i></c> operation on GCN/RDNA hardware.
///
/// @param [in] x               The first value to include in the max calculation.
/// @param [in] y               The second value to include in the max calcuation.
/// @param [in] z               The third value to include in the max calcuation.
///
/// @returns
/// The maximum value of <c><i>x</i></c>, <c><i>y</i></c>, and <c><i>z</i></c>.
///
/// @ingroup HLSLCore
FfxFloat32x2 ffxMax3(FfxFloat32x2 x, FfxFloat32x2 y, FfxFloat32x2 z)
{
    return max(x, max(y, z));
}

/// Compute the maximum of three values.
///
/// NOTE: This function should compile down to a single <c><i>V_MAX3_F32</i></c> operation on GCN/RDNA hardware.
///
/// @param [in] x               The first value to include in the max calculation.
/// @param [in] y               The second value to include in the max calcuation.
/// @param [in] z               The third value to include in the max calcuation.
///
/// @returns
/// The maximum value of <c><i>x</i></c>, <c><i>y</i></c>, and <c><i>z</i></c>.
///
/// @ingroup HLSLCore
FfxFloat32x3 ffxMax3(FfxFloat32x3 x, FfxFloat32x3 y, FfxFloat32x3 z)
{
    return max(x, max(y, z));
}

/// Compute the maximum of three values.
///
/// NOTE: This function should compile down to a single <c><i>V_MAX3_F32</i></c> operation on GCN/RDNA hardware.
///
/// @param [in] x               The first value to include in the max calculation.
/// @param [in] y               The second value to include in the max calcuation.
/// @param [in] z               The third value to include in the max calcuation.
///
/// @returns
/// The maximum value of <c><i>x</i></c>, <c><i>y</i></c>, and <c><i>z</i></c>.
///
/// @ingroup HLSLCore
FfxFloat32x4 ffxMax3(FfxFloat32x4 x, FfxFloat32x4 y, FfxFloat32x4 z)
{
    return max(x, max(y, z));
}

/// Compute the maximum of three values.
///
/// NOTE: This function should compile down to a single <c><i>V_MAX3_F32</i></c> operation on GCN/RDNA hardware.
///
/// @param [in] x               The first value to include in the max calculation.
/// @param [in] y               The second value to include in the max calcuation.
/// @param [in] z               The third value to include in the max calcuation.
///
/// @returns
/// The maximum value of <c><i>x</i></c>, <c><i>y</i></c>, and <c><i>z</i></c>.
///
/// @ingroup HLSLCore
FfxUInt32 ffxMax3(FfxUInt32 x, FfxUInt32 y, FfxUInt32 z)
{
    return max(x, max(y, z));
}

/// Compute the maximum of three values.
///
/// NOTE: This function should compile down to a single <c><i>V_MAX3_F32</i></c> operation on GCN/RDNA hardware.
///
/// @param [in] x               The first value to include in the max calculation.
/// @param [in] y               The second value to include in the max calcuation.
/// @param [in] z               The third value to include in the max calcuation.
///
/// @returns
/// The maximum value of <c><i>x</i></c>, <c><i>y</i></c>, and <c><i>z</i></c>.
///
/// @ingroup HLSLCore
FfxUInt32x2 ffxMax3(FfxUInt32x2 x, FfxUInt32x2 y, FfxUInt32x2 z)
{
    return max(x, max(y, z));
}

/// Compute the maximum of three values.
///
/// NOTE: This function should compile down to a single <c><i>V_MAX3_F32</i></c> operation on GCN/RDNA hardware.
///
/// @param [in] x               The first value to include in the max calculation.
/// @param [in] y               The second value to include in the max calcuation.
/// @param [in] z               The third value to include in the max calcuation.
///
/// @returns
/// The maximum value of <c><i>x</i></c>, <c><i>y</i></c>, and <c><i>z</i></c>.
///
/// @ingroup HLSLCore
FfxUInt32x3 ffxMax3(FfxUInt32x3 x, FfxUInt32x3 y, FfxUInt32x3 z)
{
    return max(x, max(y, z));
}

/// Compute the maximum of three values.
///
/// NOTE: This function should compile down to a single <c><i>V_MAX3_F32</i></c> operation on GCN/RDNA hardware.
///
/// @param [in] x               The first value to include in the max calculation.
/// @param [in] y               The second value to include in the max calcuation.
/// @param [in] z               The third value to include in the max calcuation.
///
/// @returns
/// The maximum value of <c><i>x</i></c>, <c><i>y</i></c>, and <c><i>z</i></c>.
///
/// @ingroup HLSLCore
FfxUInt32x4 ffxMax3(FfxUInt32x4 x, FfxUInt32x4 y, FfxUInt32x4 z)
{
    return max(x, max(y, z));
}

/// Compute the median of three values.
///
/// NOTE: This function should compile down to a single <c><i>V_MED3_F32</i></c> operation on GCN/RDNA hardware.
///
/// @param [in] x               The first value to include in the median calculation.
/// @param [in] y               The second value to include in the median calcuation.
/// @param [in] z               The third value to include in the median calcuation.
///
/// @returns
/// The median value of <c><i>x</i></c>, <c><i>y</i></c>, and <c><i>z</i></c>.
///
/// @ingroup HLSLCore
FfxFloat32 ffxMed3(FfxFloat32 x, FfxFloat32 y, FfxFloat32 z)
{
    return max(min(x, y), min(max(x, y), z));
}

/// Compute the median of three values.
///
/// NOTE: This function should compile down to a single <c><i>V_MED3_F32</i></c> operation on GCN/RDNA hardware.
///
/// @param [in] x               The first value to include in the median calculation.
/// @param [in] y               The second value to include in the median calcuation.
/// @param [in] z               The third value to include in the median calcuation.
///
/// @returns
/// The median value of <c><i>x</i></c>, <c><i>y</i></c>, and <c><i>z</i></c>.
///
/// @ingroup HLSLCore
FfxFloat32x2 ffxMed3(FfxFloat32x2 x, FfxFloat32x2 y, FfxFloat32x2 z)
{
    return max(min(x, y), min(max(x, y), z));
}

/// Compute the median of three values.
///
/// NOTE: This function should compile down to a single <c><i>V_MED3_F32</i></c> operation on GCN/RDNA hardware.
///
/// @param [in] x               The first value to include in the median calculation.
/// @param [in] y               The second value to include in the median calcuation.
/// @param [in] z               The third value to include in the median calcuation.
///
/// @returns
/// The median value of <c><i>x</i></c>, <c><i>y</i></c>, and <c><i>z</i></c>.
///
/// @ingroup HLSLCore
FfxFloat32x3 ffxMed3(FfxFloat32x3 x, FfxFloat32x3 y, FfxFloat32x3 z)
{
    return max(min(x, y), min(max(x, y), z));
}

/// Compute the median of three values.
///
/// NOTE: This function should compile down to a single <c><i>V_MED3_F32</i></c> operation on GCN/RDNA hardware.
///
/// @param [in] x               The first value to include in the median calculation.
/// @param [in] y               The second value to include in the median calcuation.
/// @param [in] z               The third value to include in the median calcuation.
///
/// @returns
/// The median value of <c><i>x</i></c>, <c><i>y</i></c>, and <c><i>z</i></c>.
///
/// @ingroup HLSLCore
FfxFloat32x4 ffxMed3(FfxFloat32x4 x, FfxFloat32x4 y, FfxFloat32x4 z)
{
    return max(min(x, y), min(max(x, y), z));
}

/// Compute the median of three values.
///
/// NOTE: This function should compile down to a single <c><i>V_MED3_F32</i></c> operation on GCN/RDNA hardware.
///
/// @param [in] x               The first value to include in the median calculation.
/// @param [in] y               The second value to include in the median calcuation.
/// @param [in] z               The third value to include in the median calcuation.
///
/// @returns
/// The median value of <c><i>x</i></c>, <c><i>y</i></c>, and <c><i>z</i></c>.
///
/// @ingroup HLSL
FfxInt32 ffxMed3(FfxInt32 x, FfxInt32 y, FfxInt32 z)
{
    return max(min(x, y), min(max(x, y), z));
    // return min(max(min(y, z), x), max(y, z));
    // return max(max(x, y), z) == x ? max(y, z) : (max(max(x, y), z) == y ? max(x, z) : max(x, y));
}

/// Compute the median of three values.
///
/// NOTE: This function should compile down to a single <c><i>V_MED3_F32</i></c> operation on GCN/RDNA hardware.
///
/// @param [in] x               The first value to include in the median calculation.
/// @param [in] y               The second value to include in the median calcuation.
/// @param [in] z               The third value to include in the median calcuation.
///
/// @returns
/// The median value of <c><i>x</i></c>, <c><i>y</i></c>, and <c><i>z</i></c>.
///
/// @ingroup HLSL
FfxInt32x2 ffxMed3(FfxInt32x2 x, FfxInt32x2 y, FfxInt32x2 z)
{
    return max(min(x, y), min(max(x, y), z));
    // return min(max(min(y, z), x), max(y, z));
    // return max(max(x, y), z) == x ? max(y, z) : (max(max(x, y), z) == y ? max(x, z) : max(x, y));
}

/// Compute the median of three values.
///
/// NOTE: This function should compile down to a single <c><i>V_MED3_F32</i></c> operation on GCN/RDNA hardware.
///
/// @param [in] x               The first value to include in the median calculation.
/// @param [in] y               The second value to include in the median calcuation.
/// @param [in] z               The third value to include in the median calcuation.
///
/// @returns
/// The median value of <c><i>x</i></c>, <c><i>y</i></c>, and <c><i>z</i></c>.
///
/// @ingroup HLSL
FfxInt32x3 ffxMed3(FfxInt32x3 x, FfxInt32x3 y, FfxInt32x3 z)
{
    return max(min(x, y), min(max(x, y), z));
}

/// Compute the median of three values.
///
/// NOTE: This function should compile down to a single <c><i>V_MED3_I32</i></c> operation on GCN/RDNA hardware.
///
/// @param [in] x               The first value to include in the median calculation.
/// @param [in] y               The second value to include in the median calcuation.
/// @param [in] z               The third value to include in the median calcuation.
///
/// @returns
/// The median value of <c><i>x</i></c>, <c><i>y</i></c>, and <c><i>z</i></c>.
///
/// @ingroup HLSL
FfxInt32x4 ffxMed3(FfxInt32x4 x, FfxInt32x4 y, FfxInt32x4 z)
{
    return max(min(x, y), min(max(x, y), z));
}

/// Compute the minimum of three values.
///
/// NOTE: This function should compile down to a single <c><i>V_MIN3_F32</i></c> operation on GCN/RDNA hardware.
///
/// @param [in] x               The first value to include in the min calculation.
/// @param [in] y               The second value to include in the min calcuation.
/// @param [in] z               The third value to include in the min calcuation.
///
/// @returns
/// The minimum value of <c><i>x</i></c>, <c><i>y</i></c>, and <c><i>z</i></c>.
///
/// @ingroup HLSLCore
FfxFloat32 ffxMin3(FfxFloat32 x, FfxFloat32 y, FfxFloat32 z)
{
    return min(x, min(y, z));
}

/// Compute the minimum of three values.
///
/// NOTE: This function should compile down to a single <c><i>V_MIN3_F32</i></c> operation on GCN/RDNA hardware.
///
/// @param [in] x               The first value to include in the min calculation.
/// @param [in] y               The second value to include in the min calcuation.
/// @param [in] z               The third value to include in the min calcuation.
///
/// @returns
/// The minimum value of <c><i>x</i></c>, <c><i>y</i></c>, and <c><i>z</i></c>.
///
/// @ingroup HLSLCore
FfxFloat32x2 ffxMin3(FfxFloat32x2 x, FfxFloat32x2 y, FfxFloat32x2 z)
{
    return min(x, min(y, z));
}

/// Compute the minimum of three values.
///
/// NOTE: This function should compile down to a single <c><i>V_MIN3_F32</i></c> operation on GCN/RDNA hardware.
///
/// @param [in] x               The first value to include in the min calculation.
/// @param [in] y               The second value to include in the min calcuation.
/// @param [in] z               The third value to include in the min calcuation.
///
/// @returns
/// The minimum value of <c><i>x</i></c>, <c><i>y</i></c>, and <c><i>z</i></c>.
///
/// @ingroup HLSLCore
FfxFloat32x3 ffxMin3(FfxFloat32x3 x, FfxFloat32x3 y, FfxFloat32x3 z)
{
    return min(x, min(y, z));
}

/// Compute the minimum of three values.
///
/// NOTE: This function should compile down to a single <c><i>V_MIN3_F32</i></c> operation on GCN/RDNA hardware.
///
/// @param [in] x               The first value to include in the min calculation.
/// @param [in] y               The second value to include in the min calcuation.
/// @param [in] z               The third value to include in the min calcuation.
///
/// @returns
/// The minimum value of <c><i>x</i></c>, <c><i>y</i></c>, and <c><i>z</i></c>.
///
/// @ingroup HLSLCore
FfxFloat32x4 ffxMin3(FfxFloat32x4 x, FfxFloat32x4 y, FfxFloat32x4 z)
{
    return min(x, min(y, z));
}

/// Compute the minimum of three values.
///
/// NOTE: This function should compile down to a single <c><i>V_MIN3_F32</i></c> operation on GCN/RDNA hardware.
///
/// @param [in] x               The first value to include in the min calculation.
/// @param [in] y               The second value to include in the min calcuation.
/// @param [in] z               The third value to include in the min calcuation.
///
/// @returns
/// The minimum value of <c><i>x</i></c>, <c><i>y</i></c>, and <c><i>z</i></c>.
///
/// @ingroup HLSLCore
FfxUInt32 ffxMin3(FfxUInt32 x, FfxUInt32 y, FfxUInt32 z)
{
    return min(x, min(y, z));
}

/// Compute the minimum of three values.
///
/// NOTE: This function should compile down to a single <c><i>V_MIN3_F32</i></c> operation on GCN/RDNA hardware.
///
/// @param [in] x               The first value to include in the min calculation.
/// @param [in] y               The second value to include in the min calcuation.
/// @param [in] z               The third value to include in the min calcuation.
///
/// @returns
/// The minimum value of <c><i>x</i></c>, <c><i>y</i></c>, and <c><i>z</i></c>.
///
/// @ingroup HLSLCore
FfxUInt32x2 ffxMin3(FfxUInt32x2 x, FfxUInt32x2 y, FfxUInt32x2 z)
{
    return min(x, min(y, z));
}

/// Compute the minimum of three values.
///
/// NOTE: This function should compile down to a single <c><i>V_MIN3_F32</i></c> operation on GCN/RDNA hardware.
///
/// @param [in] x               The first value to include in the min calculation.
/// @param [in] y               The second value to include in the min calculation.
/// @param [in] z               The third value to include in the min calculation.
///
/// @returns
/// The minimum value of <c><i>x</i></c>, <c><i>y</i></c>, and <c><i>z</i></c>.
///
/// @ingroup HLSLCore
FfxUInt32x3 ffxMin3(FfxUInt32x3 x, FfxUInt32x3 y, FfxUInt32x3 z)
{
    return min(x, min(y, z));
}

/// Compute the minimum of three values.
///
/// NOTE: This function should compile down to a single <c><i>V_MIN3_F32</i></c> operation on GCN/RDNA hardware.
///
/// @param [in] x               The first value to include in the min calculation.
/// @param [in] y               The second value to include in the min calcuation.
/// @param [in] z               The third value to include in the min calcuation.
///
/// @returns
/// The minimum value of <c><i>x</i></c>, <c><i>y</i></c>, and <c><i>z</i></c>.
///
/// @ingroup HLSLCore
FfxUInt32x4 ffxMin3(FfxUInt32x4 x, FfxUInt32x4 y, FfxUInt32x4 z)
{
    return min(x, min(y, z));
}

FfxUInt32 ffxAShrSU1(FfxUInt32 a, FfxUInt32 b)
{
    return FfxUInt32(FfxInt32(a) >> FfxInt32(b));
}

FfxUInt32 ffxPackF32(FfxFloat32x2 v){
    FfxUInt32x2 p = FfxUInt32x2(ffxF32ToF16(FfxFloat32x2(v).x), ffxF32ToF16(FfxFloat32x2(v).y));
	return p.x | (p.y << 16);
}

FfxFloat32x2 ffxUnpackF32(FfxUInt32 a){
    return f16tof32(FfxUInt32x2(a & 0xFFFF, a >> 16));
}

FfxUInt32x2 ffxPackF32x2(FfxFloat32x4 v){
	return FfxUInt32x2(ffxPackF32(v.xy), ffxPackF32(v.zw));
}

FfxFloat32x4 ffxUnpackF32x2(FfxUInt32x2 a){
    return FfxFloat32x4(ffxUnpackF32(a.x), ffxUnpackF32(a.y));
}

//==============================================================================================================================
//                                                          HLSL HALF
//==============================================================================================================================
//==============================================================================================================================
// Need to use manual unpack to get optimal execution (don't use packed types in buffers directly).
// Unpack requires this pattern: https://gpuopen.com/first-steps-implementing-fp16/
FFX_MIN16_F2 ffxUint32ToFloat16x2(FfxUInt32 x)
{
	FfxFloat32x2 t = f16tof32(FfxUInt32x2(x & 0xFFFF, x >> 16));
	return FFX_MIN16_F2(t);
}
FFX_MIN16_F4 ffxUint32x2ToFloat16x4(FfxUInt32x2 x)
{
	return FFX_MIN16_F4(ffxUint32ToFloat16x2(x.x), ffxUint32ToFloat16x2(x.y));
}
FFX_MIN16_U2 ffxUint32ToUint16x2(FfxUInt32 x)
{
	FfxUInt32x2 t = FfxUInt32x2(x & 0xFFFF, x >> 16);
	return FFX_MIN16_U2(t);
}
FFX_MIN16_U4 ffxUint32x2ToUint16x4(FfxUInt32x2 x)
{
	return FFX_MIN16_U4(ffxUint32ToUint16x2(x.x), ffxUint32ToUint16x2(x.y));
}

FfxUInt32x2 ffxFloat16x4ToUint32x2(FFX_MIN16_F4 v)
{
    FfxUInt32x2 result;
    result.x = ffxF32ToF16(v.x) | (ffxF32ToF16(v.y) << 16);
    result.y = ffxF32ToF16(v.z) | (ffxF32ToF16(v.w) << 16);
    return result;
}

/// @brief Inverts the value while avoiding division by zero. If the value is zero, zero is returned.
/// @param v Value to invert.
/// @return If v = 0 returns 0. If v != 0 returns 1/v.
FfxFloat32 ffxInvertSafe(FfxFloat32 v){
    FfxFloat32 s = FfxFloat32(sign(v));
    FfxFloat32 s2 = s*s;
    return s2/(v + s2 - 1.0);
}

/// @brief Inverts the value while avoiding division by zero. If the value is zero, zero is returned.
/// @param v Value to invert.
/// @return If v = 0 returns 0. If v != 0 returns 1/v.
FfxFloat32x2 ffxInvertSafe(FfxFloat32x2 v){
    FfxFloat32x2 s = FfxFloat32x2(sign(v));
    FfxFloat32x2 s2 = s*s;
    return s2/(v + s2 - FfxFloat32x2(1.0, 1.0));
}

/// @brief Inverts the value while avoiding division by zero. If the value is zero, zero is returned.
/// @param v Value to invert.
/// @return If v = 0 returns 0. If v != 0 returns 1/v.
FfxFloat32x3 ffxInvertSafe(FfxFloat32x3 v){
    FfxFloat32x3 s = FfxFloat32x3(sign(v));
    FfxFloat32x3 s2 = s*s;
    return s2/(v + s2 - FfxFloat32x3(1.0, 1.0, 1.0));
}

/// @brief Inverts the value while avoiding division by zero. If the value is zero, zero is returned.
/// @param v Value to invert.
/// @return If v = 0 returns 0. If v != 0 returns 1/v.
FfxFloat32x4 ffxInvertSafe(FfxFloat32x4 v){
    FfxFloat32x4 s = FfxFloat32x4(sign(v));
    FfxFloat32x4 s2 = s*s;
    return s2/(v + s2 - FfxFloat32x4(1.0, 1.0, 1.0, 1.0));
}

#define FFX_UINT32_TO_FLOAT16X2(x) ffxUint32ToFloat16x2(FfxUInt32(x))

//==============================================================================================================================
//                                                         HLSL WAVE
//==============================================================================================================================
#if defined(FFX_WAVE)
// Where 'x' must be a compile time literal.
FfxFloat32 ffxWaveXorF1(FfxFloat32 v, FfxUInt32 x)
{
    return WaveReadLaneAt(v, WaveGetLaneIndex() ^ x);
}
FfxFloat32x2 ffxWaveXorF2(FfxFloat32x2 v, FfxUInt32 x)
{
    return WaveReadLaneAt(v, WaveGetLaneIndex() ^ x);
}
FfxFloat32x3 ffxWaveXorF3(FfxFloat32x3 v, FfxUInt32 x)
{
    return WaveReadLaneAt(v, WaveGetLaneIndex() ^ x);
}
FfxFloat32x4 ffxWaveXorF4(FfxFloat32x4 v, FfxUInt32 x)
{
    return WaveReadLaneAt(v, WaveGetLaneIndex() ^ x);
}
FfxUInt32 ffxWaveXorU1(FfxUInt32 v, FfxUInt32 x)
{
    return WaveReadLaneAt(v, WaveGetLaneIndex() ^ x);
}
FfxUInt32x2 ffxWaveXorU1(FfxUInt32x2 v, FfxUInt32 x)
{
    return WaveReadLaneAt(v, WaveGetLaneIndex() ^ x);
}
FfxUInt32x3 ffxWaveXorU1(FfxUInt32x3 v, FfxUInt32 x)
{
    return WaveReadLaneAt(v, WaveGetLaneIndex() ^ x);
}
FfxUInt32x4 ffxWaveXorU1(FfxUInt32x4 v, FfxUInt32 x)
{
    return WaveReadLaneAt(v, WaveGetLaneIndex() ^ x);
}
FfxBoolean ffxWaveIsFirstLane()
{
    return WaveIsFirstLane();
}
FfxUInt32 ffxWaveLaneIndex()
{
    return WaveGetLaneIndex();
}
FfxBoolean ffxWaveReadAtLaneIndexB1(FfxBoolean v, FfxUInt32 x)
{
    return WaveReadLaneAt(v, x);
}
FfxUInt32 ffxWavePrefixCountBits(FfxBoolean v)
{
    return WavePrefixCountBits(v);
}
FfxUInt32 ffxWaveActiveCountBits(FfxBoolean v)
{
    return WaveActiveCountBits(v);
}
FfxUInt32 ffxWaveReadLaneFirstU1(FfxUInt32 v)
{
    return WaveReadLaneFirst(v);
}
FfxUInt32x2 ffxWaveReadLaneFirstU2(FfxUInt32x2 v)
{
    return WaveReadLaneFirst(v);
}
FfxBoolean ffxWaveReadLaneFirstB1(FfxBoolean v)
{
    return WaveReadLaneFirst(v);
}
FfxUInt32 ffxWaveOr(FfxUInt32 a)
{
    return WaveActiveBitOr(a);
}
FfxUInt32 ffxWaveMin(FfxUInt32 a)
{
    return WaveActiveMin(a);
}
FfxFloat32 ffxWaveMin(FfxFloat32 a)
{
    return WaveActiveMin(a);
}
FfxUInt32 ffxWaveMax(FfxUInt32 a)
{
    return WaveActiveMax(a);
}
FfxFloat32 ffxWaveMax(FfxFloat32 a)
{
    return WaveActiveMax(a);
}
FfxUInt32 ffxWaveSum(FfxUInt32 a)
{
    return WaveActiveSum(a);
}
FfxFloat32 ffxWaveSum(FfxFloat32 a)
{
    return WaveActiveSum(a);
}
FfxUInt32 ffxWaveLaneCount()
{
    return WaveGetLaneCount();
}
FfxBoolean ffxWaveAllTrue(FfxBoolean v)
{
    return WaveActiveAllTrue(v);
}
FfxFloat32 ffxQuadReadX(FfxFloat32 v)
{
    return QuadReadAcrossX(v);
}
FfxFloat32x2 ffxQuadReadX(FfxFloat32x2 v)
{
    return QuadReadAcrossX(v);
}
FfxFloat32 ffxQuadReadY(FfxFloat32 v)
{
    return QuadReadAcrossY(v);
}
FfxFloat32x2 ffxQuadReadY(FfxFloat32x2 v)
{
    return QuadReadAcrossY(v);
}

#endif // #if defined(FFX_WAVE)
