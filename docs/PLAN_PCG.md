# Plan: PCG (Mirai-Native, Zero-Legacy, Data-Oriented PCG)

Design blueprint for **PCG**, Mirai's native, data-oriented, zero-legacy procedural content
generation system. Everything proposed here is design; facts about current Mirai code and external
reference implementations are cited explicitly by file, commit, or published presentation.

Revised after adversarial DoD architecture review against Mirai's real `render/`, `engine/render/`,
`engine/volume/`, `engine/scene/`, `plugins/foliage/`, and `docs/ARCHITECTURE.md`.

---

## 1. Design Core (Three Concepts, Zero Legacy)

Mirai's PCG follows the same philosophy as `animation` (no animation graphs) and materials (text
programs, not authored node spaghetti):

1. **Flat Layer Rows + Compiled SIMD Field Expressions (`std/pcg`):**
   - No node-graph IR, no `pcg.node.*`, no `pcg.connect`, no subgraph inlining, no node-graph
     document editor.
   - A `.pcg` asset is a flat ordered list of **Layer Rows** (`id`, `tier`, `what`, `density`,
     `radius`, `ground_rule`, `field_expr` text compiled once to `Field_Program` SIMD bytecode,
     `parent_layer` for cascades) plus **1-D Shape Grammar** text strings (~400 lines) for fences,
     walls, bridges, facades, and modular city lots.
2. **Two Clean Tiers (Zero-Persistence, All Drawing in `plugins/foliage`):**
   - **Tier 1 — Physical / Gameplay (`Macro` + `Meso`, CPU `std/jobs.parallel_for`):**
     deterministic across macOS ARM64 & Windows/Linux x64, runs inside the `fixed` step with a
     **count budget** (never wall-clock timers or out-of-world background queues), ordered by
     `scene.resident`. Outputs fixed typed `Placed` slices directly into `plugins/foliage`
     (batches, octahedral impostors, crowns, wind, per-cell static physics covering all cells for
     navmesh/AI determinism).
   - **Tier 2 — Visual Micro-Scatter (`Micro`, GPU Extension Passes in `plugins/foliage`):**
     ephemeral non-colliding groundcover (grass, pebbles, flowers, litter), through
     `engine/render` alone with **generation in `Simulate` on tile residency or epoch change**
     (never re-scattered per frame/per view). Each view writes what it keeps, thinned by distance,
     into a batch the GPU fills (`batch_reserve`, `Instances` stage) that the visibility buffer of
     the scene draws: the measured direct G-buffer draw cost half a frame. Wind,
     `Foliage_Bender`, and shaders live in `plugins/foliage`; `plugins/pcg` has **no `shaders/`
     folder**.
3. **Manual Editing: Suppress + Promote + Authored Points (Zero Overrides, Zero Gizmo):**
   - One suppression mechanism for both Editor edits of generated points and Play removals:
     replicated **World rows** owned by `plugins/pcg`, keyed by `(graph_entity_id, cell_coord,
     stable_id)`—saved with the scene (authored) or save/network (Play), rolled back natively, and
     undone by the editor's native journal. Zero `suppressed_ids` in `.pcg` assets.
   - Promoting/editing a generated instance or Grammar lot suppresses its `stable_id` and spawns
     normal Mirai scene entities/prefabs/`Shape`s (inheriting native gizmo, undo, inspector,
     prefabs).
   - **Authored points in `Pcg_Cell.points` (`pcg.points`, `pcg.absorb`):** Macro/Meso `Scatter`
     layers (including `density = 0` layers for exact port placements) can hold explicit transforms
     per cell in `.pcg`, emitted regardless of ground and rasterized into Micro occupancy. An
     authored point never references a generated id (`AUTHORED_POINT_BIT | next_point`), so there
     are no transform overrides, no orphans, and no custom foliage gizmo. In the editor, promoting
     or suppressing an authored point removes it directly from `.pcg` (zero `Pcg_Suppressed`
     residue, exact inverse of `pcg.absorb`).
   - Deletes all per-instance transform overrides (`Foliage_Override` `Moved`/`Replaced`),
     `orphans`, and the custom batch gizmo in `plugins/foliage`.

---

## 2. Research Synthesis (What We Keep vs Refuse)

Five audits informed this blueprint: UE 5.8.3 & UE 6.0.0 (`4ad48cf`), Decima HZD (GDC 2017) &
Ubisoft Snowdrop/Avatar (GDC 2024) / FC5 / Wildlands, `FastNoise2` (`c35d604`), `MarkovJunior`
(`42aaf24`, deferred to optional plugin issue `#120`), `Veloren` (`6c99b29`) / `Cubyz` (`c24e72a`),
and Mirai's own codebase.

