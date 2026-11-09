# Comparing images (`mirai image`)

`mirai image` measures PNG captures without opening the editor and writes JSON to stdout. Code in
`cook/image` and `tools/mirai/image.odin` (each subcommand, with its `*_USAGE`); `mirai capture`
uses the same measures ([capture](api.md#mirai-capture)) and `capture` the same crop
([region](methods.md#editor-and-viewport)).

- `mirai image diff <a.png> <b.png>`: requires the same size.
  - `luma` (MAE, RMSE, PSNR, SSIM, maximum error and `excess`, the mean of how much brighter the
    first image is): Rec. 709 linear luminance in 0..255. `channels` r, g, b: stored value
    0..255; alpha is ignored. `psnr` is `null` if the images are equal.
  - `over_threshold_percent`: pixels with some channel above `--pixel-threshold`
    (`DEFAULT_PIXEL_THRESHOLD`). `--out`: gray difference map (maximum error per channel times
    `DIFF_GAIN`).
- With `--threshold`, it exits with 1 if the metric does not meet it (ssim and psnr: lower fails;
  mae and rmse: higher fails) and with 0 if it does. Default metric: ssim. Typical done criterion:
  `--metric ssim --threshold 0.95` over the adjusted region.
- `mirai image mottle <moving.png> <settled.png>`: the light blotches that the first capture has
  against the second, of the same settled view.
  - The relative difference of its light, smoothed to `MOTTLE_FINE` of the height, minus its mean
    at `MOTTLE_WIDE`: an exposure change or a change of the light of the whole view moves the wide
    scale, which does not count.
  - Only on the smooth surfaces of the second (without detail of their own at those scales): the
    blur of edges and textures of a moving image does not count.
  - `mean_percent` (the mean of that difference), `area_percent` (smooth surface above
    `MOTTLE_SPOT`) and `smooth_percent` (the part of the region that is smooth). `--out`: the map,
    in gray over the smooth and dark blue where it does not measure.
  - Between two still captures of a settled view it gives the floor of its fine noise: the blotches
    that are seen are the area.
- `mirai image stats <a.png>`: `mean_luma`, percentiles (linear luminance 0..1),
  `black_percent` (below `BLACK_LUMA`), `saturated_percent` (channel from `SATURATED_VALUE`) and
  `mean` per channel.
- `mirai image stats <a.png> <b.png>...`: a sequence of frames, with one line per frame and its
  `delta_luma` from the previous one, and the summary of `mean_luma` with `max_delta`, the largest
  change between two consecutive frames. In captures of a still scene, a high `max_delta` is
  flicker or exposure that does not settle.
- `mirai image montage <a.png> <b.png>... --out <x.png>`: side by side at the height of the first.
- To look closely, in pixels from the top left (numbers go loose or with commas):
  - `mirai image crop <a.png> <x> <y> <w> <h> --out <x.png>`: that part, as is.
  - `mirai image zoom ... [--factor N]`: that part with each pixel made a square of N × N (nearest
    neighbor; `ZOOM_FACTOR` by default). The factor and the side of the enlarged image have a cap
    (`ZOOM_MAX_FACTOR`, `ZOOM_MAX_SIDE`): exceeding it exits with 2 and says which.
  - `mirai image pick <a.png> <x> <y> [<x> <y>...]`: each pixel as stored (0..255) and its linear
    `luma` 0..1, as in `stats`. A point outside the image exits with 2 and says its size.
- Exit 2: usage error or unreadable image; stderr says how to fix it.
