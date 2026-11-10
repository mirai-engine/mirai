package terrain

import "base:intrinsics"
import "base:runtime"
import "core:mem"
import "mirai:asset"
import "mirai:std/base"
import "mirai:std/serial"

// Samples per side of a page of an X/Z grid.
PAGE :: 64
// Samples per side of a block of a Volume: its page of BLOCK³ samples.
BLOCK :: 16
PAGE_VALUES :: PAGE*PAGE
#assert(BLOCK*BLOCK*BLOCK==PAGE_VALUES)
// A grid in blocks holds its pages in slabs of SLAB pages a side, and names
// its slabs in tables of TABLE slabs a side: a slab or a table is there only
// where the grid is not one value (Tile).
SLAB :: 4
SLAB_PAGES :: SLAB*SLAB*SLAB
TABLE :: 16
TABLE_SLABS :: TABLE*TABLE*TABLE

// A page holds its samples, X contiguous, then Y and Z, or none: every value
// is fill, or, in a grid read by pages, the values are in its block. A page
// at a far edge holds only the samples of the grid there (grid_page_extent).
// Its values are shared (shared_make): the copies of a grid hold the same
// ones, and a writer takes values of its own first (grid_prepare).
Page :: struct($T:typeid) {
    fill:T,
    values:[]T,
    altered:bool, // written since its source was read from its file or saved to it (Source.origin)
    kept:bool,    // scratch of source_pages_leave: a resident chunk reads it
}

// Precedes the values of a page or an own block in their allocation: how
// many grids hold them, atomic because a copy in another World can let go of
// them in another thread, and the allocator that made them, which has to
// outlive every holder (that of the application or the heap).
@(private)
Shared :: struct #align(16) {
    allocator:runtime.Allocator,
    bytes:int,   // of the values after it
    holders:i32,
}

@(private)
shared_of :: #force_inline proc "contextless" (values:[]$T) -> ^Shared {
    return (^Shared)(uintptr(raw_data(values))-size_of(Shared))
}

// count values held by one, not zeroed.
shared_make :: proc($T:typeid,count:int,allocator:runtime.Allocator) -> (values:[]T,ok:bool) {
    if count<=0 {return nil,count==0}
    bytes:=count*size_of(T)
    data,error:=mem.alloc_bytes_non_zeroed(size_of(Shared)+bytes,align_of(Shared),allocator)
    if error!=nil {return}
    shared:=(^Shared)(raw_data(data))
    shared^={allocator=allocator,bytes=bytes,holders=1}
    return ([^]T)(uintptr(raw_data(data))+size_of(Shared))[:count],true
}

// One more holder of values made by shared_make, or nil.
shared_hold :: proc "contextless" (values:[]$T) -> []T {
    if values!=nil {intrinsics.atomic_add(&shared_of(values).holders,1)}
    return values
}

// A holder lets go of values made by shared_make, or nil: the last frees them.
shared_free :: proc(values:[]$T) {
    if values==nil {return}
    shared:=shared_of(values)
    if intrinsics.atomic_sub(&shared.holders,1)!=1 {return}
    _=mem.free_with_size(shared,size_of(Shared)+shared.bytes,shared.allocator)
}

// Whether only one holds values made by shared_make: it can write them.
shared_alone :: #force_inline proc "contextless" (values:[]$T) -> bool {
    return intrinsics.atomic_load(&shared_of(values).holders)==1
}

// Lets go of the values of a page, as a grid that held it.
page_free :: proc(page:Page($T)) {shared_free(page.values)}

// Where the values of a page are while they are not in memory: an LZ block
// of the file of its source, or one of its own with what the page held when
// it left with edits that file does not have.
Page_Block :: struct {
    offset:u64,  // of the block in the file
    size:u32,    // bytes of the block; 0: none, the page is uniform
    hash:u64,    // XXH3 of the block
    own:[]u8,    // the block in memory, in place of the one in the file; shared as the values of a page, and never written
    edited:bool, // its values in memory were written since they came from the block
}

// A part of a grid in blocks in its directory: every sample under it holds
// fill (the bits of a value), or child names what holds them: a table of the
// slabs of that part, or the slab of its pages.
@(private)
Tile :: struct {fill:u32,child:i32}

// Values over a grid in pages: one sample along Y is an X/Z grid in pages of
// PAGE by PAGE, which holds every page in the order of its coordinates; more
// is a Volume in blocks of BLOCK³, which holds a page only where its values
// are not those of the part of the grid around it, whatever its size: pages
// are held in slabs, in the order they were first written. A page is named
// by its id, its place among every page of the grid (x, then y, then z),
// whether it is held or not. Without a size every value is the zero of T.
Grid :: struct($T:typeid) {
    size:[3]int,
    counts:[3]int, // pages along each axis
    side:[3]int,   // samples of a page along each axis
    pages:[dynamic]Page(T),        // those it holds, by slot
    blocks:[dynamic]Page_Block,    // of a grid read by pages (paged), one per page held
    encoded:[dynamic]Page_Encoded, // the blocks grid_put_document made, kept by a writer that asks for them
    paged:bool,
    filled:bool,                   // a part of the directory took another value since the grid was read or saved (Page.altered for what holds no page)
    sparse:bool,                   // in blocks: the directory below names the slabs
    top_counts:[3]int,             // tables along each axis
    top:[]Tile,
    tables:[dynamic]^[TABLE_SLABS]Tile,
    slabs:[dynamic][3]i32,         // the place of each slab, in slabs
}

// The LZ block of a page as it was last written, and the hash of the values
// it holds: a page that still holds them is not compressed again.
Page_Encoded :: struct {raw:u64,block:[]u8}

// A run of pages in the order of their ids, as a .terrain stores them: count
// pages that hold fill alone, or one page with its LZ block.
@(private)
Page_Run :: struct {count:u32,fill:u32,offset:u64,size:u64,hash:u64}

grid_side :: proc "contextless" (size:[3]int) -> [3]int {return size.y==1?{PAGE,1,PAGE}:{BLOCK,BLOCK,BLOCK}}

grid_page_counts :: proc "contextless" (size:[3]int) -> [3]int {
    side:=grid_side(size)
    return (size+side-1)/side
}

@(private)
fill_bits :: #force_inline proc "contextless" (fill:$T) -> (bits:u32) where size_of(T)<=4 {
    fill:=fill
    intrinsics.mem_copy_non_overlapping(&bits,&fill,size_of(T))
    return
}
@(private)
fill_of :: #force_inline proc "contextless" ($T:typeid,bits:u32) -> (fill:T) where size_of(T)<=4 {
    bits:=bits
    intrinsics.mem_copy_non_overlapping(&fill,&bits,size_of(T))
    return
}

