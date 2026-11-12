package terrain

import "base:runtime"
import "core:mem"
import "mirai:std/base"

// The pages of the grids of a source, its field, weights and holes, read
// from its file when a resident chunk needs them and let go when none does; a
// page with edits leaves them in a block of its own, so it comes back as it
// was. The grids of a source share its pages: they come and go together.

// The grids of a source, which paging, the network, residency and saves go through alike.
Grid_Kind :: enum u8 {Field,Weights,Holes,Paint}

// The samples a build of a Volume chunk reads past its own along each axis:
// its gradients, and the cells its collider looks at across its faces.
@(private) VOLUME_HALO :: 2

// The samples a build of a chunk reads: its own and the halo of a Volume,
// or that of a Heightfield, which its normals, its rules of layers and the
// borders of its collider reach.
@(private)
chunk_pages_region :: proc "contextless" (s:^Source,index:int) -> (low,high:[3]int,ok:bool) {
    from,to,valid:=chunk_region(s,chunk_coord(s,index))
    if !valid {return}
    halo:=chunk_halo(s)
    for axis in 0..<3 {low[axis],high[axis]=max(from[axis]-halo,0),min(to[axis]+halo,int(s.samples[axis])-1)}
    return low,high,true
}

// The samples a build of node index of a Volume reads: those of its chunks.
@(private)
node_pages_region :: proc "contextless" (s:^Source,q:^Quad,index:int) -> (low,high:[3]int) {
    low,high=quad_region3(s,q,index)
    for axis in 0..<3 {low[axis],high[axis]=max(low[axis]-VOLUME_HALO,0),min(high[axis]+VOLUME_HALO,int(s.samples[axis])-1)}
    return
}

// Whether the Volume holds a surface in an inclusive region of samples, as
// far as its directory tells without reading a block: a block with values of
// its own, or blocks on both sides of it.
@(private)
volume_region_surface :: proc "contextless" (s:^Source,low,high:[3]int) -> bool {
    g:=&s.field
    from,to:=grid_pages(g,low,high)
    sign:=0
    for pz in from.z..=to.z {for py in from.y..=to.y {for px:=from.x;px<=to.x; {
        slot,value:=grid_find(g,{px,py,pz})
        step:=1
        if slot>=0 {
            if g.pages[slot].values!=nil || g.paged && g.blocks[slot].size>0 {return true}
            value=g.pages[slot].fill
        } else {
            span,_:=grid_uniform_span(g,{px,py,pz})
            step=max(span,1)
        }
        side:=value<0?-1:1
        if sign!=0 && side!=sign {return true}
        sign=side
        px+=step
    }}}
    return false
}

// Whether a source reads pages from its file.
@(private)
source_paged :: #force_inline proc "contextless" (s:^Source) -> bool {return s.field.paged}

@(private)
value_finite :: proc "contextless" (value:f32) -> bool {return value-value==0}

// Whether values of the field stay within its limit (field_limit).
@(private)
values_within :: proc "contextless" (values:[]f32,limit:f32) -> bool {
    for value in values {if !(abs(value)<=limit) {return false}}
    return true
}

// Whether every value of the field, in its pages in memory and for the parts
// without them, stays within its limit.
@(private)
grid_within :: proc(g:^Grid(f32),limit:f32) -> bool {
    for page in g.pages {if !(abs(page.fill)<=limit) || !values_within(page.values,limit) {return false}}
    limit:=limit
    return grid_tiles_all(g,&limit,proc(user:rawptr,fill:f32) -> bool {return abs(fill)<=(^f32)(user)^})
}

// Whether every page of the grids of a source over the inclusive region of samples is in memory.
source_region_held :: proc "contextless" (s:^Source,low,high:[3]int) -> bool {
    return !grid_region_absent(&s.field,low,high) && !grid_region_absent(&s.weights,low,high) && !grid_region_absent(&s.holes,low,high) && !grid_region_absent(&s.paint,low,high)
}

