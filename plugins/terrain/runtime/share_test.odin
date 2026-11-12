package terrain

import "base:runtime"
import "core:math"
import "core:mem"
import "core:testing"

// A Heightfield of 257 samples a side, 5 by 5 pages, every one with values.
@(private="file")
share_heightfield :: proc(t:^testing.T,s:^Source,allocator:=context.allocator) -> bool {
    if !testing.expect(t,source_make(s,.Heightfield,{257,1,257},1,16,allocator)) {return false}
    if !testing.expect(t,grid_prepare(&s.field,{},{256,0,256},s.allocator)) {return false}
    for z in 0..<257 {for x in 0..<257 {grid_set(&s.field,x,z,math.sin(f32(x)*0.05)*4+math.cos(f32(z)*0.07)*3)}}
    return true
}

// A Raise at the middle of page p: it writes only that page.
@(private="file")
share_raise :: proc(s:^Source,p:[2]int) -> Change {
    center:=source_point(s,{p.x*PAGE+32,0,p.y*PAGE+32})
    return source_edit(s,{kind=.Raise,center=center,radius=2,amount=0.5,falloff=.Smooth,hardness=0.5})
}

// The values every grid of the list holds, each counted once.
@(private="file")
share_distinct :: proc(grids:[]^Grid(f32)) -> (pages:int) {
    seen:=make(map[rawptr]bool,context.temp_allocator)
    for g in grids {for page in g.pages {
        if page.values==nil || raw_data(page.values) in seen {continue}
        seen[raw_data(page.values)]=true
        pages+=1
    }}
    return
}

@(test)
a_copy_shares_its_pages_and_a_write_on_either_side_leaves_the_other_as_it_was :: proc(t:^testing.T) {
    for kind in ([2]Source_Kind{.Heightfield,.Volume}) {
        source,copied:Source;defer source_destroy(&source);defer source_destroy(&copied)
        if kind==.Heightfield {
            if !share_heightfield(t,&source) {return}
        } else if !testing.expect(t,source_make(&source,.Volume,{97,97,97},1,16)) {return}
        g:=&source.field
        tracking:mem.Tracking_Allocator
        mem.tracking_allocator_init(&tracking,context.allocator);defer mem.tracking_allocator_destroy(&tracking)
        if !testing.expect(t,data_source_copy(&copied,&source)) {return}
        c:=&copied.field
        for page,i in g.pages {testing.expect(t,raw_data(page.values)==raw_data(c.pages[i].values),"the copy holds the values of the source")}
        testing.expect_value(t,len(c.pages),len(g.pages))
        // What a copy allocates is its tables, less than the values of one page.
        {
            context.allocator=mem.tracking_allocator(&tracking)
            again:Source;defer source_destroy(&again)
            testing.expect(t,data_source_copy(&again,&source))
            testing.expect(t,tracking.peak_memory_allocated<i64(PAGE_VALUES*4)+64*1024)
        }
        // A write on the source copies the pages it touches; the copy keeps what it read.
        at:=kind==.Heightfield?[3]int{32,0,32}:[3]int{40,46,40}
        point:=source_point(&source,at)
        before:=source_value(&source,at)
        brush:=kind==.Heightfield?Brush{kind=.Raise,center=point,radius=2,amount=0.5,falloff=.Smooth,hardness=0.5}:Brush{kind=.Carve,center=point,radius=1.5,amount=1}
        testing.expect(t,source_edit(&source,brush).changed)
        testing.expect(t,source_value(&source,at)!=before)
        testing.expect_value(t,source_value(&copied,at),before)
        touched,_:=grid_page_at(g,at)
        touched=grid_slot(g,touched)
        if !testing.expect(t,touched>=0 && touched==grid_slot(c,grid_id(g,touched)),"the copy holds its pages where the source does") {return}
        testing.expect(t,raw_data(g.pages[touched].values)!=raw_data(c.pages[touched].values),"the source took values of its own")
        shared:=0
        for page,i in g.pages {if page.values!=nil && raw_data(page.values)==raw_data(c.pages[i].values) {shared+=1}}
        testing.expect(t,shared>0,"the pages the brush did not touch stay shared")
        // And a write on the copy leaves the source as it is.
        edited:=source_value(&source,at)
        testing.expect(t,source_edit(&copied,brush).changed)
        testing.expect_value(t,source_value(&source,at),edited)
        // A page written alone is written in place: no copy is left to keep it.
        values:=raw_data(g.pages[touched].values)
        brush.kind=kind==.Heightfield?.Raise:.Add
        testing.expect(t,source_edit(&source,brush).changed)
        testing.expect_value(t,raw_data(g.pages[touched].values),values)
    }
}

