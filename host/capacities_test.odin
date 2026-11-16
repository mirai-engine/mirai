package host

import "core:testing"
import "mirai:project"
import render "mirai:render"
import "mirai:std/base"

// The marks of a scene outlive the run that wrote them; runs that write the
// same file each keep the highest of every mark, and a scene not kept takes
// the place of the one opened longest ago, never that of the scene open.
@(test)
the_marks_of_a_scene_outlive_its_run_grow_only_and_the_oldest_scenes_give_way :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"capacities")
    if folder=="" {return}
    path:=project.path(folder,"capacities",allocator=context.temp_allocator)
    cave,hall:=base.Asset_Id{1,1},base.Asset_Id{2,2}

    first:=new(Capacities,context.temp_allocator)
    first.entries[0]={scene=cave,opened=10}
    first.count,first.open=1,1
    capacity_marks_grow(&first.entries[0].marks,{cull=#partial [render.Cull_List]u32{.Visible=400_000},points=90_000})
    testing.expect(t,capacities_write(first,path),"the file is written")

    other:=new(Capacities,context.temp_allocator)
    other.entries[0]={scene=cave,opened=20,marks={cull=#partial [render.Cull_List]u32{.Visible=300_000,.Shadow_Entries=500_000}}}
    other.entries[1]={scene=hall,opened=20,marks={cull=#partial [render.Cull_List]u32{.Chunks=70_000}}}
    other.count=2
    testing.expect(t,capacities_write(other,path),"another run writes the same file")

    again:=new(Capacities,context.temp_allocator)
    capacities_take(again,path)
    testing.expect_value(t,again.count,2)
    for e in again.entries[:again.count] {
        switch e.scene {
        case cave:
            testing.expectf(t,e.marks=={cull=#partial [render.Cull_List]u32{.Visible=400_000,.Shadow_Entries=500_000},points=90_000} && e.opened==20,"the scene keeps the highest of each mark: %v",e)
        case hall:
            testing.expect_value(t,e.marks.cull[.Chunks],u32(70_000))
        case:
            testing.expectf(t,false,"a scene nobody wrote: %v",e.scene)
        }
    }
    testing.expect(t,!capacity_marks_grow(&again.entries[0].marks,{}),"no mark goes down")

    full:=new(Capacities,context.temp_allocator)
    for &e,i in full.entries {e={scene={u64(i+10),0},opened=i64(100+i)}}
    full.count,full.open=CAPACITY_SCENES,1
    capacities_take(full,path)
    testing.expect(t,full.entries[0].scene=={10,0},"the scene open stays, though the oldest")
    testing.expect(t,full.entries[1].scene=={11,0},"what other runs opened before every scene kept does not come in")
    newer:=new(Capacities,context.temp_allocator)
    newer.entries[0]={scene=hall,opened=1000,marks={cull=#partial [render.Cull_List]u32{.Chunks=80_000}}}
    newer.count=1
    testing.expect(t,capacities_write(newer,path))
    capacities_take(full,path)
    testing.expect(t,full.entries[0].scene=={10,0} && full.entries[1].scene==hall && full.entries[1].marks.cull[.Chunks]==80_000,"a scene opened later takes the place of the oldest but the one open")
}
