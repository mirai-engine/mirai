# FidelityFX Super Resolution 3.1.4

The HLSL headers of FSR 3.1.4 from <https://github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK>,
tag `v1.1.4`, commit `c6efa6bf7f2027b3ec94f28578bb5965eabb9e55`. MIT license of Advanced Micro
Devices: `LICENSE.txt` in this folder and the header of each file.

- `fsr3upscaler/` has, in a single folder, what in the SDK is in `gpu/`: the algorithm
  (`ffx_fsr3upscaler_*.h`), its portability layer (`ffx_core*.h`), `fsr1/ffx_fsr1.h` (RCAS) and
  `spd/ffx_spd.h`, the FidelityFX FSR 2.2 Single Pass Downsampler, with the callback interface
  that FSR 3.1 uses. This way each AMD `#include` resolves next to the file that makes it.
- `frameinterpolation/` and `opticalflow/` are the `gpu/` folders of frame generation, without
  the debug view or the GLSL callbacks; `spd/ffx_spd.h` is the `gpu/spd/ffx_spd.h` of the same tag
  (SPD 2.0), which their pyramids include. The portability layers of `gpu/` are those of
  `fsr3upscaler/`, byte-identical.
- The headers are reduced to the one configuration Mirai compiles: every preprocessor conditional
  on HLSL on the GPU without `FFX_HALF` or `FFX_HLSL_SM`, without GLSL, CPU, Xbox or DXC paths,
  with the options of `../fsr3_mirai.slang` and `../fsr3_framegen_mirai.slang` (reversed depth,
  HDR input color, motion vectors at the render size without jitter, SPD without wave
  operations, RCAS in 32 bits with its denoise, the approximate Lanczos of the upsample, the
  optical flow without `msad4`) and the defaults of the headers is resolved, and the dead
  branches, the macros that only chose between them, the D3D root signatures and pragmas and the
  files left unincluded (`ffx_core_gpu_common_half.h`, `ffx_opticalflow_resources.h`) are
  deleted. What stays conditional is the binding of each resource, which each entry point
  declares, the `sharpen` variant of the accumulation and `FFX_WAVE`.
- The other changes, each with a `Mirai:` comment on its line:
  - In `ffx_fsr3upscaler_callbacks_hlsl.h` and `ffx_frameinterpolation_callbacks_hlsl.h`, the
    samplers take the registers of Mirai's (`s3`, `SLOT_POINT_SAMPLER`; `s2`,
    `SLOT_LINEAR_SAMPLER`) instead of `s0` and `s1`, which in Vulkan are the bindings of the frame
    constants and of the parameters.
  - The SDK compiles with `gpu/` among the include folders and Slang resolves an `#include` next
    to the file that makes it or in the plugin's `shaders/`: the callbacks of
    `frameinterpolation/` and `opticalflow/` include `../fsr3upscaler/ffx_core.h`, those of
    `opticalflow/` their `ffx_opticalflow_common.h` without the folder, and the three SPD
    pyramids `../spd/ffx_spd.h`.
  - In `ffx_opticalflow_callbacks_hlsl.h`, the luma and flow textures, for reading and for
    writing, declare their format (`r8ui`, `rg16i`), and so does the flow one that
    `ffx_frameinterpolation_callbacks_hlsl.h` reads: Slang deduces `r32ui` and `rg32i` from the
    type of their elements, which are not those of the textures (`R8_UINT`, `R16G16_SINT`).
- `../fsr3_framegen_mirai.slang` takes the `min16*` types to 32 bits: `ffx_common_types.h` defines
  `FfxFloat16` and `FfxUInt16` with them even without `FFX_HALF`, and Slang emits them as 16-bit,
  which the device does not enable.
- The entry points are Mirai's (`../fsr3_*.comp.slang`): they name the slot of each resource,
  which `runtime/fsr.odin` and `runtime/framegen.odin` bind. `../fsr3_mirai.slang` and
  `../fsr3_framegen_mirai.slang` fix the compilation options.
- To update: replace the files with those of another tag, compare the portability layers of
  `gpu/` with those of `fsr3upscaler/`, reduce them to the same configuration, reapply the
  changes, change the commit above, and test the plugin in the demo with validation.
