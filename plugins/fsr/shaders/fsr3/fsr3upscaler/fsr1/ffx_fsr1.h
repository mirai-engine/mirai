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

/// @defgroup FfxGPUFsr1 FidelityFX FSR1
/// FidelityFX Super Resolution 1 GPU documentation
/// 
/// @ingroup FfxGPUEffects

/// Setup required constant values for EASU (works on CPU or GPU).
///
/// @param [out] con0
/// @param [out] con1
/// @param [out] con2
/// @param [out] con3
/// @param [in] inputViewportInPixelsX                  The rendered image resolution being upscaled in X dimension.
/// @param [in] inputViewportInPixelsY                  The rendered image resolution being upscaled in Y dimension.
/// @param [in] inputSizeInPixelsX                      The resolution of the resource containing the input image (useful for dynamic resolution) in X dimension.
/// @param [in] inputSizeInPixelsY                      The resolution of the resource containing the input image (useful for dynamic resolution) in Y dimension.
/// @param [in] outputSizeInPixelsX                     The display resolution which the input image gets upscaled to in X dimension.
/// @param [in] outputSizeInPixelsY                     The display resolution which the input image gets upscaled to in Y dimension.
/// 
/// @ingroup FfxGPUFsr1
FFX_STATIC void ffxFsrPopulateEasuConstants(
    FFX_PARAMETER_INOUT FfxUInt32x4 con0,
    FFX_PARAMETER_INOUT FfxUInt32x4 con1,
    FFX_PARAMETER_INOUT FfxUInt32x4 con2,
    FFX_PARAMETER_INOUT FfxUInt32x4 con3,
    FFX_PARAMETER_IN FfxFloat32 inputViewportInPixelsX,
    FFX_PARAMETER_IN FfxFloat32 inputViewportInPixelsY,
    FFX_PARAMETER_IN FfxFloat32 inputSizeInPixelsX,
    FFX_PARAMETER_IN FfxFloat32 inputSizeInPixelsY,
    FFX_PARAMETER_IN FfxFloat32 outputSizeInPixelsX,
    FFX_PARAMETER_IN FfxFloat32 outputSizeInPixelsY)
{
    // Output integer position to a pixel position in viewport.
    con0[0] = ffxAsUInt32(inputViewportInPixelsX * ffxReciprocal(outputSizeInPixelsX));
    con0[1] = ffxAsUInt32(inputViewportInPixelsY * ffxReciprocal(outputSizeInPixelsY));
    con0[2] = ffxAsUInt32(FfxFloat32(0.5) * inputViewportInPixelsX * ffxReciprocal(outputSizeInPixelsX) - FfxFloat32(0.5));
    con0[3] = ffxAsUInt32(FfxFloat32(0.5) * inputViewportInPixelsY * ffxReciprocal(outputSizeInPixelsY) - FfxFloat32(0.5));

    // Viewport pixel position to normalized image space.
    // This is used to get upper-left of 'F' tap.
    con1[0] = ffxAsUInt32(ffxReciprocal(inputSizeInPixelsX));
    con1[1] = ffxAsUInt32(ffxReciprocal(inputSizeInPixelsY));

    // Centers of gather4, first offset from upper-left of 'F'.
    //      +---+---+
    //      |   |   |
    //      +--(0)--+
    //      | b | c |
    //  +---F---+---+---+
    //  | e | f | g | h |
    //  +--(1)--+--(2)--+
    //  | i | j | k | l |
    //  +---+---+---+---+
    //      | n | o |
    //      +--(3)--+
    //      |   |   |
    //      +---+---+
    con1[2] = ffxAsUInt32(FfxFloat32(1.0) * ffxReciprocal(inputSizeInPixelsX));
    con1[3] = ffxAsUInt32(FfxFloat32(-1.0) * ffxReciprocal(inputSizeInPixelsY));

    // These are from (0) instead of 'F'.
    con2[0] = ffxAsUInt32(FfxFloat32(-1.0) * ffxReciprocal(inputSizeInPixelsX));
    con2[1] = ffxAsUInt32(FfxFloat32(2.0) * ffxReciprocal(inputSizeInPixelsY));
    con2[2] = ffxAsUInt32(FfxFloat32(1.0) * ffxReciprocal(inputSizeInPixelsX));
    con2[3] = ffxAsUInt32(FfxFloat32(2.0) * ffxReciprocal(inputSizeInPixelsY));
    con3[0] = ffxAsUInt32(FfxFloat32(0.0) * ffxReciprocal(inputSizeInPixelsX));
    con3[1] = ffxAsUInt32(FfxFloat32(4.0) * ffxReciprocal(inputSizeInPixelsY));
    con3[2] = con3[3] = 0;
}

