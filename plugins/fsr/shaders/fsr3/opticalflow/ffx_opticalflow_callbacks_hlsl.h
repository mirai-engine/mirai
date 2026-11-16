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

#ifndef FFX_OPTICALFLOW_CALLBACKS_HLSL_H
#define FFX_OPTICALFLOW_CALLBACKS_HLSL_H

#include "../fsr3upscaler/ffx_core.h" // Mirai: the core of fsr3upscaler/

#define FFX_OPTICALFLOW_BLOCK_SIZE 8

#include "ffx_opticalflow_common.h" // Mirai: beside this file


#if defined(FFX_OPTICALFLOW_BIND_CB_COMMON)
    [[vk::binding(FFX_OPTICALFLOW_BIND_CB_COMMON, 0)]] cbuffer cbOF
    {
        FfxInt32x2 iInputLumaResolution;
        FfxUInt32 uOpticalFlowPyramidLevel;
        FfxUInt32 uOpticalFlowPyramidLevelCount;

        FfxUInt32 iFrameIndex;
        FfxUInt32 backbufferTransferFunction;
        FfxFloat32x2 minMaxLuminance;
    };

#endif //FFX_OPTICALFLOW_BIND_CB_COMMON

#if defined(FFX_OPTICALFLOW_BIND_CB_SPD)
[[vk::binding(FFX_OPTICALFLOW_BIND_CB_SPD, 0)]] cbuffer cbOF_SPD{

    FfxUInt32     mips;
    FfxUInt32     numWorkGroups;
    FfxUInt32x2   workGroupOffset;
    FfxUInt32     numWorkGroupOpticalFlowInputPyramid;
    FfxUInt32     pad0_;
    FfxUInt32     pad1_;
    FfxUInt32     pad2_;
};

FfxUInt32 NumWorkGroups()
{
    return numWorkGroupOpticalFlowInputPyramid;
}
#endif //FFX_OPTICALFLOW_BIND_CB_SPD

FfxInt32x2 DisplaySize()
{
    return iInputLumaResolution;
}

FfxUInt32 FrameIndex()
{
    return iFrameIndex;
}

FfxUInt32 BackbufferTransferFunction()
{
    return backbufferTransferFunction;
}

FfxFloat32x2 MinMaxLuminance()
{
    return minMaxLuminance;
}

FfxBoolean CrossedSceneChangeThreshold(FfxFloat32 sceneChangeValue)
{
    return sceneChangeValue > 0.45f;
}

FfxUInt32 OpticalFlowPyramidLevel()
{
    return uOpticalFlowPyramidLevel;
}

FfxUInt32 OpticalFlowPyramidLevelCount()
{
    return uOpticalFlowPyramidLevelCount;
}

