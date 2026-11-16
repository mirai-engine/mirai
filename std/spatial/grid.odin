package spatial

import cmath "core:math"
import "core:mem"
import math "mirai:std/math"

// A grid of cubic cells that holds boxes. Each item is linked from every cell
// its box reaches, so an insertion or a move costs its cells and a query the
// cells of its volume: the structure for many things of about the size of a
// cell that move every tick. Two layouts share the code:
//
//   uniform grid   Grid_Desc.bounds: the cells cover that box, one list per
//                  cell. What leaves the box is taken at its border cells.
//   spatial hash   Grid_Desc.buckets > 0: space has no bounds and the cells
//                  share that many lists by a hash of their coordinates.
//
// Everything is allocated by grid_init. An insertion without an item slot or
// without links for its cells fails and counts in stats.insert_failures.

GRID_NULL :: i32(-1)

// Cells from the origin a coordinate may be at; farther ones are taken there.
@(private) GRID_CELL_LIMIT :: 1<<28
// A query or a segment over more cells than this many times the lists of a
// spatial hash reads the items instead of the cells.
@(private) GRID_SCAN_FACTOR :: 4
@(private) GRID_PAD :: 1.0/1024
@(private) GRID_NOISE :: 1.0/(1<<20)

Grid_Stats :: struct {insert_failures:u64}

Grid_Desc :: struct {
    cell_size:f32,     // side of a cell; > 0
    bounds:Aabb,       // uniform grid: the box the cells cover
    buckets:int,       // > 0: a spatial hash with this many lists, rounded up to a power of two
    item_capacity:int,
    link_capacity:int, // an item takes one per cell it reaches. 0: eight per item
    allocator:mem.Allocator,
}

// lo and hi are the first and the last cell the item is linked from. A free slot has lo.x above hi.x.
Grid_Item :: struct {aabb:Aabb, user:u64, lo,hi:[3]i32, next:i32}
Grid_Link :: struct {item,next:i32, cell:[3]i32}

// heads, items[:item_high] and links[:link_high] with the counters are the entire state.
Grid :: struct {
    heads:[]i32, items:[]Grid_Item, links:[]Grid_Link,
    origin:[3]f32, cell_size,inverse_cell:f32,
    dims:[3]i32, // zero in a spatial hash
    mask:u32,
    free_item,free_link,item_high,link_high,item_count,link_count:i32,
    allocator:mem.Allocator, stats:Grid_Stats,
}

grid_init :: proc(g:^Grid, desc:Grid_Desc) -> bool {
    g^={}
    if !(desc.cell_size>0)||desc.cell_size>max(f32)||desc.item_capacity<=0||desc.item_capacity>int(max(i32))/16 {return false}
    links:=desc.link_capacity>0?desc.link_capacity:desc.item_capacity*8
    if links>int(max(i32)) {return false}
    lists:int
    dims:[3]i32
    origin:[3]f32
    if desc.buckets>0 {
        if desc.buckets>1<<28 {return false}
        lists=1
        for lists<desc.buckets {lists<<=1}
    } else {
        if !aabb_valid(desc.bounds) {return false}
        origin=desc.bounds.min
        total:=1
        for i in 0..<3 {
            cells:=cmath.ceil((desc.bounds.max[i]-desc.bounds.min[i])/desc.cell_size)
            if !(cells<=1<<20) {return false}
            dims[i]=max(i32(cells),1)
            total*=int(dims[i])
            if total>1<<28 {return false}
        }
        lists=total
    }
    allocator:=desc.allocator.procedure!=nil?desc.allocator:context.allocator
    heads,heads_error:=make([]i32,lists,allocator)
    items,items_error:=make([]Grid_Item,desc.item_capacity,allocator)
    link_slots,links_error:=make([]Grid_Link,links,allocator)
    if heads_error!=nil||items_error!=nil||links_error!=nil {
        delete(heads,allocator);delete(items,allocator);delete(link_slots,allocator)
        return false
    }
    g^={heads=heads,items=items,links=link_slots,origin=origin,cell_size=desc.cell_size,inverse_cell=1/desc.cell_size,dims=dims,mask=desc.buckets>0?u32(lists-1):0,allocator=allocator}
    grid_clear(g)
    return true
}
grid_destroy :: proc(g:^Grid) {
    delete(g.heads,g.allocator);delete(g.items,g.allocator);delete(g.links,g.allocator)
    g^={}
}
// Drops every item; the capacities and the counters of stats stay.
grid_clear :: proc(g:^Grid) {
    for &head in g.heads {head=GRID_NULL}
    g.free_item,g.free_link=GRID_NULL,GRID_NULL
    g.item_high,g.link_high,g.item_count,g.link_count=0,0,0,0
}

@(private) grid_hashed :: #force_inline proc "contextless" (g:^Grid) -> bool {return g.dims.x==0}

