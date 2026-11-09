package terrain

import "core:testing"
import "mirai:core"

// The copy of the border a node of a Heightfield is built with, with the
// memory ending at each request in turn: the build does not start, and its
// slot stays free for the frame that tries it again. With memory enough the
// build runs: the tests of the nodes cover it.
@(test)
a_build_without_memory_for_its_border_does_not_start_and_leaves_its_slot_free :: proc(t:^testing.T) {
    owner:=context.allocator
    failure:=Mesh_Conversion_Failure{owner=owner}
    border:Piece_Border
    defer piece_border_destroy(&border)
    for i in 0..<4 {
        append(&border.sides[i],1,2,3)
        append(&border.corners[i],4)
    }
    data:Terrain_Data
    entry:Data_Source
    slot:Work_Slot
    for served in 0..<8 {
        failure.remaining=served
        context.allocator={mesh_conversion_failure_allocator,&failure}
        started:=work_build(&data,&slot,&entry,core.NONE,0,{},false,core.Phase(0),{},&border)
        context.allocator=owner
        piece_border_destroy(&slot.border)
        slot.border={}
        if !testing.expectf(t,!started && slot.kind==.None && slot.source==nil,"with %d requests served the build starts, or its slot is taken",served) {break}
    }
}
