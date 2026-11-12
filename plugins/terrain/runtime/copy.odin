package terrain

import "base:runtime"
import "core:strings"
import "mirai:std/base"
import "mirai:std/geom"

@(private)
data_source_copy :: proc(dst,src:^Source) -> bool {
    if dst.kind!=src.kind || !source_valid(dst.info) {return source_clone(dst,src) && coarse_copy(&dst.coarse,&src.coarse,dst.allocator)}
    if dst.file!=src.file {
        file,error:=strings.clone(src.file,dst.allocator)
        if error!=nil {return false}
        delete(dst.file,dst.allocator);dst.file=file
    }
    if !grid_copy(&dst.field,&src.field,dst.allocator) || !grid_copy(&dst.holes,&src.holes,dst.allocator) || !grid_copy(&dst.field,&src.field,dst.allocator) {return false}
    if !grid_copy(&dst.weights,&src.weights,dst.allocator) || !coarse_copy(&dst.coarse,&src.coarse,dst.allocator) {return false}
    for i in 0..<EDITS_MAX {if !grid_copy(&dst.edit_heights[i],&src.edit_heights[i],dst.allocator) {return false}}
    if !grid_copy(&dst.edit_under,&src.edit_under,dst.allocator) {return false}
    dst.info,dst.origin=src.info,src.origin
    return true
}

@(private)
data_chunks_copy :: proc(dst,src:^Data_Source) -> bool {
    same :: proc(dst:^[]$T,count:int,allocator:runtime.Allocator) -> bool {
        if len(dst)==count {return true}
        next,error:=make([]T,count,allocator);if error!=nil {return false}
        delete(dst^,allocator);dst^=next
        return true
    }
    if dst.allocator.procedure==nil {dst.allocator=context.allocator}
    count:=len(src.dirty)
    a:=dst.allocator
    if !same(&dst.versions,len(src.versions),a) || !same(&dst.nodes,len(src.nodes),a) || !same(&dst.dirty,count,a) {return false}
    if reserve(&dst.pending,count)!=nil || resize(&dst.pending,count)!=nil {return false}
    copy(dst.versions,src.versions);copy(dst.nodes,src.nodes)
    dst.quad=src.quad
    for i in 0..<count {dst.dirty[i]=true;dst.pending[i]=u32(i)}
    return true
}

// Puts back in dst what src holds from low to high, inclusive sample
// coordinates: the samples of a Heightfield or a Volume an edit changed,
// between two sources of the same samples.
source_restore :: proc(dst,src:^Source,low,high:[3]int) -> (change:Change) {
    if dst.kind!=src.kind || dst.samples!=src.samples {change.error=.Invalid;return}
    from,to:=low,high
    for axis in 0..<3 {
        from[axis],to[axis]=max(from[axis],0),min(to[axis],int(dst.samples[axis])-1)
        if from[axis]>to[axis] {return}
    }
    change.low,change.high=to,from
    g,h:=&dst.field,&src.field
    if !grid_prepare(g,from,to,dst.allocator) {change.error=.Out_Of_Memory;return}
    for z in from.z..=to.z {for y in from.y..=to.y {for x in from.x..=to.x {
        p:=[3]int{x,y,z}
        value:=grid_value(h,p)
        if grid_value(g,p)==value {continue}
        grid_write(g,p,value)
        change.changed=true
        for axis in 0..<3 {change.low[axis]=min(change.low[axis],p[axis]);change.high[axis]=max(change.high[axis],p[axis])}
    }}}
    return
}

// A Heightfield of other samples around the center of src, in dst: its
// heights, weights and holes stay where they were, and what grows past them
// takes the heights and weights of the nearest edge, without holes. Each side
// changes by an even number of samples, so the center stays a sample. False,
// dst as it was, otherwise or without memory.
source_resize :: proc(dst,src:^Source,samples:[2]int,allocator:=context.allocator) -> bool {
    old:=[2]int{int(src.samples.x),int(src.samples.z)}
    if src.kind!=.Heightfield || !source_samples_held(src) || (samples.x-old.x)%2!=0 || (samples.y-old.y)%2!=0 {return false}
    info:=src.info
    info.samples={u32(samples.x),1,u32(samples.y)}
    if !source_valid(info) {return false}
    temporary:Source
    if !source_allocate(&temporary,info,allocator) {return false}
    defer source_destroy(&temporary)
    shift:=(samples-old)/2
    last:=[3]int{samples.x-1,0,samples.y-1}
    if !grid_prepare(&temporary.field,{},last,allocator) {return false}
    for z in 0..<samples.y {for x in 0..<samples.x {
        grid_set(&temporary.field,x,z,grid_get(&src.field,clamp(x-shift.x,0,old.x-1),clamp(z-shift.y,0,old.y-1)))
    }}
    if !grid_prepare(&temporary.weights,{},last,allocator) {return false}
    for z in 0..<samples.y {for x in 0..<samples.x {
        grid_set(&temporary.weights,x,z,grid_get(&src.weights,clamp(x-shift.x,0,old.x-1),clamp(z-shift.y,0,old.y-1)))
    }}
    if !grid_none(&src.holes) {
        cells:=samples-1
        if !grid_init(&temporary.holes,{cells.x,1,cells.y},0,allocator) {return false}
        for z in 0..<cells.y {for x in 0..<cells.x {
            sx,sz:=x-shift.x,z-shift.y
            if sx<0 || sz<0 || sx>=old.x-1 || sz>=old.y-1 || grid_get(&src.holes,sx,sz)==0 {continue}
            if !grid_put(&temporary.holes,{x,0,z},1,allocator) {return false}
        }}
    }
    if !edits_resize(&temporary,src,shift) {return false}
    source_destroy(dst)
    dst^=temporary
    temporary={}
    return true
}
