package animation_editor

import "core:testing"

// What is attached touches its bone or nearly; a guessed offset or a pivot
// far from the triangles leaves it floating, by more than its size allows.
@(test)
an_attachment_far_from_its_bone_floats :: proc(t:^testing.T) {
    Case :: struct {bone,low,high:[3]f32,far:bool,what:string}
    for c in ([]Case{
        {{0,0,0},{-0.05,-0.05,-0.1},{0.05,0.05,0.9},false,"a sword held at its grip"},
        {{0,0,0},{0.12,-0.3,-0.3},{0.16,0.3,0.3},false,"a shield a hand's width off the spine"},
        {{0,0,0},{0.5,-0.05,-0.05},{0.6,0.05,0.8},true,"a scabbard half a metre off the hip"},
        {{0,0,0},{0.05,0,0},{0.07,0.02,0.02},false,"a ring a few centimetres off its bone"},
        {{0,0,0},{2,2,2},{2.1,2.1,4.6},true,"a blade at a guessed offset"},
    }) {
        distance,tolerance,far:=attachment_far(c.bone,c.low,c.high)
        testing.expectf(t,far==c.far,"%s: far %v (%.2f m, allows %.2f m)",c.what,far,distance,tolerance)
    }
}
