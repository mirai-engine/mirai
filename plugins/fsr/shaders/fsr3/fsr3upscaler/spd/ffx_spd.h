// This file is part of the FidelityFX SDK.
//
// Copyright (c) 2022-2023 Advanced Micro Devices, Inc. All rights reserved.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
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

//==============================================================================================================================
//                                                     NON-PACKED VERSION
//==============================================================================================================================

//_____________________________________________________________/\_______________________________________________________________

void SpdWorkgroupShuffleBarrier()
{
    GroupMemoryBarrierWithGroupSync();
}

// Only last active workgroup should proceed
bool SpdExitWorkgroup(FfxUInt32 numWorkGroups, FfxUInt32 localInvocationIndex, FfxUInt32 slice)
{
    // global atomic counter
    if (localInvocationIndex == 0)
    {
        SpdIncreaseAtomicCounter(slice);
    }

    SpdWorkgroupShuffleBarrier();
    return (SpdGetAtomicCounter() != (numWorkGroups - 1));
}

// User defined: FfxFloat32x4 SpdReduce4(FfxFloat32x4 v0, FfxFloat32x4 v1, FfxFloat32x4 v2, FfxFloat32x4 v3);
FfxFloat32x4 SpdReduceQuad(FfxFloat32x4 v)
{
    return v;
}

FfxFloat32x4 SpdReduceIntermediate(FfxUInt32x2 i0, FfxUInt32x2 i1, FfxUInt32x2 i2, FfxUInt32x2 i3)
{
    FfxFloat32x4 v0 = SpdLoadIntermediate(i0.x, i0.y);
    FfxFloat32x4 v1 = SpdLoadIntermediate(i1.x, i1.y);
    FfxFloat32x4 v2 = SpdLoadIntermediate(i2.x, i2.y);
    FfxFloat32x4 v3 = SpdLoadIntermediate(i3.x, i3.y);
    return SpdReduce4(v0, v1, v2, v3);
}

FfxFloat32x4 SpdReduceLoad4(FfxUInt32x2 i0, FfxUInt32x2 i1, FfxUInt32x2 i2, FfxUInt32x2 i3, FfxUInt32 slice)
{
    FfxFloat32x4 v0 = SpdLoad(FfxInt32x2(i0), slice);
    FfxFloat32x4 v1 = SpdLoad(FfxInt32x2(i1), slice);
    FfxFloat32x4 v2 = SpdLoad(FfxInt32x2(i2), slice);
    FfxFloat32x4 v3 = SpdLoad(FfxInt32x2(i3), slice);
    return SpdReduce4(v0, v1, v2, v3);
}

FfxFloat32x4 SpdReduceLoad4(FfxUInt32x2 base, FfxUInt32 slice)
{
    return SpdReduceLoad4(FfxUInt32x2(base + FfxUInt32x2(0, 0)), FfxUInt32x2(base + FfxUInt32x2(0, 1)), FfxUInt32x2(base + FfxUInt32x2(1, 0)), FfxUInt32x2(base + FfxUInt32x2(1, 1)), slice);
}

FfxFloat32x4 SpdReduceLoadSourceImage4(FfxUInt32x2 i0, FfxUInt32x2 i1, FfxUInt32x2 i2, FfxUInt32x2 i3, FfxUInt32 slice)
{
    FfxFloat32x4 v0 = SpdLoadSourceImage(FfxInt32x2(i0), slice);
    FfxFloat32x4 v1 = SpdLoadSourceImage(FfxInt32x2(i1), slice);
    FfxFloat32x4 v2 = SpdLoadSourceImage(FfxInt32x2(i2), slice);
    FfxFloat32x4 v3 = SpdLoadSourceImage(FfxInt32x2(i3), slice);
    return SpdReduce4(v0, v1, v2, v3);
}

