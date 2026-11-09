package main

import "core:fmt"
import "mirai:asset"
import "mirai:core"
import "mirai:std/base"
import game "mirai:demo/game"
import phys "plugins:physics/runtime"
import render "mirai:engine/render"

// A box of the house the player walks on and into: a cube of the engine's
// material with a tint.
@(private = "file")
horror_block :: proc(s: ^asset.Scene_Builder, name: string, center, size, color: [3]f32, emission: [3]f32 = {}) -> base.Entity_Id {
    id := placed(s, name, center, 1, size)
    asset.builder_set(s, id, render.Mesh_Renderer{shape = .Cube})
    tinted(s, id, color, emission)
    collider := phys.collider_box({0.5, 0.5, 0.5})
    asset.builder_set(s, id, collider)
    return id
}

// A lamp of the house: a globe that glows, its light inside, given by its switch.
@(private = "file")
horror_lamp :: proc(s: ^asset.Scene_Builder, name: string, position: [3]f32, light_switch: base.Entity_Id, flicker: f32 = 0) {
    color := [3]f32{1, 0.82, 0.6}
    glow := color * 400
    globe := placed(s, name, position, 1, {0.25, 0.25, 0.25})
    asset.builder_set(s, globe, render.Mesh_Renderer{shape = .Sphere})
    tinted(s, globe, {1, 1, 1}, glow)
    light := asset.builder_entity(s, fmt.tprintf("%s light", name), {position=position})
    asset.builder_set(s, light, render.Point_Light{color = color, intensity = 150, range = 10, radius = 0.12})
    asset.builder_set(s, light, game.House_Lamp{light_switch = core.Entity(light_switch), intensity = 150, globe = core.Entity(globe), glow = glow, flicker = flicker})
}

// The horror house: a dark room of 8 by 6 metres under the moon through a
// window, two lamps under its ceiling and a third that flickers in a corner,
// all on a switch by the door, and a flashlight the player carries. A fixed
// exposure keeps the dark dark: the eye does not open up when the lights go.
write_horror_scene :: proc(o: ^Out) {
    s: asset.Scene_Builder
    asset.builder_init(&s, &o.content, asset.KIND_SCENE, asset.content_id(PROJECT,"scene","horror"))
    defer asset.builder_destroy(&s)
    environment := render.SKY_DEFAULT
    environment.luminance, environment.background = {0.1, 0.12, 0.25}, {0.01, 0.015, 0.04}
    environment.atmosphere = false
    exposure := render.EXPOSURE_DEFAULT
    exposure.mode, exposure.aperture, exposure.shutter = .Manual, 2, 0.2
    sky_set(&s, &environment, 0, exposure)
    moon := render.Sun{color = {0.75, 0.85, 1}, illuminance = 10}
    moon_entity := asset.builder_entity(&s, "Moon", {position={-6, 4, 1}})
    pose := sun_pose({-0.8, 0.45, 0.2}, {-6, 4, 1})
    asset.builder_set(&s, moon_entity, pose)
    asset.builder_set(&s, moon_entity, moon)

    walls := [3]f32{0.55, 0.52, 0.48}
    horror_block(&s, "Ground", {0, -0.1, 0}, {16, 0.2, 14}, {0.35, 0.3, 0.26})
    horror_block(&s, "Ceiling", {0, 2.9, 0}, {8.4, 0.2, 6.4}, walls)
    horror_block(&s, "East wall", {4.1, 1.4, 0}, {0.2, 2.8, 6}, {0.45, 0.5, 0.55})
    horror_block(&s, "North wall", {0, 1.4, -3.1}, {8.4, 2.8, 0.2}, walls)
    horror_block(&s, "South wall", {0, 1.4, 3.1}, {8.4, 2.8, 0.2}, walls)
    // The wall with the window: below, above and either side of it.
    window_wall := [3]f32{0.5, 0.35, 0.3}
    horror_block(&s, "West wall below", {-4.1, 0.5, 0}, {0.2, 1, 6}, window_wall)
    horror_block(&s, "West wall above", {-4.1, 2.4, 0}, {0.2, 0.8, 6}, window_wall)
    horror_block(&s, "West wall north", {-4.1, 1.5, -1.8}, {0.2, 1, 2.4}, window_wall)
    horror_block(&s, "West wall south", {-4.1, 1.5, 1.8}, {0.2, 1, 2.4}, window_wall)
    horror_block(&s, "Table", {-0.2, 0.4, -1.1}, {1.6, 0.8, 0.8}, {0.4, 0.25, 0.15})
    horror_block(&s, "Wardrobe", {3.2, 1.05, -2.55}, {1.2, 2.1, 0.7}, {0.3, 0.2, 0.12})
    horror_block(&s, "Bed", {-3.35, 0.25, 2.2}, {0.9, 0.5, 1.2}, {0.6, 0.6, 0.62})
    horror_block(&s, "Chair", {1.2, 0.45, -0.6}, {0.5, 0.9, 0.5}, {0.35, 0.22, 0.14})

    // The switch by the door, which the lamps name.
    light_switch := horror_block(&s, "Light switch", {2.2, 1.3, 2.97}, {0.12, 0.18, 0.06}, {0.85, 0.82, 0.75})
    turned := game.LIGHT_SWITCH_DEFAULT
    asset.builder_set(&s, light_switch, turned)
    exhibit := game.Exhibit{reach = 2}
    base.text_set(exhibit.caption[:], "E: luz   F: linterna")
    asset.builder_set(&s, light_switch, exhibit)
    horror_lamp(&s, "Lamp west", {-1.5, 2.6, 0}, light_switch)
    horror_lamp(&s, "Lamp east", {2.0, 2.6, -1}, light_switch)
    horror_lamp(&s, "Lamp corner", {3.6, 2.5, 2.6}, light_switch, flicker = 3)

    // The flashlight: a spot that horror_lights takes to the eyes of the player.
    flashlight := asset.builder_entity(&s, "Flashlight", {position={0.25, 1.45, 2.2}})
    asset.builder_set(&s, flashlight, render.Spot_Light{color = {1, 0.97, 0.9}, intensity = 600, range = 15, radius = 0.03, angle = 0.3})
    asset.builder_set(&s, flashlight, game.Flashlight{intensity = 600, on = true})

    spawn_point(&s, {1.5, 0, 2.2})
    asset.builder_save(&s,path(o, "assets/horror/horror.scene"))
}