grid_init :: proc(g:^Grid($T),size:[3]int,fill:T,allocator:runtime.Allocator) -> bool {
    size:=size // it may be g.size, which grid_destroy clears
    if size.x<1 || size.y<1 || size.z<1 {return false}
    counts:=grid_page_counts(size)
    next:Grid(T)
    next.size,next.counts,next.side=size,counts,grid_side(size)
    next.pages=make([dynamic]Page(T),allocator)
    next.blocks=make([dynamic]Page_Block,allocator)
    next.encoded=make([dynamic]Page_Encoded,allocator)
    next.tables=make([dynamic]^[TABLE_SLABS]Tile,allocator)
    next.slabs=make([dynamic][3]i32,allocator)
    if size.y==1 {
        if resize(&next.pages,counts.x*counts.z)!=nil {grid_destroy(&next,allocator);return false}
        for &page in next.pages {page.fill=fill}
    } else {
        next.sparse=true
        next.top_counts=(counts+SLAB*TABLE-1)/(SLAB*TABLE)
        error:runtime.Allocator_Error
        if next.top,error=make([]Tile,next.top_counts.x*next.top_counts.y*next.top_counts.z,allocator);error!=nil {grid_destroy(&next,allocator);return false}
        for &tile in next.top {tile={fill_bits(fill),-1}}
    }
    grid_destroy(g,allocator)
    g^=next
    return true
}

grid_destroy :: proc(g:^Grid($T),allocator:runtime.Allocator) {
    for page in g.pages {shared_free(page.values)}
    for block in g.blocks {shared_free(block.own)}
    for encoded in g.encoded {delete(encoded.block,allocator)}
    for table in g.tables {free(table,allocator)}
    delete(g.pages);delete(g.blocks);delete(g.encoded);delete(g.tables);delete(g.slabs)
    delete(g.top,allocator)
    g^={}
}

// Whether a grid has no size: it holds nothing, and every value is zero.
grid_none :: #force_inline proc "contextless" (g:^Grid($T)) -> bool {return g.size.x==0}

// The id of the page at page coordinates q.
grid_page_id :: #force_inline proc "contextless" (g:^Grid($T),q:[3]int) -> int {return q.x+g.counts.x*(q.y+g.counts.y*q.z)}

// The page coordinates of a page.
grid_page_coord :: #force_inline proc "contextless" (g:^Grid($T),id:int) -> [3]int {
    return {id%g.counts.x,id/g.counts.x%g.counts.y,id/(g.counts.x*g.counts.y)}
}

// The slot of the page at page coordinates q, or -1 and the one value a
// page that is not held reads.
@(private)
grid_find :: #force_inline proc "contextless" (g:^Grid($T),q:[3]int) -> (slot:int,fill:T) #no_bounds_check {
    if !g.sparse {return q.x+g.counts.x*q.z,{}}
    r:=q/SLAB
    s:=r/TABLE
    tile:=g.top[s.x+g.top_counts.x*(s.y+g.top_counts.y*s.z)]
    if tile.child<0 {return -1,fill_of(T,tile.fill)}
    m:=r-s*TABLE
    tile=g.tables[tile.child][m.x+TABLE*(m.y+TABLE*m.z)]
    if tile.child<0 {return -1,fill_of(T,tile.fill)}
    l:=q-r*SLAB
    return int(tile.child)*SLAB_PAGES+l.x+SLAB*(l.y+SLAB*l.z),{}
}

// The slot of a page by its id; -1 for one the grid does not hold.
grid_slot :: #force_inline proc "contextless" (g:^Grid($T),id:int) -> int {
    if !g.sparse {return id>=0 && id<len(g.pages)?id:-1}
    if id<0 || id>=g.counts.x*g.counts.y*g.counts.z {return -1}
    slot,_:=grid_find(g,grid_page_coord(g,id))
    return slot
}

// The id of the page a slot holds; -1 for a slot of a slab past the far edge of the grid.
grid_id :: proc "contextless" (g:^Grid($T),slot:int) -> int #no_bounds_check {
    if !g.sparse {return slot}
    r:=g.slabs[slot/SLAB_PAGES]
    l:=slot%SLAB_PAGES
    q:=[3]int{int(r.x),int(r.y),int(r.z)}*SLAB+[3]int{l%SLAB,l/SLAB%SLAB,l/(SLAB*SLAB)}
    if q.x>=g.counts.x || q.y>=g.counts.y || q.z>=g.counts.z {return -1}
    return grid_page_id(g,q)
}

// What a page holds, by its id, as a page that is held holds it: one the
// grid does not hold reads the value of the part around it.
grid_page :: proc "contextless" (g:^Grid($T),id:int) -> Page(T) {
    if grid_none(g) {return {}}
    slot,fill:=grid_find(g,grid_page_coord(g,id))
    if slot<0 {return {fill=fill}}
    return g.pages[slot]
}

// The block of a page of a grid read by pages, by its id; none for a page it does not hold.
grid_block :: proc "contextless" (g:^Grid($T),id:int) -> Page_Block {
    if !g.paged {return {}}
    slot:=grid_slot(g,id)
    return slot<0?{}:g.blocks[slot]
}

// How many pages from page coordinates q along x read one value without
// being held, to the end of the part of the directory that says so; 0 when
// the page at q is held.
@(private)
grid_uniform_span :: proc "contextless" (g:^Grid($T),q:[3]int) -> (span:int,fill:T) #no_bounds_check {
    if !g.sparse {return}
    r:=q/SLAB
    s:=r/TABLE
    tile:=g.top[s.x+g.top_counts.x*(s.y+g.top_counts.y*s.z)]
    if tile.child<0 {return min((s.x+1)*TABLE*SLAB,g.counts.x)-q.x,fill_of(T,tile.fill)}
    m:=r-s*TABLE
    tile=g.tables[tile.child][m.x+TABLE*(m.y+TABLE*m.z)]
    if tile.child<0 {return min((r.x+1)*SLAB,g.counts.x)-q.x,fill_of(T,tile.fill)}
    return
}

// The table of the slabs of a part of the directory that held one value:
// every slab of it holds that value. False without memory.
@(private)
grid_table_make :: proc(g:^Grid($T),s:int,allocator:runtime.Allocator) -> bool {
    table,error:=new([TABLE_SLABS]Tile,allocator)
    if error!=nil {return false}
    if _,appended:=append(&g.tables,table);appended!=nil {free(table,allocator);return false}
    for &tile in table {tile={g.top[s].fill,-1}}
    g.top[s].child=i32(len(g.tables)-1)
    return true
}

