package editor

import "core:fmt"
import "core:math/linalg"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/api"
import scene "mirai:engine/scene"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

@(private="file")
Sections_World :: struct {
    entities:core.Entities,
    ids:core.Table(core.Id),
    names:core.Table(core.Name),
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    disabled:core.Table(core.Disabled),
    references:core.Table(scene.Scene_Reference),
    links:core.Table(Sections_Link),
    hierarchy:core.Hierarchy,
    views:scene.Section_Views,
    unresolved:scene.Unresolved_References,
}

// A component of the document that names an entity.
@(private="file")
Sections_Link :: struct {target:core.Entity}

@(private="file")
sections_world_settle :: proc(data,shared,editor:rawptr) {
    w:=cast(^Sections_World)data
    core.table_settle(&w.ids,&w.entities)
    core.table_settle(&w.names,&w.entities)
    core.table_settle(&w.transforms,&w.entities)
    core.table_settle(&w.parents,&w.entities)
    core.table_settle(&w.disabled,&w.entities)
    core.table_settle(&w.references,&w.entities)
    core.table_settle(&w.links,&w.entities)
    core.hierarchy_settle(&w.hierarchy,core.read(&w.parents),&w.entities)
    core.entities_activity(&w.entities,core.read(&w.disabled),core.ref(&w.hierarchy))
    core.entities_settle(&w.entities)
}

// A scene with a root entity A and a section, R, of the scene X whose
// entity C hangs from it, over an assets folder that holds X.
@(private="file")
Sections_Fixture :: struct {
    world:Sections_World,
    tables:[7]core.Table_Info,
    storages:[4]core.Storage_Info,
    info:core.World_Info,
    assets:host.Assets,
    app:host.App,
    viewport:Viewport,
    selection:Selection,
    inspector:Inspector,
    edits:Edits,
    document:Document,
    prefabs:Prefabs,
    outliner:Outliner,
    g:Editor_Ui,
    ai:Ai,
    watch:Sections_Watch,
    root:string,
    s:Session,
    a,r,c:core.Entity,
    x:base.Asset_Id,
}

SECTIONS_TEST_X :: base.Asset_Id{0x5ec7,0x1}
SECTIONS_TEST_LOCAL :: base.Entity_Id(0xc0)