// The coarse grid of a Heightfield goes the same way: a copy holds it with
// the source, and an edit gives the source the parts it writes, leaving the
// copy what it read.
@(test)
a_copy_shares_the_coarse_grid_until_an_edit_writes_it :: proc(t:^testing.T) {
    tracking:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracking,context.allocator);defer mem.tracking_allocator_destroy(&tracking)
    context.allocator=mem.tracking_allocator(&tracking)
    {
        // 1025 samples a side: a coarse grid of 129, 3 by 3 pages.
        source,copied:Source;defer source_destroy(&source);defer source_destroy(&copied)
        if !testing.expect(t,source_make(&source,.Heightfield,{1025,1,1025},1,64)) {return}
        if !testing.expect(t,grid_prepare(&source.field,{},{1024,0,1024},source.allocator)) {return}
        for z in 0..<1025 {for x in 0..<1025 {grid_set(&source.field,x,z,math.sin(f32(x)*0.05)*4)}}
        if !testing.expect(t,source_coarse_build(&source)) {return}
        if !testing.expect(t,data_source_copy(&copied,&source)) {return}
        g,c:=&source.coarse.heights,&copied.coarse.heights
        for page,i in g.pages {testing.expect(t,page.values!=nil && raw_data(page.values)==raw_data(c.pages[i].values),"the copy holds the coarse grid")}
        before:=grid_get(c,4,4)
        change:=source_edit(&source,{kind=.Raise,center=source_point(&source,{32,0,32}),radius=6,amount=2,falloff=.Smooth,hardness=0.5})
        testing.expect(t,change.changed && source_coarse_update(&source,change.low,change.high))
        testing.expect(t,grid_get(g,4,4)!=before)
        testing.expect_value(t,grid_get(c,4,4),before)
        testing.expect(t,raw_data(g.pages[0].values)!=raw_data(c.pages[0].values),"the source took its own page")
        for page,i in g.pages[1:] {testing.expect(t,raw_data(page.values)==raw_data(c.pages[i+1].values),"the pages the edit did not reach stay shared")}
    }
    testing.expect_value(t,len(tracking.allocation_map),0)
}

@(test)
the_pages_a_copy_holds_outlive_the_source_they_came_from :: proc(t:^testing.T) {
    // Two Worlds with allocators of their own, as Play and the editor.
    first,second:mem.Tracking_Allocator
    mem.tracking_allocator_init(&first,context.allocator);defer mem.tracking_allocator_destroy(&first)
    mem.tracking_allocator_init(&second,context.allocator);defer mem.tracking_allocator_destroy(&second)
    source,copied:Source
    if !share_heightfield(t,&source,mem.tracking_allocator(&first)) {return}
    {
        context.allocator=mem.tracking_allocator(&second)
        testing.expect(t,data_source_copy(&copied,&source))
    }
    expected:=source_value(&source,{100,0,200})
    held:=first.current_memory_allocated
    source_destroy(&source)
    testing.expect(t,first.current_memory_allocated>0 && first.current_memory_allocated<held,"the values the copy holds stay; the tables of the source go")
    testing.expect_value(t,source_value(&copied,{100,0,200}),expected)
    // The copy holds them alone now: it writes them in place.
    values:=raw_data(copied.field.pages[1+5*3].values)
    testing.expect(t,share_raise(&copied,{1,3}).changed)
    testing.expect_value(t,raw_data(copied.field.pages[1+5*3].values),values)
    source_destroy(&copied)
    testing.expect_value(t,len(first.allocation_map),0)
    testing.expect_value(t,len(second.allocation_map),0)
}