// The slab of the pages of a tile that held one value, at r in slabs: every
// page of it holds that value. False without memory.
@(private)
grid_slab_make :: proc(g:^Grid($T),tile:^Tile,r:[3]int) -> bool {
    first:=len(g.pages)
    if reserve(&g.pages,first+SLAB_PAGES)!=nil || reserve(&g.slabs,len(g.slabs)+1)!=nil || g.paged && reserve(&g.blocks,first+SLAB_PAGES)!=nil || len(g.encoded)>0 && reserve(&g.encoded,first+SLAB_PAGES)!=nil {return false}
    if resize(&g.pages,first+SLAB_PAGES)!=nil {return false}
    for &page in g.pages[first:] {page={fill=fill_of(T,tile.fill)}}
    if g.paged && resize(&g.blocks,first+SLAB_PAGES)!=nil {return false}
    if len(g.encoded)>0 && resize(&g.encoded,first+SLAB_PAGES)!=nil {return false}
    if _,error:=append(&g.slabs,[3]i32{i32(r.x),i32(r.y),i32(r.z)});error!=nil {return false}
    tile.child=i32(first/SLAB_PAGES)
    return true
}

// The slot of the page at q, held from now on: with the value it read. Its
// slab, and the table that names it, are made when they are not there. -1
// without memory, the grid reading as it did.
@(private)
grid_hold :: proc(g:^Grid($T),q:[3]int,allocator:runtime.Allocator) -> int {
    if slot,_:=grid_find(g,q);slot>=0 {return slot}
    r:=q/SLAB
    s:=r/TABLE
    at:=s.x+g.top_counts.x*(s.y+g.top_counts.y*s.z)
    if g.top[at].child<0 && !grid_table_make(g,at,allocator) {return -1}
    m:=r-s*TABLE
    tile:=&g.tables[g.top[at].child][m.x+TABLE*(m.y+TABLE*m.z)]
    if !grid_slab_make(g,tile,r) {return -1}
    l:=q-r*SLAB
    return int(tile.child)*SLAB_PAGES+l.x+SLAB*(l.y+SLAB*l.z)
}

// A page of a grid by its id, to write it: held from now on. nil without memory.
grid_page_ref :: proc(g:^Grid($T),id:int,allocator:runtime.Allocator) -> ^Page(T) {
    if grid_none(g) || id<0 || id>=g.counts.x*g.counts.y*g.counts.z {return nil}
    slot:=grid_hold(g,grid_page_coord(g,id),allocator)
    return slot<0?nil:&g.pages[slot]
}

// Whether page id of two grids of one size reads the same values.
grid_page_same :: proc(a,b:^Grid($T),id:int) -> bool {
    pa,pb:=grid_page(a,id),grid_page(b,id)
    if pa.values==nil && pb.values==nil {return pa.fill==pb.fill}
    if raw_data(pa.values)==raw_data(pb.values) {return true}
    if pa.values!=nil && pb.values!=nil {return mem.compare(mem.slice_to_bytes(pa.values),mem.slice_to_bytes(pb.values))==0}
    held,fill:=pa.values,pb.fill
    if held==nil {held,fill=pb.values,pa.fill}
    for value in held {if value!=fill {return false}}
    return true
}

// Whether two grids of one size read the same value wherever neither holds
// a page: the parts of their directories without pages hold the same.
grid_parts_same :: proc "contextless" (a,b:^Grid($T)) -> bool {
    if a.size!=b.size {return false}
    for tile,s in a.top {
        other:=b.top[s]
        if tile.child<0 && other.child<0 {
            if tile.fill!=other.fill {return false}
            continue
        }
        table_low:=[3]int{s%a.top_counts.x,s/a.top_counts.x%a.top_counts.y,s/(a.top_counts.x*a.top_counts.y)}*(TABLE*SLAB)
        for m in 0..<TABLE_SLABS {
            ta:=tile.child<0?tile:a.tables[tile.child][m]
            tb:=other.child<0?other:b.tables[other.child][m]
            if ta.child>=0 || tb.child>=0 || ta.fill==tb.fill {continue}
            // A slab past the far edge of the grid names no page: what it holds is read nowhere.
            if grid_box_pages(a,table_low+[3]int{m%TABLE,m/TABLE%TABLE,m/(TABLE*TABLE)}*SLAB,SLAB)!=0 {return false}
        }
    }
    return true
}

// The id of the next page either of two grids of one size holds, each once,
// from cursor on (0 to begin): those of a by slot, then those of b that a
// does not hold. next: the cursor to go on from.
grid_held_next :: proc "contextless" (a,b:^Grid($T),cursor:int) -> (id,next:int,found:bool) {
    for at:=cursor;at<len(a.pages)+len(b.pages);at+=1 {
        if at<len(a.pages) {
            if id=grid_id(a,at);id>=0 {return id,at+1,true}
            continue
        }
        if id=grid_id(b,at-len(a.pages));id>=0 && grid_slot(a,id)<0 {return id,at+1,true}
    }
    return
}

// The page for one more grid: the same values, held once more (page_free).
page_share :: proc "contextless" (page:Page($T)) -> Page(T) {return {fill=page.fill,values=shared_hold(page.values),altered=page.altered}}

// The pages of a grid of the size of g that an inclusive region of values
// touches, as coordinates of its pages: from the lowest page to the highest
// along each axis.
grid_page_range :: proc "contextless" (g:^Grid($T),low,high:[3]int) -> (from,to:[3]int,ok:bool) {
    if grid_none(g) {return}
    for axis in 0..<3 {
        lo,hi:=max(low[axis],0),min(high[axis],g.size[axis]-1)
        if lo>hi {return}
        from[axis],to[axis]=lo/g.side[axis],hi/g.side[axis]
    }
    return from,to,true
}

// A value of an X/Z grid.
grid_get :: #force_inline proc "contextless" (g:^Grid($T),x,z:int) -> T #no_bounds_check {
    if grid_none(g) {return {}}
    px,pz:=x/PAGE,z/PAGE
    page:=&g.pages[px+g.counts.x*pz]
    if page.values==nil {return page.fill}
    return page.values[x-px*PAGE+min(PAGE,g.size.x-px*PAGE)*(z-pz*PAGE)]
}

// Writes into a page of an X/Z grid that already holds its values (grid_prepare).
grid_set :: #force_inline proc "contextless" (g:^Grid($T),x,z:int,value:T) #no_bounds_check {
    px,pz:=x/PAGE,z/PAGE
    page:=&g.pages[px+g.counts.x*pz]
    page.values[x-px*PAGE+min(PAGE,g.size.x-px*PAGE)*(z-pz*PAGE)]=value
}

// A value of a grid in blocks.
block_get :: #force_inline proc "contextless" (g:^Grid($T),p:[3]int) -> T #no_bounds_check {
    if grid_none(g) {return {}}
    q:=p/BLOCK
    slot,fill:=grid_find(g,q)
    if slot<0 {return fill}
    page:=&g.pages[slot]
    if page.values==nil {return page.fill}
    q*=BLOCK
    return page.values[p.x-q.x+min(BLOCK,g.size.x-q.x)*(p.y-q.y+min(BLOCK,g.size.y-q.y)*(p.z-q.z))]
}