@(private="file")
sections_fixture_init :: proc(f:^Sections_Fixture,name:string,state:=scene.Section_State.Active) -> bool {
    w:=&f.world
    core.entities_init(&w.entities)
    core.table_init(&w.ids,"Id");core.table_init(&w.names,"Name");core.table_init(&w.transforms,"Transform")
    core.table_init(&w.parents,"Parent");core.table_init(&w.disabled,"Disabled");core.table_init(&w.references,"Scene_Reference")
    core.table_init(&w.links,"Sections_Link")
    w.ids.base,w.names.base,w.transforms.base,w.parents.base,w.disabled.base=true,true,true,true,true
    f.tables={
        {name="Id",type=core.Id,info=type_info_of(core.Id),offset=offset_of(Sections_World,ids)},
        {name="Name",type=core.Name,info=type_info_of(core.Name),offset=offset_of(Sections_World,names)},
        {name="Transform",type=core.Transform,info=type_info_of(core.Transform),offset=offset_of(Sections_World,transforms)},
        {name="Parent",type=core.Parent,info=type_info_of(core.Parent),offset=offset_of(Sections_World,parents)},
        {name="Disabled",type=core.Disabled,info=type_info_of(core.Disabled),offset=offset_of(Sections_World,disabled)},
        {name="Scene_Reference",type=scene.Scene_Reference,info=type_info_of(scene.Scene_Reference),offset=offset_of(Sections_World,references)},
        {name="Sections_Link",type=Sections_Link,info=type_info_of(Sections_Link),offset=offset_of(Sections_World,links)},
    }
    f.storages={
        {type=Prefabs,place=.Editor},{type=core.Hierarchy,info=type_info_of(core.Hierarchy),offset=offset_of(Sections_World,hierarchy)},
        {type=scene.Section_Views,info=type_info_of(scene.Section_Views),offset=offset_of(Sections_World,views)},
        {type=scene.Unresolved_References,info=type_info_of(scene.Unresolved_References),offset=offset_of(Sections_World,unresolved)},
    }
    f.info=core.World_Info{entities=offset_of(Sections_World,entities),tables=f.tables[:],storages=f.storages[:]}
    temporary,_:=os.temp_directory(context.temp_allocator)
    f.root,_=strings.replace_all(project.path(temporary,fmt.tprintf("mirai-sections-%s-%d",name,os.get_pid()),allocator=context.temp_allocator),"\\","/")
    os.remove_all(f.root)
    if os.make_directory_all(f.root)!=nil {return false}
    // The scene of the section: one entity, as it was saved before.
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    f.x=SECTIONS_TEST_X
    x:asset.Scene
    if asset.scene_init(&x,&types,asset.KIND_SCENE,f.x)!=.None {return false}
    asset.scene_entity_add(&x,SECTIONS_TEST_LOCAL,0,"Crate")
    saved:=asset.scene_save(&x,fmt.tprintf("%s/layer.scene",f.root))
    asset.scene_destroy(&x)
    if saved!=.None {return false}
    if !host.assets_init(&f.assets,{root=f.root,capacity=8}) {return false}
    host.assets_scan(&f.assets)
    f.app=host.App{assets=&f.assets,info=&f.info,allocator=context.allocator}
    f.s=Session{info=&f.info,edit_world=w,editor_world=&f.prefabs,assets_root=f.root,app=&f.app,gui=&f.g,viewport=&f.viewport,selection=&f.selection,inspector=&f.inspector,edits=&f.edits,document=&f.document,outliner=&f.outliner,ai=&f.ai}
    f.viewport.size,f.viewport.window,f.viewport.orbit={1280,720},{1280,720},ORBIT_DEFAULT
    f.a=sections_test_entity(f,1,"A",core.NONE,{0,0,0})
    f.r=sections_test_entity(f,2,"Layer",core.NONE,{100,-40,50})
    core.add(&w.references,f.r,scene.Scene_Reference{scene=f.x,extents={10,5,10},rule=.Manual,state=state,loaded=state==.Unloaded?{}:f.x})
    if state!=.Unloaded {f.c=sections_test_entity(f,SECTIONS_TEST_LOCAL,"Crate",f.r,{1,0,0})}
    sections_world_settle(w,nil,nil)
    edits_reset(&f.edits,edited_world(&f.s))
    f.document.saved=edits_scene_state(&f.edits)
    return true
}

@(private="file")
sections_test_entity :: proc(f:^Sections_Fixture,id:base.Entity_Id,name:string,parent:core.Entity,position:[3]f32) -> core.Entity {
    w:=&f.world
    e:=core.create(&w.entities)
    core.add(&w.ids,e,core.Id{id})
    core.add(&w.names,e,core.name_make(name))
    core.add(&w.transforms,e,core.Transform{position,1,{1,1,1}})
    if parent!=core.NONE {core.add(&w.parents,e,core.Parent{parent,0})}
    return e
}

@(private="file")
sections_fixture_destroy :: proc(f:^Sections_Fixture) {
    prefabs_free(&f.s)
    documents_free(&f.s)
    document_previous_free(&f.document)
    edits_free(&f.edits)
    core.value_free(&f.inspector,type_info_of(Inspector))
    core.value_free(&f.watch,type_info_of(Sections_Watch))
    delete(f.selection.entities)
    delete(f.app.worlds)
    host.assets_destroy(&f.assets)
    w:=&f.world
    core.entities_destroy(&w.entities)
    core.table_destroy(&w.ids);core.table_destroy(&w.names);core.table_destroy(&w.transforms)
    core.table_destroy(&w.parents);core.table_destroy(&w.disabled);core.table_destroy(&w.references);core.table_destroy(&w.links)
    core.value_free(&w.hierarchy,type_info_of(core.Hierarchy))
    core.value_free(&w.views,type_info_of(scene.Section_Views))
    core.value_free(&w.unresolved,type_info_of(scene.Unresolved_References))
    os.remove_all(f.root)
    delete(f.root)
}