FfxFloat32x4 SpdReduceLoadSourceImage(FfxUInt32x2 base, FfxUInt32 slice)
{
    return SpdReduceLoadSourceImage4(FfxUInt32x2(base + FfxUInt32x2(0, 0)), FfxUInt32x2(base + FfxUInt32x2(0, 1)), FfxUInt32x2(base + FfxUInt32x2(1, 0)), FfxUInt32x2(base + FfxUInt32x2(1, 1)), slice);
}

void SpdDownsampleMips_0_1_Intrinsics(FfxUInt32 x, FfxUInt32 y, FfxUInt32x2 workGroupID, FfxUInt32 localInvocationIndex, FfxUInt32 mip, FfxUInt32 slice)
{
    FfxFloat32x4 v[4];

    FfxInt32x2 tex = FfxInt32x2(workGroupID.xy * 64) + FfxInt32x2(x * 2, y * 2);
    FfxInt32x2 pix = FfxInt32x2(workGroupID.xy * 32) + FfxInt32x2(x, y);
    v[0]     = SpdReduceLoadSourceImage(tex, slice);
    SpdStore(pix, v[0], 0, slice);

    tex  = FfxInt32x2(workGroupID.xy * 64) + FfxInt32x2(x * 2 + 32, y * 2);
    pix  = FfxInt32x2(workGroupID.xy * 32) + FfxInt32x2(x + 16, y);
    v[1] = SpdReduceLoadSourceImage(tex, slice);
    SpdStore(pix, v[1], 0, slice);

    tex  = FfxInt32x2(workGroupID.xy * 64) + FfxInt32x2(x * 2, y * 2 + 32);
    pix  = FfxInt32x2(workGroupID.xy * 32) + FfxInt32x2(x, y + 16);
    v[2] = SpdReduceLoadSourceImage(tex, slice);
    SpdStore(pix, v[2], 0, slice);

    tex  = FfxInt32x2(workGroupID.xy * 64) + FfxInt32x2(x * 2 + 32, y * 2 + 32);
    pix  = FfxInt32x2(workGroupID.xy * 32) + FfxInt32x2(x + 16, y + 16);
    v[3] = SpdReduceLoadSourceImage(tex, slice);
    SpdStore(pix, v[3], 0, slice);

    if (mip <= 1)
        return;

    v[0] = SpdReduceQuad(v[0]);
    v[1] = SpdReduceQuad(v[1]);
    v[2] = SpdReduceQuad(v[2]);
    v[3] = SpdReduceQuad(v[3]);

    if ((localInvocationIndex % 4) == 0)
    {
        SpdStore(FfxInt32x2(workGroupID.xy * 16) + FfxInt32x2(x / 2, y / 2), v[0], 1, slice);
        SpdStoreIntermediate(x / 2, y / 2, v[0]);

        SpdStore(FfxInt32x2(workGroupID.xy * 16) + FfxInt32x2(x / 2 + 8, y / 2), v[1], 1, slice);
        SpdStoreIntermediate(x / 2 + 8, y / 2, v[1]);

        SpdStore(FfxInt32x2(workGroupID.xy * 16) + FfxInt32x2(x / 2, y / 2 + 8), v[2], 1, slice);
        SpdStoreIntermediate(x / 2, y / 2 + 8, v[2]);

        SpdStore(FfxInt32x2(workGroupID.xy * 16) + FfxInt32x2(x / 2 + 8, y / 2 + 8), v[3], 1, slice);
        SpdStoreIntermediate(x / 2 + 8, y / 2 + 8, v[3]);
    }
}