FfxInt32x2 OpticalFlowHistogramMaxVelocity()
{
    const FfxInt32 searchRadius = 8;
    FfxInt32 scale = FfxInt32(1) << (OpticalFlowPyramidLevelCount() - 1 - OpticalFlowPyramidLevel());
    FfxInt32 maxVelocity = searchRadius * scale;
    return FfxInt32x2(maxVelocity, maxVelocity);
}

    #if defined(FFX_OPTICALFLOW_BIND_SRV_INPUT_COLOR)
        [[vk::binding(FFX_OPTICALFLOW_BIND_SRV_INPUT_COLOR, 0)]] Texture2D<FfxFloat32x4>                   r_input_color;
    #endif
    #if defined(FFX_OPTICALFLOW_BIND_SRV_INPUT_MOTION_VECTORS)
        [[vk::binding(FFX_OPTICALFLOW_BIND_SRV_INPUT_MOTION_VECTORS, 0)]] Texture2D<FfxFloat32x2>                   r_input_motion_vectors;
    #endif
    #if defined(FFX_OPTICALFLOW_BIND_SRV_OPTICAL_FLOW_INPUT)
        [[vk::binding(FFX_OPTICALFLOW_BIND_SRV_OPTICAL_FLOW_INPUT, 0)]] [[vk::image_format("r8ui")]] Texture2D<FfxUInt32>                      r_optical_flow_input; // Mirai: R8_UINT
    #endif
    #if defined(FFX_OPTICALFLOW_BIND_SRV_OPTICAL_FLOW_PREVIOUS_INPUT)
        [[vk::binding(FFX_OPTICALFLOW_BIND_SRV_OPTICAL_FLOW_PREVIOUS_INPUT, 0)]] [[vk::image_format("r8ui")]] Texture2D<FfxUInt32>                      r_optical_flow_previous_input; // Mirai: R8_UINT
    #endif
    #if defined(FFX_OPTICALFLOW_BIND_SRV_OPTICAL_FLOW)
        [[vk::binding(FFX_OPTICALFLOW_BIND_SRV_OPTICAL_FLOW, 0)]] [[vk::image_format("rg16i")]] Texture2D<FfxInt32x2>                     r_optical_flow; // Mirai: R16G16_SINT
    #endif
    #if defined(FFX_OPTICALFLOW_BIND_SRV_OPTICAL_FLOW_PREVIOUS)
        [[vk::binding(FFX_OPTICALFLOW_BIND_SRV_OPTICAL_FLOW_PREVIOUS, 0)]] [[vk::image_format("rg16i")]] Texture2D<FfxInt32x2>                     r_optical_flow_previous; // Mirai: R16G16_SINT
    #endif
    #if defined(FFX_OPTICALFLOW_BIND_SRV_OPTICAL_FLOW_ADDITIONAL_INFO)
        [[vk::binding(FFX_OPTICALFLOW_BIND_SRV_OPTICAL_FLOW_ADDITIONAL_INFO, 0)]] Texture2D<FfxUInt32x2>                    r_optical_flow_additional_info;
    #endif
    #if defined(FFX_OPTICALFLOW_BIND_SRV_OPTICAL_FLOW_ADDITIONAL_INFO_PREVIOUS)
        [[vk::binding(FFX_OPTICALFLOW_BIND_SRV_OPTICAL_FLOW_ADDITIONAL_INFO_PREVIOUS, 0)]] Texture2D<FfxUInt32x2>                    r_optical_flow_additional_info_previous;
    #endif
    #if defined(FFX_OPTICALFLOW_BIND_SRV_OPTICAL_FLOW_HISTOGRAM)
        [[vk::binding(FFX_OPTICALFLOW_BIND_SRV_OPTICAL_FLOW_HISTOGRAM, 0)]] Texture2D<FfxUInt32>                      r_optical_flow_histogram;
    #endif
    #if defined(FFX_OPTICALFLOW_BIND_SRV_OPTICAL_FLOW_GLOBAL_MOTION_SEARCH)
        [[vk::binding(FFX_OPTICALFLOW_BIND_SRV_OPTICAL_FLOW_GLOBAL_MOTION_SEARCH, 0)]] Texture2D<FfxUInt32>                      r_optical_flow_global_motion_search;
    #endif

    // UAV declarations
    #if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_INPUT)
        [[vk::binding(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_INPUT, 0)]] [[vk::image_format("r8ui")]] RWTexture2D<FfxUInt32>                   rw_optical_flow_input; // Mirai: R8_UINT
    #endif
    #if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_INPUT_LEVEL_1)
        [[vk::binding(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_INPUT_LEVEL_1, 0)]] [[vk::image_format("r8ui")]] globallycoherent RWTexture2D<FfxUInt32>  rw_optical_flow_input_level_1; // Mirai: R8_UINT
    #endif
    #if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_INPUT_LEVEL_2)
        [[vk::binding(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_INPUT_LEVEL_2, 0)]] [[vk::image_format("r8ui")]] globallycoherent RWTexture2D<FfxUInt32>  rw_optical_flow_input_level_2; // Mirai: R8_UINT
    #endif
    #if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_INPUT_LEVEL_3)
        [[vk::binding(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_INPUT_LEVEL_3, 0)]] [[vk::image_format("r8ui")]] globallycoherent RWTexture2D<FfxUInt32>  rw_optical_flow_input_level_3; // Mirai: R8_UINT
    #endif
    #if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_INPUT_LEVEL_4)
        [[vk::binding(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_INPUT_LEVEL_4, 0)]] [[vk::image_format("r8ui")]] globallycoherent RWTexture2D<FfxUInt32>  rw_optical_flow_input_level_4; // Mirai: R8_UINT
    #endif
    #if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_INPUT_LEVEL_5)
        [[vk::binding(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_INPUT_LEVEL_5, 0)]] [[vk::image_format("r8ui")]] globallycoherent RWTexture2D<FfxUInt32>  rw_optical_flow_input_level_5; // Mirai: R8_UINT
    #endif
    #if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_INPUT_LEVEL_6)
        [[vk::binding(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_INPUT_LEVEL_6, 0)]] [[vk::image_format("r8ui")]] globallycoherent RWTexture2D<FfxUInt32>  rw_optical_flow_input_level_6; // Mirai: R8_UINT
    #endif
    #if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW)
        [[vk::binding(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW, 0)]] [[vk::image_format("rg16i")]] RWTexture2D<FfxInt32x2>                   rw_optical_flow; // Mirai: R16G16_SINT
    #endif
    #if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_NEXT_LEVEL)
        [[vk::binding(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_NEXT_LEVEL, 0)]] [[vk::image_format("rg16i")]] RWTexture2D<FfxInt32x2>                   rw_optical_flow_next_level; // Mirai: R16G16_SINT
    #endif
    #if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_ADDITIONAL_INFO)
        [[vk::binding(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_ADDITIONAL_INFO, 0)]] RWTexture2D<FfxUInt32x2>                  rw_optical_flow_additional_info;
    #endif
    #if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_ADDITIONAL_INFO_NEXT_LEVEL)
        [[vk::binding(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_ADDITIONAL_INFO_NEXT_LEVEL, 0)]] RWTexture2D<FfxUInt32x2>                  rw_optical_flow_additional_info_next_level;
    #endif
    #if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_HISTOGRAM)
        [[vk::binding(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_HISTOGRAM, 0)]] RWTexture2D<FfxUInt32>                    rw_optical_flow_histogram;
    #endif
    #if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_GLOBAL_MOTION_SEARCH)
        [[vk::binding(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_GLOBAL_MOTION_SEARCH, 0)]] globallycoherent RWTexture2D<FfxUInt32>   rw_optical_flow_global_motion_search;
    #endif
    #if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_SCD_HISTOGRAM)
        [[vk::binding(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_SCD_HISTOGRAM, 0)]] RWTexture2D<FfxUInt32>                    rw_optical_flow_scd_histogram;
    #endif
    #if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_SCD_PREVIOUS_HISTOGRAM)
        [[vk::binding(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_SCD_PREVIOUS_HISTOGRAM, 0)]] RWTexture2D<FfxFloat32>                   rw_optical_flow_scd_previous_histogram;
    #endif
    #if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_SCD_TEMP)
        [[vk::binding(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_SCD_TEMP, 0)]] RWTexture2D<FfxUInt32>                    rw_optical_flow_scd_temp;
    #endif
    #if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_SCD_OUTPUT)
        [[vk::binding(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_SCD_OUTPUT, 0)]] RWTexture2D<FfxUInt32>                    rw_optical_flow_scd_output;
    #endif