// Whether a step of the history holds a row or the life of e.
@(private="file")
sections_step_has :: proc(step:^Edit_Step,e:core.Entity) -> bool {
    for rows in step.tables {
        if slice.contains(rows.entities[:],e) {return true}
    }
    return slice.contains(step.entities.indices[:],u32(core.entity_index(e)))
}

@(test)
a_section_turned_on_or_off_in_the_view_is_no_edit_and_its_reference_keeps_what_it_asks :: proc(t:^testing.T) {
    f:=new(Sections_Fixture)
    defer free(f)
    if !testing.expect(t,sections_fixture_init(f,"view",.Unloaded)) {return}
    defer sections_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    testing.expect_value(t,section_shown(s,w,f.r),Section_Shown.Unloaded)
    testing.expect_value(t,section_view_set(s,w,f.r,.Active),"")
    state,overridden:=section_view(s,w,f.r)
    testing.expect(t,overridden && state==.Active)
    testing.expect_value(t,section_shown(s,w,f.r),Section_Shown.Loading)
    // scene_sections reads the view over the reference, which keeps what it asks.
    reference:=core.get(&f.world.references,f.r)
    testing.expect_value(t,scene.section_wanted(&f.world.views,f.r,reference^),scene.Section_State.Active)
    sections_watch(s,&f.watch,w)
    c:=sections_test_entity(f,SECTIONS_TEST_LOCAL,"Crate",f.r,{1,0,0})
    reference.loaded=f.x
    core.world_settle(w)
    sections_watched(s,&f.watch,w)
    reference=core.get(&f.world.references,f.r)
    testing.expect(t,reference.state==.Unloaded && reference.rule==.Manual,"the reference keeps what it asks")
    testing.expect_value(t,section_shown(s,w,f.r),Section_Shown.Active)
    testing.expect(t,!edits_commit(&f.edits,w,&f.selection) && f.edits.error==.No_Change,"what the section loaded is no step")
    testing.expect(t,!document_dirty(s))
    // An edit of the user after it holds only its own rows.
    testing.expect(t,transform_set(s,f.a,{{3,0,0},1,{1,1,1}}))
    testing.expect(t,edits_commit(&f.edits,w,&f.selection))
    testing.expect_value(t,len(f.edits.steps),1)
    testing.expect(t,!sections_step_has(&f.edits.steps[0],c),"the step does not hold the section")
    testing.expect(t,undo(&f.edits,w,&f.selection))
    testing.expect(t,entity_alive(w,c) && entity_local(w,f.a).position==[3]f32{0,0,0})
    // Off: it goes, outside the undo too.
    testing.expect_value(t,section_view_set(s,w,f.r,.Unloaded),"")
    sections_watch(s,&f.watch,w)
    core.world_destroy_tree(w,c)
    core.get(&f.world.references,f.r).loaded={}
    core.world_settle(w)
    sections_watched(s,&f.watch,w)
    testing.expect(t,!entity_alive(w,c))
    testing.expect(t,!edits_commit(&f.edits,w,&f.selection) && f.edits.error==.No_Change,"what the section dropped is no step")
    // Auto gives it back to its reference; the view rules over what a Spatial one streams too.
    testing.expect_value(t,section_view_set(s,w,f.r,.Active,true),"")
    _,overridden=section_view(s,w,f.r)
    testing.expect(t,!overridden && len(f.world.views.items)==0)
    core.get(&f.world.references,f.r).rule=.Spatial
    edits_reset(&f.edits,w)
    testing.expect_value(t,section_view_set(s,w,f.r,.Loaded),"")
    sections_watch(s,&f.watch,w)
    sections_watched(s,&f.watch,w)
    reference=core.get(&f.world.references,f.r)
    testing.expect(t,reference.rule==.Spatial && reference.state==.Unloaded && reference.streamed==.Active)
    testing.expect_value(t,scene.section_wanted(&f.world.views,f.r,reference^),scene.Section_State.Loaded)
    testing.expect(t,!edits_commit(&f.edits,w,&f.selection) && f.edits.error==.No_Change)
    // Play starts with what the references ask.
    s.mode=.Play
    testing.expect(t,section_view_set(s,w,f.r,.Active)!="")
}