// Writes into a block that already holds its values (grid_prepare).
block_set :: #force_inline proc "contextless" (g:^Grid($T),p:[3]int,value:T) #no_bounds_check {
    q:=p/BLOCK
    slot,_:=grid_find(g,q)
    page:=&g.pages[slot]
    q*=BLOCK
    page.values[p.x-q.x+min(BLOCK,g.size.x-q.x)*(p.y-q.y+min(BLOCK,g.size.y-q.y)*(p.z-q.z))]=value
}

// Writes into a page of a grid of either shape that already holds its values (grid_prepare).
grid_write :: #force_inline proc "contextless" (g:^Grid($T),p:[3]int,value:T) #no_bounds_check {
    _,at:=grid_page_at(g,p)
    slot,_:=grid_find(g,p/g.side)
    g.pages[slot].values[at]=value
}

// The id of the page that holds sample p, and where p is among its values.
grid_page_at :: #force_inline proc "contextless" (g:^Grid($T),p:[3]int) -> (id,at:int) {
    q:=p/g.side
    low:=q*g.side
    r:=p-low
    extent:=linalg_min(g.side,g.size-low)
    return q.x+g.counts.x*(q.y+g.counts.y*q.z),r.x+extent.x*(r.y+extent.y*r.z)
}

@(private="file")
linalg_min :: #force_inline proc "contextless" (a,b:[3]int) -> [3]int {return {min(a.x,b.x),min(a.y,b.y),min(a.z,b.z)}}

// The samples of page id along each axis, and how many it holds: those of a
// whole page, or at a far edge those of the grid there.
grid_page_extent :: #force_inline proc "contextless" (g:^Grid($T),id:int) -> (extent:[3]int,count:int) {
    low,high:=grid_page_region(g,id)
    extent=high-low+1
    return extent,extent.x*extent.y*extent.z
}

// A value of a grid of either shape.
grid_value :: proc "contextless" (g:^Grid($T),p:[3]int) -> T #no_bounds_check {
    if grid_none(g) {return {}}
    _,at:=grid_page_at(g,p)
    slot,fill:=grid_find(g,p/g.side)
    if slot<0 {return fill}
    page:=&g.pages[slot]
    if page.values==nil {return page.fill}
    return page.values[at]
}

// The first sample of page id, and its last within the grid.
grid_page_region :: proc "contextless" (g:^Grid($T),id:int) -> (low,high:[3]int) {
    low=grid_page_coord(g,id)*g.side
    for axis in 0..<3 {high[axis]=min(low[axis]+g.side[axis],g.size[axis])-1}
    return
}

// The pages of g over the inclusive region of samples, as page coordinates;
// an X/Z grid takes its row whatever the region is along Y.
grid_pages :: proc "contextless" (g:^Grid($T),low,high:[3]int) -> (from,to:[3]int) {
    for axis in 0..<3 {
        if g.size[axis]==1 {continue}
        from[axis],to[axis]=max(low[axis],0)/g.side[axis],min(high[axis],g.size[axis]-1)/g.side[axis]
    }
    return
}

// Whether page id of a grid read by pages has its values in its block, not in memory.
grid_absent :: #force_inline proc "contextless" (g:^Grid($T),id:int) -> bool {
    if !g.paged {return false}
    slot:=grid_slot(g,id)
    return slot>=0 && g.pages[slot].values==nil && g.blocks[slot].size>0
}

// Whether a page of the inclusive region of samples of a grid read by pages
// has its values in its block.
grid_region_absent :: proc "contextless" (g:^Grid($T),low,high:[3]int) -> bool {
    if !g.paged {return false}
    from,to:=grid_pages(g,low,high)
    for pz in from.z..=to.z {for py in from.y..=to.y {for px:=from.x;px<=to.x; {
        slot,_:=grid_find(g,{px,py,pz})
        if slot<0 {
            span,_:=grid_uniform_span(g,{px,py,pz})
            px+=max(span,1)
            continue
        }
        if g.pages[slot].values==nil && g.blocks[slot].size>0 {return true}
        px+=1
    }}}
    return false
}

// Gives each page of the inclusive region values of its own that no other
// grid holds, so grid_set and block_set can write there: those it has when
// it holds them alone, otherwise a copy, which a job of another World that
// reads the shared ones goes on reading. What fails leaves pages that read
// the same. A page whose values are in its block fails: it is read first.
grid_prepare :: proc(g:^Grid($T),low,high:[3]int,allocator:runtime.Allocator) -> bool {
    if grid_none(g) {return false}
    from,to:=grid_pages(g,low,high)
    for pz in from.z..=to.z {for py in from.y..=to.y {for px in from.x..=to.x {
        slot:=grid_hold(g,{px,py,pz},allocator)
        if slot<0 {return false}
        page:=&g.pages[slot]
        if g.paged {
            if page.values==nil && g.blocks[slot].size>0 {return false}
            g.blocks[slot].edited=true
        }
        page.altered=true
        if page.values!=nil {
            if shared_alone(page.values) {continue}
            values,ok:=shared_make(T,len(page.values),allocator)
            if !ok {return false}
            copy(values,page.values)
            shared_free(page.values)
            page.values=values
            continue
        }
        _,count:=grid_page_extent(g,grid_page_id(g,{px,py,pz}))
        values,ok:=shared_make(T,count,allocator)
        if !ok {return false}
        for &value in values {value=page.fill}
        page.values=values
    }}}
    return true
}

// Writes one value, giving its page its own values when needed.
grid_put :: proc(g:^Grid($T),p:[3]int,value:T,allocator:runtime.Allocator) -> bool {
    if grid_value(g,p)==value {return true}
    if !grid_prepare(g,p,p,allocator) {return false}
    grid_write(g,p,value)
    return true
}

// The values the pages hold in memory of their own, the memory the grid costs.
grid_dense :: proc "contextless" (g:^Grid($T)) -> (count:int) {
    for page in g.pages {count+=len(page.values)}
    return
}

// Whether the values of a page are all equal.
@(private)
page_uniform :: proc "contextless" (values:[]$T) -> bool {
    for value in values {if value!=values[0] {return false}}
    return true
}

// The pages of the inclusive region that hold values of their own, all
// equal, take them as their fill: a block all air or all solid stores none.
grid_settle :: proc(g:^Grid($T),low,high:[3]int,allocator:runtime.Allocator) {
    if grid_none(g) {return}
    from,to:=grid_pages(g,low,high)
    for pz in from.z..=to.z {for py in from.y..=to.y {for px in from.x..=to.x {
        slot,_:=grid_find(g,{px,py,pz})
        if slot<0 {continue}
        page:=&g.pages[slot]
        if page.values==nil || !page_uniform(page.values) {continue}
        if g.paged {shared_free(g.blocks[slot].own);g.blocks[slot]={}}
        page.fill=page.values[0]
        shared_free(page.values)
        page.values=nil
    }}}
}