### Adopted

- **FastNoise2 → Pure-Odin Tiled SIMD `Field_Program` (`W=4`):** LUT-free prime-multiply integer
  hashing (`0xF797C5C7`, `0x6C060C89`, `0x465FD04F`), branchless gradient selection, fused fat
  noise ops, evaluated over L1-resident tiles (`TILE :: 256`, `MAX_SLOTS :: 16`, 16 KiB scratch)
  with strict cross-arch bit-identity (no FMA, `select(a < b, a, b)` min/max, finite clamp before
  `f32 -> i32`, IEEE `sqrt`/`/`, deterministic polynomial trig). Single width `W=4` (NEON/SSE2)
  first; `W=8` AVX2 only if a benchmark proves noise (not ground probes) is the bottleneck.
- **UE 5.8 / 6.0 PCG:** 1-D scalable-module Shape Grammar (`[A,B]3`, `*`, `+`, `<A,B>`, `{A:2,B:1}`,
  `bScalable`), world-anchored seeding, stochastic rounding (`floor(d*A) + (hash < frac)`),
  bilinear coverage-probability acceptance at mask edges, and `(spline_entity, span, ordinal)`
  stable keys for spline grammar modules.
- **Decima / Snowdrop / FC5 / Wildlands:** zero persisted transform clouds, layered dithering for
  O(1) mutual exclusion among equal footprints, viability competition + SDF edge tapering,
  parent→child cascades (`(parent_id, child_idx)`), quality-scaled filler budgets, density-modulated
  LOD/impostor distance, and **Suppress + Promote** (`foliage.promote` on interaction/edit).

### Explicitly Refused (Zero Legacy, Zero Over-Engineering)

- **No authored node-graph IR or node-graph editor** (`pcg.node.*`, `pcg.connect`, subgraphs,
  hoisting, capability bitmasks). Flat layer rows + text field expressions + grammar strings only.
- **No `Point_Table` mini-ECS** (`Column{rawptr, owned, constant, extra}`). Fused kernels emit
  typed slices of a fixed `Placed` struct into caller-owned preallocated arenas.
- **No Work Graphs (disabled by Microsoft in SM 6.10), no Slang emitter in Layer 0, no GPU-to-CPU
  readbacks, no `Out_RemovePoint` sentinels.** CPU evaluates micro density fields on change; GPU
  runs one fixed Slang compute kernel in `Simulate` (per tile on change) + one fill per view into
  batches the GPU fills, culled by the scene.
- **No duplicate ground/mask caches or schedulers.** `Pcg_Ground` is the sole CPU ground cache;
  GPU clipmaps are `@(storage, host, by_world)` uploads of `Pcg_Ground` + micro density tiles by
  revision; `volume.Zone` + `volume.gpu_volume` handle spatial masks without reinventing `Pcg_Mask`;
  `scene.resident` is the sole residency ordering (no 100 ms priority heap or wall-clock scheduler).
- **No `Foliage_Override` (`Moved`/`Replaced`), `orphans`, or custom batch gizmo.** Authored points
  in `Pcg_Cell.points` never reference generated IDs.
- **No MarkovJunior / WFC in core** (tracked separately in GitHub issue `#120` as optional
  `plugins/pcg_grid`).

---

## 3. Layers and Package Boundaries