@(test)
an_entity_of_a_section_reads_only_on_every_path_with_an_error_that_names_the_section :: proc(t:^testing.T) {
    f:=new(Sections_Fixture)
    defer free(f)
    if !testing.expect(t,sections_fixture_init(f,"lock")) {return}
    defer sections_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    toast :: proc(s:^Session) -> string {return string(s.toast[:s.toast_length])}
    testing.expect(t,!transform_set(s,f.c,{{5,0,0},1,{1,1,1}}))
    testing.expect(t,strings.contains(toast(s),"section Layer"),toast(s))
    testing.expect(t,!entity_rename(s,f.c,"Box"))
    entities_delete(s,{f.c})
    testing.expect(t,entity_alive(w,f.c))
    testing.expect(t,len(entities_duplicate(s,{f.c}))==0)
    testing.expect(t,!entity_reparent(s,f.a,f.c) && !entity_reparent(s,f.a,f.r),"nothing goes into a section")
    testing.expect(t,entity_create(s,{name="Inside",parent=f.c})==core.NONE)
    testing.expect(t,selection_section_locked(s,w)==false)
    selection_set(&f.selection,{f.c})
    testing.expect(t,selection_section_locked(s,w),"the gizmo is off")
    testing.expect(t,!edits_commit(&f.edits,w,&f.selection) && len(f.edits.steps)==0)
    // scene.set and scene.delete fail saying it is of a section.
    out:serial.Writer;serial.writer_init(&out);defer serial.writer_destroy(&out)
    call:=api.Call{raw=fmt.tprintf(`{{"entity":"0x%016x","position":[1,2,3]}}`,u64(SECTIONS_TEST_LOCAL)),out=&out,allocator=context.temp_allocator}
    a:Rpc_Args
    rpc_init(&a,&call,call.raw)
    _,applied:=api_set_apply(s,&a,w)
    testing.expect(t,!applied && call.failed && strings.contains(call.error.message,"section Layer") && !strings.contains(call.error.message,"prefab"),call.error.message)
    removal:=api.Call{out=&out,allocator=context.temp_allocator}
    testing.expect(t,!api_delete_apply(s,&removal,w,api_entity(w,SECTIONS_TEST_LOCAL)) && strings.contains(removal.error.message,"section"),removal.error.message)
    testing.expect_value(t,entity_local(w,f.c).position,[3]f32{1,0,0})
    // Edited in its world, the section is edited and the rest reads only; what is added goes inside it.
    section_edit_set(s,f.r)
    testing.expect(t,transform_set(s,f.c,{{5,0,0},1,{1,1,1}}))
    testing.expect(t,!transform_set(s,f.a,{{5,0,0},1,{1,1,1}}))
    testing.expect(t,strings.contains(toast(s),"outside the section Layer"),toast(s))
    inside:=entity_create(s,{name="Inside"})
    core.world_settle(w)
    testing.expect_value(t,entity_parent(w,inside),f.r)
    testing.expect(t,edits_commit(&f.edits,w,&f.selection))
    _,overridden:=section_view(s,w,f.r)
    testing.expect(t,overridden && section_view_set(s,w,f.r,.Unloaded)!="","the section edited stays on")
    // Deleted with its reference, what a section holds goes with it.
    section_edit_set(s,core.NONE)
    entities_delete(s,{f.r,f.c})
    core.world_settle(w)
    testing.expect(t,!entity_alive(w,f.r) && !entity_alive(w,f.c))
}

