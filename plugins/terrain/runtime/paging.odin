package terrain

import "base:runtime"
import "core:mem"
import "mirai:std/base"

// Pages of a Heightfield and blocks of a Volume read from its file when a
// resident chunk needs them and let go when none does; a page with edits
// leaves them in a block of its own, so it comes back as it was. The weights
// of a Volume, in blocks as its distances, come and go with them.

Grid_Kind :: enum u8 {Heights,Weights,Holes,Distances}

// The grid of the samples of a Heightfield or Volume, whose pages the
// chunks mark as those they read.
source_samples_grid :: #force_inline proc "contextless" (s:^Source) -> ^Grid(f32) {
    return s.kind==.Volume?&s.distances:&s.heights
}

// The samples a build of a Volume chunk reads past its own along each axis:
// the gradients of its coarsest level, and the cells its collider looks at
// across its faces.
@(private)
volume_halo :: proc "contextless" (s:^Source) -> int {
    level:=0
    for level<LOD_LEVELS_MAX && 2<<uint(level+1)<=int(s.chunk_cells) {level+=1}
    return max(1<<uint(level),2)
}

// The samples a build of a chunk reads: its own and the halo of a Volume,
// or that of a Heightfield, which its normals, its rules of layers and the
// borders of its collider reach.
@(private)
chunk_pages_region :: proc "contextless" (s:^Source,index:int) -> (low,high:[3]int,ok:bool) {
    from,to,valid:=chunk_region(s,chunk_coord(s,index))
    if !valid {return}
    halo:=s.kind==.Volume?volume_halo(s):max(int(s.chunk_cells)/2,LAYER_RULE_SAMPLES)+2
    for axis in 0..<3 {low[axis],high[axis]=max(from[axis]-halo,0),min(to[axis]+halo,int(s.samples[axis])-1)}
    return low,high,true
}

// Whether a source reads pages from its file.
@(private)
source_paged :: #force_inline proc "contextless" (s:^Source) -> bool {return len(source_samples_grid(s).blocks)>0}

@(private)
distance_finite :: proc "contextless" (value:f32) -> bool {return value-value==0}

// Whether the distances of a Volume stay within its band.
@(private)
distances_within :: proc "contextless" (values:[]f32,band:f32) -> bool {
    for value in values {if !(abs(value)<=band) {return false}}
    return true
}

// Whether every page of the grids of a source over the region is in memory.
@(private)
source_region_held :: proc(s:^Source,low,high:[3]int) -> bool {
    if !source_paged(s) {return true}
    if s.kind==.Volume {return volume_held(s,low,high)}
    held :: proc(g:^Grid($T),low,high:[3]int) -> bool {
        if len(g.blocks)==0 {return true}
        from,to:=grid_pages(g,low,high)
        for pz in from.z..=to.z {for py in from.y..=to.y {for px in from.x..=to.x {
            if grid_absent(g,px+g.counts.x*(py+g.counts.y*pz)) {return false}
        }}}
        return true
    }
    return held(&s.heights,low,high) && held(&s.weights,low,high) && held(&s.holes,low,high)
}

// A page whose values are in its block, into memory: false when the block
// cannot be read or does not hold valid values, or without memory.
@(private)
grid_page_read :: proc(g:^Grid($T),i:int,file:string,valid:proc "contextless" (value:T) -> bool,allocator:runtime.Allocator) -> bool {
    if !grid_absent(g,i) {return true}
    _,count:=grid_page_extent(g,i)
    read:Page_Reader
    read_ok:=page_reader_init(&read,context.temp_allocator)
    defer page_reader_destroy(&read,context.temp_allocator)
    values,made:=shared_make(T,count,allocator)
    if !read_ok || !made {shared_free(values);return false}
    if !page_load(g.blocks[i],file,&read,mem.slice_to_bytes(values)) || !page_valid(values,valid) {shared_free(values);return false}
    grid_page_install(g,i,values)
    return true
}

// Reads the block of a page and decodes it into out; what a job of a page runs.
@(private)
page_load :: proc(block:Page_Block,file:string,read:^Page_Reader,out:[]u8) -> bool {
    bytes,ok:=page_block_read(block,file,read.block)
    return ok && page_decode(bytes,block.hash,out,&read.decoder,read.coded)
}

@(private)
page_valid :: proc(values:[]$T,valid:proc "contextless" (value:T) -> bool) -> bool {
    for value in values {if !valid(value) {return false}}
    return true
}

// The values of a page read from its block take its place in memory.
@(private)
grid_page_install :: proc(g:^Grid($T),i:int,values:[]T) {
    block:=&g.blocks[i]
    g.pages[i].values=values
    block.edited=false
}

