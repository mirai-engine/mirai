# std/math

Package declared `mirai_math`, imported with `import "mirai:std/math"`. Each file documents its
types and procedures; this holds the conventions and the contracts that cross files.

- The types (`Vec2`…`Vec4`, `Quat`, `Mat3`, `Mat4`) are aliases of the native Odin ones, so
  `core:math/linalg` operates on them without conversion.
- Right-handed, Y up, +X right, -Z forward, meters, seconds, radians, column vectors. Code names
  the forward `FORWARD`, `quat_forward` and `yaw_of_direction`, never `{0,0,-1}` or `atan2(-x,-z)`.

## Transform and TRS composition (`transform.odin`, `types.odin`)

A zeroed `Transform` is not usable: start from `TRANSFORM_IDENTITY`. Rotations are unit
quaternions; `q1*q2` applies `q2` first.

- `transform_compose(parent, local)` is the hierarchy composition of Mirai: the child's position
  goes through the parent's rotation and scale, and the scales are multiplied axis by axis
  regardless of the rotation. A rotated child under a parent of uneven scale keeps its dimensions
  and its right angles. It is not associative: the world transform is composed from the root.
- `transform_relative(world, parent)` is the inverse that the change of parent uses to keep the
  world pose; it fails, returning the identity, if an axis of the parent's scale is almost zero.
- `transform_from_matrix` fails with axes of no length or not perpendicular (shear); a mirrored
  matrix gives a negative X scale.
- `transform_interpolate` interpolates the rotation with `quat_nlerp` along the short arc: what the
  render does between two ticks.

### Euler

Euler angles are for displaying and writing rotations; the engine stores quaternions. Radians,
applied X, then Y, then Z (R = Rz·Ry·Rx).

- `quat_to_euler` leaves Y within a quarter turn. A rotation has two triples, {x, y, z} and
  {x+π, π−y, z+π}: a Y of 100° comes back as 180°, 80°, 180°.
- `euler_closest` chooses the triple closest to the displayed one; the editor stores the displayed
  triple and passes it as a reference.

## Cameras (`camera.odin`)

- Everything looks toward −Z with +Y up. Clip space has Y up and an inverted depth from 0 to 1 (near
  at 1, far at 0).
- Screen points are pixels from the top-left corner of the viewport, Y downward.
- `frustum_from_matrix` gives six inward-normalized planes, in the order `Left, Right, Bottom, Top,
  Far, Near` (the depth 0 plane is the far one), with the layout of `[6]Vec4`.

## Shapes and queries (`shapes.odin`, `ray.odin`, `overlap.odin`, `closest.odin`, `cull.odin`)

- `Plane{normal, d}` satisfies dot(normal, p)+d = 0 (in `std/geom` the sign of `d` is the opposite).
- `float_min`, `float_max`, `vec3_min` and `vec3_max` are one instruction each; with a NaN they give
  the second value.
- The direction of a ray need not be unit: `t` is in units of its length and is preserved when
  taking the ray to another space with a matrix. Only hits with `t >= 0` count; a ray that starts
  inside a solid hits where it exits.
- In overlaps touching counts; `frustum_overlaps_aabb` is conservative.

## Scalars (`scalar.odin`)

- `damp` is the frame-rate-independent smoothing and `spring_critical` the exact solution of the
  critical spring: stable with any `dt` and with the same result even if the time is split into
  steps. `smooth_damp` arrives in about `smooth_time` seconds without overshooting; the caller
  stores the velocity.

## Deterministic functions (`deterministic.odin`)

- `exp_det`, `ln_det`, `sincos_det`, `sin_det` and `cos_det` give the same bits on every platform:
  they compute in `f64` using only sums, products, divisions and bit operations and round once to
  `f32`. `core:math` calls those of the compiler and the C library, which may round differently on
  another system.
- `damp`, `damp_angle`, `spring_critical`, `smooth_damp` and `random_gaussian` use them, which the
  fixed-tick simulation calls. Assumption: the compiler does not fuse products and sums (FMA).
- The rest stay with `core:math` because they only affect the image: color conversions, elastic
  easings, noise, `quat_axis_angle` and camera projections.

## Easing and curves (`ease.odin`, `curve.odin`)

- Penner's set. Back, elastic and bounce are own: those of `core:math/ease` do not use Penner's
  constants.
- `Ease` is the `u8` enum for data, with fixed values (0 is `Linear`).
- `Curve_Key.interpolation` is that of the segment that starts at the key; `curve_evaluate` holds
  the ends and `curve_evaluate_from` is for playback.

## Random and noise (`random.odin`, `noise.odin`)

- The distributions go over `base.Rng`, with the same values per seed on all platforms.
- Noise goes roughly in −1..1, with variation at distances of order 1; the ranges of each fractal
  are in `noise.odin`.

## Color and quantization (`color.odin`, `quantize.odin`)

- Colors are linear RGB in `Vec3`, or `Vec4` with alpha; `rgba8_from_linear` and `color_parse_hex`
  convert between sRGB bytes or hex text and linear.
- `normal_pack` encodes the 16+16-bit octahedral normal of the mesh vertex; an almost-null normal is
  encoded as 0, which decodes as +Z. `quat_pack` stores the three smallest components; the identity
  is exact.
