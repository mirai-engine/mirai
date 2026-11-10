# Verification

## GPU environment

- The GPU suites of `rhi`, `render` and `engine/render` run without a window and fail if they
  cannot create a device, except with `MIRAI_ALLOW_GPU_SKIP=1`.
- Vulkan: `MIRAI_VALIDATION=1` (or `Device_Desc.validation`) enables the Khronos layer with
  synchronization validation; a GPU test fails on a single layer error. If the layer is not
  installed, `VK_LAYER_PATH` points to it (on Windows, the SDK `Bin` or
  `.deps/vulkan-sdk-windows`). Metal: `MTL_DEBUG_LAYER=1`.
- The `_hw` variants need a GPU with ray queries or Mesa lavapipe (`VK_DRIVER_FILES` pointing to
  its ICD). `MIRAI_RT=software` forces the software BVH.
- A GPU test takes its device with `shared_device.take_or_skip` (`rhi/shared_device`), and one of
  `render` its renderer with `fixture_init` (`render/fixture_test.odin`): the tests of a
  process share one per variant (with and without hardware ray tracing) and run one at a time
  even if there are several threads. It fails if it leaves alive anything it made or if the
  device or the validation report errors. Only a test that exercises a device (capacities, ring,
  messages, loss) or measures without validation makes its own device, with
  `shared_device.create_or_skip` or after `shared_device.hold`, to run alone. The GPU tests of
  `rhi` are in `rhi/tests`
  (`mirai test rhi/tests`), which can import it; those of `rhi` do not touch the GPU.
- The GPU tests of a plugin load the shaders that `mirai test` generates before compiling them in
  `.mirai/tmp/<plugin>-test-shaders`: those of the plugin and, as `<plugin>_test`, the programs of
  the package's `testdata/`. A test of a runtime package does not import `cook`: the shipped game
  also compiles the `*_test.odin` of its packages, and `cook` is not shipped.
- A package of the engine with programs in its `testdata/` gets them the same way, in
  `.mirai/tmp/<package>-test-shaders`. The Surface programs the tests of `render` draw (`Grid`,
  `Ocean`, `Pieces`) are in `render/testdata/`: a test that draws one starts its renderer with that
  generation (`fixture_init(programs = true)`, `fixture_catalog` without a device), the others with
  the embedded one.
- The math or synchronization tests check the result read back from the GPU.
- While another session measures, `mirai test` runs at low priority and with the shared GPU a
  test can take ten times longer, or compile its pipelines cold for minutes: its time says nothing
  about the code. The time of a test is taken with the machine idle.

## Packages

- `rhi`: device contract. A meta-test, Vulkan only, checks that an omitted barrier produces a
  synchronization error.