// A copy of a grid holds the values of its pages and its own blocks with
// src: it allocates only its tables, and a page is copied when one of them
// writes it (grid_prepare).
grid_clone :: proc(dst,src:^Grid($T),allocator:runtime.Allocator) -> bool {
    if grid_none(src) {grid_destroy(dst,allocator);return true}
    next:Grid(T)
    if !grid_init(&next,src.size,T{},allocator) {return false}
    if resize(&next.pages,len(src.pages))!=nil || resize(&next.blocks,len(src.blocks))!=nil || resize(&next.slabs,len(src.slabs))!=nil || reserve(&next.tables,len(src.tables))!=nil {grid_destroy(&next,allocator);return false}
    for table in src.tables {
        copied,error:=new([TABLE_SLABS]Tile,allocator)
        if error!=nil {grid_destroy(&next,allocator);return false}
        copied^=table^
        append(&next.tables,copied)
    }
    copy(next.top,src.top)
    copy(next.slabs[:],src.slabs[:])
    next.paged,next.filled=src.paged,src.filled
    for block,i in src.blocks {next.blocks[i]=block;shared_hold(block.own)}
    for page,i in src.pages {next.pages[i]=page_share(page)}
    grid_destroy(dst,allocator)
    dst^=next
    return true
}

// Whether two grids hold the same pages in the same slots.
@(private)
grid_same_layout :: proc "contextless" (a,b:^Grid($T)) -> bool {
    if a.size!=b.size || len(a.pages)!=len(b.pages) || len(a.blocks)!=len(b.blocks) || len(a.tables)!=len(b.tables) || len(a.slabs)!=len(b.slabs) || a.paged!=b.paged {return false}
    for slab,i in a.slabs {if slab!=b.slabs[i] {return false}}
    return true
}

// Copies src over dst without allocating when dst holds the pages src holds,
// as a copy of it made before does while src took no new slab: dst lets go
// of the values it held that src does not, and holds those of src.
grid_copy :: proc(dst,src:^Grid($T),allocator:runtime.Allocator) -> bool {
    if grid_none(src) || !grid_same_layout(dst,src) {return grid_clone(dst,src,allocator)}
    for &page,i in src.pages {
        target:=&dst.pages[i]
        if raw_data(target.values)!=raw_data(page.values) {
            shared_free(target.values)
            target.values=shared_hold(page.values)
        }
        target.fill,target.altered=page.fill,page.altered
    }
    for &block,i in src.blocks {
        target:=&dst.blocks[i]
        if raw_data(target.own)!=raw_data(block.own) {
            shared_free(target.own)
            shared_hold(block.own)
        }
        target^=block
    }
    copy(dst.top,src.top)
    for table,i in src.tables {dst.tables[i]^=table^}
    dst.filled=src.filled
    return true
}

// The inclusive region whose values differ; changed false for none. Both
// grids hold every page in memory.
grid_diff :: proc(a,b:^Grid($T)) -> (low,high:[3]int,changed:bool) {
    if a.size!=b.size || !grid_parts_same(a,b) {
        for axis in 0..<3 {high[axis]=max(a.size[axis],b.size[axis])-1}
        return {},high,true
    }
    low,high=a.size,{-1,-1,-1}
    for cursor:=0;true; {
        id,next,found:=grid_held_next(a,b,cursor)
        if !found {break}
        cursor=next
        page,other:=grid_page(a,id),grid_page(b,id)
        if page.values==nil && other.values==nil && page.fill==other.fill || page.values!=nil && raw_data(page.values)==raw_data(other.values) {continue}
        first,last:=grid_page_region(a,id)
        for z in first.z..=last.z {for y in first.y..=last.y {for x in first.x..=last.x {
            p:=[3]int{x,y,z}
            if grid_value(a,p)==grid_value(b,p) {continue}
            for axis in 0..<3 {low[axis]=min(low[axis],p[axis]);high[axis]=max(high[axis],p[axis])}
            changed=true
        }}}
    }
    return
}

// Whether two grids of one size read the same value at every sample.
grid_equal :: proc(a,b:^Grid($T)) -> bool {
    if a.size!=b.size {return false}
    if grid_none(a) {return true}
    _,_,changed:=grid_diff(a,b)
    return !changed
}

// The block of a page: its own, or the one in file read into out.
@(private)
page_block_read :: proc(block:Page_Block,file:string,out:[]u8) -> (bytes:[]u8,ok:bool) {
    if block.own!=nil {return block.own,true}
    if file=="" || int(block.size)>len(out) {return}
    if serial.file_read_range(file,i64(block.offset),out[:block.size])!=.None {return}
    return out[:block.size],true
}

// How many pages of the grid a box of pages from low holds, size a side:
// those within the grid.
@(private)
grid_box_pages :: #force_inline proc "contextless" (g:^Grid($T),low:[3]int,size:int) -> int {
    extent:=[3]int{clamp(g.counts.x-low.x,0,size),clamp(g.counts.y-low.y,0,size),clamp(g.counts.z-low.z,0,size)}
    return extent.x*extent.y*extent.z
}

// A page or a part of a grid as a .terrain orders them: every page of an
// X/Z grid by its id; of a grid in blocks, the tables of its directory, in
// each its slabs and in each its pages, x first, then y and z. The pages of a
// part that holds one value without holding them come as one item.
@(private)
Grid_Item :: struct {slot:i32,count:u32,fill:u32} // slot -1: count pages that hold fill

@(private)
grid_items :: proc(g:^Grid($T),items:^[dynamic]Grid_Item) -> bool {
    if !g.sparse {
        if reserve(items,len(g.pages))!=nil {return false}
        for _,slot in g.pages {append(items,Grid_Item{slot=i32(slot),count=1})}
        return true
    }
    for tile,s in g.top {
        table_low:=[3]int{s%g.top_counts.x,s/g.top_counts.x%g.top_counts.y,s/(g.top_counts.x*g.top_counts.y)}*(TABLE*SLAB)
        if tile.child<0 {
            if _,error:=append(items,Grid_Item{slot=-1,count=u32(grid_box_pages(g,table_low,TABLE*SLAB)),fill=tile.fill});error!=nil {return false}
            continue
        }
        for slab,m in g.tables[tile.child] {
            slab_low:=table_low+[3]int{m%TABLE,m/TABLE%TABLE,m/(TABLE*TABLE)}*SLAB
            inside:=grid_box_pages(g,slab_low,SLAB)
            if inside==0 {continue}
            if slab.child<0 {
                if _,error:=append(items,Grid_Item{slot=-1,count=u32(inside),fill=slab.fill});error!=nil {return false}
                continue
            }
            for l in 0..<SLAB_PAGES {
                q:=slab_low+[3]int{l%SLAB,l/SLAB%SLAB,l/(SLAB*SLAB)}
                if q.x>=g.counts.x || q.y>=g.counts.y || q.z>=g.counts.z {continue}
                if _,error:=append(items,Grid_Item{slot=slab.child*SLAB_PAGES+i32(l),count=1});error!=nil {return false}
            }
        }
    }
    return true
}

