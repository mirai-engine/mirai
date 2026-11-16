package ai

import "core:math/linalg"
import "core:testing"
import math "mirai:std/math"

// Rooftops of a city block in one tile of 16 m: a roof at 0 from x 0 to 4, a
// gap to x 6, a roof at 1 m from 6 to 10, and the street at -4 m from 10 to 16, right under its edge.
// Each is a quad across z from 2 to 6.
rooftops :: proc(t:^testing.T,mesh:^Nav_Mesh) {
    testing.expect(t,nav_mesh_init(mesh,{tile_width=16,climb=0.3,max_tiles=1,max_links=64}))
    vertices:=[]math.Vec3{
        {0,0,2},{4,0,2},{4,0,6},{0,0,6},
        {6,1,2},{10,1,2},{10,1,6},{6,1,6},
        {10,-4,2},{16,-4,2},{16,-4,6},{10,-4,6},
    }
    indices:=[]u32{0,1,2,0,2,3,4,5,6,4,6,7,8,9,10,8,10,11}
    data,ok:=nav_tile_from_triangles({0,0},{{0,-10,0},{16,10,16}},vertices,indices)
    testing.expect(t,ok && nav_mesh_add_tile(mesh,data))
}

@(test)
jumps_and_drops_are_found_from_ledges_within_what_a_class_can_do :: proc(t:^testing.T) {
    mesh:Nav_Mesh
    rooftops(t,&mesh)
    defer nav_mesh_destroy(&mesh)
    links:[64]Nav_Jump_Link
    jump:=Nav_Jump{up=1.2,across=3,down=6,radius=0.3,climb=0.3,step=0.25}
    count,complete:=nav_jump_links(&mesh,{0,0},jump,links[:])
    testing.expect(t,complete)
    up,back,drop,street:=0,0,0,0
    for link in links[:count] {
        switch {
        case link.kind==.Jump && link.start.x<5 && link.end.x>5: up+=1;testing.expect(t,abs(link.need.up-1)<1e-3 && link.need.across<=3)
        case link.kind==.Jump && link.start.x>5 && link.end.x<5: back+=1
        case link.kind==.Drop && link.start.x>9 && link.end.x>10: drop+=1;testing.expect(t,abs(link.need.down-5)<1e-3)
        case link.end.y< -3: street+=1
        }
    }
    // One link per ledge that faces the other roof; the street is a drop from the higher roof only.
    testing.expect(t,up==1 && back==1 && drop==1 && street==0)

    // Without the height to jump up, only the way down is a jump.
    low:=jump
    low.up=0.5
    count,_=nav_jump_links(&mesh,{0,0},low,links[:])
    up,back=0,0
    for link in links[:count] {
        if link.kind==.Jump && link.start.x<5 && link.end.x>5 {up+=1}
        if link.kind==.Jump && link.start.x>5 && link.end.x<5 {back+=1}
    }
    testing.expect(t,up==0 && back==1)

    // A drop deeper than the class drops is no link.
    shallow:=jump
    shallow.down=2
    count,_=nav_jump_links(&mesh,{0,0},shallow,links[:])
    for link in links[:count] {testing.expect(t,link.kind!=.Drop)}
}

@(test)
an_arc_that_is_not_clear_makes_no_link :: proc(t:^testing.T) {
    mesh:Nav_Mesh
    rooftops(t,&mesh)
    defer nav_mesh_destroy(&mesh)
    links:[64]Nav_Jump_Link
    jump:=Nav_Jump{up=1.2,across=3,down=6,radius=0.3,climb=0.3,step=0.25}
    // A wall across the gap, up to 5 m.
    walled :: proc(user:rawptr,link:Nav_Jump_Link) -> bool {
        for i in 0..<16 {
            p:=nav_jump_point(link,f32(i)/15)
            if p.x>4.8 && p.x<5.2 && p.y<5 {return false}
        }
        return true
    }
    count,_:=nav_jump_links(&mesh,{0,0},jump,links[:],walled)
    for link in links[:count] {testing.expect(t,!(link.kind==.Jump && (link.start.x<5)!=(link.end.x<5)))}
    // The arc rises above the higher end and lands on the other.
    link:=Nav_Jump_Link{start={4,0,4},end={6,1,4},kind=.Jump}
    top:=f32(-1)
    for i in 0..=100 {top=max(top,nav_jump_point(link,f32(i)/100).y)}
    testing.expect(t,abs(top-(1+NAV_JUMP_CLEARANCE))<0.01)
    testing.expect(t,linalg.distance(nav_jump_point(link,1),link.end)<1e-4 && nav_jump_point(link,0)==link.start)
}

@(test)
a_jump_up_is_found_past_a_street_the_class_could_drop_to :: proc(t:^testing.T) {
    // The roofs of rooftops with a street at -3 m under the gap between them, as the Horde arena of the demo.
    mesh:Nav_Mesh
    testing.expect(t,nav_mesh_init(&mesh,{tile_width=16,climb=0.3,max_tiles=1,max_links=64}))
    defer nav_mesh_destroy(&mesh)
    vertices:=[]math.Vec3{
        {0,0,2},{4,0,2},{4,0,6},{0,0,6},
        {6,1,2},{10,1,2},{10,1,6},{6,1,6},
        {4,-3,2},{6,-3,2},{6,-3,6},{4,-3,6},
    }
    indices:=[]u32{0,1,2,0,2,3,4,5,6,4,6,7,8,9,10,8,10,11}
    data,ok:=nav_tile_from_triangles({0,0},{{0,-10,0},{16,10,16}},vertices,indices)
    testing.expect(t,ok && nav_mesh_add_tile(&mesh,data))
    links:[64]Nav_Jump_Link
    jump:=Nav_Jump{up=1.2,across=3,down=4,radius=0.3,climb=0.3,step=0.25}
    count,complete:=nav_jump_links(&mesh,{0,0},jump,links[:])
    testing.expect(t,complete)
    up,down,street:=0,0,0
    for link in links[:count] {
        switch {
        case link.kind==.Jump && link.start.x<4.5 && link.end.x>5.5: up+=1;testing.expect(t,abs(link.need.up-1)<1e-3 && link.need.across<=3)
        case link.kind==.Jump && link.start.x>5.5 && link.end.x<4.5: down+=1
        case link.end.y< -2: street+=1
        }
    }
    testing.expect(t,up==1)
    testing.expect(t,down==1)
    testing.expect(t,street>=1)
}