- `render`: passes, scene, materials, UI, extension stages, without allocations in stable frames.
  The particles, in `plugins/vfx/runtime`
  ([verification](../../mirai-world/references/vfx.md#verification)).
- `engine/render`: world extraction and visual instances.
- `cook/shaders`: generation, cache, catalog and transactions; the programs require `slangc`.

## Cases with their own conditions

- `a_shared_texture_shows_on_another_device_what_its_owner_wrote` (`rhi`): two devices; on Linux
  it checks `VK_KHR_external_memory_fd` and `pidfd_getfd`, on Windows the named handle.
- `metal_unpaced_frames_keep_rendering_until_a_drawable_is_ready` (`rhi`): only on a Mac, plus an
  editor with a window and Metal validation alternating VSync and frame limit.
- `area_lights_give_what_their_points_give` (`render`): with `MIRAI_AREA_DUMP=<folder>` it saves
  its images.
- The probe volume follows the camera: capture before and right after moving it more than one
  cell, without intermediate warm-up.

## Image comparison

- Every image read of the `render` tests goes through `render/golden_test.odin`:
  `MIRAI_GOLDEN=write:<dir>` stores each read and `MIRAI_GOLDEN=compare:<dir>` fails the test
  whose read is not among the stored ones nor within `GOLDEN_MEAN_LIMIT` of one, in mean
  difference of its values over their mean.
- A change that must not alter the image is checked by storing before and comparing after, on the
  same machine.
- A change in the pipeline stages preserves the images of the `render` suite with the standard
  pipeline.

## Scene captures

`mirai capture demo --plan` (and `mirai capture templates/game --plan`) capture the scenes that the
[render check](#render-check) does not measure, from each project's `captures.mirai`, with
validation, against their references in `bin/references` and each view's threshold
([`mirai capture`](../../mirai-agent-api/references/api.md#mirai-capture)). The references belong
to the machine's GPU: they are made with `--write` from a build whose image was reviewed and are
measured again when changing GPU or driver. A threshold stays below what the view repeats
(`--repeat`), which is measured when adding it.

## Regenerating shaders

- `mirai shaders` on unchanged sources answers `up to date` and does not touch the outputs. After
  editing Slang it compiles only the stages of the touched sources; their outputs, the manifest,
  the catalog and the table fingerprint change.
- An executable compiled before regenerating ignores the project's generation (`Stale`) and runs
  with its embedded shaders, without extension stages or hooks: compile the engine again.

## Extensions

- Nested views, texture views, stages, hooks and deformable meshes are verified with the plugins
  that use them: open each scene of
  [the render plugins](../../mirai-plugins/references/render-plugins.md#verification) in the
  windowless editor with validation and capture up close and in motion.
- The `render` suite covers the path without extensions, which keeps its images.

## Measuring

- Fix scene, camera, settings and resolution; separate warm-up from samples; measure GPU times
  without a frame limit (an idle GPU lowers its frequency). The per-pass times of Vulkan and the
  total of the Metal command buffer are different intervals.
- Benchmarks, without `MIRAI_VALIDATION`:
  - `mirai test render render_benchmark_reports_gpu_time_by_pass --release
    -define:RENDER_BENCHMARK=true`: GPU time of each pass of a fixed scene.
  - `gpu_skin_benchmark_reports_skinning_and_refit_time` and
    `gpu_skin_benchmark_reports_the_cost_of_posing_every_level_and_morph_targets` with `--release
    -define:SKIN_BENCHMARK=true`.
- Open editor: `uv run scripts/bench_compare.py presentation` measures presentation with VSync and
  limit disabled (fix view and size, warm up and alternate the builds); `... fade`, the extraction
  when changing the opacity of an entity among thousands of cubes.

## Measuring GI

It measures GI on synthetic fixtures: it does not replace the [render check](#render-check).

`gi_benchmark_reports_noise_error_settling_and_cost` (`render/gi_test.odin`) with `--release`,
`-define:GI_BENCHMARK=true` and `-define:ODIN_TEST_THREADS=1`, without validation:

- Synthetic scenes, each a sequence with its changes, and pans through the entrance room of
  `gallery/main.scene` at `MIRAI_GI_HZ`; each starts as a freshly loaded world. The cases are in
  the test.
- The indirect (`Debug_View.Indirect`, without TAA) is compared in nits with the
  [reference](gi.md#indirect-reference) at its key moments (error, SSIM, bias and leak); the
  shadow cases (`Gi_Case.direct`: a pushed body and a falling one, with the view still) compare
  the direct light (`Debug_View.Direct`) with `reference_lights` in the same pose, while moving
  and after stopping;
  in a still window noise, boiling, flicker, fireflies and blotches are measured, whose floor is
  the noise of the reference (`MIRAI_GI_REFERENCE_FRAMES` lowers it); in the pans, the
  reprojected flicker and the settling on stopping; after each change, the time to 90 % and 99 %
  of the settled value; and the GPU and CPU cost.
- Controls: `MIRAI_RT=software`, `MIRAI_GI_REFERENCE=<folder>` (stores and reuses the
  references), `MIRAI_GI_DUMP=<folder>`, `MIRAI_GI_CASES`, `MIRAI_GI_SETTINGS=name=value,...` and
  `MIRAI_GI_WINDOW=from,to` for ablations.
- Blotches in an editor scene: the deviation of the luminance against its blur on a smooth wall,
  in `mirai capture` or in `capture` with `ui` after hundreds of frames: they measure the
  same.

## Render check

`mirai render check demo` measures what the user sees: the fixed views of `demo/render_check.mirai`
in a windowless editor compiled at `--dev`, measured only between checkouts (it takes the `mirai
measure` turn), against the `main` build measured the same way. A global change of the image or its
cost (GI, light, shadows, TAA, exposure, tonemap, demo materials, a pass that runs in every scene)
is accepted only with this check, without regressions, besides the reference metrics of `gi_test`:
synthetic fixtures are not enough to assert quality or cost. It runs once, at the end; which variant
depends on what the GPU receives and does:

- **Nothing the GPU receives changes**: how assets are stored, compressed or loaded when they
  decode to the same data, tools, editor UI. No render check; captures against `main` if the
  image could differ.
- **Only the image changes**: a constant, a value of a scene, an asset of the same size and
  format, an encoding setting such as the RDO lambda. `--quality`, which measures no cost.
- **The work can change**: a pass, a resource, a shader that does more or less work, a texture
  format or resolution. The full one, which measures cost: only on a machine with no other load.
  With a game or another GPU job running its times are not valid, so it waits for the machine.

While working, `--views` and `--quality`.

- **`--dev` or `--release`.** Both builds of a check are built in the same mode, `--dev` unless it
  says otherwise. The image, the frame and the GPU of each pass come out the same in the two modes;
  the CPU costs about twice as much in `--dev`, and its figures only compare against another
  `--dev`. `--release` only when the doubt is the cost of the CPU or a budget in absolute numbers,
  or when the user asks for it. Measures saved of one mode do not serve the other, and against a
  report of the other mode the cost is not compared.
- **Views** (`render_check.mirai`): window sizes (the demo measures only 1440×900; another with
  `--sizes` when the doubt is about scale), frames and, per view, scene, editor camera and `luma`,
  the mean luminance of its art direction. A view with `play` advances Play and leaves it
  paused: only the render changes. One with `fly` flies the camera like a person
  (`editor.input`), with a fixed `ev100` to compare the light and not the eye adapting. One with
  `push` moves an entity of the scene (`scene.set`, unsaved) one step per frame with the camera
  still, with a fixed `ev100`.
- **Metrics**, per view and size:
  - Cost: median and p95 of the frame, GPU, CPU and GPU of each pass (`profile.capture`).
  - Stability: luma MAE (like `mirai image diff`) between consecutive captures, over the window
    without the bar or the panels, and that of the worst block. A still and settled view does not
    change: what changes is boiling of the GI, the shadows or TAA. The windowless editor draws
    with the fixed `dt` of `engine.step`, and the captures come a fixed count of frames after
    `camera.set`, a cut that restarts the jitter of the view, and before the cost, whose
    `profile.capture` runs frames by the clock: a view gives the same image whatever was measured
    before it and however long anything took.
  - Mean luminance of that region in the first capture.
  - In a flying view: the trail, how much brighter the image is on stopping than settled
    (`excess` of `mirai image diff`), and the light blotches on smooth surfaces
    ([`mirai image mottle`](../../mirai-agent-api/references/image.md)) on stopping and
    `RENDER_MOTTLE_AFTER` frames later: what the camera uncovers before the histories gather their
    samples (`main_wall` flies sideways).
  - In a pushing view (`church_push`): the luma MAE at mid push against the same settled pose,
    judged like the stability, and the frames after stopping until the image is within 10 % and
    1 % of what it deviated by on stopping (`RENDER_PUSH_AFTER`). The editor does not expose
    `reference_lights`: against it `gi_benchmark` measures.
  - Captures, the difference map and, with a base, the two builds side by side.
- **Regressions**, with the limits of `tools/mirai/render.odin` (`RENDER_COST_LIMIT`,
  `RENDER_STABILITY_*`, `RENDER_MOTTLE_FLOOR`, `RENDER_LUMA_LIMIT`): the longest frame; the
  stability, the worst block, the trail (if both builds flew) or the blotches that grow; the
  luminance far from the base or from the view's `luma`. Far from the `luma` in the base too is
  reported without counting as a regression, and moving back toward it is not one either. A view
  that the base did not measure stays uncompared. It ends with 1 on a regression or on a view of
  this build that was not measured.
- **Cost repetition**: the cost changes from one session to another with what the machine is doing
  and with the views measured earlier in the same session; the image metrics do not. So a cost that
  passes the limit is measured again before the verdict, only those views, in a new session of each
  build, starting with the one that was second. The verdict is that of the repetition; the report
  keeps both.
- **Base** (`--base`):
  - A branch or a commit, `main` by default (behind `origin`, that of `origin`), compiled with its
    own `./mirai` in `<main>/.worktrees/render-base`; the two builds are measured alternating
    which goes first. If the checkout has the base's sources, there is no base.
  - **Saved base**: what the base of a commit measures without other load stays in the shared cache
    (`RENDER_SAVED`), with a key of the tool, the project, the GPU, the view and the plan; another
    check measures the base only for what is missing. Its quality always holds; its cost, only on
    this machine, during `RENDER_SAVED_COST_HOURS` and as a filter: the view whose cost passes the
    limit against it is measured again alternating with this build. The time limit bounds a base
    measured slower than today, which would hide a regression. `--fresh-base` measures it even if
    it is saved.
  - A previous `report.json` (its `head` run, without repeating the cost), `none` (only this
    build) or the folder of another checkout with its editor compiled; `--checkout` measures
    another checkout this way instead of its own, and the fields its API does not accept are
    removed.
- **Load**: before compiling it waits, up to `--wait`, for the other `mirai-editor` and
  `mirai-player` to close, and if it does not finish it ends saying which and how to close them
  (`--allow-load` measures anyway). Each session warns of another engine program open and of a
  busy GPU without the measured editor drawing: with warnings a cost is not asserted. Each view
  stores the GPU memory the editor has and what the system leaves it (`gpu_memory` of
  `engine.status`); past `RENDER_MEMORY_SHARE` of the budget, the system evicts GPU memory, the
  passes that read what was evicted cost several times more and the view warns that its cost does
  not count. With an open `mirai session` of the project it does not start.
- **Settings**: the editors of a check read no file of the machine
  (`project.SETTINGS_NO_MACHINE_ENV`): both builds measure what the project asks for, whatever
  preset was chosen on this computer.
- **Quality only** (`--quality`): without `profile.capture`, without the `mirai measure` turn and
  without waiting for the other programs, with the captures at the same frames as the full check.
  It asserts nothing about cost; a saved base of the full one serves it, and one of its own does
  not serve the full one.
- **Output** (`--out`; by default `bin/render-check/<date>`): `report.json`, logs and captures. The
  console ends with a summary of the regressions, with the GPU pass that changed most, and of the
  views not measured or not compared. `mirai render compare <base.json> <report.json>` gives the
  verdicts between two reports.
- **While working**: `--views a,b` and `--sizes WxH,...` bound the run, `--quality` leaves the
  cost out and `--rerun <report.json>` measures again only what that report marked. The check that
  accepts a change is the full one, once, at the end; its table goes to the final report of the
  task. A cost regression is diagnosed with `--rerun` or `profile.compare` in the session, not
  with another full check, and a plugin that the demo does not use is validated with its capture
  and `--reference`, without a render check.
- Focal tests of the tool: `mirai test tools/mirai` with
  `render_judge_finds_the_regressions_of_head_against_base`,
  `render_judge_holds_the_art_direction_of_a_view`,
  `render_judge_finds_a_trail_where_both_builds_flew`,
  `render_judge_finds_blotches_where_both_builds_flew`,
  `render_judge_finds_a_push_that_leaves_more_behind`,
  `render_settle_frames_waits_for_the_last_capture_off_settled`,
  `render_plan_load_refuses_a_push_it_cannot_make`,
  `render_judge_repeats_a_cost_past_the_limit_and_judges_the_repeat`,
  `render_judge_does_not_compare_a_view_the_base_did_not_measure`,
  `render_judge_leaves_the_cost_out_of_a_quality_check`,
  `render_base_key_names_what_a_measure_depends_on`,
  `render_saved_find_gives_the_cost_only_while_it_is_recent`,
  `render_options_parse_reads_the_flags_and_refuses_what_cannot_go_together`,
  `render_flagged_lists_what_a_report_marked`,
  `render_summary_says_what_regressed_and_the_pass_that_changed_most`,
  `render_free_region_leaves_out_the_bar_and_the_panels` and
  `render_plan_load_refuses_a_camera_without_a_target`.
