package main

import "mirai:asset"
import "core:fmt"
import "core:math"
import "mirai:core"
import game "mirai:demo/game"
import audio "mirai:engine/audio"
import inp "mirai:engine/input"
import cam "mirai:engine/camera"
import spawn "plugins:spawn/runtime"
import phys "plugins:physics/runtime"
import render "mirai:engine/render"
import "mirai:std/base"
import mm "mirai:std/math"
import portals "plugins:portals/runtime"

// The portal chamber: a closed room of white panels the portal gun opens
// portals on and dark ones it does not, with a ledge too high to climb, a pit,
// a conveyor, a ledge of glass that one jumps up through and an exit door that
// a button in the floor opens, behind a grill. And the player that carries the
// gun. The floors are 2 m thick: who falls into a portal in them has room to
// fall until the eyes go through.

@(private="file") WHITE :: [3]f32{0.86,0.87,0.88}
@(private="file") DARK :: [3]f32{0.16,0.17,0.19}

// A slab of the chamber; white ones take portals.
@(private="file")
panel :: proc(s:^asset.Scene_Builder,o:^Out,name:string,center,size:[3]f32,white:bool,parent:base.Entity_Id=0) -> base.Entity_Id {
    id:=slab(s,o,name,center,size,white?"Matte paint":"Rough metal",parent)
    tinted(s,id,white?WHITE:DARK)
    if white {asset.builder_set(s,id,game.Portal_Surface{})}
    return id
}

@(private="file")
caption :: proc(s:^asset.Scene_Builder,id:base.Entity_Id,reach:f32,text:string) {
    exhibit:=game.Exhibit{reach=reach}
    base.text_set(exhibit.caption[:],text)
    asset.builder_set(s,id,exhibit)
}

// One of the two portals: unplaced, it is not drawn. Its opening, a film of its color that shows while
// it leads nowhere, and a rim of light.
@(private="file")
portal_mouth :: proc(s:^asset.Scene_Builder,name:string,color:game.Portal_Color) {
    glow:=game.PORTAL_GLOW
    tint:=glow[color]
    root:=asset.builder_entity(s,name,{position={0,-50,0}})
    size:=game.PORTAL_SIZE
    opening:=asset.builder_entity(s,"Opening",{scale={size.x,size.y,1}},root)
    asset.builder_set(s,opening,portals.Portal{})
    film:=asset.builder_entity(s,"Film",{position={0,0,-0.012},scale={size.x,size.y,0.004}},root)
    cube(s,film,"Matte paint")
    tinted(s,film,tint*0.4,nits(LAMPLIT,tint*2.5))
    RIM :: f32(0.08)
    rims:=[4]struct{name:string,position,scale:[3]f32}{
        {"Rim left",{-0.5*size.x-0.5*RIM,0,-0.006},{RIM,size.y+2*RIM,0.03}},
        {"Rim right",{0.5*size.x+0.5*RIM,0,-0.006},{RIM,size.y+2*RIM,0.03}},
        {"Rim top",{0,0.5*size.y+0.5*RIM,-0.006},{size.x,RIM,0.03}},
        {"Rim bottom",{0,-0.5*size.y-0.5*RIM,-0.006},{size.x,RIM,0.03}},
    }
    for rim in rims {
        id:=asset.builder_entity(s,rim.name,{position=rim.position,scale=rim.scale},root)
        cube(s,id,"Matte paint")
        tinted(s,id,tint,nits(LAMPLIT,tint*1.4))
    }
    mouth:=game.Portal_Mouth{color=color,opening=core.Entity(opening),film=core.Entity(film)}
    asset.builder_set(s,root,mouth)
    asset.builder_set(s,root,render.Hidden{})
}

// A cube the player carries and the portals carry: a bullet, so that its sweep meets the grill however fast it is thrown.
@(private="file")
portal_cube :: proc(s:^asset.Scene_Builder,name:string,position:[3]f32) {
    id:=placed(s,name,position,mm.quat_axis_angle({0,1,0},0.4),{0.6,0.6,0.6})
    cube(s,id,"Satin paint")
    tinted(s,id,{0.82,0.8,0.78},nits(LAMPLIT,{0.5,0.12,0.25}))
    body:=phys.RIGID_BODY_DYNAMIC
    body.bullet=true
    collider:=phys.collider_box({0.5,0.5,0.5})
    collider.density=150
    asset.builder_set(s,id,body)
    asset.builder_set(s,id,collider)
    asset.builder_set(s,id,portals.Traveler{})
    asset.builder_set(s,id,game.Portal_Cube{})
}