// The pages of a grid as a table of runs in the order of grid_items and a
// column of the LZ blocks of the pages that are not uniform, stored as they
// are so that one page is read alone. A run is a page with its block, or the
// pages that follow one another with one value and none: what a grid holds
// of pages that read one value does not change its file. A page in its block
// in file is copied from there. valid checks each value. quantize stores f32
// values on the lattice of HEIGHT_STEP (page_code): a page in a block of its
// own, which keeps them as they were, is coded again.
// With keep, the grid keeps each block it makes (encoded), and a page that
// still holds the values of its kept block is not compressed again.
@(private)
grid_put_document :: proc(document:^asset.Document,types:^asset.Types,g:^Grid($T),pages_name,blocks_name:string,valid:proc "contextless" (value:T) -> bool,file:string,allocator:runtime.Allocator,keep:=false,quantize:=false) -> asset.Error where size_of(T)<=4 {
    if keep && len(g.encoded)!=len(g.pages) {
        if resize(&g.encoded,len(g.pages))!=nil {return .Out_Of_Memory}
    }
    items:=make([dynamic]Grid_Item,allocator)
    defer delete(items)
    if !grid_items(g,&items) {return .Out_Of_Memory}
    runs:=make([dynamic]Page_Run,allocator)
    defer delete(runs)
    blocks:=make([dynamic]u8,allocator)
    defer delete(blocks)
    reader:Page_Reader
    if !page_reader_init(&reader,allocator) {return .Out_Of_Memory}
    defer page_reader_destroy(&reader,allocator)
    writer:Page_Writer
    if !page_writer_init(&writer,allocator) {return .Out_Of_Memory}
    defer page_writer_destroy(&writer)
    decoded,decoded_error:=make([]T,PAGE_VALUES,allocator)
    if decoded_error!=nil {return .Out_Of_Memory}
    defer delete(decoded,allocator)
    // More pages that hold fill alone: they join the run before them.
    uniform :: proc(runs:^[dynamic]Page_Run,fill:u32,count:u32) -> bool {
        if n:=len(runs);n>0 && runs[n-1].size==0 && runs[n-1].fill==fill && u64(runs[n-1].count)+u64(count)<=u64(max(u32)) {
            runs[n-1].count+=count
            return true
        }
        _,error:=append(runs,Page_Run{count=count,fill=fill})
        return error==nil
    }
    for item in items {
        if item.slot<0 {
            value:=fill_of(T,item.fill)
            if !valid(value) {return .Invalid}
            if !uniform(&runs,item.fill,item.count) {return .Out_Of_Memory}
            continue
        }
        slot:=int(item.slot)
        id:=grid_id(g,slot)
        page:=g.pages[slot]
        if !valid(page.fill) {return .Invalid}
        values:=page.values
        block:[]u8
        extent,count:=grid_page_extent(g,id)
        if g.paged && values==nil && g.blocks[slot].size>0 {
            read,read_ok:=page_block_read(g.blocks[slot],file,reader.block)
            if !read_ok || !page_decode(read,g.blocks[slot].hash,mem.slice_to_bytes(decoded[:count]),&reader.decoder,reader.coded) {return .IO}
            values=decoded[:count]
            if !quantize || g.blocks[slot].own==nil {block=read}
        }
        fill:=page.fill
        when T==f32 {
            if quantize {
                fill=height_quantize(fill)
                if values!=nil {
                    for value,k in values {
                        if !valid(value) {return .Invalid}
                        decoded[k]=height_quantize(value)
                    }
                    values=decoded[:count]
                }
            }
        }
        if values!=nil {
            for value in values {if !valid(value) {return .Invalid}}
            fill=values[0]
            if page_uniform(values) {values=nil}
        }
        if values==nil {
            if !uniform(&runs,fill_bits(fill),1) {return .Out_Of_Memory}
            continue
        }
        if block==nil && keep {
            raw:=base.hash64(mem.slice_to_bytes(values))
            kept:=&g.encoded[slot]
            if kept.block==nil || kept.raw!=raw {
                encoded,ok:=page_encode(&writer,values,extent.x,quantize)
                if !ok {return .Out_Of_Memory}
                delete(kept.block,allocator)
                copied,error:=make([]u8,len(encoded),allocator)
                if error!=nil {kept^={};return .Out_Of_Memory}
                copy(copied,encoded)
                kept^={raw=raw,block=copied}
            }
            block=kept.block
        }
        if block==nil {
            ok:bool
            if block,ok=page_encode(&writer,values,extent.x,quantize);!ok {return .Out_Of_Memory}
        }
        if _,error:=append(&runs,Page_Run{count=1,fill=fill_bits(fill),size=u64(len(block)),offset=u64(len(blocks)),hash=base.hash64(block)});error!=nil {return .Out_Of_Memory}
        if append(&blocks,..block)!=len(block) {return .Out_Of_Memory}
    }
    asset.document_put(document,types,pages_name,runs[:]) or_return
    asset.document_put(document,types,blocks_name,blocks[:],{.Bulk},.None) or_return
    return .None
}

// Gives every page of a box of pages, from to to inclusive in page
// coordinates, one value and no values of their own. A part of the directory
// the box covers whole and that holds no pages takes the value itself; the
// pages of the others are held. False without memory.
grid_fill_box :: proc(g:^Grid($T),from,to:[3]int,fill:T,allocator:runtime.Allocator) -> bool {
    if grid_none(g) {return false}
    from,to:=from,to
    for axis in 0..<3 {
        from[axis],to[axis]=max(from[axis],0),min(to[axis],g.counts[axis]-1)
        if from[axis]>to[axis] {return true}
    }
    bits:=fill_bits(fill)
    set :: proc(g:^Grid($T),slot:int,fill:T) {
        page:=&g.pages[slot]
        shared_free(page.values)
        page.values,page.fill,page.altered=nil,fill,true
        if g.paged {shared_free(g.blocks[slot].own);g.blocks[slot]={}}
    }
    if !g.sparse {
        for pz in from.z..=to.z {for px in from.x..=to.x {set(g,px+g.counts.x*pz,fill)}}
        return true
    }
    // Whether the box holds every page of the grid in the part from low, size a side.
    covers :: proc "contextless" (g:^Grid($T),from,to,low:[3]int,size:int) -> bool {
        for axis in 0..<3 {if from[axis]>low[axis] || to[axis]<min(low[axis]+size,g.counts[axis])-1 {return false}}
        return true
    }
    span:=TABLE*SLAB
    for tz in from.z/span..=to.z/span {for ty in from.y/span..=to.y/span {for tx in from.x/span..=to.x/span {
        s:=tx+g.top_counts.x*(ty+g.top_counts.y*tz)
        table_low:=[3]int{tx,ty,tz}*span
        if g.top[s].child<0 {
            if g.top[s].fill==bits {continue}
            if covers(g,from,to,table_low,span) {g.top[s].fill,g.filled=bits,true;continue}
            if !grid_table_make(g,s,allocator) {return false}
        }
        table:=g.tables[g.top[s].child]
        for mz in max(from.z-table_low.z,0)/SLAB..=min(to.z-table_low.z,span-1)/SLAB {for my in max(from.y-table_low.y,0)/SLAB..=min(to.y-table_low.y,span-1)/SLAB {for mx in max(from.x-table_low.x,0)/SLAB..=min(to.x-table_low.x,span-1)/SLAB {
            m:=mx+TABLE*(my+TABLE*mz)
            slab_low:=table_low+[3]int{mx,my,mz}*SLAB
            if table[m].child<0 {
                if table[m].fill==bits {continue}
                if covers(g,from,to,slab_low,SLAB) {table[m].fill,g.filled=bits,true;continue}
                if !grid_slab_make(g,&table[m],slab_low/SLAB) {return false}
            }
            for l in 0..<SLAB_PAGES {
                q:=slab_low+[3]int{l%SLAB,l/SLAB%SLAB,l/(SLAB*SLAB)}
                if q.x<from.x || q.y<from.y || q.z<from.z || q.x>to.x || q.y>to.y || q.z>to.z {continue}
                set(g,int(table[m].child)*SLAB_PAGES+l,fill)
            }
        }}}
    }}}
    return true
}