// A page whose values are in its block, into memory: false when the block
// cannot be read or does not hold valid values, or without memory.
@(private)
grid_page_read :: proc(g:^Grid($T),id:int,file:string,valid:proc "contextless" (value:T) -> bool,allocator:runtime.Allocator) -> bool {
    if !grid_absent(g,id) {return true}
    _,count:=grid_page_extent(g,id)
    read:Page_Reader
    read_ok:=page_reader_init(&read,context.temp_allocator)
    defer page_reader_destroy(&read,context.temp_allocator)
    values,made:=shared_make(T,count,allocator)
    if !read_ok || !made {shared_free(values);return false}
    if !page_load(grid_block(g,id),file,&read,mem.slice_to_bytes(values)) || !page_valid(values,valid) {shared_free(values);return false}
    grid_page_install(g,id,values)
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

// The values of a page a grid holds, read from its block, take its place in memory.
@(private)
grid_page_install :: proc(g:^Grid($T),id:int,values:[]T) {
    slot:=grid_slot(g,id)
    g.pages[slot].values=values
    g.blocks[slot].edited=false
}

// Reads every page of the grids of a source over the region that is in its
// block, now: what an edit and a chunk that cannot wait need. False when one
// cannot be read or there is no memory. Each page read marks for entry, if
// given, the chunks that read it (data_pages_arrived).
source_region_read :: proc(s:^Source,low,high:[3]int,entry:^Data_Source=nil) -> bool {
    if !source_paged(s) {return true}
    read :: proc(g:^Grid($T),low,high:[3]int,file:string,valid:proc "contextless" (value:T) -> bool,allocator:runtime.Allocator,entry:^Data_Source,limit:f32=0) -> bool {
        if !g.paged {return true}
        from,to:=grid_pages(g,low,high)
        for pz in from.z..=to.z {for py in from.y..=to.y {for px:=from.x;px<=to.x; {
            slot,_:=grid_find(g,{px,py,pz})
            if slot<0 {
                span,_:=grid_uniform_span(g,{px,py,pz})
                px+=max(span,1)
                continue
            }
            px+=1
            id:=grid_page_id(g,{px-1,py,pz})
            if !grid_absent(g,id) {continue}
            if !grid_page_read(g,id,file,valid,allocator) {return false}
            when T==f32 {
                if limit>0 && !values_within(g.pages[slot].values,limit) {
                    shared_free(g.pages[slot].values)
                    g.pages[slot].values=nil
                    return false
                }
            }
            if entry!=nil {
                first,last:=grid_page_region(g,id)
                data_pages_arrived(entry,first,last)
            }
        }}}
        return true
    }
    return read(&s.field,low,high,s.file,value_finite,s.allocator,entry,field_limit(s.info)) && read(&s.weights,low,high,s.file,weights_full,s.allocator,entry) && read(&s.holes,low,high,s.file,hole_valid,s.allocator,entry) && read(&s.paint,low,high,s.file,paint_valid,s.allocator,entry)
}

// What chunks read of the samples low..high came into memory: the chunks
// whose build reads them take the next change of the source, so that who
// reads the source (a bridge) reads them again. A chunk that shows something
// read them before: none of those is marked.
@(private)
data_pages_arrived :: proc(entry:^Data_Source,low,high:[3]int) {
    s:=&entry.source
    halo:=chunk_halo(s)
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

// A page of a grid read by pages, rewritten without coming into memory: a
// block of its own, or none when it turned uniform, and its fill.
@(private)
Away_Page :: struct($T:typeid) {slot:int,block:Page_Block,fill:T}

// Rewrites by change the values of every page of g that is in its block, one
// page in memory at a time, into blocks of their own for grid_away_install:
// g does not change. False when a page cannot be read or without memory.
@(private)
grid_away_map :: proc(g:^Grid($T),file:string,valid:proc "contextless" (value:T) -> bool,user:rawptr,change:proc(user:rawptr,value:T) -> T,out:^[dynamic]Away_Page(T),allocator:runtime.Allocator) -> bool {
    if !g.paged {return true}
    read:Page_Reader
    if !page_reader_init(&read,context.temp_allocator) {return false}
    defer page_reader_destroy(&read,context.temp_allocator)
    writer:Page_Writer
    if !page_writer_init(&writer,context.temp_allocator) {return false}
    defer page_writer_destroy(&writer)
    scratch,error:=make([]T,PAGE_VALUES,context.temp_allocator)
    if error!=nil {return false}
    for slot in 0..<len(g.pages) {
        id:=grid_id(g,slot)
        if id<0 || !grid_absent(g,id) {continue}
        extent,count:=grid_page_extent(g,id)
        values:=scratch[:count]
        if !page_load(g.blocks[slot],file,&read,mem.slice_to_bytes(values)) || !page_valid(values,valid) {return false}
        for &value in values {value=change(user,value)}
        away:=Away_Page(T){slot=slot,fill=values[0]}
        if !page_uniform(values) {
            encoded,ok:=page_encode(&writer,values,extent.x,false)
            if !ok {return false}
            own,made:=shared_make(u8,len(encoded),allocator)
            if !made {return false}
            copy(own,encoded)
            away.block={size=u32(len(encoded)),hash=base.hash64(own),own=own}
        }
        if _,append_error:=append(out,away);append_error!=nil {shared_free(away.block.own);return false}
    }
    return true
}

// Puts in place what grid_away_map made.
@(private)
grid_away_install :: proc(g:^Grid($T),away:[]Away_Page(T)) {
    for page in away {
        shared_free(g.blocks[page.slot].own)
        g.blocks[page.slot]=page.block
        g.pages[page.slot].fill=page.fill
    }
}

@(private)
grid_away_free :: proc(away:[]Away_Page($T)) {for page in away {shared_free(page.block.own)}}

// Lets go of the values of the page a slot holds: with edits, they stay in a
// block of its own first. False without memory, with the page as it was.
@(private)
grid_page_leave :: proc(g:^Grid($T),slot:int,allocator:runtime.Allocator) -> bool {
    page,block:=&g.pages[slot],&g.blocks[slot]
    if page.values==nil {return true}
    if block.edited || block.size==0 {
        if page_uniform(page.values) {
            shared_free(block.own)
            page.fill,block^=page.values[0],{}
        } else {
            writer:Page_Writer
            if !page_writer_init(&writer,context.temp_allocator) {return false}
            defer page_writer_destroy(&writer)
            extent,_:=grid_page_extent(g,grid_id(g,slot))
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

// Lets go of the pages of the grids of a paged source that chunk_pages_mark
// did not mark since the last call, and forgets the marks; returns how many
// left.
@(private)
source_pages_leave :: proc(s:^Source) -> (left:int) {
    if !source_paged(s) {return}
    leave :: proc(g:^Grid($T),allocator:runtime.Allocator) -> (left:int) {
        if !g.paged {return}
        for &page,slot in g.pages {
            kept:=page.kept
            page.kept=false
            if kept || page.values==nil || grid_id(g,slot)<0 {continue}
            if grid_page_leave(g,slot,allocator) {left+=1}
        }
        return
    }
    return leave(&s.field,s.allocator)+leave(&s.weights,s.allocator)+leave(&s.holes,s.allocator)+leave(&s.paint,s.allocator)
}

// Marks the pages of the grids of a source a build of chunk index reads, for
// source_pages_leave to keep.
@(private)
chunk_pages_mark :: proc(s:^Source,index:int) {
    low,high,ok:=chunk_pages_region(s,index)
    if ok {region_pages_mark(s,low,high)}
}

// Marks the pages of the grids of a source over an inclusive region of
// samples, for source_pages_leave to keep.
@(private)
region_pages_mark :: proc(s:^Source,low,high:[3]int) {
    mark :: proc(g:^Grid($T),low,high:[3]int) {
        if !g.paged {return}
        from,to:=grid_pages(g,low,high)
        for pz in from.z..=to.z {for py in from.y..=to.y {for px in from.x..=to.x {
            if px>=g.counts.x || py>=g.counts.y || pz>=g.counts.z {continue}
            if slot,_:=grid_find(g,{px,py,pz});slot>=0 {g.pages[slot].kept=true}
        }}}
    }
    mark(&s.field,low,high);mark(&s.weights,low,high);mark(&s.holes,low,high);mark(&s.paint,low,high)
}

// What differs between next, read again, and g of the same size: next takes
// the values g holds in memory of each page whose block in next holds the
// same, and g holds them no more. Nothing else of g changes. writer codes
// the pages of g as the file does, quantize as grid_put_document.
@(private)
grid_take :: proc(next,g:^Grid($T),writer:^Page_Writer,quantize:bool) -> (low,high:[3]int,changed:bool) {
    whole :: proc(next,g:^Grid($T)) -> (low,high:[3]int,changed:bool) {
        for axis in 0..<3 {high[axis]=max(next.size[axis],g.size[axis])-1}
        return {},high,true
    }
    if next.size!=g.size {return whole(next,g)}
    if grid_none(next) {return}
    // Parts neither holds that read another value: all of it may differ.
    if !grid_parts_same(next,g) {return whole(next,g)}
    low,high=next.size,{-1,-1,-1}
    uniform :: proc(values:[]$T,fill:T) -> bool {
        for value in values {if value!=fill {return false}}
        return true
    }
    for cursor:=0;true; {
        id,following,found:=grid_held_next(next,g,cursor)
        if !found {break}
        cursor=following
        page,old:=grid_page(next,id),grid_page(g,id)
        block,old_block:=grid_block(next,id),grid_block(g,id)
        old_absent:=grid_absent(g,id)
        same:bool
        switch {
        case page.values!=nil:
            if old.values!=nil {same=mem.compare(mem.slice_to_bytes(page.values),mem.slice_to_bytes(old.values))==0} else if !old_absent {same=uniform(page.values,old.fill)}
        case grid_absent(next,id):
            if old.values!=nil {
                if g.paged && !old_block.edited {
                    same=old_block.size>0 && old_block.hash==block.hash
                } else {
                    extent,_:=grid_page_extent(g,id)
                    encoded,ok:=page_encode(writer,old.values,extent.x,quantize)
                    same=ok && base.hash64(encoded)==block.hash
                }
                if same {
                    next.pages[grid_slot(next,id)].values=old.values
                    g.pages[grid_slot(g,id)].values=nil
                }
            } else if old_absent {
                same=old_block.hash==block.hash
            }
        case:
            if old.values!=nil {same=uniform(old.values,page.fill)} else {same=!old_absent && old.fill==page.fill}
        }
        if same {continue}
        first,last:=grid_page_region(next,id)
        for axis in 0..<3 {low[axis]=min(low[axis],first[axis]);high[axis]=max(high[axis],last[axis])}
        changed=true
    }
    return
}

// After a change of every weight in memory, as changing the layers makes,
// the pages keep it when they leave.
@(private)
source_pages_edited :: proc(s:^Source) {
    if !s.weights.paged {return}
    for &block,slot in s.weights.blocks {if s.weights.pages[slot].values!=nil {block.edited=true}}
}
