# Visibility buffer, software raster and voxel foliage

Work in progress on branch `vis-buffer` (on top of `foliage-perf`). Goal: dense foliage as cheap
as Nanite draws it (the forest of `demo/assets/forest` at High on a GTX 1070), by the same means:

- a visibility buffer: the raster writes 64 bits per pixel with an atomic maximum (depth above,
  the visible cluster and triangle below), and the material runs once per pixel;
- a software rasterizer in compute for clusters of small triangles;
- voxels for distant foliage (`ENaniteShapePreservation::Voxelize` in Unreal 5.8).

The user chose 64-bit atomics knowing that Apple M1 lacks them.

## Design

- **Payload.** `uint64`: high word the reverse-Z depth bits (nearer is larger), low word the
  index of the entry in the visible list (25 bits) and the triangle of the cluster (7 bits).
  Zero is empty. One `uint64` per pixel of the view in a storage buffer, cleared every frame.
- **Who goes through it.** Visible clusters of materials without a Surface program, opaque or
  masked, batches included (their vertex hook runs in the raster and again in the resolve).
  Clusters of programs, glass, overlays and the Gbuffer stage of extensions (impostors) keep the
  forward raster and test against the depth the visibility buffer exports.
- **Raster.** Hardware first: `gbuffer.vert` with a fragment shader that tests the alpha of a
  masked material and the fade, then `InterlockedMax`. The software raster comes next, for the
  clusters whose triangles are small on screen, choosing per cluster in the cull.
- **Depth export.** After each phase a full-screen pass writes the hardware depth and the linear
  depth from the visibility buffer, so the depth pyramid and the forward draws see it.
- **Resolve.** One full-screen pass after phase 1: decode the payload, rebuild the triangle
  (posed vertices, transform, vertex hook), barycentrics and their screen derivatives from the
  three clip positions, then `fragment_evaluate` and the same targets as `gbuffer.frag`, with
  depth test greater-or-equal so nearer forward draws stay.
- **Derivatives.** The resolve sets the screen gradients of uv0, uv1 and the world position
  analytically; material maps sample with `SampleGrad` through their uv transform, texture
  feedback reads the same gradients, and the footprint of the context is set from them.

## Steps

1. `rhi`: enable 64-bit buffer atomics on Vulkan, report them in the device features.
2. Visibility raster (hardware) and depth export, behind a renderer setting for comparison.
3. Resolve with analytic gradients; capture against the forward G-buffer (SSIM) in the forest,
   the gallery and the church; measure with `bench compare`.
4. Software raster for clusters of small triangles.
5. Voxel foliage at the import (bricks) and their raster.
6. Remove the forward path for what the visibility buffer covers; docs and skills.

## Status

- Step 1: `rhi.Features.atomics_64` (Vulkan `shaderBufferInt64Atomics`; Metal false), and
  `Render_Pass_Desc.area` for a pass without targets. Stages marked `//! atomics 64` get no
  Metal code (`metal_lacks` in cook/shaders); their pipelines need the feature.
- Steps 2-3 done: `gbuffer.vert` variant `visibility`, `vis_raster.frag`, `vis_depth.frag`,
  `vis_resolve.frag` (+ plain, layers), `gbuffer_build.slang` (the vertex both share),
  `gbuffer_output.slang` (the targets both write), `MATERIAL_GRADIENTS` in scene.slang;
  `gbuffer_pass` in render/frame.odin; `Settings.visibility_buffer` (default on). Against the
  forward G-buffer at High: SSIM 0.999 in the forest, 0.993 in the gallery; the render tests pass
  with validation (but the Catalog one that fails on main).
- Next: step 4. The raster of the visibility buffer is the larger part of what is left in the
  forest; measure how much of it is vertices and how much fragments before the software raster.
