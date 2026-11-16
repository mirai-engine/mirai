package base

import "core:mem"
import "core:testing"

// A copy takes the chunks whose stamps differ, or all of them whole, reads zeros past the end of its source
// and keeps to what its destination holds, whatever the counts it is given.
@(test)
chunks_copy_takes_what_differs_and_keeps_within_its_arrays :: proc(t:^testing.T) {
    Case :: struct {name:string,src_slots,src_chunks,slots:int,dst_stamps:[3]u64,whole:bool,written:int,copied:[3]bool}
    cases:=[?]Case{
        {"same stamps",192,3,192,{1,2,3},false,0,{false,false,false}},
        {"one chunk written",192,3,192,{1,9,3},false,64*4,{false,true,false}},
        {"whole",192,3,192,{1,2,3},true,192*4,{true,true,true}},
        {"source shorter: zeros",70,2,192,{0,0,0},false,128*4,{true,true,false}},
        {"stamps of the source shorter: stamp 0",192,1,192,{1,5,5},false,128*4,{false,true,true}},
        {"fewer slots asked",192,3,10,{0,0,0},false,64*4,{true,false,false}},
        {"no slots",192,3,-5,{0,0,0},true,0,{false,false,false}},
        {"more slots than held",192,3,1<<40,{0,0,0},false,192*4,{true,true,true}},
    }
    for c in cases {
        src,dst:[192]u32
        for &value,i in src[:c.src_slots] {value=u32(i)+1}
        for &value in dst {value=0xffffffff}
        src_stamps:=[3]u64{1,2,3}
        dst_stamps:=c.dst_stamps
        arrays:=[2]Chunk_Copy{{mem.slice_to_bytes(dst[:]),mem.slice_to_bytes(src[:c.src_slots]),size_of(u32)},{nil,nil,0}}
        written:=chunks_copy(arrays[:],dst_stamps[:],src_stamps[:c.src_chunks],c.slots,c.whole)
        testing.expectf(t,written==c.written,"%v: %v bytes written",c.name,written)
        for copied,k in c.copied {
            want:=u32(0xffffffff)
            if copied {want=k*CHUNK<c.src_slots?u32(k*CHUNK)+1:0}
            testing.expectf(t,dst[k*CHUNK]==want,"%v: chunk %v holds %v",c.name,k,dst[k*CHUNK])
            if copied {testing.expectf(t,dst_stamps[k]==chunk_stamp_at(src_stamps[:c.src_chunks],k),"%v: chunk %v kept its stamp",c.name,k)}
        }
    }
    // Nothing to copy into: nothing written.
    testing.expect_value(t,chunks_copy(nil,nil,nil,100,true),0)
    stamps:[1]u64
    testing.expect_value(t,chunks_copy([]Chunk_Copy{{nil,nil,4}},stamps[:],nil,100,true),0)
}
