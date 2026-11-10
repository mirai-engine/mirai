package terrain

import "base:runtime"
import "core:mem"
import "core:testing"

@(private)
terrain_copy_fixture :: proc(data:^Terrain_Data) -> bool {
    data.settings={sources=2,chunks=32,samples=4096};data.ready=true;data.epoch=17
    data.stats={loads=3,edits=4,saves=1}
    if resize(&data.entries,2)!=nil {return false}
    for &entry,i in data.entries {
        entry.id={u64(i+1),u64(i+2)}
        if !source_make(&entry.source,i==0?.Heightfield:.Volume,i==0?[3]int{9,1,9}:[3]int{5,5,5},1,4) {return false}
        if i==0 && !source_set(&entry.source,{4,0,4},.75) {return false}
        entry.source.revision=u32(i+10)
        if !data_chunks_allocate(&entry,context.allocator) {return false}
        clear(&entry.pending);for &dirty in entry.dirty {dirty=false}
        for &version,j in entry.versions {version=u32(j+20)}
        data.samples+=u32(source_cost(&entry.source))
    }
    return true
}

@(private)
terrain_copy_expect :: proc(t:^testing.T,dst,src:^Terrain_Data) {
    if !testing.expect_value(t,len(dst.entries),len(src.entries)) {return}
    testing.expect(t,dst.ready && dst.settings==src.settings && dst.stats==src.stats && dst.samples==src.samples)
    for &entry,i in src.entries {
        copy:=&dst.entries[i]
        testing.expect(t,copy.id==entry.id && copy.source.info==entry.source.info)
        testing.expect_value(t,mem.compare(mem.slice_to_bytes(copy.versions),mem.slice_to_bytes(entry.versions)),0)
        testing.expect_value(t,len(copy.pending),len(entry.dirty))
        testing.expect(t,copy.quad==entry.quad && len(copy.dirty)==quad_total(&entry.quad))
        testing.expect_value(t,mem.compare(mem.slice_to_bytes(copy.ranges),mem.slice_to_bytes(entry.ranges)),0)
        testing.expect(t,copy.source.coarse.size==entry.source.coarse.size && grid_equal(&copy.source.coarse.heights,&entry.source.coarse.heights) && grid_equal(&copy.source.coarse.weights,&entry.source.coarse.weights))
        for dirty,j in copy.dirty {testing.expect(t,dirty && copy.pending[j]==u32(j))}
        if entry.source.kind==.Heightfield {
            testing.expect(t,grid_equal(&copy.source.heights,&entry.source.heights))
            testing.expect(t,raw_data(copy.source.heights.pages[0].values)==raw_data(entry.source.heights.pages[0].values),"the copy shares the pages")
        } else {
            testing.expect(t,grid_equal(&copy.source.distances,&entry.source.distances))
            testing.expect(t,raw_data(copy.source.distances.pages[0].values)==raw_data(entry.source.distances.pages[0].values),"the copy shares the blocks")
        }
        testing.expect_value(t,len(entry.pending),0)
        for dirty in entry.dirty {testing.expect(t,!dirty)}
    }
}

@(test)
terrain_copies_report_every_allocation_failure_without_publishing_partial_ready_data_and_retry_all_representations :: proc(t:^testing.T) {
    source:Terrain_Data;defer terrain_data_free(&source)
    if !testing.expect(t,terrain_copy_fixture(&source)) {return}
    original:=context;defer context=original
    failure:=Failing_Allocator{owner=context.allocator};allocator:=runtime.Allocator{failing_allocator,&failure}
    failures:=0;completed:=false
    for budget in 0..<128 {
        destination:Terrain_Data
        failure.remaining=budget;context.allocator=allocator
        copied:=terrain_data_copy(&destination,&source)
        if copied {terrain_copy_expect(t,&destination,&source);terrain_data_free(&destination);completed=true;break}
        failures+=1
        testing.expect(t,!destination.ready)
        testing.expect(t,source.ready && source.stats.saves==1 && source.epoch==17 && len(source.entries)==2)
        failure.remaining=1000
        testing.expect(t,terrain_data_copy(&destination,&source))
        terrain_copy_expect(t,&destination,&source)
        terrain_data_free(&destination)
    }
    testing.expect(t,completed && failures>8)
}

@(test)
warm_terrain_copies_and_swaps_reuse_all_source_buffers_and_invalidate_both_host_identities_without_allocations :: proc(t:^testing.T) {
    source,destination:Terrain_Data;defer terrain_data_free(&source);defer terrain_data_free(&destination)
    if !testing.expect(t,terrain_copy_fixture(&source)) {return}
    original:=context;defer context=original
    failure:=Failing_Allocator{owner=context.allocator,remaining=1000};allocator:=runtime.Allocator{failing_allocator,&failure}
    context.allocator=allocator
    if !testing.expect(t,terrain_data_copy(&destination,&source)) {return}
    values:=raw_data(destination.entries[0].source.heights.pages[0].values)
    failure.remaining=0;context.temp_allocator=runtime.nil_allocator()
    for _ in 0..<16 {testing.expect(t,terrain_data_copy(&destination,&source))}
    terrain_copy_expect(t,&destination,&source)
    testing.expect_value(t,raw_data(destination.entries[0].source.heights.pages[0].values),values)
    source.epoch=1000;terrain_data_swap(&source,&destination)
    testing.expect(t,source.epoch==1001 && destination.epoch==1001 && source.ready && destination.ready)
    source.epoch=max(u32);terrain_data_swap(&source,&destination)
    testing.expect(t,source.epoch==1 && destination.epoch==1)
    terrain_data_swap(&source,&source);testing.expect_value(t,source.epoch,u32(1))
}