#if defined(FFX_OPTICALFLOW_BIND_SRV_INPUT_COLOR)
FfxFloat32x4 LoadInputColor(FfxUInt32x2 iPxHistory)
{
    return r_input_color[iPxHistory];
}
#endif

#if defined(FFX_OPTICALFLOW_BIND_SRV_INPUT_MOTION_VECTORS)
FfxFloat32x2 LoadGameMotionVector(FfxInt32x2 iPxPos)
{
    FfxFloat32x2 positionScale = FfxFloat32x2(RenderSize()) / DisplaySize();
    return r_input_motion_vectors[iPxPos * positionScale] * motionVectorScale / positionScale;
}
#endif

#if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_INPUT)
void StoreOpticalFlowInput(FfxInt32x2 iPxPos, FfxUInt32 fLuma)
{
    rw_optical_flow_input[iPxPos] = fLuma;
}
#endif

#if defined(FFX_OPTICALFLOW_BIND_SRV_OPTICAL_FLOW_INPUT)
FfxUInt32 LoadOpticalFlowInput(FfxInt32x2 iPxPos)
{
    return r_optical_flow_input[iPxPos];
}
#endif

#if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_INPUT)
FfxUInt32 LoadRwOpticalFlowInput(FfxInt32x2 iPxPos)
{
    return rw_optical_flow_input[iPxPos];
}
#endif

#if defined(FFX_OPTICALFLOW_BIND_SRV_OPTICAL_FLOW_PREVIOUS_INPUT)
FfxUInt32 LoadOpticalFlowPreviousInput(FfxInt32x2 iPxPos)
{
    return r_optical_flow_previous_input[iPxPos];
}
#endif

