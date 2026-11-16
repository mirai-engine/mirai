package editor

import "core:testing"
import "mirai:core"
import mm "mirai:std/math"
import "mirai:std/spatial"

// A world query of boxes, as the library that simulates a world gives one.
@(private="file")
Boxes :: struct {boxes:[]mm.Aabb}

@(private="file")
boxes_probe :: proc(user:rawptr,origin,direction:[3]f32,length,radius:f32,ignore:core.Entity,mask:u32) -> (hit:core.World_Hit,met:bool) {
    nearest:=f32(1)
    for box in (^Boxes)(user).boxes {
        fraction:f32
        crossed:bool
        if radius>0 {
            fraction,crossed=spatial.aabb_sweep(box,{origin-radius,origin+radius},direction*length,nearest)
        } else {
            fraction,crossed=spatial.aabb_ray(box,origin,direction*length,nearest)
        }
        if crossed {nearest,met=fraction,true}
    }
    return {point=origin+direction*length*nearest,distance=length*nearest},met
}

// A figure stands on the floor in no body, where the camera sees it, and on
// its way to the other side of a wall it goes over it: no frame of the way
// stands in one. Without a world query it goes straight and stands where it
// is told.
@(test)
presence_stands_and_goes_around_the_bodies_of_the_scene :: proc(t:^testing.T) {
    boxes:=[2]mm.Aabb{{{-20,-0.1,-20},{20,0,20}},{{-0.1,0,-3},{0.1,4,3}}} // a floor and a wall along z
    scene:=Boxes{boxes[:]}
    low,high:=[3]f32{-0.4,-0.6,-0.4},[3]f32{0.4,0.3,0.4}
    space:=presence_space({},low,high)
    space.query={user=&scene,probe=boxes_probe}
    lift:=[3]f32{0,-low.y,0}

    testing.expect(t,presence_blocked(space,lift),"the wall goes through a figure standing in it")
    open:=[3]f32{-5,0,-10}
    testing.expect(t,!presence_blocked(space,open+lift),"the floor it stands on does not")
    testing.expect_value(t,presence_free_place(space,low,open,{},{-5,1,0}),open)
    // The camera is in front of the end of the wall: of the free places, one it sees.
    eye:=[3]f32{0,1.5,12}
    place:=presence_free_place(space,low,{0,0,-1.5},{0,0,-3},eye)
    testing.expect(t,!presence_blocked(space,place+lift),"the figure is moved out of the wall")
    testing.expect(t,presence_seen(space,place+lift,eye),"and to where the camera sees it")
    testing.expect_value(t,place.y,f32(0))

    Way :: struct {from,to:[3]f32,turns:int}
    ways:=[2]Way{{{-3,1,0},{3,1,0},2},{{-3,1,-10},{3,1,-10},0}}
    for way in ways {
        route,count,clear:=presence_route(space,way.from,way.to)
        if !testing.expect(t,clear) || !testing.expect_value(t,count,way.turns) {continue}
        figure:=Presence{at=way.from,placed=true,goal=way.to,route=route,route_count=count}
        crossed:=false
        for _ in 0..<600 {
            presence_follow(&figure,way.to,1.0/60)
            if presence_blocked(space,figure.at) {crossed=true}
            if figure.at==way.to {break}
        }
        testing.expect(t,!crossed,"no frame of the way stands in a body")
        testing.expect_value(t,figure.at,way.to)
    }

    alone:=presence_space({},low,high)
    testing.expect_value(t,presence_free_place(alone,low,{0,0,-1.5},{0,0,-3},eye),[3]f32{0,0,-1.5})
    _,count,clear:=presence_route(alone,{-3,1,0},{3,1,0})
    testing.expect(t,clear && count==0,"with no world query the way is straight")
}
