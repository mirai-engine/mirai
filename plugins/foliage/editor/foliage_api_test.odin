package foliage_editor

import "core:strings"
import "core:testing"
import "mirai:editor/api"
import mm "mirai:std/math"
import foliage "plugins:foliage/runtime"

// A point a method of the foliage is given, and what a brush reaches around
// it, stay where the Foliage holds instances, or the call fails naming the
// field and how to fix it.
@(test)
a_point_past_what_a_foliage_holds_fails_naming_its_field :: proc(t:^testing.T) {
    Case :: struct {point:[3]f32,owner:mm.Transform,reach:f32,held:bool}
    far:=foliage.POSITION_MAX
    cases:=[]Case{
        {{10,5,-10},{rotation=1,scale=1},0,true},
        {{far+1,0,0},{rotation=1,scale=1},0,false},
        {{0,0,far-10},{rotation=1,scale=1},20,false},
        {{far+1,0,0},{position={far,0,0},rotation=1,scale=1},0,true},
        {{0,-far*1.5,0},{rotation=1,scale=1},0,false},
    }
    for c in cases {
        to_local,_:=mm.transform_inverse_matrix(c.owner)
        call:=api.Call{allocator=context.temp_allocator}
        held:=point_held(&call,"at",c.point,to_local,c.reach)
        testing.expectf(t,held==c.held && call.failed==!c.held,"%v",c)
        if !held {testing.expectf(t,strings.has_prefix(call.error.message,"at is at") && strings.contains(call.error.message,"move the Foliage"),"%s",call.error.message)}
    }
}