void SpdDownsampleMips_0_1_LDS(FfxUInt32 x, FfxUInt32 y, FfxUInt32x2 workGroupID, FfxUInt32 localInvocationIndex, FfxUInt32 mip, FfxUInt32 slice)
{
    FfxFloat32x4 v[4];

    FfxInt32x2 tex = FfxInt32x2(workGroupID.xy * 64) + FfxInt32x2(x * 2, y * 2);
    FfxInt32x2 pix = FfxInt32x2(workGroupID.xy * 32) + FfxInt32x2(x, y);
    v[0]     = SpdReduceLoadSourceImage(tex, slice);
    SpdStore(pix, v[0], 0, slice);

    tex  = FfxInt32x2(workGroupID.xy * 64) + FfxInt32x2(x * 2 + 32, y * 2);
    pix  = FfxInt32x2(workGroupID.xy * 32) + FfxInt32x2(x + 16, y);
    v[1] = SpdReduceLoadSourceImage(tex, slice);
    SpdStore(pix, v[1], 0, slice);

    tex  = FfxInt32x2(workGroupID.xy * 64) + FfxInt32x2(x * 2, y * 2 + 32);
    pix  = FfxInt32x2(workGroupID.xy * 32) + FfxInt32x2(x, y + 16);
    v[2] = SpdReduceLoadSourceImage(tex, slice);
    SpdStore(pix, v[2], 0, slice);

    tex  = FfxInt32x2(workGroupID.xy * 64) + FfxInt32x2(x * 2 + 32, y * 2 + 32);
    pix  = FfxInt32x2(workGroupID.xy * 32) + FfxInt32x2(x + 16, y + 16);
    v[3] = SpdReduceLoadSourceImage(tex, slice);
    SpdStore(pix, v[3], 0, slice);

    if (mip <= 1)
        return;

    for (FfxUInt32 i = 0; i < 4; i++)
    {
        SpdStoreIntermediate(x, y, v[i]);
        SpdWorkgroupShuffleBarrier();
        if (localInvocationIndex < 64)
        {
            v[i] = SpdReduceIntermediate(FfxUInt32x2(x * 2 + 0, y * 2 + 0), FfxUInt32x2(x * 2 + 1, y * 2 + 0), FfxUInt32x2(x * 2 + 0, y * 2 + 1), FfxUInt32x2(x * 2 + 1, y * 2 + 1));
            SpdStore(FfxInt32x2(workGroupID.xy * 16) + FfxInt32x2(x + (i % 2) * 8, y + (i / 2) * 8), v[i], 1, slice);
        }
        SpdWorkgroupShuffleBarrier();
    }

    if (localInvocationIndex < 64)
    {
        SpdStoreIntermediate(x + 0, y + 0, v[0]);
        SpdStoreIntermediate(x + 8, y + 0, v[1]);
        SpdStoreIntermediate(x + 0, y + 8, v[2]);
        SpdStoreIntermediate(x + 8, y + 8, v[3]);
    }
}

void SpdDownsampleMips_0_1(FfxUInt32 x, FfxUInt32 y, FfxUInt32x2 workGroupID, FfxUInt32 localInvocationIndex, FfxUInt32 mip, FfxUInt32 slice)
{
    SpdDownsampleMips_0_1_LDS(x, y, workGroupID, localInvocationIndex, mip, slice);
}

void SpdDownsampleMip_2(FfxUInt32 x, FfxUInt32 y, FfxUInt32x2 workGroupID, FfxUInt32 localInvocationIndex, FfxUInt32 mip, FfxUInt32 slice)
{
    if (localInvocationIndex < 64)
    {
        FfxFloat32x4 v = SpdReduceIntermediate(FfxUInt32x2(x * 2 + 0, y * 2 + 0), FfxUInt32x2(x * 2 + 1, y * 2 + 0), FfxUInt32x2(x * 2 + 0, y * 2 + 1), FfxUInt32x2(x * 2 + 1, y * 2 + 1));
        SpdStore(FfxInt32x2(workGroupID.xy * 8) + FfxInt32x2(x, y), v, mip, slice);
        // store to LDS, try to reduce bank conflicts
        // x 0 x 0 x 0 x 0 x 0 x 0 x 0 x 0
        // 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
        // 0 x 0 x 0 x 0 x 0 x 0 x 0 x 0 x
        // 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
        // x 0 x 0 x 0 x 0 x 0 x 0 x 0 x 0
        // ...
        // x 0 x 0 x 0 x 0 x 0 x 0 x 0 x 0
        SpdStoreIntermediate(x * 2 + y % 2, y * 2, v);
    }
}