#if defined(FFX_OPTICALFLOW_BIND_SRV_OPTICAL_FLOW)
FfxInt32x2 LoadOpticalFlow(FfxInt32x2 iPxPos)
{
    return r_optical_flow[iPxPos];
}
#endif

#if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW)
FfxInt32x2 LoadRwOpticalFlow(FfxInt32x2 iPxPos)
{
    return rw_optical_flow[iPxPos];
}
#endif

#if defined(FFX_OPTICALFLOW_BIND_SRV_OPTICAL_FLOW_PREVIOUS)
FfxInt32x2 LoadPreviousOpticalFlow(FfxInt32x2 iPxPos)
{
    return r_optical_flow_previous[iPxPos];
}
#endif

#if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW)
void StoreOpticalFlow(FfxInt32x2 iPxPos, FfxInt32x2 motionVector)
{
    rw_optical_flow[iPxPos] = motionVector;
}
#endif

#if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_NEXT_LEVEL)
void StoreOpticalFlowNextLevel(FfxInt32x2 iPxPos, FfxInt32x2 motionVector)
{
    rw_optical_flow_next_level[iPxPos] = motionVector;
}
#endif

#if defined(FFX_OPTICALFLOW_BIND_SRV_OPTICAL_FLOW_ADDITIONAL_INFO)
FfxUInt32x2 LoadOpticalFlowAdditionalInfo(FfxInt32x2 iPxPos)
{
    return r_optical_flow_additional_info[iPxPos];
}
#endif

#if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_ADDITIONAL_INFO)
FfxUInt32x2 LoadRwOpticalFlowAdditionalInfo(FfxInt32x2 iPxPos)
{
    return rw_optical_flow_additional_info[iPxPos];
}
#endif

#if defined(FFX_OPTICALFLOW_BIND_SRV_OPTICAL_FLOW_ADDITIONAL_INFO_PREVIOUS)
FfxUInt32x2 LoadPreviousOpticalFlowAdditionalInfo(FfxInt32x2 iPxPos)
{
    return r_optical_flow_additional_info_previous[iPxPos];
}
#endif

#if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_ADDITIONAL_INFO)
void StoreOpticalFlowAdditionalInfo(FfxInt32x2 iPxPos, FfxUInt32x2 additionalInfo)
{
    rw_optical_flow_additional_info[iPxPos] = additionalInfo;
}
#endif

#if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_ADDITIONAL_INFO_NEXT_LEVEL)
void StoreOpticalFlowNextLevelAdditionalInfo(FfxInt32x2 iPxPos, FfxUInt32x2 additionalInfo)
{
    rw_optical_flow_additional_info_next_level[iPxPos] = additionalInfo;
}
#endif

#if defined(FFX_OPTICALFLOW_BIND_SRV_OPTICAL_FLOW_HISTOGRAM)
FfxUInt32 LoadOpticalFlowHistogram(FfxInt32x2 iBucketId)
{
    return r_optical_flow_histogram[iBucketId];
}
#endif

#if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_HISTOGRAM)
void AtomicIncrementOpticalFlowHistogram(FfxInt32x2 iBucketId)
{
    InterlockedAdd(rw_optical_flow_histogram[iBucketId], 1);
}
#endif

#if defined(FFX_OPTICALFLOW_BIND_SRV_OPTICAL_FLOW_GLOBAL_MOTION_SEARCH)
FfxInt32x2 LoadGlobalMotionVector()
{
    FfxInt32 vx = FfxInt32(r_optical_flow_global_motion_search[FfxInt32x2(0, 0)]);
    FfxInt32 vy = FfxInt32(r_optical_flow_global_motion_search[FfxInt32x2(1, 0)]);
    return FfxInt32x2(vx, vy);
}
#endif

#if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_GLOBAL_MOTION_SEARCH)
FfxInt32x2 LoadRwGlobalMotionVector()
{
    FfxInt32 vx = FfxInt32(rw_optical_flow_global_motion_search[FfxInt32x2(0, 0)]);
    FfxInt32 vy = FfxInt32(rw_optical_flow_global_motion_search[FfxInt32x2(1, 0)]);
    return FfxInt32x2(vx, vy);
}
#endif

#if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_GLOBAL_MOTION_SEARCH)
FfxUInt32 LoadGlobalMotionValue(FfxInt32 index)
{
    return rw_optical_flow_global_motion_search[FfxInt32x2(index, 0)];
}
#endif