// The cell of a point: inside the box of a uniform grid, within the limit of a spatial hash.
grid_cell :: proc "contextless" (g:^Grid, point:[3]f32) -> (cell:[3]i32) {
    for i in 0..<3 {
        v:=cmath.floor((point[i]-g.origin[i])*g.inverse_cell)
        if g.dims.x>0 {
            cell[i]=v>=f32(g.dims[i])?g.dims[i]-1:v>0?i32(v):0
        } else {
            cell[i]=v>=GRID_CELL_LIMIT?GRID_CELL_LIMIT:v>-GRID_CELL_LIMIT?i32(v):-GRID_CELL_LIMIT
        }
    }
    return
}
// The cells an item is linked from: those of its box grown by a sliver of a cell and by the
// rounding of its coordinates, so that a segment that clips a corner of the box is never in a
// cell the item is missing from by the last bit of a division.
@(private) grid_range :: proc "contextless" (g:^Grid, aabb:Aabb) -> (lo,hi:[3]i32) {
    pad:[3]f32
    for i in 0..<3 {pad[i]=g.cell_size*GRID_PAD+fmax(abs(aabb.min[i]),abs(aabb.max[i]))*GRID_NOISE}
    return grid_cell(g,aabb.min-pad),grid_cell(g,aabb.max+pad)
}
@(private) grid_list :: #force_inline proc "contextless" (g:^Grid, cell:[3]i32) -> i32 {
    if g.dims.x>0 {return cell.x+g.dims.x*(cell.y+g.dims.y*cell.z)}
    return i32((u32(cell.x)*73856093~u32(cell.y)*19349663~u32(cell.z)*83492791)&g.mask)
}
// Cells of a range; more than any pool of links holds for a range no product of i64 can count.
@(private) grid_cell_count :: #force_inline proc "contextless" (lo,hi:[3]i32) -> i64 {
    x,y,z:=i64(hi.x)-i64(lo.x)+1,i64(hi.y)-i64(lo.y)+1,i64(hi.z)-i64(lo.z)+1
    if x>1<<20||y>1<<20||z>1<<20 {return max(i64)}
    return x*y*z
}
@(private) grid_live :: #force_inline proc "contextless" (g:^Grid, item:i32) -> bool {
    return item>=0&&item<g.item_high&&g.items[item].lo.x<=g.items[item].hi.x
}

@(private) grid_link :: proc(g:^Grid, item:i32, lo,hi:[3]i32) {
    for z in lo.z..=hi.z {
        for y in lo.y..=hi.y {
            for x in lo.x..=hi.x {
                index:=g.free_link
                if index!=GRID_NULL {g.free_link=g.links[index].next} else {index=g.link_high;g.link_high+=1}
                list:=grid_list(g,{x,y,z})
                g.links[index]={item,g.heads[list],{x,y,z}}
                g.heads[list]=index
            }
        }
    }
    g.link_count+=i32(grid_cell_count(lo,hi))
}
@(private) grid_unlink :: proc(g:^Grid, item:i32, lo,hi:[3]i32) {
    for z in lo.z..=hi.z {
        for y in lo.y..=hi.y {
            for x in lo.x..=hi.x {
                cell:=[3]i32{x,y,z}
                at:=&g.heads[grid_list(g,cell)]
                for at^!=GRID_NULL {
                    link:=&g.links[at^]
                    if link.item==item&&link.cell==cell {
                        index:=at^
                        at^=link.next
                        link.next=g.free_link
                        g.free_link=index
                        break
                    }
                    at=&link.next
                }
            }
        }
    }
    g.link_count-=i32(grid_cell_count(lo,hi))
}

