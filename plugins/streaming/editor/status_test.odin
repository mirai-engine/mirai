package streaming_editor

import "core:testing"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import scene "mirai:engine/scene"
import "mirai:host"
import "mirai:std/base"
import streaming "plugins:streaming/runtime"

@(test_world,host="Status_Shared")
Status_World :: struct {
    using world:Test_World,
    ids:core.Table(core.Id),
    references:core.Table(scene.Scene_Reference),
    sources:scene.Streaming_Sources,
    settings:streaming.Streaming_Settings,
}

Status_Shared :: struct {loads:core.By_World(scene.Section_Loads)}

// streaming.status lists the sources, the loads under way and each section
// with its rule, what is asked, what streaming wants and what it is now.
@(test)
streaming_status_tells_sources_loads_and_sections :: proc(t:^testing.T) {
    world:Status_World
    if !test_world_init(t,&world) {return}
    defer test_world_destroy(&world)
    shared:Status_Shared
    loads:scene.Section_Loads
    app:=host.App{info=test_world_info(&world),shared=&shared,allocator=context.allocator}
    append(&app.worlds,host.World_Slot{data=&world,generation=1})
    defer delete(app.worlds)
    append(&shared.loads.entries,core.By_World_Entry(scene.Section_Loads){world={0,1},value=&loads})
    defer delete(shared.loads.entries)
    world.settings={active=30,load=90}
    world.sources.items[0]={position={1,2,3},ahead={4,5,6}}
    world.sources.items[1]={position={50,0,0},ahead={50,0,0},distance=20}
    world.sources.count,world.sources.revision=2,7
    Row :: struct {id:u64,reference:scene.Scene_Reference,state:string,far:bool}
    rows:=[]Row{
        {1,{scene={1,1},rule=.Spatial,streamed=.Active,loaded={1,1}},"Active",false},
        {2,{scene={2,2},rule=.Spatial,streamed=.Loaded,loaded={2,2},held=true},"Loaded",false},
        {3,{scene={3,3},rule=.Spatial,streamed=.Unloaded,far={3,3}},"Unloaded",true},
        {4,{scene={4,4},rule=.Manual,state=.Active},"Unloaded",false},
    }
    entities:[4]core.Entity
    for row,i in rows {
        entities[i]=core.create(&world.entities)
        core.add(&world.ids,entities[i],core.Id{base.Entity_Id(row.id)})
        core.add(&world.references,entities[i],row.reference)
    }
    test_world_settle(&world)
    job:scene.Load_Job
    job.root=rows[3].reference.scene
    loads.items[0]={&job,entities[3]}
    session:=editor.Session{info=test_world_info(&world),edit_world=&world,app=&app}
    result:Streaming_Status_Result
    method:=api.Method{result_id=Streaming_Status_Result}
    call:=api.Call{method=&method,result=&result,allocator=context.temp_allocator}
    streaming_status(&session,&call)
    testing.expect(t,!call.failed,call.error.message)
    testing.expect(t,result.active==30 && result.load==90 && result.revision==7,"the settings and the revision of the sources")
    if testing.expect_value(t,len(result.sources),2) {
        testing.expect(t,result.sources[0].ahead==[3]f32{4,5,6} && result.sources[1].distance==20,"each source with where it goes and its distance")
    }
    if testing.expect_value(t,len(result.loads),1) {
        testing.expect(t,result.loads[0].section==4 && result.loads[0].scene==rows[3].reference.scene && !result.loads[0].far && result.loads[0].phase=="Idle","the load under way, by the Id of its section")
    }
    if !testing.expect_value(t,len(result.sections),len(rows)) {return}
    for row,i in rows {
        got:=result.sections[i]
        testing.expectf(t,got.entity==base.Entity_Id(row.id) && got.state==row.state && got.far==row.far,"section %d: %v",row.id,got)
    }
    testing.expect_value(t,result.sections[3].rule,"Manual")
    testing.expect_value(t,result.sections[3].asked,"Active")
    testing.expect(t,result.loaded==2 && result.on==1 && result.far==1,"counted: two loaded, one on, one far")
    // A world without sections says how to have them.
    bare:=editor.Session{}
    failed:=api.Call{method=&method,result=&result,allocator=context.temp_allocator}
    streaming_status(&bare,&failed)
    testing.expect(t,failed.failed,"no shown world, no status")
}