#if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_GLOBAL_MOTION_SEARCH)
void StoreGlobalMotionValue(FfxInt32 index, FfxUInt32 value)
{
    rw_optical_flow_global_motion_search[FfxInt32x2(index, 0)] = value;
}
#endif

#if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_GLOBAL_MOTION_SEARCH)
FfxUInt32 AtomicIncrementGlobalMotionValue(FfxInt32 index)
{
    FfxUInt32 initialValue;
    InterlockedAdd(rw_optical_flow_global_motion_search[FfxInt32x2(index, 0)], 1, initialValue);
    return initialValue;
}
#endif

#if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_SCD_HISTOGRAM)
FfxUInt32 LoadRwSCDHistogram(FfxInt32 iIndex)
{
    return rw_optical_flow_scd_histogram[FfxInt32x2(iIndex, 0)];
}
#endif

#if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_SCD_HISTOGRAM)
void StoreSCDHistogram(FfxInt32 iIndex, FfxUInt32 value)
{
    rw_optical_flow_scd_histogram[FfxInt32x2(iIndex, 0)] = value;
}
#endif

#if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_SCD_HISTOGRAM)
void AtomicIncrementSCDHistogram(FfxInt32 iIndex, FfxUInt32 valueToAdd)
{
    InterlockedAdd(rw_optical_flow_scd_histogram[FfxInt32x2(iIndex, 0)], valueToAdd);
}
#endif

#if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_SCD_PREVIOUS_HISTOGRAM)
FfxFloat32 LoadRwSCDPreviousHistogram(FfxInt32 iIndex)
{
    return rw_optical_flow_scd_previous_histogram[FfxInt32x2(iIndex, 0)];
}
#endif

#if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_SCD_PREVIOUS_HISTOGRAM)
void StoreSCDPreviousHistogram(FfxInt32 iIndex, FfxFloat32 value)
{
    rw_optical_flow_scd_previous_histogram[FfxInt32x2(iIndex, 0)] = value;
}
#endif

#if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_SCD_TEMP)
FfxUInt32 LoadRwSCDTemp(FfxInt32 iIndex)
{
    return rw_optical_flow_scd_temp[FfxInt32x2(iIndex, 0)];
}
#endif

#if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_SCD_TEMP)
void AtomicIncrementSCDTemp(FfxInt32 iIndex, FfxUInt32 valueToAdd)
{
    InterlockedAdd(rw_optical_flow_scd_temp[FfxInt32x2(iIndex, 0)], valueToAdd);
}
#endif

#if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_SCD_TEMP)
void ResetSCDTemp()
{
    rw_optical_flow_scd_temp[FfxInt32x2(0, 0)] = 0;
    rw_optical_flow_scd_temp[FfxInt32x2(1, 0)] = 0;
    rw_optical_flow_scd_temp[FfxInt32x2(2, 0)] = 0;
}
#endif

#if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_SCD_OUTPUT)
FfxUInt32 LoadRwSCDOutput(FfxInt32 iIndex)
{
    return rw_optical_flow_scd_output[FfxInt32x2(iIndex, 0)];
}
#endif

#if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_SCD_OUTPUT)
void StoreSCDOutput(FfxInt32 iIndex, FfxUInt32 value)
{
    rw_optical_flow_scd_output[FfxInt32x2(iIndex, 0)] = value;
}
#endif

#if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_SCD_OUTPUT)
FfxUInt32 AtomicIncrementSCDOutput(FfxInt32 iIndex, FfxUInt32 valueToAdd)
{
    FfxUInt32 initialValue;
    InterlockedAdd(rw_optical_flow_scd_output[FfxInt32x2(iIndex, 0)], valueToAdd, initialValue);
    return initialValue;
}
#endif

#if defined(FFX_OPTICALFLOW_BIND_UAV_DEBUG_VISUALIZATION)
void StoreDebugVisualization(FfxUInt32x2 iPxPos, FfxFloat32x3 fColor)
{
    rw_debug_visualization[iPxPos] = FfxFloat32x4(fColor, 1.f);
}
#endif

#if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_SCD_OUTPUT)
FfxFloat32 GetSceneChangeValue()
{
    if (FrameIndex() <= 5)
        return 1.0;
    else
        return ffxAsFloat(LoadRwSCDOutput(SCD_OUTPUT_SCENE_CHANGE_SLOT));
}

FfxBoolean IsSceneChanged()
{
    if (FrameIndex() <= 5)
    {
        return true;
    }
    else
    {
        return (LoadRwSCDOutput(SCD_OUTPUT_HISTORY_BITS_SLOT) & 0xfu) != 0;
    }
}
#endif