grid_insert :: proc(g:^Grid, aabb:Aabb, user:u64) -> (item:i32, ok:bool) {
    if len(g.items)==0||!aabb_valid(aabb) {
        g.stats.insert_failures+=1
        return GRID_NULL,false
    }
    lo,hi:=grid_range(g,aabb)
    if int(g.item_count)>=len(g.items)||grid_cell_count(lo,hi)>i64(len(g.links))-i64(g.link_count) {
        g.stats.insert_failures+=1
        return GRID_NULL,false
    }
    item=g.free_item
    if item!=GRID_NULL {g.free_item=g.items[item].next} else {item=g.item_high;g.item_high+=1}
    g.items[item]={aabb,user,lo,hi,GRID_NULL}
    g.item_count+=1
    grid_link(g,item,lo,hi)
    return item,true
}
grid_remove :: proc(g:^Grid, item:i32) {
    if !grid_live(g,item) {return}
    entry:=&g.items[item]
    grid_unlink(g,item,entry.lo,entry.hi)
    entry^={lo={1,0,0},next=g.free_item}
    g.free_item=item
    g.item_count-=1
}
// Gives an item another box. False, with the item where it was, for a box
// that is not valid or that reaches more cells than there are links left.
grid_move :: proc(g:^Grid, item:i32, aabb:Aabb) -> bool {
    if !grid_live(g,item)||!aabb_valid(aabb) {return false}
    entry:=&g.items[item]
    lo,hi:=grid_range(g,aabb)
    if lo!=entry.lo||hi!=entry.hi {
        if grid_cell_count(lo,hi)>i64(len(g.links))-i64(g.link_count)+grid_cell_count(entry.lo,entry.hi) {
            g.stats.insert_failures+=1
            return false
        }
        grid_unlink(g,item,entry.lo,entry.hi)
        grid_link(g,item,lo,hi)
        entry.lo,entry.hi=lo,hi
    }
    entry.aabb=aabb
    return true
}
// An item that is not live reads as zero and takes no user.
grid_aabb :: proc(g:^Grid, item:i32) -> Aabb {return grid_live(g,item)?g.items[item].aabb:{}}
grid_user :: proc(g:^Grid, item:i32) -> u64 {return grid_live(g,item)?g.items[item].user:0}
grid_set_user :: proc(g:^Grid, item:i32, user:u64) {
    if grid_live(g,item) {g.items[item].user=user}
}

// Every link is of a live item and in the list of its cell, every item has one link per cell it
// reaches, and the counters match.
grid_validate :: proc(g:^Grid) -> bool {
    links:=0
    for head,list in g.heads {
        for index:=head;index!=GRID_NULL;index=g.links[index].next {
            link:=g.links[index]
            if !grid_live(g,link.item)||int(grid_list(g,link.cell))!=list {return false}
            entry:=g.items[link.item]
            for i in 0..<3 {
                if link.cell[i]<entry.lo[i]||link.cell[i]>entry.hi[i] {return false}
            }
            links+=1
            if links>len(g.links) {return false}
        }
    }
    items,wanted:=0,i64(0)
    for index in 0..<g.item_high {
        if !grid_live(g,index) {continue}
        entry:=g.items[index]
        lo,hi:=grid_range(g,entry.aabb)
        if lo!=entry.lo||hi!=entry.hi {return false}
        items+=1
        wanted+=grid_cell_count(entry.lo,entry.hi)
    }
    return items==int(g.item_count)&&links==int(g.link_count)&&wanted==i64(links)
}

// -- Iterators --------------------------------------------------------------
//
// Iterators only read the grid and own their state: any number of them can run from different
// threads. An item is given once, however many cells it shares with the volume.

Grid_Query :: struct {grid:^Grid, aabb:Aabb, lo,hi,cell:[3]i32, link:i32, scan:bool, done:bool}

grid_query :: proc(g:^Grid, aabb:Aabb) -> Grid_Query {
    q:=Grid_Query{grid=g,aabb=aabb,link=GRID_NULL,done=true}
    if len(g.heads)==0||g.item_count==0||!aabb_valid(aabb) {return q}
    q.lo,q.hi=grid_cell(g,aabb.min),grid_cell(g,aabb.max)
    q.cell,q.done=q.lo,false
    if grid_hashed(g)&&grid_cell_count(q.lo,q.hi)>i64(len(g.heads))*GRID_SCAN_FACTOR {
        q.scan,q.link=true,0
    } else {
        q.link=g.heads[grid_list(g,q.cell)]
    }
    return q
}
// One item whose box overlaps the query per call: cell by cell along x, then y, then z, and
// inside a cell the last one linked first.
grid_query_next :: proc(q:^Grid_Query) -> (item:i32, user:u64, ok:bool) {
    g:=q.grid
    if q.done {return GRID_NULL,0,false}
    if q.scan {
        for q.link<g.item_high {
            index:=q.link
            q.link+=1
            if grid_live(g,index)&&math.aabb_overlaps(g.items[index].aabb,q.aabb) {return index,g.items[index].user,true}
        }
        q.done=true
        return GRID_NULL,0,false
    }
    for {
        for q.link!=GRID_NULL {
            link:=g.links[q.link]
            q.link=link.next
            if link.cell!=q.cell {continue}
            entry:=&g.items[link.item]
            // Only in the first cell of the query the item reaches.
            first:=[3]i32{max(entry.lo.x,q.lo.x),max(entry.lo.y,q.lo.y),max(entry.lo.z,q.lo.z)}
            if first!=q.cell||!math.aabb_overlaps(entry.aabb,q.aabb) {continue}
            return link.item,entry.user,true
        }
        if q.cell.x<q.hi.x {
            q.cell.x+=1
        } else if q.cell.y<q.hi.y {
            q.cell.x=q.lo.x;q.cell.y+=1
        } else if q.cell.z<q.hi.z {
            q.cell.x,q.cell.y=q.lo.x,q.lo.y;q.cell.z+=1
        } else {
            q.done=true
            return GRID_NULL,0,false
        }
        q.link=g.heads[grid_list(g,q.cell)]
    }
}