@(test)
a_ring_of_snapshots_holds_only_what_changed_within_it_and_lets_go_of_what_leaves :: proc(t:^testing.T) {
    RING :: 4
    live:Terrain_Data;defer terrain_data_free(&live)
    live.settings=TERRAIN_SETTINGS_DEFAULT;live.ready=true
    resize(&live.entries,1)
    entry:=&live.entries[0]
    entry.id={5,5}
    if !share_heightfield(t,&entry.source) {return}
    if !testing.expect(t,data_chunks_allocate(entry,context.allocator)) {return}
    pages:=len(entry.source.field.pages)
    ring:[RING]Terrain_Data
    defer {for &snapshot in ring {terrain_data_free(&snapshot)}}
    grids :: proc(live:^Terrain_Data,ring:^[RING]Terrain_Data) -> (list:[RING+1]^Grid(f32)) {
        list[0]=&live.entries[0].source.field
        for &snapshot,i in ring {list[i+1]=len(snapshot.entries)>0?&snapshot.entries[0].source.field:list[0]}
        return
    }
    // A brush a tick, on a page another tick touched too or on a new one:
    // the ring holds the page as each snapshot read it, and no more.
    walk:=[?][2]int{{0,0},{1,0},{1,0},{2,1},{3,3},{3,3},{3,3},{0,3},{3,0},{2,2},{1,1},{0,0}}
    for p,tick in walk {
        testing.expect(t,share_raise(&entry.source,p).changed)
        testing.expect(t,terrain_data_copy(&ring[tick%RING],&live))
        list:=grids(&live,&ring)
        retained:=share_distinct(list[:])-pages
        testing.expectf(t,retained<=min(tick,RING),"tick %d: the ring retains %d pages past the live World",tick,retained)
    }
    // Without changes, the ring comes to hold what the live World holds.
    for tick in 0..<RING {testing.expect(t,terrain_data_copy(&ring[tick%RING],&live))}
    list:=grids(&live,&ring)
    testing.expect_value(t,share_distinct(list[:]),pages)
    // A rollback copies a snapshot back; the live World and the ring share it.
    testing.expect(t,share_raise(&entry.source,{2,2}).changed)
    testing.expect(t,terrain_data_copy(&live,&ring[0]))
    list=grids(&live,&ring)
    testing.expect_value(t,share_distinct(list[:]),pages)
}

@(test)
stable_snapshots_and_rollbacks_of_a_world_allocate_nothing :: proc(t:^testing.T) {
    original:=context;defer context=original
    failure:=Failing_Allocator{owner=context.allocator,remaining=max(int)}
    context.allocator=runtime.Allocator{failing_allocator,&failure}
    live,snapshot:Terrain_Data;defer terrain_data_free(&live);defer terrain_data_free(&snapshot)
    live.settings=TERRAIN_SETTINGS_DEFAULT;live.ready=true
    resize(&live.entries,1)
    entry:=&live.entries[0]
    entry.id={6,6}
    if !share_heightfield(t,&entry.source) {return}
    if !testing.expect(t,data_chunks_allocate(entry,context.allocator)) {return}
    // A first edit leaves the room a brush reuses.
    testing.expect(t,share_raise(&entry.source,{0,0}).changed)
    // Each side takes once the room of the other: then neither allocates.
    if !testing.expect(t,terrain_data_copy(&snapshot,&live)) || !testing.expect(t,terrain_data_copy(&live,&snapshot)) {return}
    entry=&live.entries[0]
    failure.remaining=0
    temporary:=context.temp_allocator
    context.temp_allocator=runtime.nil_allocator()
    for _ in 0..<8 {
        testing.expect(t,terrain_data_copy(&snapshot,&live))
        testing.expect(t,terrain_data_copy(&live,&snapshot))
    }
    // An edit is a transaction: it copies the one page it writes, shared
    // with the snapshot, and only that.
    context.temp_allocator=temporary
    failure.remaining=1
    testing.expect(t,share_raise(&entry.source,{2,2}).changed)
    testing.expect_value(t,failure.remaining,0)
    context.temp_allocator=runtime.nil_allocator()
    testing.expect(t,terrain_data_copy(&snapshot,&live))
}