@(test)
the_camera_travels_to_a_section_and_turns_it_on_in_the_view :: proc(t:^testing.T) {
    f:=new(Sections_Fixture)
    defer free(f)
    if !testing.expect(t,sections_fixture_init(f,"travel",.Unloaded)) {return}
    defer sections_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    testing.expect_value(t,section_travel(s,w,f.r),"")
    state,overridden:=section_view(s,w,f.r)
    testing.expect(t,overridden && state==.Active,"it loads in the view")
    o:=f.viewport.orbit
    center:=[3]f32{100,-40,50}
    testing.expect(t,linalg.length(o.target-center)<15 && o.distance>10 && o.distance<SECTION_TRAVEL_DISTANCE,fmt.tprint(o))
    testing.expect(t,!edits_commit(&f.edits,w,&f.selection) && f.edits.error==.No_Change,"travel is no edit")
    // Into a big one, at its middle.
    core.get(&f.world.references,f.r).extents={2000,300,2000}
    testing.expect_value(t,section_travel(s,w,f.r),"")
    testing.expect(t,f.viewport.orbit.target==center && f.viewport.orbit.distance==SECTION_TRAVEL_DISTANCE)
    // One its reference asks on needs nothing of the view.
    testing.expect_value(t,section_view_set(s,w,f.r,.Active,true),"")
    core.get(&f.world.references,f.r).state=.Active
    testing.expect_value(t,section_travel(s,w,f.r),"")
    testing.expect_value(t,len(f.world.views.items),0)
}

@(test)
save_writes_each_section_edited_in_its_world_that_changed_and_stays_unsaved_when_one_cannot_be :: proc(t:^testing.T) {
    f:=new(Sections_Fixture)
    defer free(f)
    if !testing.expect(t,sections_fixture_init(f,"save")) {return}
    defer sections_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    file:=fmt.tprintf("%s/layer.scene",f.root)
    // Another reference to the same scene shows what is saved, outside the undo.
    other:=sections_test_entity(f,3,"Layer again",core.NONE,{0,40,0})
    core.add(&f.world.references,other,scene.Scene_Reference{scene=f.x,loaded=f.x})
    core.world_settle(w)
    edits_reset(&f.edits,w)
    section_edit_set(s,f.r)
    testing.expect(t,transform_set(s,f.c,{{7,0,0},1,{1,1,1}}))
    testing.expect(t,edits_commit(&f.edits,w,&f.selection))
    steps:=len(f.edits.steps)
    testing.expect_value(t,scene_save(s,"world.scene"),Document_Error.None)
    testing.expect(t,!document_dirty(s),"saved, the document is clean")
    testing.expect_value(t,len(f.edits.steps),steps)
    saved:asset.Scene
    testing.expect_value(t,asset.scene_load(&saved,&f.assets.types,file),asset.Error.None)
    placed,found:=asset.scene_get(&saved,SECTIONS_TEST_LOCAL,"Transform",core.Transform)
    testing.expect(t,found && placed.position==[3]f32{7,0,0},"the scene of the section holds the change")
    stamp:=saved.stamp
    asset.scene_destroy(&saved)
    children:=entity_children(w,other)
    testing.expect(t,len(children)==1 && entity_local(w,children[0]).position==[3]f32{7,0,0},"the other reference shows it")
    // Unchanged, it is not written again.
    before,_:=os.stat(file,context.temp_allocator)
    testing.expect_value(t,scene_save(s,"world.scene"),Document_Error.None)
    after,_:=os.stat(file,context.temp_allocator)
    testing.expect(t,before.modification_time==after.modification_time)
    // Left with a change, the next Save still writes it.
    testing.expect(t,transform_set(s,f.c,{{9,0,0},1,{1,1,1}}))
    testing.expect(t,edits_commit(&f.edits,w,&f.selection))
    section_edit_set(s,core.NONE)
    testing.expect(t,strings.contains(string(s.toast[:s.toast_length]),"keeps its unsaved changes"))
    testing.expect_value(t,scene_save(s,"world.scene"),Document_Error.None)
    testing.expect(t,asset.scene_load(&saved,&f.assets.types,file)==.None && saved.stamp!=stamp)
    placed,_=asset.scene_get(&saved,SECTIONS_TEST_LOCAL,"Transform",core.Transform)
    testing.expect_value(t,placed.position,[3]f32{9,0,0})
    asset.scene_destroy(&saved)
    // A section that cannot be written leaves the document unsaved.
    section_edit_set(s,f.r)
    testing.expect(t,transform_set(s,f.c,{{11,0,0},1,{1,1,1}}))
    testing.expect(t,edits_commit(&f.edits,w,&f.selection))
    core.get(&f.world.references,f.r).held=true
    testing.expect_value(t,scene_save(s,"world.scene"),Document_Error.None)
    testing.expect(t,document_dirty(s),"a section not written keeps the document unsaved")
    testing.expect(t,strings.contains(string(s.toast[:s.toast_length]),"was not saved"))
    // A scene referenced as a section does not turn into a prefab.
    _,why:=asset_convert(s,f.x)
    testing.expect(t,strings.contains(why,"section"),why)
}