void SpdDownsampleMip_3(FfxUInt32 x, FfxUInt32 y, FfxUInt32x2 workGroupID, FfxUInt32 localInvocationIndex, FfxUInt32 mip, FfxUInt32 slice)
{
    if (localInvocationIndex < 16)
    {
        // x 0 x 0
        // 0 0 0 0
        // 0 x 0 x
        // 0 0 0 0
        FfxFloat32x4 v =
            SpdReduceIntermediate(FfxUInt32x2(x * 4 + 0 + 0, y * 4 + 0), FfxUInt32x2(x * 4 + 2 + 0, y * 4 + 0), FfxUInt32x2(x * 4 + 0 + 1, y * 4 + 2), FfxUInt32x2(x * 4 + 2 + 1, y * 4 + 2));
        SpdStore(FfxInt32x2(workGroupID.xy * 4) + FfxInt32x2(x, y), v, mip, slice);
        // store to LDS
        // x 0 0 0 x 0 0 0 x 0 0 0 x 0 0 0
        // 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
        // 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
        // 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
        // 0 x 0 0 0 x 0 0 0 x 0 0 0 x 0 0
        // ...
        // 0 0 x 0 0 0 x 0 0 0 x 0 0 0 x 0
        // ...
        // 0 0 0 x 0 0 0 x 0 0 0 x 0 0 0 x
        // ...
        SpdStoreIntermediate(x * 4 + y, y * 4, v);
    }
}

void SpdDownsampleMip_4(FfxUInt32 x, FfxUInt32 y, FfxUInt32x2 workGroupID, FfxUInt32 localInvocationIndex, FfxUInt32 mip, FfxUInt32 slice)
{
    if (localInvocationIndex < 4)
    {
        // x 0 0 0 x 0 0 0
        // ...
        // 0 x 0 0 0 x 0 0
        FfxFloat32x4 v = SpdReduceIntermediate(FfxUInt32x2(x * 8 + 0 + 0 + y * 2, y * 8 + 0),
                                         FfxUInt32x2(x * 8 + 4 + 0 + y * 2, y * 8 + 0),
                                         FfxUInt32x2(x * 8 + 0 + 1 + y * 2, y * 8 + 4),
                                         FfxUInt32x2(x * 8 + 4 + 1 + y * 2, y * 8 + 4));
        SpdStore(FfxInt32x2(workGroupID.xy * 2) + FfxInt32x2(x, y), v, mip, slice);
        // store to LDS
        // x x x x 0 ...
        // 0 ...
        SpdStoreIntermediate(x + y * 2, 0, v);
    }
}

void SpdDownsampleMip_5(FfxUInt32x2 workGroupID, FfxUInt32 localInvocationIndex, FfxUInt32 mip, FfxUInt32 slice)
{
    if (localInvocationIndex < 1)
    {
        // x x x x 0 ...
        // 0 ...
        FfxFloat32x4 v = SpdReduceIntermediate(FfxUInt32x2(0, 0), FfxUInt32x2(1, 0), FfxUInt32x2(2, 0), FfxUInt32x2(3, 0));
        SpdStore(FfxInt32x2(workGroupID.xy), v, mip, slice);
    }
}