// Reads every page of the grids of a source over the region that is in its
// block, now: what an edit and a chunk that cannot wait need. False when one
// cannot be read or there is no memory. Each page read marks for entry, if
// given, the chunks that read it (data_pages_arrived).
@(private)
source_region_read :: proc(s:^Source,low,high:[3]int,entry:^Data_Source=nil) -> bool {
    if !source_paged(s) {return true}
    read :: proc(g:^Grid($T),low,high:[3]int,file:string,valid:proc "contextless" (value:T) -> bool,allocator:runtime.Allocator,entry:^Data_Source,band:f32=0) -> bool {
        if len(g.blocks)==0 {return true}
        from,to:=grid_pages(g,low,high)
        for pz in from.z..=to.z {for py in from.y..=to.y {for px in from.x..=to.x {
            i:=px+g.counts.x*(py+g.counts.y*pz)
            if !grid_absent(g,i) {continue}
            if !grid_page_read(g,i,file,valid,allocator) {return false}
            when T==f32 {
                if band>0 && !distances_within(g.pages[i].values,band) {
                    shared_free(g.pages[i].values)
                    g.pages[i].values=nil
                    return false
                }
            }
            if entry!=nil {
                first,last:=grid_page_region(g,i)
                data_pages_arrived(entry,first,last)
            }
        }}}
        return true
    }
    if s.kind==.Volume {return read(&s.distances,low,high,s.file,distance_finite,s.allocator,entry,s.cell*SDF_BAND_CELLS) && read(&s.weights,low,high,s.file,weights_full,s.allocator,entry)}
    return read(&s.heights,low,high,s.file,height_valid,s.allocator,entry) && read(&s.weights,low,high,s.file,weights_full,s.allocator,entry) && read(&s.holes,low,high,s.file,hole_valid,s.allocator,entry)
}

// What chunks read of the samples low..high came into memory: the chunks
// whose build reads them take the next change of the source, so that who
// reads the source (a bridge) reads them again. A chunk that shows something
// read them before: none of those is marked.
@(private)
data_pages_arrived :: proc(entry:^Data_Source,low,high:[3]int) {
    s:=&entry.source
    halo:=s.kind==.Volume?volume_halo(s):max(int(s.chunk_cells)/2,LAYER_RULE_SAMPLES)+2
    cells:=int(s.chunk_cells)
    counts:=chunk_counts(s)
    from,to:[3]int
    for axis in 0..<3 {from[axis],to[axis]=max(low[axis]-halo,0)/cells,min((high[axis]+halo)/cells,counts[axis]-1)}
    entry.change+=1
    for cz in from.z..=to.z {for cy in from.y..=to.y {for cx in from.x..=to.x {
        index:=chunk_index(s,{i32(cx),i32(cy),i32(cz)})
        a,b,ok:=chunk_pages_region(s,index)
        if index<0 || !ok || a.x>high.x || a.y>high.y || a.z>high.z || b.x<low.x || b.y<low.y || b.z<low.z {continue}
        data_mark_chunk(entry,index)
    }}}
}

// Every page of the weights of a source into memory, as taking a layer away needs.
@(private)
source_weights_read_all :: proc(s:^Source) -> bool {
    g:=&s.weights
    for i in 0..<len(g.blocks) {if !grid_page_read(g,i,s.file,weights_full,s.allocator) {return false}}
    return true
}

// Lets go of the values of page i: with edits, they stay in a block of its
// own first. False without memory, with the page as it was.
@(private)
grid_page_leave :: proc(g:^Grid($T),i:int,allocator:runtime.Allocator) -> bool {
    page,block:=&g.pages[i],&g.blocks[i]
    if page.values==nil {return true}
    if block.edited || block.size==0 {
        if page_uniform(page.values) {
            shared_free(block.own)
            page.fill,block^=page.values[0],{}
        } else {
            writer:Page_Writer
            if !page_writer_init(&writer,context.temp_allocator) {return false}
            defer page_writer_destroy(&writer)
            extent,_:=grid_page_extent(g,i)
            encoded,ok:=page_encode(&writer,page.values,extent.x,false)
            if !ok {return false}
            own,made:=shared_make(u8,len(encoded),allocator)
            if !made {return false}
            copy(own,encoded)
            shared_free(block.own)
            block^={size=u32(len(encoded)),hash=base.hash64(own),own=own}
            page.fill=page.values[0]
        }
    }
    shared_free(page.values)
    page.values=nil
    return true
}

// Lets go of the pages of the grids of a paged source that needed does not
// mark, by page of its grid of samples (source_samples_grid); returns how
// many left. The holes of a Heightfield, a sample fewer, share its pages.
@(private)
source_pages_leave :: proc(s:^Source,needed:[]bool) -> (left:int) {
    if !source_paged(s) {return}
    leave :: proc(g:^Grid($T),needed:[]bool,counts:[3]int,allocator:runtime.Allocator) -> (left:int) {
        if len(g.blocks)==0 {return}
        for page,i in g.pages {
            if page.values==nil {continue}
            q:=[3]int{i%g.counts.x,i/g.counts.x%g.counts.y,i/(g.counts.x*g.counts.y)}
            at:=q.x+counts.x*(q.y+counts.y*q.z)
            if at<len(needed) && needed[at] {continue}
            if grid_page_leave(g,i,allocator) {left+=1}
        }
        return
    }
    if s.kind==.Volume {return leave(&s.distances,needed,s.distances.counts,s.allocator)+leave(&s.weights,needed,s.distances.counts,s.allocator)}
    counts:=s.heights.counts
    return leave(&s.heights,needed,counts,s.allocator)+leave(&s.weights,needed,counts,s.allocator)+leave(&s.holes,needed,counts,s.allocator)
}