@(test)
the_map_shows_each_section_by_its_box_and_the_api_reads_it_and_turns_it_in_the_view :: proc(t:^testing.T) {
    f:=new(Sections_Fixture)
    defer free(f)
    if !testing.expect(t,sections_fixture_init(f,"map")) {return}
    defer sections_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    m:World_Map
    defer core.value_free(&m,type_info_of(World_Map))
    // From above a box turned around the vertical is its four corners; from a side, its height down the map.
    turned:=core.get(&f.world.transforms,f.r)
    turned.rotation=quaternion(x=0,y=0.38268343,z=0,w=0.9238795)
    world_map_gather(s,&m,w)
    testing.expect_value(t,len(m.items),1)
    item:=m.items[0]
    testing.expect_value(t,item.count,4)
    testing.expect(t,hull_contains(item.outline[:item.count],{100,50}) && !hull_contains(item.outline[:item.count],{109,59}),"the middle is inside and a corner turned away is not")
    m.view=.Side
    world_map_gather(s,&m,w)
    item=m.items[0]
    low,high:=item.outline[0],item.outline[0]
    for p in item.outline[1:item.count] {low,high=linalg.min(low,p),linalg.max(high,p)}
    testing.expect(t,abs(low.y-35)<1e-3 && abs(high.y-45)<1e-3,"its height, 40 m down, spans 10 m")
    testing.expect_value(t,item.shown,Section_Shown.Active)
    // The API turns it off in the view, and says so.
    out:serial.Writer;serial.writer_init(&out);defer serial.writer_destroy(&out)
    server:=api.Server{max_response=1<<16}
    method:=api.Method{params_id=Api_Section_View_Params}
    params:Api_Section_View_Params;copy(params.entity[:],"0000000000000002")
    base.text_set(params.state[:],"Off")
    call:=api.Call{server=&server,method=&method,params=&params,out=&out,allocator=context.temp_allocator}
    api_section_view(s,&call)
    testing.expect(t,call.failed && strings.contains(call.error.message,"Unloaded"),call.error.message)
    base.text_set(params.state[:],"Unloaded")
    call=api.Call{server=&server,method=&method,params=&params,out=&out,allocator=context.temp_allocator}
    api_section_view(s,&call)
    testing.expect(t,!call.failed && strings.contains(string(serial.writer_bytes(&out)),`"view":"Unloaded"`),string(serial.writer_bytes(&out)))
    serial.writer_reset(&out)
    listing:=api.Call{server=&server,out=&out,allocator=context.temp_allocator}
    api_sections(s,&listing)
    text:=string(serial.writer_bytes(&out))
    testing.expect(t,!listing.failed && strings.contains(text,`"name":"Layer"`) && strings.contains(text,`"rule":"Manual"`) && strings.contains(text,`"entities":1`),text)
}

