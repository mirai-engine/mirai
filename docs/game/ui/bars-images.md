# Bars, gauges and images

What a `Progress` and an `Image` draw, by their style. Writing the `.ui`:
[writing-ui.md](writing-ui.md); styles and looks: [styles.md](styles.md).

## Bars

A `Progress` shows its `bind_value`, from 0 to 1, as its `fill` over its `track`; `fill_mode` is
where it grows from: `right` (from the left edge, the default), `left`, `down`, `up` or `center`.
`radius` rounds its corners; `stroke` draws its edge.

## Gauges

`"fill_mode": "radial"` makes it go around: a ring `border` wide, or a disc without one.

```json
"styles": {"depth": {"fill": "#30c0ff", "track": "#ffffff33", "fill_mode": "radial",
  "border": 10, "radius": 5, "arc_start": -0.375, "arc_sweep": 0.75}}
```

- `arc_start` is the turn it starts at, clockwise from the top (`0.25`: the right). `arc_sweep`
  is how much of a turn its track covers, and its fill covers that part of it its value says;
  negative goes counterclockwise; unset is a whole turn. The example is open at the bottom.
- `radius` makes the ends of the ring round, those of the track and those of the fill.
- Track and fill are each one shape, smooth at any size; a cooldown that empties counterclockwise
  is `"arc_sweep": -1` with the value going down.

## Images

An `Image` shows its image as its `fit` says, tinted by its `fill`: white when unset, the
image as it is. A node tints its own without a style of its own,
`"look": {"extends": "icon", "fill": "#ff8000"}`, and `bind_tint` takes the color from data
(linear RGBA floats or display RGBA bytes). The tint multiplies color and alpha: `#ffffff80`
draws it half transparent. `shadow`, `radius`, `stroke` and `program` work as on a `Box`.