write_portal_chamber_scene :: proc(o:^Out) {
    s:asset.Scene_Builder
    feature_scene_begin(&s,o,"portal_chamber",.Night,{0.55,0.68,1},0.05,{0.3,0.8,0.5},LAMPLIT)
    // The floor, 2 m thick, around a pit 6 m deep in the west whose bottom takes portals.
    chamber:=asset.builder_entity(&s,"Chamber")
    // It reaches under the walls, which stand on it: the hole of a portal in a wall has floor under it.
    panel(&s,o,"Floor north",{0,-1,-4.5},{26,2,13},true,chamber)
    panel(&s,o,"Floor south",{0,-1,9},{26,2,4},true,chamber)
    panel(&s,o,"Floor east",{3.5,-1,4.5},{19,2,5},true,chamber)
    panel(&s,o,"Floor west",{-12,-1,4.5},{2,2,5},true,chamber)
    pit:=asset.builder_entity(&s,"Pit",{position={-8.5,0,4.5}},chamber)
    caption(&s,pit,4,"A pit 6 m deep: a portal in its bottom flings what falls into it")
    panel(&s,o,"Pit north",{-8.5,-4,1.75},{5,4,0.5},false,chamber)
    panel(&s,o,"Pit south",{-8.5,-4,7.25},{5,4,0.5},false,chamber)
    panel(&s,o,"Pit west",{-11.25,-4,4.5},{0.5,4,5},false,chamber)
    panel(&s,o,"Pit east",{-5.75,-4,4.5},{0.5,4,5},false,chamber)
    panel(&s,o,"Pit bottom",{-8.5,-7,4.5},{5,2,5},true,chamber)

    // Walls 1 m thick and 8 high; a door in the east one, and the ceiling dark.
    panel(&s,o,"Wall north",{0,4,-10.5},{26,8,1},true,chamber)
    panel(&s,o,"Wall south",{0,4,10.5},{26,8,1},true,chamber)
    panel(&s,o,"Wall west",{-12.5,4,0},{1,8,20},true,chamber)
    panel(&s,o,"Wall east south",{12.5,4,5.75},{1,8,8.5},true,chamber)
    panel(&s,o,"Wall east north",{12.5,4,-5.75},{1,8,8.5},true,chamber)
    panel(&s,o,"Wall east lintel",{12.5,5.6,0},{1,4.8,3},false,chamber)
    panel(&s,o,"Ceiling",{0,8.5,0},{26,1,22},false,chamber)
    // Dark panels on the walls take no portal.
    panel(&s,o,"Panel south",{-4,3,9.95},{6,4,0.1},false,chamber)
    panel(&s,o,"Panel west",{-11.95,5,-3},{0.1,3,5},false,chamber)

    // A ledge 4 m high along the north wall, with a cube on it: the portals take the player up there. It
    // is one white block, so that a portal on its top goes down through all of it; dark panels cover its
    // sides, which take no portal.
    panel(&s,o,"Ledge",{-7,2,-8},{10,4,4},true,chamber)
    panel(&s,o,"Ledge front",{-7,2,-5.95},{10,4,0.1},false,chamber)
    panel(&s,o,"Ledge side",{-1.95,2,-8},{0.1,4,4.2},false,chamber)
    ledge:=asset.builder_entity(&s,"Ledge sign",{position={-7,4.5,-7}},chamber)
    caption(&s,ledge,5,"Too high to climb: open a portal up here and another one below")
    portal_cube(&s,"Cube on the ledge",{-9,4.31,-8})
    portal_cube(&s,"Cube",{0,0.31,5.8})

    // A conveyor that carries what is put on it to the button, and the button that opens the door.
    belt:=panel(&s,o,"Conveyor",{4.5,0.15,-3},{8,0.3,1.6},false,chamber)
    belt_collider:=phys.collider_box({4,0.15,0.8})
    belt_collider.surface_speed={1.4,0,0}
    asset.builder_set(&s,belt,belt_collider)
    caption(&s,belt,3,"A conveyor: its surface carries what stands on it to the button")
    for i in 0..<8 {
        stripe:=asset.builder_entity(&s,fmt.tprintf("Stripe %d",i+1),{position={1+f32(i),0.302,-3},scale={0.12,0.004,1.5}},chamber)
        cube(&s,stripe,"Matte paint")
        tinted(&s,stripe,{1,0.7,0.1},nits(LAMPLIT,{1.2,0.7,0.05}))
    }
    button:=asset.builder_entity(&s,"Button",{position={9.8,0,-3}},chamber)
    zone:=phys.collider_box({0.7,0.45,0.7})
    zone.center={0,0.45,0}
    zone.preset=phys.PRESET_TRIGGER // it overlaps what stands on it
    zone.density=0
    asset.builder_set(&s,button,zone)
    plate:=asset.builder_entity(&s,"Plate",{position={0,0.05,0},scale={1.3,0.1,1.3}},button)
    shape(&s,plate,.Cylinder,"Matte paint")
    tinted(&s,plate,{0.3,0.05,0.04},game.DOOR_CLOSED_GLOW)
    caption(&s,button,3,"A button: the door is open while something stands on it")

    // The exit: a door that slides up, a grill behind it, and a room with the way out.
    lamp:=asset.builder_entity(&s,"Door lamp",{position={12,3.6,0},scale={0.25,0.25,0.25}},chamber)
    cube(&s,lamp,"Matte paint")
    tinted(&s,lamp,{0.1,0.1,0.1},game.DOOR_CLOSED_GLOW)
    door:=slab(&s,o,"Exit door",{12.5,1.6,0},{0.4,3.2,3},"Rough metal",chamber)
    tinted(&s,door,DARK)
    asset.builder_set(&s,door,game.Door{travel=3.1,speed=3,lamp=core.Entity(lamp)})
    pressed:=game.Floor_Button{door=core.Entity(door),plate=core.Entity(plate)}
    asset.builder_set(&s,button,pressed)
    grill:=asset.builder_entity(&s,"Grill",{position={13.4,1.6,0},scale={0.02,3.2,3}},chamber)
    cube(&s,grill,"Glass")
    tinted(&s,grill,{0.4,0.75,1},nits(LAMPLIT,{0.15,0.45,0.9}))
    field:=phys.collider_box({0.5,0.5,0.5})
    field.preset=phys.PRESET_TRIGGER
    field.density=0
    asset.builder_set(&s,grill,field)
    asset.builder_set(&s,grill,game.Grill{})
    caption(&s,grill,3,"A grill: who goes through it loses the portals, and a cube goes back")
    exit:=asset.builder_entity(&s,"Exit room",{position={16,0,0}})
    panel(&s,o,"Floor",{0,-1,0},{6,2,6},false,exit)
    panel(&s,o,"Wall north",{0,2,-3.5},{6,4,1},false,exit)
    panel(&s,o,"Wall south",{0,2,3.5},{6,4,1},false,exit)
    panel(&s,o,"Wall east",{3.5,2,0},{1,4,8},false,exit)
    panel(&s,o,"Ceiling",{0,4.5,0},{6,1,8},false,exit)
    goal:=asset.builder_entity(&s,"Way out",{position={2,1.2,0},scale={0.5,2.4,1.6}},exit)
    cube(&s,goal,"Matte paint")
    tinted(&s,goal,{0.1,0.3,0.1},nits(LAMPLIT,{0.4,2.4,0.6}))
    caption(&s,goal,4,"The way out")
    point_light(&s,"Exit light",{16,3.5,0},{0.7,1,0.75},8*LAMP,9)

    // A ledge of glass: it holds what comes down on it and lets through what comes up.
    glass:=slab(&s,o,"Glass ledge",{-2,1,4.5},{3,0.1,3},"Glass",chamber)
    glass_collider:=phys.collider_box({1.5,0.05,1.5})
    glass_collider.one_way=true
    asset.builder_set(&s,glass,glass_collider)
    caption(&s,glass,3,"A ledge of glass: jump up through it and stand on it")
    portal_cube(&s,"Cube on the glass",{-2,1.4,4.5})

    // Light: panels in the ceiling and lamps under it.
    for x in ([3]f32{-7,0,7}) {
        glowing_panel(&s,fmt.tprintf("Ceiling light %d",int(x)),{x,7.99,0},mm.quat_axis_angle({1,0,0},math.PI/2),{3,1.2},{1,0.97,0.92},5,16,chamber)
    }
    point_light(&s,"Lamp north",{0,6.5,-6},{1,0.95,0.88},30*LAMP,20,chamber,0.1)
    point_light(&s,"Lamp south",{0,6.5,6},{1,0.95,0.88},30*LAMP,20,chamber,0.1)
    point_light(&s,"Lamp pit",{-8.5,-1,4.5},{0.8,0.9,1},6*LAMP,8,chamber,0.1)

    portal_mouth(&s,"Blue portal",.Blue)
    portal_mouth(&s,"Orange portal",.Orange)
    start:=spawn.Spawn_Point{prefab=PORTAL_PLAYER_PREFAB_ID}
    asset.builder_set(&s,placed(&s,"Player start",{0,0,7.5},1,{1,1,1}),start)
    feature_scene_end(&s,o,"portal_chamber")
}

