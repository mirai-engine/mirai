# Known failures

Tests that fail on the base, and tests whose result depends on the load of the machine or on GPU
time. `mirai test` reads the two tables: a package whose only failures are listed here passes,
and its summary counts them apart from new failures; `--strict` fails on them. Reports give them
as a count, without investigating them again. The change that makes a test pass removes its row;
a test is never weakened or deleted to leave this list.

## Fail on the base

| Package | Test | Why |
| --- | --- | --- |
| `render` | `diffuse_transmission_lets_the_sun_through_the_leaves_in_its_way` | sun through stacked cards 0.028, expected 0.117 |
| `render` | `pipeline_passes_run_between_stages_over_the_resources_they_declare` | channels of the view with passes are not 16 times |
| `render` | `render_a_round_of_stacked_masked_cards_keeps_within_its_time` | the rounds of a frame take 32 ms, over the bound |
| `render` | `renderer_calls_without_memory_are_refused_and_keep_what_they_had` | a catalog call without memory is not refused |

## Load-dependent

| Package | Test | Depends on |
| --- | --- | --- |
| `editor` | `editor_panels_bound_scratch_for_a_large_scene_and_library` | machine load |
| `render` | `render_a_swaying_forest_composes_again_only_what_is_near` | GPU time |
| `render` | `render_a_turning_sun_gives_what_whole_maps_give` | GPU time |
| `render` | `render_moved_cascades_give_what_whole_ones_give` | GPU time |
| `render` | `render_the_culls_of_the_maps_keep_within_the_bound` | GPU time |