// Marks in needed, by page of the grid of samples, the pages a build of chunk index reads.
@(private)
chunk_pages_mark :: proc(s:^Source,index:int,needed:[]bool) {
    low,high,ok:=chunk_pages_region(s,index)
    if !ok {return}
    g:=source_samples_grid(s)
    from,to:=grid_pages(g,low,high)
    for pz in from.z..=to.z {for py in from.y..=to.y {for px in from.x..=to.x {needed[px+g.counts.x*(py+g.counts.y*pz)]=true}}}
}

// What differs between next, read again, and g of the same size: next takes
// the values g holds in memory of each page whose block in next holds the
// same, and g holds them no more. Nothing else of g changes. writer codes
// the pages of g as the file does, quantize as grid_put_document.
@(private)
grid_take :: proc(next,g:^Grid($T),writer:^Page_Writer,quantize:bool) -> (low,high:[3]int,changed:bool) {
    if next.size!=g.size || len(next.pages)!=len(g.pages) {
        for axis in 0..<3 {high[axis]=max(next.size[axis],g.size[axis])-1}
        return {},high,true
    }
    low,high=next.size,{-1,-1,-1}
    uniform :: proc(values:[]$T,fill:T) -> bool {
        for value in values {if value!=fill {return false}}
        return true
    }
    for &page,i in next.pages {
        old:=&g.pages[i]
        same:bool
        switch {
        case page.values!=nil:
            if old.values!=nil {same=mem.compare(mem.slice_to_bytes(page.values),mem.slice_to_bytes(old.values))==0} else if !grid_absent(g,i) {same=uniform(page.values,old.fill)}
        case grid_absent(next,i):
            block:=&next.blocks[i]
            if old.values!=nil {
                if len(g.blocks)>0 && !g.blocks[i].edited {
                    same=g.blocks[i].size>0 && g.blocks[i].hash==block.hash
                } else {
                    extent,_:=grid_page_extent(g,i)
                    encoded,ok:=page_encode(writer,old.values,extent.x,quantize)
                    same=ok && base.hash64(encoded)==block.hash
                }
                if same {page.values,old.values=old.values,nil}
            } else if grid_absent(g,i) {
                same=g.blocks[i].hash==block.hash
            }
        case:
            if old.values!=nil {same=uniform(old.values,page.fill)} else {same=!grid_absent(g,i) && old.fill==page.fill}
        }
        if same {continue}
        first,last:=grid_page_region(next,i)
        for axis in 0..<3 {low[axis]=min(low[axis],first[axis]);high[axis]=max(high[axis],last[axis])}
        changed=true
    }
    return
}

// After a change of every weight in memory, as changing the layers makes,
// the pages keep it when they leave.
@(private)
source_pages_edited :: proc(s:^Source) {
    for &block,i in s.weights.blocks {if s.weights.pages[i].values!=nil {block.edited=true}}
}

// Whether the four samples around cell c,r of a Heightfield are in memory.
cell_held :: #force_inline proc "contextless" (s:^Source,c,r:int) -> bool {
    if len(s.heights.blocks)==0 {return true}
    g:=&s.heights
    return !grid_absent(g,c/PAGE+g.counts.x*(r/PAGE)) && !grid_absent(g,(c+1)/PAGE+g.counts.x*(r/PAGE)) && !grid_absent(g,c/PAGE+g.counts.x*((r+1)/PAGE)) && !grid_absent(g,(c+1)/PAGE+g.counts.x*((r+1)/PAGE))
}

// Whether the samples of a Volume from low to high, inclusive, are in memory.
volume_held :: proc "contextless" (s:^Source,low,high:[3]int) -> bool {
    held :: proc "contextless" (g:^Grid($T),low,high:[3]int) -> bool {
        if len(g.blocks)==0 {return true}
        from,to:=grid_pages(g,low,high)
        for pz in from.z..=to.z {for py in from.y..=to.y {for px in from.x..=to.x {
            if grid_absent(g,px+g.counts.x*(py+g.counts.y*pz)) {return false}
        }}}
        return true
    }
    return held(&s.distances,low,high) && held(&s.weights,low,high)
}

// The height of a Heightfield at a local point x,z, as source_height; ok is
// false outside the source or where its pages are not in memory.
source_height_held :: proc "contextless" (s:^Source,x,z:f32) -> (height:f32,ok:bool) {
    if s.kind!=.Heightfield || !source_valid(s.info) || len(s.heights.pages)==0 {return}
    origin:=source_origin(s)
    column,row:=(x-origin.x)/s.cell,(z-origin.z)/s.cell
    if !(column>=0 && row>=0 && column<=f32(s.samples.x-1) && row<=f32(s.samples.z-1)) {return}
    if !cell_held(s,min(int(column),int(s.samples.x)-2),min(int(row),int(s.samples.z)-2)) {return}
    return source_height(s,x,z),true
}