Strictly obeys [ARCHITECTURE.md](ARCHITECTURE.md#package-map):

```
Layer 0  std/pcg                Pure, engine-agnostic DoD PCG core (zero global state,
                                zero core/host/render imports):
                                  - sample.odin      Sobol+Owen (lifted from foliage), 3x3 spacing
                                                     Grid, layered dithering, stochastic rounding,
                                                     viability competition, coverage acceptance
                                  - field.odin       Text expr parser -> compiled Field_Program
                                                     bytecode + L1 tiled SIMD W=4 evaluator
                                  - grammar.odin     Flat 1-D scalable-module Shape Grammar (~400 L)
                                                     + (spline_entity, span, ordinal) stable keys

Layer 8  plugins/pcg            First-party plugin, ZERO plugin dependencies, NO shaders/:
           runtime/             - .pcg binary asset (Fourcc PCGG): flat Layer_Row table +
                                  compiled Field_Programs + compiled Grammar_Modules + ecotope refs
                                - Pcg_Graph (@(component, far)), Pcg_Zone (uses volume.Volume /
                                  volume.Spline + volume.Zone, no reinvented shape/mask system)
                                - Pcg_Ground (lifted from foliage, sole CPU ground-tile cache over
                                  core.Ground_Queries, count-budgeted)
                                - Pcg_Suppressed (World table rows keyed by graph Entity_Id, cell,
                                  stable_id: unified Editor suppression + Play removals, replicated,
                                  saved, rolled back, undone via native journal)
                                - Count-budgeted fixed-step parallel_for generator ordered by
                                  scene.resident; optional @(storage, host) memo cache
           editor/              - .pcg layer/expression inspector & Revision_History undo
                                - Mask/density brush (F) & Edit_Follow_Provider live regen
                                - 1-click Suppress + Promote (spawns normal entities/prefabs)
                                - pcg.* JSON-RPC / MCP API (pcg.create, pcg.layer, pcg.grammar,
                                  pcg.suppress, pcg.promote, pcg.points, pcg.absorb, pcg.sample,
                                  pcg.inspect)

Layer 8  plugins/foliage        Depends on: pcg, physics (SOLE rendering & physics sink):
           runtime/             - Tier 1 (Macro/Meso): render.batch_set, octahedral impostors,
                                  crowns, wind, Foliage_Bender, per-cell static colliders (all
                                  cells collide for deterministic navmesh/AI), filler budgets,
                                  density-modulated LODs, foliage.promote
                                - Tier 2 (Micro GPU): @(storage, host, by_world) clipmap upload of
                                  Pcg_Ground + micro density + pre-suppression occupancy; Simulate
                                  stage generates tiles on residency/epoch change into persistent
                                  pass_buffer; Instances stage fills GPU batches per view, drawn by
                                  the visibility buffer (Metal + Vulkan)
           shaders/             - Shared wind/sway + micro scatter/fill Slang shaders

Layer 8  plugins/pcg_terrain    Automatic bridge (pcg + terrain): Terrain_Conform splines & brushes.
Layer 8  plugins/pcg_physics    Automatic bridge (pcg + physics): Collider exclusions & 3D overlap.
Layer 8  plugins/pcg_shapes     Automatic bridge (pcg + shapes): Grammar -> Shape / Spline / Bend.
```

---

## 4. Key Contracts and Invariants

### 4.1 Stable Identity & Multi-Grid Handoff

- **Scatter `stable_id`:** `u64(authored_layer_id) << 32 | u64(point_index)` (cell coord is already
  the lookup key; `authored_layer_id` is persistent and never reused on layer removal; Sobol+Owen
  `point_index` is stable under density changes so lowering density drops tail IDs only).
- **World-anchored vs entity-space:** `Pcg_Graph` documents explicitly whether a graph is
  world-anchored (world cell coords; moving bounds never shifts points) or entity-local (for
  movable prefabs/sections).
- **Grammar `stable_id`:** keyed by `(spline_entity_id, span_index, module_ordinal)` so nudging a
  spline point does not rekey unrelated spans.
- **Macro → Meso → Micro handoff:**
  - CPU Meso queries CPU Macro survivors directly as points via the 3×3 spatial `Grid` (exact trunk
    radii + parent IDs for cascades; zero coarse-texel quantization).
  - GPU Micro reads a single clipmap occupancy layer at clipmap texel resolution, rasterized from
    Macro/Meso survivors **before** suppression (so chopping a tree in Play never causes new
    collidable bushes to sprout at the stump).

### 4.2 Determinism, Rollback & Memory Safety

- **Zero steady-state allocations:** all per-cell evaluation uses preallocated worker arena slabs
  with content-derived instance caps (`CELL_GENERATED_MAX` + `generated_share` proportional
  thinning), never machine-dependent OOM truncation.
- **Cross-arch bit-identity:** golden hash tests verify identical `Field_Program` and `sample`
  outputs on macOS ARM64 and Windows/Linux x64.
- **World copy / `app_world_replace` safety:** all authoritative state (`Pcg_Graph`,
  `Pcg_Suppressed`) is plain copyable `World` table data; GPU clipmaps, `pass_buffer`s, and memo
  caches live in `@(storage, host, by_world)` and are freed in `release`.

---

## 5. Contract-First Milestones and Verification

Each milestone lands from `main` in its own worktree branch with proving tests:

1. **M0 — Sampling Lift (`std/pcg/sample.odin` + `plugins/foliage` refactor):**
   - Lift Sobol+Owen (`scatter`, `sobol_second`, `owen_scramble`), 3×3 spacing `Grid`, and
     deterministic scatter helpers from the former scatterer of `plugins/foliage` into
     `std/pcg/sample.odin`. Add stochastic rounding, layered dithering, viability competition, and
     coverage-probability acceptance.
   - **Verify:** `mirai test std/pcg`, `mirai test plugins/foliage/runtime --no-gpu` (bit-identical
     output), `mirai check plugins/foliage/editor -collection:plugins=$(pwd)/plugins`.
2. **M1A — SIMD Field Engine (`std/pcg/field*.odin`):**
   - Text field expression parser → flat `Field_Program` bytecode compiler (CSE, constant fold,
     fractal unroll, linear-scan register alloc over `MAX_SLOTS :: 16`) + L1-tiled `W=4` SIMD
     evaluator (`TILE :: 256`, 64-byte aligned `Field_Scratch`, FastNoise2 prime hashes, branchless
     gradients, strict cross-arch bit-identity).
   - **Verify:** `mirai test std/pcg` (unit, hostile NaN/Inf/syntax/slot-overflow/OOM, zero-alloc
     steady state, scalar==batch identity, cross-arch golden hashes).
3. **M1B — 1-D Shape Grammar (`std/pcg/grammar*.odin`):**
   - Flat compiled 1-D Shape Grammar (`[A,B]3`, `*`, `+`, `<A,B>`, `{A:2,B:1}`, `bScalable`
     remainder split) + `(spline_entity, span, ordinal)` stable keys.
   - **Verify:** `mirai test std/pcg` (facades, fences, bridges, priority/stochastic/scalable,
     hostile degenerate lengths, OOM).
4. **M2 — `plugins/pcg` Runtime, Lifted `Pcg_Ground` & World Suppression:**
   - `.pcg` (`PCGG`) flat layer asset, `Pcg_Graph`, `Pcg_Zone` (over `volume.Zone`), `Pcg_Ground`
     (lifted from `foliage`), `Pcg_Suppressed` (World rows, replicated + saved + rollback), and
     count-budgeted `fixed` `parallel_for` generator ordered by `scene.resident`.
   - **Verify:** `mirai test plugins/pcg/runtime`, rollback/world-copy tests, `mirai generate demo`.
5. **M3 — Foliage Unification (Zero Legacy):**
   - Switch `plugins/foliage` to depend on `pcg`; delete `Foliage_Rule`, old scatter fields,
     `Foliage_Keep_Out`, `Foliage_Ground`, `Foliage_Override` (`Moved`/`Replaced`), `manual` lists,
     `orphans`, the duplicated play removals (unified into `Pcg_Suppressed`), and custom batch gizmo
     modes; add filler budgets, density-modulated LODs, and `foliage.promote`; update `demo`.
   - **Verify:** `mirai test plugins/foliage/runtime`, `mirai play test`, validation-clean
     `mirai capture` on `demo`, `mirai bench compare --base main`.
6. **M4 — Tier 2 GPU Micro-Scatter (in `plugins/foliage` via `engine/render`):**
   - Upload `Pcg_Ground` + CPU-evaluated micro density + pre-suppression occupancy into a
     `@(storage, host, by_world)` clipmap texture array on tile revision change.
   - One fixed Slang compute shader generates micro tiles in `Simulate` (on residency/epoch change)
     into a persistent `pass_buffer`; each view fills the batch of each look in `Instances` (thinned
     by distance), drawn by the visibility buffer with the batches' wind/sway/bender hook.
   - **Verify:** GPU validation on Metal (macOS ARM64) & Vulkan (Windows x64),
     `mirai render check --views`, `mirai bench compare --base main`, headless server skips cleanly.
7. **M5 — Automatic Bridges & Editor (`pcg_terrain`, `pcg_physics`, `pcg_shapes`,
   `plugins/pcg/editor`):**
   - Bridges for terrain conform/brushes, collider keep-outs/3D overlap, and Grammar → `shapes`.
   - Editor layer/expression inspector, density/mask brush (`F`), `Revision_History`,
     `Edit_Follow_Provider`, 1-click Suppress+Promote picking, `Inspect` overlays, `pcg.*` API, and
     `demo` showcase scene.
   - **Verify:** `uv run scripts/check_ui_style.py`, `mirai rpc describe pcg`, `play.audit`,
     `mirai capture` at `Medium`, `mirai build game demo` (editor-time exclusion).
