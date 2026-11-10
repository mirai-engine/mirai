# Resident animation storage

`std/anim` keeps the editable document as `Keyframe`. `library_compress` prepares a shared library,
immutable during a load, as the runtime plays it: the tracks of each clip go into one stream per
clip (`sampled.odin`), compressed as [ACL](https://github.com/nfrechette/acl) does, which Unreal
uses by default. A prepared library rejects `clip_add` and a second preparation. The `.anim` of a
project keeps its keys; a [cooked one](../../mirai-assets/references/kinds.md#animation) keeps the
streams. A change that gives other streams for the same keys and config advances
`COMPRESS_VERSION`: the [project cache](../../mirai-core/references/host.md#content) keys
compressions by it.

## Error

- `Compress_Config.precision` is how far the origin of a bone or a point `shell` away from it along
  any of its axes may move, in the space of the entity that plays the clip; `COMPRESS_DEFAULT` is
  ACL's (0.1 mm at 3 cm).
- The bones are those of the skeleton the clip plays on (`skeletons`, per clip), whose rest pose
  holds what the clip does not move: a scaled root it does not animate puts the error in scene
  units, as Unreal compresses on its `USkeleton`. A transform track outside it hangs from the track
  `parents` names (`asset.animation_parents` derives it from the target paths); without skeleton,
  a bone without a `Position` track is measured at its parent's origin.
- `Float` and `Vector` tracks are measured per component against `float_precision` and
  `vector_precision`.
- The error is measured at the samples and at three points between each two, decoding exactly as
  the runtime does: Mirai keeps the error between samples within the precision, which ACL does not
  measure. `Compress_Stats.error` and `curve_error` are the worst measured.

## Sampling

- A clip is sampled from 0 to its duration at the interval most of its keys share
  (`COMPRESS_RATE` when none does), fitted over the longest track whose keys all share it so the
  samples land on the keys; a duration between two samples makes the last interval shorter.
- Rotations are stored as x, y and z with `w>=0` and interpolated along the short arc at constant
  speed, as the keys' slerp: linear keys of a fast rotation are followed between samples.
- A track whose keys the samples cannot follow between them (keys off the clip's grid, cubic slopes,
  easing, steps) keeps its keys (`Stream_Kind.Keys`), and so does one whose keys take fewer bytes
  than its samples. Linear keys go into the stream as their times and values, read exactly as
  `track_evaluate` reads them; the others stay `Keyframe` in the library.
- A track that holds the rest pose of its bone is a `Constant`: a stream does not know the
  skeleton, so a library plays without it.

## Stream

- Per track 4 bits: its kind (`Default`, `Constant`, `Animated`, `Keys`) and its width. A track
  that holds still within the precision is `Constant` (its f32 value) or, when that value is
  `STREAM_DEFAULTS` of its property, `Default` (nothing); no track has a header of its own.
- Animated tracks go in blocks, as ACL groups them: rotations, then positions and scales, then
  curves, each block in the clip's order (the stream's `order`). Each has its range over the clip
  and is cut into segments of 16 to 31 samples with its range in 255ths of it; the samples of a
  segment are packed one after another, each with every animated track, at the bits per component
  of each track in that segment: 0 (still in the segment), 1 to `STREAM_MAX_BITS` or the f32. A
  stream of one segment has no segment ranges.
- `stream_check` validates a stream against the tracks of its clip; `clip_add` takes streams
  (`Clip_Desc.stream`) only through it, and `asset.animation_check` through it too.

## Bit rates

ACL's search, per segment:

1. Rigid shells: from the leaves up, a bone whose child's shell points reach farther from it takes
   that distance and the child's precision, so a parent is measured where its farthest descendant
   moves. Constants and defaults are decided on the shells over the clip, each track alone with the
   rest exact.
2. Per bone, the cheapest rates of its slots (rotation, position, scale) within its precision with
   its parents exact, from the combinations sorted by bits.
3. Parents first, the rates of each bone's chain rise by ACL's plans until it is within its
   precision in object space.
4. The whole clip is measured as the runtime decodes it, the samples of a segment next to those of
   the next: where something moves too far, the rate that moves it most rises.

## Access

- `clip_evaluate` gives the same contract for keys and streams; a single sampled track reads its
  clip's stream up to it.
- A pose reads a whole clip in one pass: `clip_reader` and `clip_reader_next` (which `bones_blend`
  uses) or `clip_sample`. The reader gives each track with its place in the clip, not in the
  clip's order: first those that hold still or keep keys, then each block of animated tracks in
  chunks, rotations mixed four at a time. It neither allocates nor reads outside the stream,
  whatever the library holds: its loop skips bounds checks only after checking every read itself.

## Errors and statistics

- Compression validates ranges, enums, values, times, parents and configuration before publishing
  the new tables; each failure, including lack of intermediate memory, leaves the library intact.
- `library_resident_bytes` counts keys, streams, tracks, clips and markers, without the temporary
  memory of the transaction or the source files.

## Verification

- `mirai test std/anim` with the cases of `compress_test.odin`,
  `hostile_streams_through_the_decoder` and the affected `track_*` and `library_*`.
- `mirai test asset animation_compression_of_the_demo --release -define:ANIMATION_BENCH=true`
  (`asset/animation_bench_test.odin`) measures bytes, the worst error, sampling per bone and load
  of the demo's animations; `compact_bench_test.odin` measures a synthetic library.