@(test)
a_reference_a_step_makes_loads_in_that_step_and_what_hangs_from_a_reference_gone_goes_with_it :: proc(t:^testing.T) {
    f:=new(Sections_Fixture)
    defer free(f)
    if !testing.expect(t,sections_fixture_init(f,"made",.Unloaded)) {return}
    defer sections_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    // A paste: until its step, scene_sections is asked to leave it; the step loads it.
    opened,ready:=edit_open(s,"Paste")
    testing.expect(t,ready)
    pasted:=entity_create(s,{name="Pasted"})
    core.add(&f.world.references,pasted,scene.Scene_Reference{scene=f.x,rule=.Manual})
    edit_close(s,opened)
    core.world_settle(w)
    sections_watch(s,&f.watch,w)
    testing.expect_value(t,scene.section_wanted(&f.world.views,pasted,core.get(&f.world.references,pasted)^),scene.Section_State.Unloaded)
    sections_watched(s,&f.watch,w)
    testing.expect_value(t,core.get(&f.world.references,pasted).state,scene.Section_State.Active)
    _,overridden:=section_view(s,w,pasted)
    testing.expect(t,!overridden,"waiting for its step is no view of the user")
    sections_sync(s)
    testing.expect(t,edits_commit(&f.edits,w,&f.selection))
    core.world_settle(w)
    loaded:=entity_children(w,pasted)
    testing.expect(t,len(loaded)==1 && core.get(&f.world.references,pasted).loaded==f.x,"the step loaded it")
    sections_watch(s,&f.watch,w)
    sections_watched(s,&f.watch,w)
    testing.expect(t,len(f.world.views.items)==0 && len(f.watch.made)==0,"after its step the view gives it back")
    crate:=loaded[0] if len(loaded)>0 else core.NONE
    testing.expect(t,undo(&f.edits,w,&f.selection))
    testing.expect(t,!entity_alive(w,pasted) && !entity_alive(w,crate),"its undo takes both")
    testing.expect(t,redo(&f.edits,w,&f.selection))
    pasted=api_entity(w,api_entity_id(w,pasted))
    // A reference that goes outside the undo takes what hangs from it, outside the undo too.
    sections_watch(s,&f.watch,w)
    sections_watched(s,&f.watch,w)
    hung:=sections_test_entity(f,0x99,"Crate",f.r,{})
    core.get(&f.world.references,f.r).loaded=f.x
    core.world_settle(w)
    edits_reset(&f.edits,w)
    core.destroy(core.world_entities(w),f.r)
    core.world_settle(w)
    testing.expect(t,entity_alive(w,hung))
    sections_watch(s,&f.watch,w)
    sections_watched(s,&f.watch,w)
    testing.expect(t,!entity_alive(w,hung),"what hung from it goes with it")
}