// The player of the portal chamber in first person, with the portal gun. Its
// capsule has dominance: the cubes it walks into or carries do not push it back.
write_portal_player :: proc(o:^Out) {
    s:asset.Scene_Builder
    prefab_root(o,&s,PORTAL_PLAYER_PREFAB_ID,"Portal player")
    character,capsule,walk:=phys.character_default(),phys.collider_character(),game.player_walk()
    capsule.dominance=1
    asset.builder_set(&s,1,character)
    asset.builder_set(&s,1,walk)
    asset.builder_set(&s,1,capsule)
    asset.builder_set(&s,1,game.Portal_Gun{})
    asset.builder_set(&s,1,portals.Traveler{point={0,EYE_HEIGHT,0}})
    eyes:=placed(&s,"Player view",{0,EYE_HEIGHT,0},1,{1,1,1},1)
    asset.builder_set(&s,1,inp.Drivable{camera=core.Entity(eyes)})
    asset.builder_set(&s,eyes,render.Camera{fov=game.VIEW_FOV,near=0.05})
    asset.builder_set(&s,eyes,audio.Audio_Listener{})
    first_person:=cam.Camera_Follow{mode=.Eyes,offset={0,EYE_HEIGHT,0}}
    asset.builder_set(&s,eyes,first_person)
    prefab_save(o,&s,"assets/prefabs/Portal player.prefab")
}
