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

#ifndef FFX_COMMON_TYPES_H
#define FFX_COMMON_TYPES_H

#define FFX_PARAMETER_IN        in
#define FFX_PARAMETER_OUT       out
#define FFX_PARAMETER_INOUT     inout
#define FFX_PARAMETER_UNIFORM uniform

#define FfxFloat32Mat4 matrix <float, 4, 4>
#define FfxFloat32Mat3 matrix <float, 3, 3>

/// A typedef for a boolean value.
///
/// @ingroup HLSLTypes
typedef bool FfxBoolean;

/// @defgroup HLSLBaseTypes HLSL 6.1 And Below Types
/// HLSL 6.1 and below type defines for all commonly used variables
/// 
/// @ingroup HLSLTypes

#define FfxFloat32   float
#define FfxFloat32x2 float2
#define FfxFloat32x3 float3
#define FfxFloat32x4 float4

/// A [cacao_placeholder] typedef for matrix type until confirmed.
#define FfxFloat32x4x4 float4x4
#define FfxFloat32x3x4 float3x4
#define FfxFloat32x3x3 float3x3
#define FfxFloat32x2x2 float2x2

/// A typedef for a unsigned 32bit integer.
///
/// @ingroup GPU
typedef uint        FfxUInt32;
typedef uint2       FfxUInt32x2;
typedef uint3       FfxUInt32x3;
typedef uint4       FfxUInt32x4;

typedef int         FfxInt32;
typedef int2        FfxInt32x2;
typedef int3        FfxInt32x3;
typedef int4        FfxInt32x4;

#define FFX_MIN16_SCALAR( TypeName, BaseComponentType )           typedef BaseComponentType TypeName;
#define FFX_MIN16_VECTOR( TypeName, BaseComponentType, COL )      typedef vector<BaseComponentType, COL> TypeName;

#define FFX_16BIT_SCALAR( TypeName, BaseComponentType )           typedef BaseComponentType TypeName;
#define FFX_16BIT_VECTOR( TypeName, BaseComponentType, COL )      typedef vector<BaseComponentType, COL> TypeName;

// Common typedefs:
FFX_MIN16_SCALAR( FFX_MIN16_F , float );
FFX_MIN16_VECTOR( FFX_MIN16_F2, float, 2 );
FFX_MIN16_VECTOR( FFX_MIN16_F3, float, 3 );
FFX_MIN16_VECTOR( FFX_MIN16_F4, float, 4 );

FFX_MIN16_SCALAR( FFX_MIN16_I,  int );
FFX_MIN16_VECTOR( FFX_MIN16_I2, int, 2 );
FFX_MIN16_VECTOR( FFX_MIN16_I3, int, 3 );
FFX_MIN16_VECTOR( FFX_MIN16_I4, int, 4 );

FFX_MIN16_SCALAR( FFX_MIN16_U,  uint );
FFX_MIN16_VECTOR( FFX_MIN16_U2, uint, 2 );
FFX_MIN16_VECTOR( FFX_MIN16_U3, uint, 3 );
FFX_MIN16_VECTOR( FFX_MIN16_U4, uint, 4 );

FFX_16BIT_SCALAR( FFX_F16_t , float );
FFX_16BIT_VECTOR( FFX_F16_t2, float, 2 );
FFX_16BIT_VECTOR( FFX_F16_t3, float, 3 );
FFX_16BIT_VECTOR( FFX_F16_t4, float, 4 );

FFX_16BIT_SCALAR( FFX_I16_t,  int );
FFX_16BIT_VECTOR( FFX_I16_t2, int, 2 );
FFX_16BIT_VECTOR( FFX_I16_t3, int, 3 );
FFX_16BIT_VECTOR( FFX_I16_t4, int, 4 );

FFX_16BIT_SCALAR( FFX_U16_t,  uint );
FFX_16BIT_VECTOR( FFX_U16_t2, uint, 2 );
FFX_16BIT_VECTOR( FFX_U16_t3, uint, 3 );
FFX_16BIT_VECTOR( FFX_U16_t4, uint, 4 );

#endif // #ifndef FFX_COMMON_TYPES_H