@(test)
what_a_library_derives_in_edit_is_no_part_of_the_next_step :: proc(t:^testing.T) {
    f:=new(Sections_Fixture)
    defer free(f)
    if !testing.expect(t,sections_fixture_init(f,"derived")) {return}
    defer sections_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    edits_reset(&f.edits,w)
    // A library moves the entity in Edit, as a Bone_Attachment does, and the journal takes it.
    core.get(&f.world.transforms,f.a).position={0,2,0}
    edits_take_derived(&f.edits,w,core.Transform,f.a)
    testing.expect(t,!edits_commit(&f.edits,w,&f.selection) && f.edits.error==.No_Change,"what a library derived is no step")
    // An edit of the user stays a step, and its undo goes back to where the library put it.
    testing.expect(t,transform_set(s,f.a,{{3,0,0},1,{1,1,1}}))
    testing.expect(t,edits_commit(&f.edits,w,&f.selection))
    testing.expect(t,undo(&f.edits,w,&f.selection))
    testing.expect_value(t,entity_local(w,f.a).position,[3]f32{0,2,0})
    // While a gesture is open what changed is the user's, and the journal does not take it.
    opened,ready:=edit_open(s,"Transform")
    testing.expect(t,ready)
    core.get(&f.world.transforms,f.a).position={5,0,0}
    edits_take_derived(&f.edits,w,core.Transform,f.a)
    edit_close(s,opened)
    testing.expect(t,edits_commit(&f.edits,w,&f.selection),"the edit inside the gesture stays a step")
}

@(test)
what_a_section_load_resolves_in_the_document_is_no_part_of_the_next_step :: proc(t:^testing.T) {
    f:=new(Sections_Fixture)
    defer free(f)
    if !testing.expect(t,sections_fixture_init(f,"resolved")) {return}
    defer sections_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    // A names the crate of the section, which is not loaded yet.
    core.add(&f.world.links,f.a,Sections_Link{})
    core.world_settle(w)
    edits_reset(&f.edits,w)
    links_table:=-1
    for info,i in w.info.tables {if info.type==Sections_Link {links_table=i}}
    append(&f.world.unresolved.items,scene.Unresolved_Reference{entity=f.a,table=base.name_hash("Sections_Link"),offset=0,target=SECTIONS_TEST_LOCAL})
    // The section loads and the resolve gives the field its entity.
    scene.references_resolve(w)
    link,_:=core.get(core.read(&f.world.links),f.a)
    testing.expect_value(t,link.target,f.c)
    testing.expect_value(t,len(f.world.unresolved.resolved),1)
    sections_resolved(s,w)
    testing.expect(t,!edits_commit(&f.edits,w,&f.selection) && f.edits.error==.No_Change,"what the load resolved is no step")
    // The next edit of the user holds only its own rows, and its undo keeps the field.
    testing.expect(t,transform_set(s,f.a,{{3,0,0},1,{1,1,1}}))
    testing.expect(t,edits_commit(&f.edits,w,&f.selection))
    testing.expect_value(t,len(f.edits.steps),1)
    for rows in f.edits.steps[0].tables {
        testing.expect(t,rows.table!=links_table,"the step does not hold the field the load resolved")
    }
    testing.expect(t,undo(&f.edits,w,&f.selection))
    link,_=core.get(core.read(&f.world.links),f.a)
    testing.expect(t,link.target==f.c && entity_local(w,f.a).position==[3]f32{0,0,0})
    // Once taken, the same resolve is not taken again over an edit of the user.
    core.get(&f.world.links,f.a).target=f.r
    sections_resolved(s,w)
    testing.expect(t,edits_commit(&f.edits,w,&f.selection),"the edit of the user stays a step")
    // The drop of the section gives the field none back, outside the undo too.
    core.get(&f.world.links,f.a).target=f.c
    testing.expect(t,edits_commit(&f.edits,w,&f.selection))
    steps:=len(f.edits.steps)
    inside:=make([]bool,int(core.entity_index(f.c))+1,context.temp_allocator)
    inside[core.entity_index(f.c)]=true
    scene.references_release(w,inside,nil)
    link,_=core.get(core.read(&f.world.links),f.a)
    testing.expect_value(t,link.target,core.NONE)
    sections_resolved(s,w)
    testing.expect(t,!edits_commit(&f.edits,w,&f.selection) && f.edits.error==.No_Change,"what the drop released is no step")
    testing.expect_value(t,len(f.edits.steps),steps)
}