// The runs of a .terrain as they are taken, one page or one part at a time.
@(private)
Run_Cursor :: struct {runs:[]Page_Run,at:int,left:u64}

// The value the next count pages hold alone, when the run they are in says so.
@(private)
runs_uniform :: proc "contextless" (c:^Run_Cursor,count:int) -> (fill:u32,ok:bool) {
    if c.at>=len(c.runs) || c.runs[c.at].size!=0 || c.left<u64(count) {return}
    return c.runs[c.at].fill,true
}

@(private)
runs_take :: proc "contextless" (c:^Run_Cursor,count:int) {
    c.left-=u64(count)
    for c.left==0 && c.at<len(c.runs) {
        c.at+=1
        if c.at<len(c.runs) {c.left=u64(c.runs[c.at].count)}
    }
}

// The pages a .terrain holds. paged leaves the values of the pages in their
// blocks in the file, read when they are needed (paging.odin); otherwise
// every page comes into memory now. A grid in blocks holds a page only where
// its runs give it a block or the part around it another value.
@(private)
grid_read_document :: proc(g:^Grid($T),file:^asset.Asset,types:^asset.Types,size:[3]int,pages_name,blocks_name:string,valid:proc "contextless" (value:T) -> bool,allocator:runtime.Allocator,paged:=false) -> bool where size_of(T)<=4 {
    runs,e0:=asset.asset_rows(file,types,pages_name,"",Page_Run)
    if e0!=.None || len(runs)==0 {return false}
    table,found:=asset.asset_table(file,blocks_name)
    if !found || len(table.columns)!=1 {return false}
    entry:=asset.blob_chunk(&file.blob,table.columns[0].chunk)
    if entry.compression!=.None {return false}
    stored:=u64(entry.uncompressed_size)
    counts:=grid_page_counts(size)
    total:=u64(0)
    for run in runs {
        if run.count==0 || !valid(fill_of(T,run.fill)) {return false}
        if run.size!=0 && (run.count!=1 || run.offset>stored || run.size>stored-run.offset || run.size>u64(asset.pack_bound(PAGE_BYTES_MAX))) {return false}
        total+=u64(run.count)
    }
    if total!=u64(counts.x)*u64(counts.y)*u64(counts.z) {return false}
    blocks:[]u8
    if !paged {
        e1:asset.Error
        if blocks,e1=asset.asset_rows(file,types,blocks_name,"",u8);e1!=.None || u64(len(blocks))!=stored {return false}
    }
    // What its directory holds where it names no page of the grid is a value of its own.
    next:Grid(T)
    if !grid_init(&next,size,fill_of(T,runs[0].fill),allocator) {return false}
    ok:=false
    defer if !ok {grid_destroy(&next,allocator)}
    next.paged=paged
    if paged && !next.sparse && resize(&next.blocks,len(next.pages))!=nil {return false}
    coded:[]u8
    error:runtime.Allocator_Error
    if !paged {
        if coded,error=make([]u8,PAGE_BYTES_MAX,allocator);error!=nil {return false}
    }
    defer delete(coded,allocator)
    Reading :: struct($T:typeid) {
        g:^Grid(T),
        file:^asset.Asset,
        cursor:Run_Cursor,
        blocks,coded:[]u8,
        offset:u64, // of the column of blocks in the file
        valid:proc "contextless" (value:T) -> bool,
        allocator:runtime.Allocator,
    }
    // The page a slot holds takes the next page of the runs.
    page_take :: proc(r:^Reading($T),slot,id:int) -> bool {
        g:=r.g
        run:=r.cursor.runs[r.cursor.at]
        runs_take(&r.cursor,1)
        g.pages[slot].fill=fill_of(T,run.fill)
        if run.size==0 {return true}
        if g.paged {
            g.blocks[slot]={offset=r.offset+run.offset,size=u32(run.size),hash=run.hash}
            return true
        }
        _,count:=grid_page_extent(g,id)
        page,made:=shared_make(T,count,r.allocator)
        if !made {return false}
        g.pages[slot].values=page
        decoder,decoder_error:=asset.asset_decoder(r.file)
        if decoder_error!=.None || !page_decode(r.blocks[run.offset:][:run.size],run.hash,mem.slice_to_bytes(page),&decoder.lz,r.coded) {return false}
        for value in page {if !r.valid(value) {return false}}
        return true
    }
    r:=Reading(T){g=&next,file=file,cursor={runs=runs,left=u64(runs[0].count)},blocks=blocks,coded=coded,offset=entry.offset,valid=valid,allocator=allocator}
    if !next.sparse {
        for slot in 0..<len(next.pages) {if !page_take(&r,slot,slot) {return false}}
    } else {
        span:=TABLE*SLAB
        for &tile,s in next.top {
            table_low:=[3]int{s%next.top_counts.x,s/next.top_counts.x%next.top_counts.y,s/(next.top_counts.x*next.top_counts.y)}*span
            inside:=grid_box_pages(&next,table_low,span)
            if fill,uniform:=runs_uniform(&r.cursor,inside);uniform {
                tile={fill,-1}
                runs_take(&r.cursor,inside)
                continue
            }
            if !grid_table_make(&next,s,allocator) {return false}
            slabs:=next.tables[next.top[s].child]
            for &slab,m in slabs {
                slab_low:=table_low+[3]int{m%TABLE,m/TABLE%TABLE,m/(TABLE*TABLE)}*SLAB
                held:=grid_box_pages(&next,slab_low,SLAB)
                if held==0 {continue}
                if fill,uniform:=runs_uniform(&r.cursor,held);uniform {
                    slab={fill,-1}
                    runs_take(&r.cursor,held)
                    continue
                }
                if !grid_slab_make(&next,&slab,slab_low/SLAB) {return false}
                for l in 0..<SLAB_PAGES {
                    q:=slab_low+[3]int{l%SLAB,l/SLAB%SLAB,l/(SLAB*SLAB)}
                    if q.x>=counts.x || q.y>=counts.y || q.z>=counts.z {continue}
                    if !page_take(&r,int(slab.child)*SLAB_PAGES+l,grid_page_id(&next,q)) {return false}
                }
            }
        }
    }
    if r.cursor.at!=len(runs) {return false}
    grid_destroy(g,allocator)
    g^=next
    ok=true
    return true
}

