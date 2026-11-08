package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "mirai:asset"
import game "mirai:demo/game"
import render "mirai:engine/render"
import mm "mirai:std/math"

@(private = "file")
night_shape :: proc(s: ^Scene_Out, name: string, kind: render.Shape, position, size, color: [3]f32, rotation: mm.Quat = 1, emission: [3]f32 = {}) {
    id := placed(s, name, position, rotation, size)
    put(s, id, "Mesh_Renderer", &render.Mesh_Renderer{shape = kind})
    tinted(s, id, color, emission)
}

// A globe of light of `size` across that glows, and the light it gives, as
// wide as it: intensity in candela.
@(private = "file")
night_lamp :: proc(s: ^Scene_Out, name: string, position, color: [3]f32, size, intensity, range: f32) {
    night_shape(s, name, .Sphere, position, {size, size, size}, color, emission = nits(LAMPLIT, color * 6))
    point_light(s, fmt.tprintf("%s light", name), position, color, intensity, range, radius = size * 0.5)
}

// A square at night, with no sun: the only light is that of its lamps. A row
// of street lamps of which few reach each place, four colored spots over a
// stage whose shadows cross, strings of small lights over a terrace, where
// many reach every place, and candles up a staircase. Every surface has the
// material of the engine and a tint.
write_night_scene :: proc(o: ^Out) {
    s: Scene_Out
    asset.scene_init(&s.scene, &o.types, asset.KIND_SCENE, id_of("scene", "night"))
    environment := render.SKY_DEFAULT
    environment.luminance, environment.background = nits(LAMPLIT, {0.02, 0.025, 0.04}), nits(LAMPLIT, {0.004, 0.006, 0.012})
    environment.atmosphere = false
    // The meter reads from EV100 -0.4 (the stage) to 4.2 (under a lamp): no compensation holds
    // every view, and a light must look the same wherever one looks from. A fixed exposure, EV100
    // 3.5 without the bias of every view (render.EXPOSURE_BIAS), gives `night` in
    // demo/render_check.mirai its luma.
    exposure := render.EXPOSURE_DEFAULT
    exposure.mode, exposure.aperture, exposure.shutter, exposure.compensation = .Manual, 2.8, 0.7, -1
    sky_set(&s, &environment, 0, exposure)

    night_shape(&s, "Ground", .Cube, {0, -0.15, 0}, {44, 0.3, 32}, {0.3, 0.31, 0.34})
    night_shape(&s, "Back wall", .Cube, {0, 3, -15}, {44, 6, 0.6}, {0.42, 0.22, 0.18})
    night_shape(&s, "West house", .Cube, {-18, 2.5, -6}, {8, 5, 14}, {0.5, 0.5, 0.55})
    night_shape(&s, "East wall", .Cube, {21.7, 1.2, 0}, {0.6, 2.4, 32}, {0.4, 0.4, 0.42})
    for i in 0 ..< 6 {
        night_shape(&s, fmt.tprintf("Column %d", i + 1), .Cylinder, {-10 + 4 * f32(i), 2.5, -13.4}, {0.7, 5, 0.7}, {0.85, 0.83, 0.78})
    }

    // The street: ten lamps four metres apart, and what stands between them.
    for i in 0 ..< 10 {
        x := -18 + 4 * f32(i)
        night_shape(&s, fmt.tprintf("Lamp post %d", i + 1), .Cylinder, {x, 1.4, 4.5}, {0.12, 2.8, 0.12}, {0.12, 0.12, 0.14})
        night_lamp(&s, fmt.tprintf("Street lamp %d", i + 1), {x, 3.3, 4.5}, {1, 0.76, 0.5}, 0.42, 14 * LAMP, 7)
        if i % 3 == 1 {night_shape(&s, "Crate", .Cube, {x + 1.4, 0.5, 3.4}, {1, 1, 1}, {0.55, 0.4, 0.25}, mm.quat_axis_angle({0, 1, 0}, 0.4))}
        if i % 3 == 2 {night_shape(&s, "Bench", .Cube, {x + 2, 0.25, 5.6}, {2, 0.5, 0.6}, {0.35, 0.25, 0.18})}
    }
    night_shape(&s, "Barrel", .Cylinder, {-7.3, 0.6, 2.6}, {0.9, 1.2, 0.9}, {0.3, 0.42, 0.5})
    night_shape(&s, "Ball", .Sphere, {3.2, 0.5, 6.3}, {1, 1, 1}, {0.8, 0.2, 0.2})

    // The stage: four spots of four colors on three shapes.
    night_shape(&s, "Stage", .Cube, {0, 0.25, -8}, {9, 0.5, 5}, {0.5, 0.4, 0.3})
    night_shape(&s, "Statue", .Sphere, {0, 1.5, -8}, {2, 2, 2}, {0.9, 0.9, 0.9})
    night_shape(&s, "Plinth", .Cube, {-2.7, 1.1, -7.4}, {1.2, 1.2, 1.2}, {0.9, 0.9, 0.9}, mm.quat_axis_angle({0, 1, 0}, 0.5))
    night_shape(&s, "Drum", .Cylinder, {2.7, 1.25, -8.4}, {1.1, 1.5, 1.1}, {0.9, 0.9, 0.9})
    spots := [4][3]f32{{-4, 5.5, -4.5}, {4, 5.5, -4.5}, {-1.4, 6.2, -3.5}, {1.4, 6.2, -3.5}}
    colors := [4][3]f32{{1, 0.15, 0.1}, {0.15, 0.3, 1}, {0.2, 1, 0.3}, {1, 0.9, 0.75}}
    for at, i in spots {
        towards := linalg.normalize([3]f32{0, 1, -8} - at)
        id := placed(&s, fmt.tprintf("Spot %d", i + 1), at, mm.quat_between([3]f32{0, 0, -1}, towards), {1, 1, 1})
        put(&s, id, "Spot_Light", &render.Spot_Light{color = colors[i], intensity = 60 * LAMP, range = 11, angle = 22.5 * mm.RAD_PER_DEG, radius = 0.08})
    }

    // The terrace: six strings of sixteen small lights over tables and stools.
    night_shape(&s, "Terrace", .Cube, {13, 0.05, 11}, {15, 0.1, 9}, {0.4, 0.3, 0.22})
    for corner in ([4][2]f32{{6, 7}, {20, 7}, {6, 15}, {20, 15}}) {
        night_shape(&s, "String post", .Cylinder, {corner.x, 1.45, corner.y}, {0.1, 2.9, 0.1}, {0.12, 0.12, 0.14})
    }
    string_colors := [4][3]f32{{1, 0.7, 0.4}, {0.3, 0.9, 1}, {1, 0.4, 0.7}, {1, 0.9, 0.3}}
    for row in 0 ..< 6 {
        for i in 0 ..< 16 {
            along := (f32(i) + 0.5) / 16
            position := [3]f32{6.4 + 13.2 * along, 2.75 - 0.3 * math.sin(math.PI * along), 7.4 + 1.44 * f32(row)}
            night_lamp(&s, fmt.tprintf("String light %d", row * 16 + i + 1), position, string_colors[(i + row) % 4], 0.12, 1.5 * LAMP, 3.4)
        }
    }
    for table in 0 ..< 4 {
        at := [3]f32{9 + 3 * f32(table), 0, 9 + 3.4 * f32(table % 2)}
        night_shape(&s, fmt.tprintf("Table %d", table + 1), .Cylinder, at + {0, 0.4, 0}, {1.3, 0.8, 1.3}, {0.7, 0.68, 0.62})
        night_shape(&s, "Stool", .Cylinder, at + {1.1, 0.25, 0.3}, {0.45, 0.5, 0.45}, {0.25, 0.3, 0.4})
        night_shape(&s, "Stool", .Cylinder, at + {-0.9, 0.25, -0.7}, {0.45, 0.5, 0.45}, {0.25, 0.3, 0.4})
    }

    // The staircase: twelve candles on six steps.
    for step in 0 ..< 6 {
        rise := 0.3 * f32(step + 1)
        night_shape(&s, fmt.tprintf("Step %d", step + 1), .Cube, {-14, rise * 0.5, 13 - 0.7 * f32(step)}, {5, rise, 0.7}, {0.55, 0.55, 0.58})
        for side in ([2]f32{-1.6, 1.3}) {
            position := [3]f32{-14 + side + 0.2 * f32(step % 2), rise + 0.16, 13 - 0.7 * f32(step)}
            night_shape(&s, "Candle", .Cylinder, position - {0, 0.08, 0}, {0.07, 0.16, 0.07}, {0.9, 0.88, 0.8})
            night_lamp(&s, fmt.tprintf("Flame %d", step * 2 + (side < 0 ? 1 : 2)), position + {0, 0.09, 0}, {1, 0.6, 0.25}, 0.05, 0.5 * LAMP, 1.6)
        }
    }

    eye := [3]f32{0, 8, 24}
    camera := placed(&s, "Camera", eye, mm.quat_look([3]f32{0, 1, 0} - eye, {0, 1, 0}), {1, 1, 1})
    put(&s, camera, "Camera", &render.Camera{fov = 55 * mm.RAD_PER_DEG, near = 0.1, active = true})
    feature_scene_end(&s, o, "night")
}