#if defined(FFX_OPTICALFLOW_BIND_SRV_OPTICAL_FLOW_INPUT)
FfxUInt32 LoadFirstImagePackedLuma(FfxInt32x2 iPxPos)
{
    const FfxInt32 lumaTextureWidth = DisplaySize().x >> OpticalFlowPyramidLevel();
    const FfxInt32 lumaTextureHeight = DisplaySize().y >> OpticalFlowPyramidLevel();

    FfxInt32x2 adjustedPos = FfxInt32x2(
        ffxClamp(iPxPos.x, 0, lumaTextureWidth - 4),
        ffxClamp(iPxPos.y, 0, lumaTextureHeight - 1)
    );

    FfxUInt32 luma0 = LoadOpticalFlowInput(adjustedPos + FfxInt32x2(0, 0));
    FfxUInt32 luma1 = LoadOpticalFlowInput(adjustedPos + FfxInt32x2(1, 0));
    FfxUInt32 luma2 = LoadOpticalFlowInput(adjustedPos + FfxInt32x2(2, 0));
    FfxUInt32 luma3 = LoadOpticalFlowInput(adjustedPos + FfxInt32x2(3, 0));

    return GetPackedLuma(lumaTextureWidth, iPxPos.x, luma0, luma1, luma2, luma3);
}
#endif

#if defined(FFX_OPTICALFLOW_BIND_SRV_OPTICAL_FLOW_PREVIOUS_INPUT)
FfxUInt32 LoadSecondImagePackedLuma(FfxInt32x2 iPxPos)
{
    const FfxInt32 lumaTextureWidth = DisplaySize().x >> OpticalFlowPyramidLevel();
    const FfxInt32 lumaTextureHeight = DisplaySize().y >> OpticalFlowPyramidLevel();

    FfxInt32x2 adjustedPos = FfxInt32x2(
        ffxClamp(iPxPos.x, 0, lumaTextureWidth - 4),
        ffxClamp(iPxPos.y, 0, lumaTextureHeight - 1)
    );

    FfxUInt32 luma0 = LoadOpticalFlowPreviousInput(adjustedPos + FfxInt32x2(0, 0));
    FfxUInt32 luma1 = LoadOpticalFlowPreviousInput(adjustedPos + FfxInt32x2(1, 0));
    FfxUInt32 luma2 = LoadOpticalFlowPreviousInput(adjustedPos + FfxInt32x2(2, 0));
    FfxUInt32 luma3 = LoadOpticalFlowPreviousInput(adjustedPos + FfxInt32x2(3, 0));

    return GetPackedLuma(lumaTextureWidth, iPxPos.x, luma0, luma1, luma2, luma3);
}
#endif

void SPD_SetMipmap(int2 iPxPos, int index, float value)
{
    switch (index)
    {
    case 0:
#if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_INPUT_LEVEL_1)
        rw_optical_flow_input_level_1[iPxPos] = FfxUInt32(value);
#endif // #if defined FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_INPUT_LEVEL_1
        break;
    case 1:
#if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_INPUT_LEVEL_2)
        rw_optical_flow_input_level_2[iPxPos] = FfxUInt32(value);
#endif // #if defined FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_INPUT_LEVEL_2
        break;
    case 2:
#if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_INPUT_LEVEL_3)
        rw_optical_flow_input_level_3[iPxPos] = FfxUInt32(value);
#endif // #if defined FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_INPUT_LEVEL_3
        break;
    case 3:
#if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_INPUT_LEVEL_4)
        rw_optical_flow_input_level_4[iPxPos] = FfxUInt32(value);
#endif // #if defined FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_INPUT_LEVEL_4
        break;
    case 4:
#if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_INPUT_LEVEL_5)
        rw_optical_flow_input_level_5[iPxPos] = FfxUInt32(value);
#endif // #if defined FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_INPUT_LEVEL_5
        break;
    case 5:
#if defined(FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_INPUT_LEVEL_6)
        rw_optical_flow_input_level_6[iPxPos] = FfxUInt32(value);
#endif // #if defined FFX_OPTICALFLOW_BIND_UAV_OPTICAL_FLOW_INPUT_LEVEL_6
        break;
    }
}

#endif // FFX_OPTICALFLOW_CALLBACKS_HLSL_H