// Gives each value a grid holds for a part without pages, in its directory, what f makes of it.
@(private)
grid_tiles_map :: proc(g:^Grid($T),user:rawptr,f:proc(user:rawptr,fill:T) -> T) {
    for &tile in g.top {if tile.child<0 {tile.fill=fill_bits(f(user,fill_of(T,tile.fill)))}}
    for table in g.tables {for &tile in table {if tile.child<0 {tile.fill=fill_bits(f(user,fill_of(T,tile.fill)))}}}
}

// Whether every value a grid holds for a part without pages, in its directory, is one f takes.
@(private)
grid_tiles_all :: proc(g:^Grid($T),user:rawptr,f:proc(user:rawptr,fill:T) -> bool) -> bool {
    for tile in g.top {if tile.child<0 && !f(user,fill_of(T,tile.fill)) {return false}}
    for table in g.tables {for tile in table {if tile.child<0 && !f(user,fill_of(T,tile.fill)) {return false}}}
    return true
}

// A table of the directory whose slabs all hold one value and no pages goes:
// its part holds that value.
@(private)
grid_table_settle :: proc(g:^Grid($T),s:int,allocator:runtime.Allocator) {
    child:=g.top[s].child
    if child<0 {return}
    table:=g.tables[child]
    table_low:=[3]int{s%g.top_counts.x,s/g.top_counts.x%g.top_counts.y,s/(g.top_counts.x*g.top_counts.y)}*(TABLE*SLAB)
    fill,any:=u32(0),false
    for tile,m in table {
        if grid_box_pages(g,table_low+[3]int{m%TABLE,m/TABLE%TABLE,m/(TABLE*TABLE)}*SLAB,SLAB)==0 {continue}
        if tile.child>=0 || any && tile.fill!=fill {return}
        fill,any=tile.fill,true
    }
    last:=i32(len(g.tables)-1)
    if child!=last {
        g.tables[child]=g.tables[last]
        for &tile in g.top {if tile.child==last {tile.child=child;break}}
    }
    pop(&g.tables)
    free(table,allocator)
    g.top[s]={fill,-1}
}

// Gives every page of a grid in blocks what page computes for it: into
// values, the samples of the page from first, extent a side (x first, then y
// and z), or the one value they all hold, uniform, without writing them. A
// part whose pages all come out with one value holds no pages. False without
// memory, the grid then holding part of it.
grid_generate :: proc(g:^Grid($T),user:rawptr,page:proc(user:rawptr,first,extent:[3]int,values:[]T) -> (fill:T,uniform:bool),allocator:runtime.Allocator) -> bool {
    if !g.sparse {return false}
    // The pages of a slab at a time: more than a temporary allocator is asked for.
    scratch,error:=make([]T,SLAB_PAGES*PAGE_VALUES,allocator)
    if error!=nil {return false}
    defer delete(scratch,allocator)
    fills:[SLAB_PAGES]T
    flat:[SLAB_PAGES]bool
    for s in 0..<len(g.top) {
        table_low:=[3]int{s%g.top_counts.x,s/g.top_counts.x%g.top_counts.y,s/(g.top_counts.x*g.top_counts.y)}*(TABLE*SLAB)
        for m in 0..<TABLE_SLABS {
            slab_low:=table_low+[3]int{m%TABLE,m/TABLE%TABLE,m/(TABLE*TABLE)}*SLAB
            if grid_box_pages(g,slab_low,SLAB)==0 {continue}
            same,any:=true,false
            one:T
            for l in 0..<SLAB_PAGES {
                q:=slab_low+[3]int{l%SLAB,l/SLAB%SLAB,l/(SLAB*SLAB)}
                if q.x>=g.counts.x || q.y>=g.counts.y || q.z>=g.counts.z {continue}
                id:=grid_page_id(g,q)
                first,_:=grid_page_region(g,id)
                extent,count:=grid_page_extent(g,id)
                values:=scratch[l*PAGE_VALUES:][:count]
                fill,uniform:=page(user,first,extent,values)
                if !uniform && page_uniform(values) {fill,uniform=values[0],true}
                fills[l],flat[l]=fill,uniform
                switch {
                case !uniform: same=false
                case !any: one,any=fill,true
                case fill!=one: same=false
                }
            }
            if same {
                if !grid_fill_box(g,slab_low,slab_low+SLAB-1,one,allocator) {return false}
                continue
            }
            for l in 0..<SLAB_PAGES {
                q:=slab_low+[3]int{l%SLAB,l/SLAB%SLAB,l/(SLAB*SLAB)}
                if q.x>=g.counts.x || q.y>=g.counts.y || q.z>=g.counts.z {continue}
                if flat[l] {
                    if !grid_fill_box(g,q,q,fills[l],allocator) {return false}
                    continue
                }
                id:=grid_page_id(g,q)
                _,count:=grid_page_extent(g,id)
                held:=grid_page_ref(g,id,allocator)
                values,made:=shared_make(T,count,allocator)
                if held==nil || !made {shared_free(values);return false}
                copy(values,scratch[l*PAGE_VALUES:][:count])
                shared_free(held.values)
                held.values,held.fill=values,values[0]
                if g.paged {slot:=grid_slot(g,id);shared_free(g.blocks[slot].own);g.blocks[slot]={}}
            }
        }
        grid_table_settle(g,s,allocator)
    }
    return true
}

// Trades what page id of a grid holds with page: the grid holds that page
// from now on. False without memory, both as they were.
grid_page_trade :: proc(g:^Grid($T),id:int,page:^Page(T),allocator:runtime.Allocator) -> bool {
    held:=grid_page_ref(g,id,allocator)
    if held==nil {return false}
    held.fill,page.fill=page.fill,held.fill
    held.values,page.values=page.values,held.values
    held.altered,page.altered=page.altered,held.altered
    return true
}

// Gives page id of a grid what page holds, in place of what it held; the
// grid holds page from now on. False without memory: page is let go.
grid_page_give :: proc(g:^Grid($T),id:int,page:Page(T),allocator:runtime.Allocator) -> bool {
    held:=grid_page_ref(g,id,allocator)
    if held==nil {page_free(page);return false}
    shared_free(held.values)
    held.fill,held.values,held.altered=page.fill,page.values,page.altered
    return true
}