/// Setup required constant values for EASU (works on CPU or GPU).
///
/// @param [out] con0
/// @param [out] con1
/// @param [out] con2
/// @param [out] con3
/// @param [in] inputViewportInPixelsX              The resolution of the input in the X dimension.
/// @param [in] inputViewportInPixelsY              The resolution of the input in the Y dimension.
/// @param [in] inputSizeInPixelsX                  The input size in pixels in the X dimension.
/// @param [in] inputSizeInPixelsY                  The input size in pixels in the Y dimension.
/// @param [in] outputSizeInPixelsX                 The output size in pixels in the X dimension.
/// @param [in] outputSizeInPixelsY                 The output size in pixels in the Y dimension.
/// @param [in] inputOffsetInPixelsX                The input image offset in the X dimension into the resource containing it (useful for dynamic resolution).
/// @param [in] inputOffsetInPixelsY                The input image offset in the Y dimension into the resource containing it (useful for dynamic resolution).
///
/// @ingroup FfxGPUFsr1
FFX_STATIC void ffxFsrPopulateEasuConstantsOffset(
    FFX_PARAMETER_INOUT FfxUInt32x4 con0,
    FFX_PARAMETER_INOUT FfxUInt32x4 con1,
    FFX_PARAMETER_INOUT FfxUInt32x4 con2,
    FFX_PARAMETER_INOUT FfxUInt32x4 con3,
    FFX_PARAMETER_IN FfxFloat32 inputViewportInPixelsX,
    FFX_PARAMETER_IN FfxFloat32 inputViewportInPixelsY,
    FFX_PARAMETER_IN FfxFloat32 inputSizeInPixelsX,
    FFX_PARAMETER_IN FfxFloat32 inputSizeInPixelsY,
    FFX_PARAMETER_IN FfxFloat32 outputSizeInPixelsX,
    FFX_PARAMETER_IN FfxFloat32 outputSizeInPixelsY,
    FFX_PARAMETER_IN FfxFloat32 inputOffsetInPixelsX,
    FFX_PARAMETER_IN FfxFloat32 inputOffsetInPixelsY)
{
    ffxFsrPopulateEasuConstants(
        con0,
        con1,
        con2,
        con3,
        inputViewportInPixelsX,
        inputViewportInPixelsY,
        inputSizeInPixelsX,
        inputSizeInPixelsY,
        outputSizeInPixelsX,
        outputSizeInPixelsY);

    // override 
    con0[2] = ffxAsUInt32(FfxFloat32(0.5) * inputViewportInPixelsX * ffxReciprocal(outputSizeInPixelsX) - FfxFloat32(0.5) + inputOffsetInPixelsX);
    con0[3] = ffxAsUInt32(FfxFloat32(0.5) * inputViewportInPixelsY * ffxReciprocal(outputSizeInPixelsY) - FfxFloat32(0.5) + inputOffsetInPixelsY);
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//_____________________________________________________________/\_______________________________________________________________
//==============================================================================================================================
//
//                                      FSR - [RCAS] ROBUST CONTRAST ADAPTIVE SHARPENING
//
//------------------------------------------------------------------------------------------------------------------------------
// CAS uses a simplified mechanism to convert local contrast into a variable amount of sharpness.
// RCAS uses a more exact mechanism, solving for the maximum local sharpness possible before clipping.
// RCAS also has a built in process to limit sharpening of what it detects as possible noise.
// RCAS sharper does not support scaling, as it should be applied after EASU scaling.
// Pass EASU output straight into RCAS, no color conversions necessary.
//------------------------------------------------------------------------------------------------------------------------------
// RCAS is based on the following logic.
// RCAS uses a 5 tap filter in a cross pattern (same as CAS),
//    w                n
//  w 1 w  for taps  w m e 
//    w                s
// Where 'w' is the negative lobe weight.
//  output = (w*(n+e+w+s)+m)/(4*w+1)
// RCAS solves for 'w' by seeing where the signal might clip out of the {0 to 1} input range,
//  0 == (w*(n+e+w+s)+m)/(4*w+1) -> w = -m/(n+e+w+s)
//  1 == (w*(n+e+w+s)+m)/(4*w+1) -> w = (1-m)/(n+e+w+s-4*1)
// Then chooses the 'w' which results in no clipping, limits 'w', and multiplies by the 'sharp' amount.
// This solution above has issues with MSAA input as the steps along the gradient cause edge detection issues.
// So RCAS uses 4x the maximum and 4x the minimum (depending on equation)in place of the individual taps.
// As well as switching from 'm' to either the minimum or maximum (depending on side), to help in energy conservation.
// This stabilizes RCAS.
// RCAS does a simple highpass which is normalized against the local contrast then shaped,
//       0.25
//  0.25  -1  0.25
//       0.25
// This is used as a noise detection filter, to reduce the effect of RCAS on grain, and focus on real edges.
//
//  GLSL example for the required callbacks :
// 
//  FfxFloat16x4 FsrRcasLoadH(FfxInt16x2 p){return FfxFloat16x4(imageLoad(imgSrc,FfxInt32x2(p)));}
//  void FsrRcasInputH(inout FfxFloat16 r,inout FfxFloat16 g,inout FfxFloat16 b)
//  {
//    //do any simple input color conversions here or leave empty if none needed
//  }
//  
//  FsrRcasCon need to be called from the CPU or GPU to set up constants.
//  Including a GPU example here, the 'con' value would be stored out to a constant buffer.
// 
//  FfxUInt32x4 con;
//  FsrRcasCon(con,
//   0.0); // The scale is {0.0 := maximum sharpness, to N>0, where N is the number of stops (halving) of the reduction of sharpness}.
// ---------------
//==============================================================================================================================
// This is set at the limit of providing unnatural results for sharpening.
#define FSR_RCAS_LIMIT (0.25-(1.0/16.0))
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//_____________________________________________________________/\_______________________________________________________________
//==============================================================================================================================
//                                                      CONSTANT SETUP
//==============================================================================================================================
// Call to setup required constant values (works on CPU or GPU).
 FFX_STATIC void FsrRcasCon(FfxUInt32x4 con,
                            // The scale is {0.0 := maximum, to N>0, where N is the number of stops (halving) of the reduction of sharpness}.
                            FfxFloat32 sharpness)
 {
     // Transform from stops to linear value.
     sharpness = exp2(-sharpness);
     FfxFloat32x2 hSharp  = {sharpness, sharpness};
     con[0] = ffxAsUInt32(sharpness);
     con[1] = ffxPackHalf2x16(hSharp);
     con[2] = 0;
     con[3] = 0;
 }
 ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//_____________________________________________________________/\_______________________________________________________________
//==============================================================================================================================
//                                                   NON-PACKED 32-BIT VERSION
//==============================================================================================================================
 // Input callback prototypes that need to be implemented by calling shader
 FfxFloat32x4 FsrRcasLoadF(FfxInt32x2 p);
 void FsrRcasInputF(inout FfxFloat32 r,inout FfxFloat32 g,inout FfxFloat32 b);
//------------------------------------------------------------------------------------------------------------------------------
 void FsrRcasF(out FfxFloat32 pixR,  // Output values, non-vector so port between RcasFilter() and RcasFilterH() is easy.
               out FfxFloat32 pixG,
               out FfxFloat32 pixB,
               FfxUInt32x2 ip,  // Integer pixel position in output.
               FfxUInt32x4 con)
 {  // Constant generated by RcasSetup().
     // Algorithm uses minimal 3x3 pixel neighborhood.
     //    b
     //  d e f
     //    h
     FfxInt32x2   sp = FfxInt32x2(ip);
     FfxFloat32x3 b  = FsrRcasLoadF(sp + FfxInt32x2(0, -1)).rgb;
     FfxFloat32x3 d  = FsrRcasLoadF(sp + FfxInt32x2(-1, 0)).rgb;
     FfxFloat32x3 e = FsrRcasLoadF(sp).rgb;
     FfxFloat32x3 f = FsrRcasLoadF(sp + FfxInt32x2(1, 0)).rgb;
     FfxFloat32x3 h = FsrRcasLoadF(sp + FfxInt32x2(0, 1)).rgb;
     // Rename (32-bit) or regroup (16-bit).
     FfxFloat32 bR = b.r;
     FfxFloat32 bG = b.g;
     FfxFloat32 bB = b.b;
     FfxFloat32 dR = d.r;
     FfxFloat32 dG = d.g;
     FfxFloat32 dB = d.b;
     FfxFloat32 eR = e.r;
     FfxFloat32 eG = e.g;
     FfxFloat32 eB = e.b;
     FfxFloat32 fR = f.r;
     FfxFloat32 fG = f.g;
     FfxFloat32 fB = f.b;
     FfxFloat32 hR = h.r;
     FfxFloat32 hG = h.g;
     FfxFloat32 hB = h.b;
     // Run optional input transform.
     FsrRcasInputF(bR, bG, bB);
     FsrRcasInputF(dR, dG, dB);
     FsrRcasInputF(eR, eG, eB);
     FsrRcasInputF(fR, fG, fB);
     FsrRcasInputF(hR, hG, hB);
     // Luma times 2.
     FfxFloat32 bL = bB * FfxFloat32(0.5) + (bR * FfxFloat32(0.5) + bG);
     FfxFloat32 dL = dB * FfxFloat32(0.5) + (dR * FfxFloat32(0.5) + dG);
     FfxFloat32 eL = eB * FfxFloat32(0.5) + (eR * FfxFloat32(0.5) + eG);
     FfxFloat32 fL = fB * FfxFloat32(0.5) + (fR * FfxFloat32(0.5) + fG);
     FfxFloat32 hL = hB * FfxFloat32(0.5) + (hR * FfxFloat32(0.5) + hG);
     // Noise detection.
     FfxFloat32 nz = FfxFloat32(0.25) * bL + FfxFloat32(0.25) * dL + FfxFloat32(0.25) * fL + FfxFloat32(0.25) * hL - eL;
     nz            = ffxSaturate(abs(nz) * ffxApproximateReciprocalMedium(ffxMax3(ffxMax3(bL, dL, eL), fL, hL) - ffxMin3(ffxMin3(bL, dL, eL), fL, hL)));
     nz            = FfxFloat32(-0.5) * nz + FfxFloat32(1.0);
     // Min and max of ring.
     FfxFloat32 mn4R = ffxMin(ffxMin3(bR, dR, fR), hR);
     FfxFloat32 mn4G = ffxMin(ffxMin3(bG, dG, fG), hG);
     FfxFloat32 mn4B = ffxMin(ffxMin3(bB, dB, fB), hB);
     FfxFloat32 mx4R = max(ffxMax3(bR, dR, fR), hR);
     FfxFloat32 mx4G = max(ffxMax3(bG, dG, fG), hG);
     FfxFloat32 mx4B = max(ffxMax3(bB, dB, fB), hB);
     // Immediate constants for peak range.
     FfxFloat32x2 peakC = FfxFloat32x2(1.0, -1.0 * 4.0);
     // Limiters, these need to be high precision RCPs.
     FfxFloat32 hitMinR = mn4R * ffxReciprocal(FfxFloat32(4.0) * mx4R);
     FfxFloat32 hitMinG = mn4G * ffxReciprocal(FfxFloat32(4.0) * mx4G);
     FfxFloat32 hitMinB = mn4B * ffxReciprocal(FfxFloat32(4.0) * mx4B);
     FfxFloat32 hitMaxR = (peakC.x - mx4R) * ffxReciprocal(FfxFloat32(4.0) * mn4R + peakC.y);
     FfxFloat32 hitMaxG = (peakC.x - mx4G) * ffxReciprocal(FfxFloat32(4.0) * mn4G + peakC.y);
     FfxFloat32 hitMaxB = (peakC.x - mx4B) * ffxReciprocal(FfxFloat32(4.0) * mn4B + peakC.y);
     FfxFloat32 lobeR   = max(-hitMinR, hitMaxR);
     FfxFloat32 lobeG   = max(-hitMinG, hitMaxG);
     FfxFloat32 lobeB   = max(-hitMinB, hitMaxB);
     FfxFloat32 lobe    = max(FfxFloat32(-FSR_RCAS_LIMIT), ffxMin(ffxMax3(lobeR, lobeG, lobeB), FfxFloat32(0.0))) * ffxAsFloat
     (con.x);
 // Apply noise removal.
     lobe *= nz;
     // Resolve, which needs the medium precision rcp approximation to avoid visible tonality changes.
     FfxFloat32 rcpL = ffxApproximateReciprocalMedium(FfxFloat32(4.0) * lobe + FfxFloat32(1.0));
     pixR            = (lobe * bR + lobe * dR + lobe * hR + lobe * fR + eR) * rcpL;
     pixG            = (lobe * bG + lobe * dG + lobe * hG + lobe * fG + eG) * rcpL;
     pixB            = (lobe * bB + lobe * dB + lobe * hB + lobe * fB + eB) * rcpL;
     return;
 }
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//_____________________________________________________________/\_______________________________________________________________
//==============================================================================================================================
//                                                  NON-PACKED 16-BIT VERSION
//==============================================================================================================================
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//_____________________________________________________________/\_______________________________________________________________
//==============================================================================================================================
//                                                     PACKED 16-BIT VERSION
//==============================================================================================================================
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//_____________________________________________________________/\_______________________________________________________________
//==============================================================================================================================
//
//                                          FSR - [LFGA] LINEAR FILM GRAIN APPLICATOR
//
//------------------------------------------------------------------------------------------------------------------------------
// Adding output-resolution film grain after scaling is a good way to mask both rendering and scaling artifacts.
// Suggest using tiled blue noise as film grain input, with peak noise frequency set for a specific look and feel.
// The 'Lfga*()' functions provide a convenient way to introduce grain.
// These functions limit grain based on distance to signal limits.
// This is done so that the grain is temporally energy preserving, and thus won't modify image tonality.
// Grain application should be done in a linear colorspace.
// The grain should be temporally changing, but have a temporal sum per pixel that adds to zero (non-biased).
//------------------------------------------------------------------------------------------------------------------------------
// Usage,
//   FsrLfga*(
//    color, // In/out linear colorspace color {0 to 1} ranged.
//    grain, // Per pixel grain texture value {-0.5 to 0.5} ranged, input is 3-channel to support colored grain.
//    amount); // Amount of grain (0 to 1} ranged.
//------------------------------------------------------------------------------------------------------------------------------
// Example if grain texture is monochrome: 'FsrLfgaF(color,ffxBroadcast3(grain),amount)'
//==============================================================================================================================
 // Maximum grain is the minimum distance to the signal limit.
 void FsrLfgaF(inout FfxFloat32x3 c, FfxFloat32x3 t, FfxFloat32 a)
 {
     c += (t * ffxBroadcast3(a)) * ffxMin(ffxBroadcast3(1.0) - c, c);
 }
//==============================================================================================================================
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//_____________________________________________________________/\_______________________________________________________________
//==============================================================================================================================
//
//                                          FSR - [SRTM] SIMPLE REVERSIBLE TONE-MAPPER
//
//------------------------------------------------------------------------------------------------------------------------------
// This provides a way to take linear HDR color {0 to FP16_MAX} and convert it into a temporary {0 to 1} ranged post-tonemapped linear.
// The tonemapper preserves RGB ratio, which helps maintain HDR color bleed during filtering.
//------------------------------------------------------------------------------------------------------------------------------
// Reversible tonemapper usage,
//  FsrSrtm*(color); // {0 to FP16_MAX} converted to {0 to 1}.
//  FsrSrtmInv*(color); // {0 to 1} converted into {0 to 32768, output peak safe for FP16}.
//==============================================================================================================================
 void FsrSrtmF(inout FfxFloat32x3 c)
 {
     c *= ffxBroadcast3(ffxReciprocal(ffxMax3(c.r, c.g, c.b) + FfxFloat32(1.0)));
 }
 // The extra max solves the c=1.0 case (which is a /0).
 void FsrSrtmInvF(inout FfxFloat32x3 c){c*=ffxBroadcast3(ffxReciprocal(max(FfxFloat32(1.0/32768.0),FfxFloat32(1.0)-ffxMax3(c.r,c.g,c.b))));}
//==============================================================================================================================
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//_____________________________________________________________/\_______________________________________________________________
//==============================================================================================================================
//
//                                       FSR - [TEPD] TEMPORAL ENERGY PRESERVING DITHER
//
//------------------------------------------------------------------------------------------------------------------------------
// Temporally energy preserving dithered {0 to 1} linear to gamma 2.0 conversion.
// Gamma 2.0 is used so that the conversion back to linear is just to square the color.
// The conversion comes in 8-bit and 10-bit modes, designed for output to 8-bit UNORM or 10:10:10:2 respectively.
// Given good non-biased temporal blue noise as dither input,
// the output dither will temporally conserve energy.
// This is done by choosing the linear nearest step point instead of perceptual nearest.
// See code below for details.
//------------------------------------------------------------------------------------------------------------------------------
// DX SPEC RULES FOR FLOAT->UNORM 8-BIT CONVERSION
// ===============================================
// - Output is 'FfxUInt32(floor(saturate(n)*255.0+0.5))'.
// - Thus rounding is to nearest.
// - NaN gets converted to zero.
// - INF is clamped to {0.0 to 1.0}.
//==============================================================================================================================
 // Hand tuned integer position to dither value, with more values than simple checkerboard.
 // Only 32-bit has enough precision for this compddation.
 // Output is {0 to <1}.
 FfxFloat32 FsrTepdDitF(FfxUInt32x2 p, FfxUInt32 f)
 {
     FfxFloat32 x = FfxFloat32(p.x + f);
     FfxFloat32 y = FfxFloat32(p.y);
     // The 1.61803 golden ratio.
     FfxFloat32 a = FfxFloat32((1.0 + ffxSqrt(5.0f)) / 2.0);
     // Number designed to provide a good visual pattern.
     FfxFloat32 b = FfxFloat32(1.0 / 3.69);
     x            = x * a + (y * b);
     return ffxFract(x);
 }
  //------------------------------------------------------------------------------------------------------------------------------
 // This version is 8-bit gamma 2.0.
 // The 'c' input is {0 to 1}.
 // Output is {0 to 1} ready for image store.
 void FsrTepdC8F(inout FfxFloat32x3 c, FfxFloat32 dit)
 {
     FfxFloat32x3 n = ffxSqrt(c);
     n              = floor(n * ffxBroadcast3(255.0)) * ffxBroadcast3(1.0 / 255.0);
     FfxFloat32x3 a = n * n;
     FfxFloat32x3 b = n + ffxBroadcast3(1.0 / 255.0);
     b              = b * b;
     // Ratio of 'a' to 'b' required to produce 'c'.
     // ffxApproximateReciprocal() won't work here (at least for very high dynamic ranges).
     // ffxApproximateReciprocalMedium() is an IADD,FMA,MUL.
     FfxFloat32x3 r = (c - b) * ffxApproximateReciprocalMedium(a - b);
     // Use the ratio as a cutoff to choose 'a' or 'b'.
     // ffxIsGreaterThanZero() is a MUL.
     c = ffxSaturate(n + ffxIsGreaterThanZero(ffxBroadcast3(dit) - r) * ffxBroadcast3(1.0 / 255.0));
 }
 //------------------------------------------------------------------------------------------------------------------------------
 // This version is 10-bit gamma 2.0.
 // The 'c' input is {0 to 1}.
 // Output is {0 to 1} ready for image store.
 void FsrTepdC10F(inout FfxFloat32x3 c, FfxFloat32 dit)
 {
     FfxFloat32x3 n = ffxSqrt(c);
     n              = floor(n * ffxBroadcast3(1023.0)) * ffxBroadcast3(1.0 / 1023.0);
     FfxFloat32x3 a = n * n;
     FfxFloat32x3 b = n + ffxBroadcast3(1.0 / 1023.0);
     b              = b * b;
     FfxFloat32x3 r = (c - b) * ffxApproximateReciprocalMedium(a - b);
     c              = ffxSaturate(n + ffxIsGreaterThanZero(ffxBroadcast3(dit) - r) * ffxBroadcast3(1.0 / 1023.0));
 }
//==============================================================================================================================
