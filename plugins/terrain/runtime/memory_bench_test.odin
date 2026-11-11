package terrain

import "core:fmt"
import "core:math"
import "core:mem"
import "core:testing"
import "mirai:asset"
import "mirai:std/base"

// The memory of a Volume source: what it holds after it is made (a box) and
// after caves and hills are sculpted into it, what a snapshot of the history
// holds, its file, and with blocks what a viewer at its middle keeps.
// Optional: -define:TERRAIN_BENCH=true.
@(test)
bench_terrain_volume_memory :: proc(t:^testing.T) {
    when !TERRAIN_BENCH {return} else {
        types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
        sculpt :: proc(s:^Source) {
            for i in 0..<24 {
                a:=f32(i)*0.45
                center:=[3]f32{math.cos(a)*f32(s.samples.x)*0.3,-f32(s.samples.y)*0.25+math.sin(a*2)*3,math.sin(a)*f32(s.samples.z)*0.3}*s.cell
                source_edit(s,{kind=.Carve,center=center,radius=5*s.cell,amount=1})
            }
            for i in 0..<12 {
                a:=f32(i)*0.9
                center:=[3]f32{math.cos(a)*f32(s.samples.x)*0.2,0,math.sin(a*1.3)*f32(s.samples.z)*0.2}*s.cell
                source_edit(s,{kind=.Add,center=center,radius=6*s.cell,amount=1})
            }
        }
        // The last ones pass what a Volume once reached along an axis.
        sizes:=[?][3]int{{65,17,65},{129,65,129},{129,129,129},{513,129,513},{513,513,513},{2049,257,2049}}
        for samples in sizes {for carved in ([2]bool{false,true}) {
            tracking:mem.Tracking_Allocator
            mem.tracking_allocator_init(&tracking,context.allocator)
            defer mem.tracking_allocator_destroy(&tracking)
            allocator:=mem.tracking_allocator(&tracking)
            s:Source
            testing.expect(t,source_make(&s,.Volume,samples,1,16,allocator))
            if carved {
                context.allocator=allocator
                sculpt(&s)
            }
            held:=tracking.current_memory_allocated
            snapshot:Source
            testing.expect(t,source_clone(&snapshot,&s,allocator))
            snapshot_bytes:=tracking.current_memory_allocated-held
            data,error:=source_bytes(&s,base.Asset_Id{7,7},&types,context.allocator)
            testing.expect_value(t,error,asset.Error.None)
            dense:=samples.x*samples.y*samples.z*4
            name:=fmt.tprintf("%dx%dx%d %s",samples.x,samples.y,samples.z,carved?"caves":"box")
            fmt.printfln("BENCH | %s | dense %d | source %d | snapshot %d | file %d |",name,dense,held,snapshot_bytes,len(data))
            // With a viewer at the middle of its top: the blocks the chunks
            // within REACH of it read, with their halo.
            REACH :: 24
            g:=&s.field
            counts:=chunk_counts(&s)
            needed:=make([]bool,len(g.pages));defer delete(needed)
            for i in 0..<counts.x*counts.y*counts.z {
                low,high,_:=chunk_region(&s,chunk_coord(&s,i))
                a:=source_origin(&s)+[3]f32{f32(low.x),f32(low.y),f32(low.z)}*s.cell
                b:=source_origin(&s)+[3]f32{f32(high.x),f32(high.y),f32(high.z)}*s.cell
                outside:=[3]f32{max(a.x,0,-b.x),max(a.y,0,-b.y),max(a.z,0,-b.z)}
                if outside.x*outside.x+outside.y*outside.y+outside.z*outside.z<=REACH*REACH {
                    from,to,_:=chunk_pages_region(&s,i)
                    from,to=grid_pages(g,from,to)
                    for pz in from.z..=min(to.z,g.counts.z-1) {for py in from.y..=min(to.y,g.counts.y-1) {for px in from.x..=min(to.x,g.counts.x-1) {
                        if slot,_:=grid_find(g,{px,py,pz});slot>=0 {needed[slot]=true}
                    }}}
                }
            }
            near:=0
            for page,slot in g.pages {if needed[slot] {near+=len(page.values)}}
            fmt.printfln("BENCH | %s | blocks %d | slots %d | values %d | directory %d | resident near a viewer %d |",name,g.counts.x*g.counts.y*g.counts.z,len(g.pages),grid_dense(g)*4,grid_tables_bytes(g),near*4)
            delete(data)
            source_destroy(&snapshot)
            source_destroy(&s)
        }}
    }
}