void SpdDownsampleMips_6_7(FfxUInt32 x, FfxUInt32 y, FfxUInt32 mips, FfxUInt32 slice)
{
    FfxInt32x2   tex = FfxInt32x2(x * 4 + 0, y * 4 + 0);
    FfxInt32x2   pix = FfxInt32x2(x * 2 + 0, y * 2 + 0);
    FfxFloat32x4 v0  = SpdReduceLoad4(tex, slice);
    SpdStore(pix, v0, 6, slice);

    tex       = FfxInt32x2(x * 4 + 2, y * 4 + 0);
    pix       = FfxInt32x2(x * 2 + 1, y * 2 + 0);
    FfxFloat32x4 v1 = SpdReduceLoad4(tex, slice);
    SpdStore(pix, v1, 6, slice);

    tex       = FfxInt32x2(x * 4 + 0, y * 4 + 2);
    pix       = FfxInt32x2(x * 2 + 0, y * 2 + 1);
    FfxFloat32x4 v2 = SpdReduceLoad4(tex, slice);
    SpdStore(pix, v2, 6, slice);

    tex       = FfxInt32x2(x * 4 + 2, y * 4 + 2);
    pix       = FfxInt32x2(x * 2 + 1, y * 2 + 1);
    FfxFloat32x4 v3 = SpdReduceLoad4(tex, slice);
    SpdStore(pix, v3, 6, slice);

    if (mips <= 7)
        return;
    // no barrier needed, working on values only from the same thread

    FfxFloat32x4 v = SpdReduce4(v0, v1, v2, v3);
    SpdStore(FfxInt32x2(x, y), v, 7, slice);
    SpdStoreIntermediate(x, y, v);
}

void SpdDownsampleNextFour(FfxUInt32 x, FfxUInt32 y, FfxUInt32x2 workGroupID, FfxUInt32 localInvocationIndex, FfxUInt32 baseMip, FfxUInt32 mips, FfxUInt32 slice)
{
    if (mips <= baseMip)
        return;
    SpdWorkgroupShuffleBarrier();
    SpdDownsampleMip_2(x, y, workGroupID, localInvocationIndex, baseMip, slice);

    if (mips <= baseMip + 1)
        return;
    SpdWorkgroupShuffleBarrier();
    SpdDownsampleMip_3(x, y, workGroupID, localInvocationIndex, baseMip + 1, slice);

    if (mips <= baseMip + 2)
        return;
    SpdWorkgroupShuffleBarrier();
    SpdDownsampleMip_4(x, y, workGroupID, localInvocationIndex, baseMip + 2, slice);

    if (mips <= baseMip + 3)
        return;
    SpdWorkgroupShuffleBarrier();
    SpdDownsampleMip_5(workGroupID, localInvocationIndex, baseMip + 3, slice);
}

void SpdDownsample(FfxUInt32x2 workGroupID, FfxUInt32 localInvocationIndex, FfxUInt32 mips, FfxUInt32 numWorkGroups, FfxUInt32 slice)
{
    FfxUInt32x2        sub_xy = ffxRemapForWaveReduction(localInvocationIndex % 64);
    FfxUInt32 x      = sub_xy.x + 8 * ((localInvocationIndex >> 6) % 2);
    FfxUInt32 y      = sub_xy.y + 8 * ((localInvocationIndex >> 7));
    SpdDownsampleMips_0_1(x, y, workGroupID, localInvocationIndex, mips, slice);

    SpdDownsampleNextFour(x, y, workGroupID, localInvocationIndex, 2, mips, slice);

    if (mips <= 6)
        return;

    if (SpdExitWorkgroup(numWorkGroups, localInvocationIndex, slice))
        return;

    SpdResetAtomicCounter(slice);

    // After mip 6 there is only a single workgroup left that downsamples the remaining up to 64x64 texels.
    SpdDownsampleMips_6_7(x, y, mips, slice);

    SpdDownsampleNextFour(x, y, FfxUInt32x2(0, 0), localInvocationIndex, 8, mips, slice);
}

void SpdDownsample(FfxUInt32x2 workGroupID, FfxUInt32 localInvocationIndex, FfxUInt32 mips, FfxUInt32 numWorkGroups, FfxUInt32 slice, FfxUInt32x2 workGroupOffset)
{
    SpdDownsample(workGroupID + workGroupOffset, localInvocationIndex, mips, numWorkGroups, slice);
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

//==============================================================================================================================
//                                                       PACKED VERSION
//==============================================================================================================================