// The caller may lower max_fraction between calls to clip what is left of the traversal.
Grid_Ray :: struct {
    grid:^Grid, origin,translation:[3]f32, max_fraction:f32,
    cell,previous,step:[3]i32, next,delta:[3]f32, // fractions at which the segment crosses to the next cell on each axis
    link:i32, first,scan,done:bool,
}

// The items whose box the segment origin + t*translation, t in [0,max_fraction], touches.
grid_ray :: proc(g:^Grid, origin,translation:[3]f32, max_fraction:f32) -> Grid_Ray {
    r:=Grid_Ray{grid=g,origin=origin,translation=translation,max_fraction=max_fraction,link=GRID_NULL,first=true,done=true}
    if len(g.heads)==0||g.item_count==0||!(max_fraction>=0) {return r}
    for i in 0..<3 {
        if !(abs(origin[i])<=max(f32))||!(abs(translation[i])<=max(f32)) {return r}
    }
    start:=f32(0)
    if grid_hashed(g) {
        cells:=f32(0)
        for i in 0..<3 {cells+=abs(translation[i])*max_fraction*g.inverse_cell}
        if !(cells<=f32(len(g.heads)*GRID_SCAN_FACTOR)) {
            r.scan,r.link,r.done=true,0,false
            return r
        }
    } else {
        // Outside its box a uniform grid has nothing: the walk starts where the segment enters it.
        size:=[3]f32{f32(g.dims.x),f32(g.dims.y),f32(g.dims.z)}*g.cell_size
        hit:bool
        if start,hit=aabb_ray({g.origin,g.origin+size},origin,translation,max_fraction);!hit {return r}
    }
    r.done=false
    r.cell=grid_cell(g,origin+translation*start)
    for i in 0..<3 {
        if abs(translation[i])<SEGMENT_PARALLEL {
            r.next[i],r.delta[i]=INFINITY,INFINITY
            continue
        }
        r.step[i]=translation[i]>0?1:-1
        r.delta[i]=g.cell_size/abs(translation[i])
        boundary:=g.origin[i]+f32(r.cell[i]+(translation[i]>0?1:0))*g.cell_size
        r.next[i]=fmax((boundary-origin[i])/translation[i],start)
    }
    r.link=g.heads[grid_list(g,r.cell)]
    return r
}
// One item the segment touches per call, cell by cell in the order the segment crosses them. A
// spatial hash asked for a segment over more cells than it reads gives them in slot order.
grid_ray_next :: proc(r:^Grid_Ray) -> (item:i32, user:u64, ok:bool) {
    g:=r.grid
    if r.done {return GRID_NULL,0,false}
    if r.scan {
        for r.link<g.item_high {
            index:=r.link
            r.link+=1
            if !grid_live(g,index) {continue}
            if _,hit:=aabb_ray(g.items[index].aabb,r.origin,r.translation,r.max_fraction);hit {return index,g.items[index].user,true}
        }
        r.done=true
        return GRID_NULL,0,false
    }
    for {
        for r.link!=GRID_NULL {
            link:=g.links[r.link]
            r.link=link.next
            if link.cell!=r.cell {continue}
            entry:=&g.items[link.item]
            // The walk only advances along each axis, so the cells of an item it crosses are
            // consecutive: the item is given in the first of them.
            if !r.first {
                p:=r.previous
                if p.x>=entry.lo.x&&p.x<=entry.hi.x&&p.y>=entry.lo.y&&p.y<=entry.hi.y&&p.z>=entry.lo.z&&p.z<=entry.hi.z {continue}
            }
            if _,hit:=aabb_ray(entry.aabb,r.origin,r.translation,r.max_fraction);hit {return link.item,entry.user,true}
        }
        axis:=0
        if r.next.y<r.next[axis] {axis=1}
        if r.next.z<r.next[axis] {axis=2}
        // No crossing at an infinite fraction: the axes a segment is parallel to never have one.
        if !(r.next[axis]<=r.max_fraction)||r.next[axis]>=INFINITY {
            r.done=true
            return GRID_NULL,0,false
        }
        r.previous,r.first=r.cell,false
        r.cell[axis]+=r.step[axis]
        if g.dims.x>0 {
            if r.cell[axis]<0||r.cell[axis]>=g.dims[axis] {
                r.done=true
                return GRID_NULL,0,false
            }
        } else if r.cell[axis]>GRID_CELL_LIMIT||r.cell[axis]<-GRID_CELL_LIMIT {
            r.done=true
            return GRID_NULL,0,false
        }
        r.next[axis]+=r.delta[axis]
        r.link=g.heads[grid_list(g,r.cell)]
    }
}
