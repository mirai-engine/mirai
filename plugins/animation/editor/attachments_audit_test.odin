package animation_editor

import "core:testing"
import mm "mirai:std/math"

// What is attached touches its bone, or another part drawn of its model; a
// guessed offset or a pivot far from the triangles leaves it floating, by more
// than its size allows.
@(test)
an_attachment_far_from_its_bone_floats :: proc(t:^testing.T) {
    // A hull 4 m long around the bone that carries it, and a body of a
    // character 1.8 m tall around its hip.
    hull:=[]mm.Aabb{{{-1.8,-1,-2},{1.8,1,2}}}
    body:=[]mm.Aabb{{{-0.25,-1,-0.15},{0.25,0.8,0.15}}}
    Case :: struct {bone,low,high:[3]f32,parts:[]mm.Aabb,far:bool,what:string}
    for c in ([]Case{
        {{0,0,0},{-0.05,-0.05,-0.1},{0.05,0.05,0.9},nil,false,"a sword held at its grip"},
        {{0,0,0},{0.12,-0.3,-0.3},{0.16,0.3,0.3},nil,false,"a shield a hand's width off the spine"},
        {{0,0,0},{0.5,-0.05,-0.05},{0.6,0.05,0.8},nil,true,"a scabbard half a metre off the hip"},
        {{0,0,0},{0.05,0,0},{0.07,0.02,0.02},nil,false,"a ring a few centimetres off its bone"},
        {{0,0,0},{2,2,2},{2.1,2.1,4.6},nil,true,"a blade at a guessed offset"},
        {{0,0,0},{1.5,0.9,0.1},{1.6,1.0,0.25},hull,false,"a key on the console of a hull 1.5 m from its bone"},
        {{0,0,0},{1.75,-0.3,-0.6},{2.1,0.3,0.6},hull,false,"a door on the side of a hull"},
        {{0,0,0},{3.5,3,3},{3.6,3.1,3.6},hull,true,"a part of a vehicle at a guessed offset, off its hull"},
        {{0,0,0},{0.5,-0.05,-0.05},{0.6,0.05,0.8},body,true,"a scabbard half a metre off the hip, beside the body"},
        {{0,0,0},{2,2,2},{2.1,2.1,4.6},body,true,"a blade at a guessed offset, off the body"},
    }) {
        distance,tolerance,far:=attachment_far(c.bone,c.low,c.high,c.parts)
        testing.expectf(t,far==c.far,"%s: far %v (%.2f m, allows %.2f m)",c.what,far,distance,tolerance)
    }
}
