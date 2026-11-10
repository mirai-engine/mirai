package anim

import "core:math/linalg"
import "core:testing"
import "mirai:core"
import mm "mirai:std/math"

@(private="file")
Grounding_World :: struct {
    using world:core.Test_World,
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    verticals:core.Table(core.Vertical),
}

// The feet of the rig of a character stand along the up of its vertical,
// whatever its bones do; a rig of no character, along its up in the frame
// it is placed in.
@(test)
the_feet_stand_along_the_vertical_of_the_character :: proc(t:^testing.T) {
    w:Grounding_World
    if !core.test_world_init(t,&w) {return}
    defer core.test_world_destroy(&w)
    character,rig,statue:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    side:=mm.quat_between({0,1,0},{1,0,0})
    core.add(&w.transforms,character,core.Transform{position={20,0,0},rotation=side,scale=1})
    core.add(&w.transforms,rig,core.Transform{rotation=mm.quat_axis_angle({0,0,1},0.4),scale=1})
    core.add(&w.transforms,statue,core.Transform{rotation=side,scale=1})
    core.add(&w.parents,rig,core.Parent{entity=character})
    core.add(&w.verticals,character,core.Vertical{side})
    core.test_world_settle(&w)
    inputs:=Grounding_Inputs{transforms=core.read(&w.transforms),parents=core.read(&w.parents),verticals=core.read(&w.verticals)}
    basis,_:=core.world_of(core.read(&w.transforms),core.read(&w.parents),character)
    up:=grounding_up(inputs,rig,basis,{0,1,0})
    testing.expectf(t,linalg.length(up-{1,0,0})<1e-4,"the up of the vertical of the character, not of the rig: %v",up)
    up=grounding_up(inputs,statue,mm.TRANSFORM_IDENTITY,{0,1,0})
    testing.expectf(t,linalg.length(up-{1,0,0})<1e-4,"without a character, the up of the rig as placed: %v",up)
}
