package streaming_editor

import "core:fmt"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import scene "mirai:engine/scene"
import "mirai:host"
import "mirai:std/base"
import streaming "plugins:streaming/runtime"

@(storage)
Streaming_Api :: struct {provider:editor.Api_Provider}

STREAMING_API_DEFAULT :: Streaming_Api{provider={register=streaming_api_register}}

Streaming_Status_Result :: struct {
    active,load:f32 `mirai:"unit=m,label=Streaming_Settings: a section turns on, or loads off, this near a source"`,
    revision:u64 `mirai:"label=Of the sources: grows when one comes, goes or moves"`,
    sources:[]Streaming_Source_Status,
    loads:[]Streaming_Load_Status `mirai:"label=Sections loading apart now, and far forms being read"`,
    sections:[]Streaming_Section_Status,
    loaded,on,far:int `mirai:"label=Sections loaded (on or off), loaded and on, and not loaded with their far form kept"`,
}

Streaming_Source_Status :: struct {
    position,ahead:[3]f32 `mirai:"label=Where it is, and where its motion takes it"`,
    distance:f32 `mirai:"unit=m,label=What stays loaded around it; 0: what each library keeps around the view"`,
}

Streaming_Load_Status :: struct {
    section:base.Entity_Id,
    scene:base.Asset_Id,
    far:bool `mirai:"label=The far form of a section that is not loaded"`,
    phase:string `mirai:"label=Idle, Reading, Warming or Waiting"`,
    done,total:int,
}

Streaming_Section_Status :: struct {
    entity:base.Entity_Id,
    scene:base.Asset_Id,
    rule:string `mirai:"label=With_Document, Manual or Spatial"`,
    asked:string `mirai:"label=The state the game asks: Active, Loaded or Unloaded"`,
    streamed:string `mirai:"label=Spatial: what streaming wants by where the sources are"`,
    state:string `mirai:"label=What it is now: Active, Loaded or Unloaded"`,
    far:bool `mirai:"label=Not loaded, its far form kept"`,
    extents:[3]f32 `mirai:"unit=m"`,
    distance:f32 `mirai:"unit=m"`,
}

@(private)
streaming_api_register :: proc(s:^editor.Session) {
    editor.api_method_register(s,{name="streaming.status",summary="The streaming of the shown world: its sources (the view, the bodies the seats drive and the Streaming_Source entities, with where their motion takes them), the sections loading apart and the far forms being read, and each section with its rule, the state asked, what streaming wants of it by where the sources are and what it is now (loaded on, loaded off or not loaded, with its far form kept). Read it to know why a section is or is not loaded.",flags={.Read_Only},result=type_info_of(Streaming_Status_Result),run=streaming_status})
}

@(private)
streaming_status :: proc(s:^editor.Session,call:^api.Call) {
    w:=editor.shown_world(s)
    references:^core.Table(scene.Scene_Reference)
    if w.data!=nil {references=core.world_table_of(w,scene.Scene_Reference)}
    if references==nil {api.call_fail(call,api.INVALID_PARAMS,"The shown world has no sections: activate the plugin streaming in project.mirai");return}
    r:=api.call_result(call,Streaming_Status_Result)
    settings:=streaming.STREAMING_SETTINGS_DEFAULT
    if found:=core.world_storage_of(w,streaming.Streaming_Settings);found!=nil {settings=found^}
    r.active,r.load=settings.active,settings.load
    if sources:=core.world_storage_of(w,scene.Streaming_Sources);sources!=nil {
        r.revision=sources.revision
        r.sources=make([]Streaming_Source_Status,sources.count,call.allocator)
        for source,i in sources.items[:sources.count] {r.sources[i]={source.position,source.ahead,source.distance}}
    }
    ids:=core.world_table_of(w,core.Id)
    id_of :: proc(ids:^core.Table(core.Id),e:core.Entity) -> base.Entity_Id {
        if ids==nil {return 0}
        id,_:=core.get(ids,e)
        return id.value
    }
    loads:=make([dynamic]Streaming_Load_Status,call.allocator)
    if s.app!=nil {
        if l:=host.app_world_storage(s.app,w.data,scene.Section_Loads);l!=nil {
            add :: proc(loads:^[dynamic]Streaming_Load_Status,ids:^core.Table(core.Id),items:[]scene.Section_Load,far:bool) {
                for item in items {
                    if item.job==nil {continue}
                    progress:=scene.load_progress(item.job)
                    append(loads,Streaming_Load_Status{id_of(ids,item.entity),progress.scene,far,fmt.tprintf("%v",progress.phase),progress.done,progress.total})
                }
            }
            add(&loads,ids,l.items[:],false)
            add(&loads,ids,l.far[:],true)
        }
    }
    r.loads=loads[:]
    r.sections=make([]Streaming_Section_Status,core.count(references),call.allocator)
    for row in 0..<core.count(references) {
        reference:=core.at(references,row)
        state:=scene.Section_State.Unloaded
        if reference.loaded!={} {state=.Loaded if reference.held else .Active}
        far:=state==.Unloaded && reference.far!={}
        r.sections[row]={
            entity=id_of(ids,core.entity_at(references,row)),scene=reference.scene,
            rule=fmt.tprintf("%v",reference.rule),asked=fmt.tprintf("%v",reference.state),
            streamed=fmt.tprintf("%v",reference.streamed),state=fmt.tprintf("%v",state),
            far=far,extents=reference.extents,distance=reference.distance,
        }
        if state!=.Unloaded {r.loaded+=1}
        if state==.Active {r.on+=1}
        if far {r.far+=1}
    }
}
