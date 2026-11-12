# Third-party notices

Mirai is licensed under either of [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your
option. It includes, or is derived from, the third-party work listed here, which keeps its own
license. Each entry says where it ends up:

- **game**: in the binary of a game built with Mirai;
- **editor**: in the editor and the `mirai` tool, not in a game;
- **package**: shipped as a separate program or file in the engine package
  (`mirai package engine`).

A game shipped with Mirai must carry the notices of the entries marked **game** that it uses. The
texts of the licenses are at the [end](#license-texts).

## Libraries

- **SDL3** (zlib; © 1997-2026 Sam Lantinga), <https://libsdl.org>. Game: `SDL3.dll` or
  `libSDL3.so.0` next to the executable.
- **stb** `stb_image` and `stb_vorbis` (MIT or public domain; © 2017 Sean Barrett),
  <https://github.com/nothings/stb>. Game.
- **FreeType 2.14.3** (FreeType License; © The FreeType Project), <https://freetype.org>. Game.
- **cgltf** (MIT; © 2018-2021 Johannes Kuhlmann), <https://github.com/jkuhlmann/cgltf>. Editor.
- **ufbx 0.23.1** (MIT or public domain; © 2020 Samuli Raivio), <https://github.com/ufbx/ufbx>.
  Editor.
- **SQLite 3.54.1** (public domain), <https://www.sqlite.org>. Editor.
- **Odin** `base`, `core` and `vendor` (BSD-3-Clause; © 2016-2025 Ginger Bill),
  <https://odin-lang.org>. Game; the compiler, in the package.
- **Slang** (Apache-2.0 with LLVM exception; © Slang contributors), <https://shader-slang.org>.
  Package.
- **SPIRV-Tools and SPIRV-Cross** (Apache-2.0; © The Khronos Group Inc.),
  <https://github.com/KhronosGroup>. Package.

FreeType: portions of this software are copyright © 2026 The FreeType Project
(www.freetype.org). All rights reserved. Its licenses are in `third_party/freetype/LICENSE.TXT`
and `FTL.TXT`.

Slang, the SPIR-V tools and Odin ship in the engine package with the license files of their own
folders, which include the notices of the work they carry.

## Adapted code

Parts of Mirai are rewrites in Odin or Slang of the algorithms of these projects. Their notices
are kept here and, where the license asks for it, in the header of the file.

- **Clay v0.14** (zlib; © 2024 Nic Barker), <https://github.com/nicbarker/clay>.
  `ui/layout_tree.odin`, altered. Game.
- **MikkTSpace** (zlib; © 2011 Morten S. Mikkelsen), <https://github.com/mmikk/MikkTSpace>.
  `std/geom/tangents.odin`, altered. Game.
- **Box2D and Box3D** (MIT; © Erin Catto), <https://github.com/erincatto/box2d>.
  `plugins/physics/runtime/sim`, the drag of `plugins/physics/runtime/step.odin` and
  `std/spatial/dynamic_tree.odin`. Game.
- **Jolt Physics** (MIT; © 2021 Jorrit Rouwe), <https://github.com/jrouwe/JoltPhysics>.
  `gjk.odin`, `mesh.odin` and `contact.odin` of `plugins/physics/runtime/sim`, and the scale
  checks of `plugins/physics/runtime/step.odin` and `geometry.odin`. Game.
- **earcut** (ISC; © 2016 Mapbox), <https://github.com/mapbox/earcut>.
  `std/geom/triangulate.odin`. Game.
- **Delaunator** (ISC; © 2021 Mapbox), <https://github.com/mapbox/delaunator>.
  `std/geom/delaunay.odin`. Game.
- **meshoptimizer 1.3** (MIT; © 2016-2026 Arseny Kapoulkine),
  <https://github.com/zeux/meshoptimizer>.
  `std/geom/simplify.odin`, `cluster.odin`, `partition.odin` and `cluster_dag.odin`. Game.
  The vertex codec and the quaternion and exponential filters of
  `cook/import/gltf/meshopt.odin`. Editor.
- **Mesh2Motion** (MIT; © 2025 Scott Petrovic), <https://github.com/Mesh2Motion/mesh2motion-app>.
  The skinning solvers of `cook/rig/weights.odin`, altered. Editor.
- **ACL 2.1, Animation Compression Library** (MIT; © 2017 Nicholas Frechette),
  <https://github.com/nfrechette/acl>. The table of bit rates, the constant and default tracks,
  the rigid shells, the segments with their ranges, the blocks of animated tracks and the search
  of bit rates of
  `std/anim/compress.odin` and the stream that `std/anim/sampled.odin` reads, altered. Game.
- **Motion-Matching** (MIT; © Daniel Holden), <https://github.com/orangeduck/Motion-Matching>.
  The features, their normalization by kind and the search bounded by runs of rows of
  `std/anim/matching.odin`, altered. Game, with the `animation` plugin.
- **Recast and Detour** (zlib; © 2009 Mikko Mononen),
  <https://github.com/recastnavigation/recastnavigation>. `std/ai/nav_*.odin` and the path
  following of `plugins/navigation/runtime/agents.odin`, altered. Game.
- **RVO2 Library** (Apache-2.0; © 2008 University of North Carolina at Chapel Hill),
  <https://github.com/snape/RVO2>. The obstacle lines of `std/ai/avoidance.odin`, altered. Game.
- **Steam Audio** (Apache-2.0; © 2017-2023 Valve Corporation),
  <https://github.com/ValveSoftware/steam-audio>. `audio/hrtf.odin`, `audio/binaural.odin`,
  `audio/direct.odin`, the mix per ear and the delay of a voice of `audio/mix.odin`, and the
  occlusion and transmission of `engine/audio/audio.odin`, altered. Game.
- **Godot Engine** (MIT; © 2014-present Godot Engine contributors, © 2007-2014 Juan Linietsky,
  Ariel Manzur), <https://github.com/godotengine/godot>. The Hermite resampling of
  `audio/mix.odin`, the loop points of `audio/wav.odin`, the limiter and the filter coefficients
  of `audio/bus.odin`, the steady ticks of `host/frame.odin`, the floor between two slopes of
  `plugins/physics/runtime/sim/character.odin` and the start of a process of
  `std/subprocess/subprocess_posix.odin`, altered. Game.
- **Odin** `core:os` (BSD-3-Clause; © 2016-2025 Ginger Bill), <https://odin-lang.org>. The start
  of a process of `std/subprocess/subprocess_posix.odin`, altered. Game.
- **taffy** (MIT; © 2018 Visly Inc., © 2026 Taffy Authors),
  <https://github.com/DioxusLabs/taffy>. The rounding to device pixels of
  `ui/layout_tree.odin`. Game.
- **ozz-animation** (MIT; © 2020 Guillaume Blanc),
  <https://github.com/guillaumeblanc/ozz-animation>. The aim at a point of `std/anim/ik.odin`.
  Game.
- **pbrt-v4** (Apache-2.0; © 1998-2020 Matt Pharr, Wenzel Jakob and Greg Humphreys),
  <https://github.com/mmp/pbrt-v4>. The watertight test of a ray and a triangle of
  `shaders/include/trace.slang` and `std/math/ray.odin`, and the union of cones of
  `render/light_tree.odin`. Game.
- **lightyear** (MIT or Apache-2.0; © the lightyear contributors),
  <https://github.com/cBournhonesque/lightyear>. The input delay of `net/clock.odin`. Game.
- **MaterialX** (Apache-2.0; © Contributors to the MaterialX Project),
  <https://github.com/AcademySoftwareFoundation/MaterialX>. The sheen fit of
  `shaders/include/brdf.slang`. Game.
- **Khronos PBR Neutral** (Apache-2.0; © The Khronos Group Inc.),
  <https://github.com/KhronosGroup/ToneMapping>. `shaders/include/display.slang`. Game.
- **OpenColorIO 2.4** (BSD-3-Clause; © Contributors to the OpenColorIO Project),
  <https://github.com/AcademySoftwareFoundation/OpenColorIO>. `shaders/include/aces.slang` and
  `shaders/display_tables.comp.slang`. Game.
- **AMD FidelityFX Super Resolution 3.1.4** (MIT; © 2024 Advanced Micro Devices, Inc.),
  <https://github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK>. `plugins/fsr/shaders/fsr3` (the
  upscaler, optical flow, frame interpolation and SPD headers, altered: reduced to the one
  configuration Mirai compiles, as their `UPSTREAM.md` says) and the pass sequence of
  `plugins/fsr/runtime/framegen.odin`, translated from `ffx_opticalflow.cpp` and
  `ffx_frameinterpolation.cpp`. Game, with the `fsr` plugin.
- **Zstandard 1.5.7** (BSD-3-Clause; © Meta Platforms, Inc. and affiliates),
  <https://github.com/facebook/zstd>. `std/compressor/zstd`, a translation of its decoder and of
  three levels of its encoder, as its `UPSTREAM.md` says. Game.
- **LZ4 1.10.0** (BSD-2-Clause; © 2011-2020 Yann Collet), <https://github.com/lz4/lz4>.
  `std/compressor/lz4`, a translation of its block decoder and of its HC encoder, as its
  `UPSTREAM.md` says. Game.
- **bc7enc_rdo** (MIT or public domain; © 2020-2021 Richard Geldreich, Jr.),
  <https://github.com/richgel999/bc7enc_rdo>. `std/compressor/blocks/rgbcx`, `bc7enc`
  and `rdo`, translated; a block keeps the alpha 0 and 255 of its texels. Editor.
- **ISPC Texture Compressor** (MIT; © 2017 Intel Corporation),
  <https://github.com/GameTechDev/ISPCTextureCompressor>. The BC6H encoder of
  `std/compressor/blocks/bc6h`, translated. Editor.

The files derived from Apache-2.0 work state their changes in their header.

## Fonts and assets

- **Inter 4.1** (SIL OFL 1.1; © The Inter Project Authors), <https://rsms.me/inter>. Game, with
  `assets/fonts/Inter-LICENSE.txt`.
- **JetBrains Mono 2.304** (SIL OFL 1.1; © The JetBrains Mono Project Authors),
  <https://www.jetbrains.com/lp/mono>. Game, with `assets/fonts/JetBrainsMono-LICENSE.txt`.
- **CIPIC HRTF Database**, the set `cipic_124` as Steam Audio ships it (free to reproduce and
  use for any purpose, keeping its notice: Copyright (c) 2001 The Regents of the University of
  California. All Rights Reserved), <https://github.com/ValveSoftware/steam-audio>.
  `audio/hrtf/cipic_124.hrtf`. Game.
- **Kenney Input Prompts 1.5A** (CC0 1.0; Kenney), <https://kenney.nl/assets/input-prompts>.
  Game, with the `prompts_kenney` plugin.
- **Mesh2Motion** human rig, its reference model and the clips `walk` and `idle-a` (CC0 1.0;
  Scott Petrovic), and the model `psx-05` (CC0 1.0; elbolilloduro), from
  <https://github.com/Mesh2Motion/mesh2motion-app>. The rig is the template of
  `cook/rig/template.odin`; editor. The files are test fixtures in
  `assets/fixtures/mesh2motion-human`, not distributed.
- **Mesh2Motion** fox, horse, bird, dragon, kaiju, shark, snake and spider rigs and their models
  (CC0 1.0; Scott Petrovic), from the same repository: their bones and samples of their surfaces
  are the templates of `cook/rig/animals.odin` and `cook/rig/animals/`; editor. The fox's `walk`
  clip and its `horse` variation are test fixtures in `assets/fixtures/mesh2motion-fox`, not
  distributed.
- **Poly Haven** HDRIs `kloofendal_48d_partly_cloudy`, `belfast_sunset` and `kloofendal_overcast`
  (CC0 1.0; Greg Zaal and Dimitrios Savva), <https://polyhaven.com/hdris>. The skies of the demo,
  in `demo/source/textures`.
- **Terrain3D 1.1** brush alphas (MIT; © 2023-2026 Cory Petkovsek, Roope Palmroos, and
  Contributors), <https://github.com/TokisanGames/Terrain3D>. Editor, with
  `plugins/terrain/editor/alphas/LICENSE`.

Content imported by a user keeps the license of its source: the license of Mirai grants no rights
over it.

## Not distributed

The editor runs these programs when the user has installed them, or downloads them on request to
the user's data folder; Mirai does not ship them, and each comes with its own terms:

- the Vulkan loader and drivers, and Metal (provided by the system);
- the ACP adapters `@agentclientprotocol/codex-acp` and `@agentclientprotocol/claude-agent-acp`
  (Apache-2.0), Codex (Apache-2.0) and Bun (MIT, with JavaScriptCore under LGPL 2);
- Claude Code and the Claude Agent SDK (proprietary, © Anthropic PBC, under Anthropic's terms);
- the Tracy profiler (BSD-3-Clause), whose protocol the development plugin `tracy` speaks.

## License texts

### MIT

> Permission is hereby granted, free of charge, to any person obtaining a copy of this software
> and associated documentation files (the "Software"), to deal in the Software without
> restriction, including without limitation the rights to use, copy, modify, merge, publish,
> distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the
> Software is furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all copies or
> substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
> BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
> NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
> DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

### zlib

> This software is provided 'as-is', without any express or implied warranty. In no event will
> the authors be held liable for any damages arising from the use of this software.
>
> Permission is granted to anyone to use this software for any purpose, including commercial
> applications, and to alter it and redistribute it freely, subject to the following
> restrictions:
>
> 1. The origin of this software must not be misrepresented; you must not claim that you wrote
>    the original software. If you use this software in a product, an acknowledgment in the
>    product documentation would be appreciated but is not required.
> 2. Altered source versions must be plainly marked as such, and must not be misrepresented as
>    being the original software.
> 3. This notice may not be removed or altered from any source distribution.

### ISC

> Permission to use, copy, modify, and/or distribute this software for any purpose with or
> without fee is hereby granted, provided that the above copyright notice and this permission
> notice appear in all copies.
>
> THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS
> SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE
> AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
> WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT,
> NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
> PERFORMANCE OF THIS SOFTWARE.

### BSD-2-Clause

> Redistribution and use in source and binary forms, with or without modification, are
> permitted provided that the following conditions are met:
>
> 1. Redistributions of source code must retain the above copyright notice, this list of
>    conditions and the following disclaimer.
> 2. Redistributions in binary form must reproduce the above copyright notice, this list of
>    conditions and the following disclaimer in the documentation and/or other materials
>    provided with the distribution.
>
> THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS
> OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
> MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
> COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
> EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE
> GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
> ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
> NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED
> OF THE POSSIBILITY OF SUCH DAMAGE.

### BSD-3-Clause

> Redistribution and use in source and binary forms, with or without modification, are
> permitted provided that the following conditions are met:
>
> 1. Redistributions of source code must retain the above copyright notice, this list of
>    conditions and the following disclaimer.
> 2. Redistributions in binary form must reproduce the above copyright notice, this list of
>    conditions and the following disclaimer in the documentation and/or other materials
>    provided with the distribution.
> 3. Neither the name of the copyright holder nor the names of its contributors may be used to
>    endorse or promote products derived from this software without specific prior written
>    permission.
>
> THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS
> OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
> MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
> COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
> EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE
> GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
> ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
> NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED
> OF THE POSSIBILITY OF SUCH DAMAGE.

### Apache-2.0

The text is in [LICENSE-APACHE](LICENSE-APACHE).
