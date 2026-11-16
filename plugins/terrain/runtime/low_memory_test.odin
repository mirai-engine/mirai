package terrain

import "base:runtime"
import "core:mem"
import "core:testing"
import "mirai:core"

// The copy of the border a node of a Heightfield is built with, with the
// memory ending at each request in turn: the build does not start, and its
// slot stays free for the frame that tries it again. With memory enough the
// build runs: the tests of the nodes cover it.
@(test)
a_build_without_memory_for_its_border_does_not_start_and_leaves_its_slot_free :: proc(t:^testing.T) {
    owner:=context.allocator
    failure:=Failing_Allocator{owner=owner}
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
        context.allocator={failing_allocator,&failure}
        started:=work_build(&data,&slot,&entry,core.NONE,0,{},false,core.Phase(0),{},&border)
        context.allocator=owner
        piece_border_destroy(&slot.border)
        slot.border={}
        if !testing.expectf(t,!started && slot.kind==.None && slot.source==nil,"with %d requests served the build starts, or its slot is taken",served) {break}
    }
}

// The source a head starts where none is loaded, with the memory ending at
// each request in turn: Out_Of_Memory with nothing loaded, and with memory
// enough the source is among the loaded.
@(test)
a_head_without_memory_loads_no_source :: proc(t:^testing.T) {
    failure:=Failing_Allocator{owner=context.allocator,remaining=-1}
    limited:=runtime.Allocator{failing_allocator,&failure}
    shape:Source
    if !testing.expect(t,source_make(&shape,.Heightfield,{9,1,9},1,4)) {return}
    head:=Head{origin=shape.origin,info=shape.info}
    source_destroy(&shape)
    bytes:[HEAD_BYTES]u8
    mem.copy_non_overlapping(&bytes,&head,HEAD_BYTES)
    data:Terrain_Data
    data.settings.sources=4
    data.entries=make([dynamic]Data_Source,limited)
    defer terrain_data_free(&data)
    loaded,refused:=false,false
    for served:=0;!loaded && served<256;served+=1 {
        failure.remaining=served
        entry,error:=replay_head(&data,nil,{kind=.Head,source={7,7},whole=true,values=bytes[:]},limited)
        failure.remaining=-1
        loaded=error==.None
        if loaded {
            testing.expect(t,entry!=nil && len(data.entries)==1 && data.samples>0,"the source is among the loaded")
            break
        }
        refused=true
        testing.expectf(t,error==.Out_Of_Memory && len(data.entries)==0 && data.samples==0,"with %d requests served: %v, %d sources loaded",served,error,len(data.entries))
    }
    testing.expect(t,loaded && refused,"refused without memory, and loaded with it")
}
