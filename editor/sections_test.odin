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
import "mirai:editor/history"
import scene "mirai:engine/scene"
import "mirai:host"
import "mirai:std/base"

@(private)
@(test_world,editor="Sections_Editor")
Sections_World :: struct {
    using world:Test_World,
    using scene_tables:Test_Scene,
    references:core.Table(scene.Scene_Reference),
    links:core.Table(Sections_Link),
    views:scene.Section_Views,
    unresolved:scene.Unresolved_References,
}

// A component of the document that names an entity.
@(private)
Sections_Link :: struct {target:core.Entity}

@(private)
Sections_Editor :: struct {prefabs:Prefabs}

// A scene with a root entity A and a section, R, of the scene X whose
// entity C hangs from it, over an assets folder that holds X.
@(private="file")
Sections_Fixture :: struct {
    world:Sections_World,
    info:core.World_Info,
    assets:host.Assets,
    app:host.App,
    using edited:Test_Session,
    inspector:Inspector,
    editor:Sections_Editor,
    outliner:Outliner,
    ai:Ai,
    watch:Sections_Watch,
    root:string,
    a,r,c:core.Entity,
    x:base.Asset_Id,
}

SECTIONS_TEST_X :: base.Asset_Id{0x5ec7,0x1}
SECTIONS_TEST_LOCAL :: base.Entity_Id(0xc0)

@(private="file")
sections_fixture_init :: proc(t:^testing.T,f:^Sections_Fixture,name:string,state:=scene.Section_State.Active) -> bool {
    w:=&f.world
    f.info=test_info(t,Sections_World) or_return
    if !core.world_init(&f.info,.World,w,context.allocator) {return false}
    f.root=base.test_folder(t,fmt.tprintf("sections-%s",name))
    if f.root=="" {return false}
    // The scene of the section: one entity, as it was saved before.
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    f.x=SECTIONS_TEST_X
    x:asset.Scene
    if asset.scene_init(&x,&types,f.x)!=.None {return false}
    asset.scene_entity_add(&x,SECTIONS_TEST_LOCAL,0,"Crate")
    saved:=asset.scene_save(&x,fmt.tprintf("%s/layer.scene",f.root))
    asset.scene_destroy(&x)
    if saved!=.None {return false}
    if !host.assets_init(&f.assets,{root=f.root,capacity=8}) {return false}
    host.assets_scan(&f.assets)
    f.app=host.App{assets=&f.assets,info=&f.info,allocator=context.allocator}
    f.viewport.size,f.viewport.window,f.viewport.orbit={1280,720},{1280,720},ORBIT_DEFAULT
    f.a=sections_test_entity(f,1,"A",core.NONE,{0,0,0})
    f.r=sections_test_entity(f,2,"Layer",core.NONE,{100,-40,50})
    core.add(&w.references,f.r,scene.Scene_Reference{scene=f.x,extents={10,5,10},rule=.Manual,state=state,loaded=state==.Unloaded?{}:f.x})
    if state!=.Unloaded {f.c=sections_test_entity(f,SECTIONS_TEST_LOCAL,"Crate",f.r,{1,0,0})}
    core.settle(&f.info,w,nil)
    test_session_open(&f.edited,core.world_ref(w,&f.info))
    f.s.editor_world,f.s.assets_root,f.s.app,f.s.inspector,f.s.outliner,f.s.ai=&f.editor,f.root,&f.app,&f.inspector,&f.outliner,&f.ai
    f.document.saved=history.edits_scene_state(&f.edits)
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
    test_session_close(&f.edited)
    core.value_free(&f.inspector,type_info_of(Inspector))
    core.value_free(&f.watch,type_info_of(Sections_Watch))
    delete(f.app.worlds)
    host.assets_destroy(&f.assets)
    core.world_destroy(&f.info,.World,&f.world)
    test_info_destroy(&f.info)
}

// Whether a step of the history holds a row or the life of e.
@(private="file")
sections_step_has :: proc(step:^history.Edit_Step,e:core.Entity) -> bool {
    for rows in step.tables {
        if slice.contains(rows.entities[:],e) {return true}
    }
    return slice.contains(step.entities.indices[:],u32(core.entity_index(e)))
}

@(test)
a_section_turned_on_or_off_in_the_view_is_no_edit_and_its_reference_keeps_what_it_asks :: proc(t:^testing.T) {
    f:=new(Sections_Fixture)
    defer free(f)
    if !testing.expect(t,sections_fixture_init(t,f,"view",.Unloaded)) {return}
    defer sections_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    testing.expect_value(t,section_shown(s,w,f.r),Section_Shown.Unloaded)
    testing.expect_value(t,section_view_set(s,w,f.r,.Active),"")
    state,overridden:=section_view(s,w,f.r)
    testing.expect(t,overridden && state==.Active)
    testing.expect_value(t,section_shown(s,w,f.r),Section_Shown.Loading)
    // scene_sections reads the view over the reference, which keeps what it asks.
    reference:=core.edit(&f.world.references,f.r)
    testing.expect_value(t,scene.section_wanted(&f.world.views,f.r,reference^),scene.Section_State.Active)
    sections_watch(s,&f.watch,w)
    c:=sections_test_entity(f,SECTIONS_TEST_LOCAL,"Crate",f.r,{1,0,0})
    reference.loaded=f.x
    core.world_settle(w)
    sections_watched(s,&f.watch,w)
    reference=core.edit(&f.world.references,f.r)
    testing.expect(t,reference.state==.Unloaded && reference.rule==.Manual,"the reference keeps what it asks")
    testing.expect_value(t,section_shown(s,w,f.r),Section_Shown.Active)
    testing.expect(t,!history.edits_commit(&f.edits,w,&f.selection) && f.edits.error==.No_Change,"what the section loaded is no step")
    testing.expect(t,!document_dirty(s))
    // An edit of the user after it holds only its own rows.
    testing.expect(t,transform_set(s,f.a,{{3,0,0},1,{1,1,1}}))
    testing.expect(t,history.edits_commit(&f.edits,w,&f.selection))
    testing.expect_value(t,len(f.edits.steps),1)
    testing.expect(t,!sections_step_has(&f.edits.steps[0],c),"the step does not hold the section")
    testing.expect(t,history.undo(&f.edits,w,&f.selection))
    testing.expect(t,entity_alive(w,c) && entity_local(w,f.a).position==[3]f32{0,0,0})
    // Off: it goes, outside the undo too.
    testing.expect_value(t,section_view_set(s,w,f.r,.Unloaded),"")
    sections_watch(s,&f.watch,w)
    core.world_destroy_tree(w,c)
    core.edit(&f.world.references,f.r).loaded={}
    core.world_settle(w)
    sections_watched(s,&f.watch,w)
    testing.expect(t,!entity_alive(w,c))
    testing.expect(t,!history.edits_commit(&f.edits,w,&f.selection) && f.edits.error==.No_Change,"what the section dropped is no step")
    // Auto gives it back to its reference; the view rules over what a Spatial one streams too.
    testing.expect_value(t,section_view_set(s,w,f.r,.Active,true),"")
    _,overridden=section_view(s,w,f.r)
    testing.expect(t,!overridden && len(f.world.views.items)==0)
    core.edit(&f.world.references,f.r).rule=.Spatial
    history.edits_reset(&f.edits,w)
    testing.expect_value(t,section_view_set(s,w,f.r,.Loaded),"")
    sections_watch(s,&f.watch,w)
    sections_watched(s,&f.watch,w)
    reference=core.edit(&f.world.references,f.r)
    testing.expect(t,reference.rule==.Spatial && reference.state==.Unloaded && reference.streamed==.Active)
    testing.expect_value(t,scene.section_wanted(&f.world.views,f.r,reference^),scene.Section_State.Loaded)
    testing.expect(t,!history.edits_commit(&f.edits,w,&f.selection) && f.edits.error==.No_Change)
    // Play starts with what the references ask.
    s.mode=.Play
    testing.expect(t,section_view_set(s,w,f.r,.Active)!="")
}

@(test)
an_entity_of_a_section_reads_only_on_every_path_with_an_error_that_names_the_section :: proc(t:^testing.T) {
    f:=new(Sections_Fixture)
    defer free(f)
    if !testing.expect(t,sections_fixture_init(t,f,"lock")) {return}
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
    history.selection_set(&f.selection,{f.c})
    testing.expect(t,selection_section_locked(s,w),"the gizmo is off")
    testing.expect(t,!history.edits_commit(&f.edits,w,&f.selection) && len(f.edits.steps)==0)
    // scene.write fails saying it is of a section, named as root or by id.
    state:Api_State
    surface:=Api{state=&state}
    s.api=&surface
    api_schema_build(s,&state)
    defer {api_schema_free(&state);s.api=nil}
    for document in ([]string{`{{"root":"0x%016x","merge":true,"entities":[{{"position":[1,2,3]}}]}}`,`{{"merge":true,"entities":[{{"id":"0x%016x","delete":true}}]}}`}) {
        method:=api.Method{result_id=Api_Write_Result}
        result:Api_Write_Result
        call:=api.Call{method=&method,result=&result,raw=fmt.tprintf(document,u64(SECTIONS_TEST_LOCAL)),allocator=context.temp_allocator}
        api_scene_write(s,&call)
        testing.expect(t,call.failed && strings.contains(call.error.message,"section Layer") && !strings.contains(call.error.message,"prefab"),call.error.message)
    }
    testing.expect_value(t,entity_local(w,f.c).position,[3]f32{1,0,0})
    // Edited in its world, the section is edited and the rest reads only; what is added goes inside it.
    section_edit_set(s,f.r)
    testing.expect(t,transform_set(s,f.c,{{5,0,0},1,{1,1,1}}))
    testing.expect(t,!transform_set(s,f.a,{{5,0,0},1,{1,1,1}}))
    testing.expect(t,strings.contains(toast(s),"outside the section Layer"),toast(s))
    inside:=entity_create(s,{name="Inside"})
    core.world_settle(w)
    testing.expect_value(t,entity_parent(w,inside),f.r)
    testing.expect(t,history.edits_commit(&f.edits,w,&f.selection))
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
    if !testing.expect(t,sections_fixture_init(t,f,"travel",.Unloaded)) {return}
    defer sections_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    testing.expect_value(t,section_travel(s,w,f.r),"")
    state,overridden:=section_view(s,w,f.r)
    testing.expect(t,overridden && state==.Active,"it loads in the view")
    o:=f.viewport.orbit
    center:=[3]f32{100,-40,50}
    testing.expect(t,linalg.length(o.target-center)<15 && o.distance>10 && o.distance<SECTION_TRAVEL_DISTANCE,fmt.tprint(o))
    testing.expect(t,!history.edits_commit(&f.edits,w,&f.selection) && f.edits.error==.No_Change,"travel is no edit")
    // Into a big one, at its middle.
    core.edit(&f.world.references,f.r).extents={2000,300,2000}
    testing.expect_value(t,section_travel(s,w,f.r),"")
    testing.expect(t,f.viewport.orbit.target==center && f.viewport.orbit.distance==SECTION_TRAVEL_DISTANCE)
    // One its reference asks on needs nothing of the view.
    testing.expect_value(t,section_view_set(s,w,f.r,.Active,true),"")
    core.edit(&f.world.references,f.r).state=.Active
    testing.expect_value(t,section_travel(s,w,f.r),"")
    testing.expect_value(t,len(f.world.views.items),0)
}

@(test)
save_writes_each_section_edited_in_its_world_that_changed_and_stays_unsaved_when_one_cannot_be :: proc(t:^testing.T) {
    f:=new(Sections_Fixture)
    defer free(f)
    if !testing.expect(t,sections_fixture_init(t,f,"save")) {return}
    defer sections_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    file:=fmt.tprintf("%s/layer.scene",f.root)
    // Another reference to the same scene shows what is saved, outside the undo.
    other:=sections_test_entity(f,3,"Layer again",core.NONE,{0,40,0})
    core.add(&f.world.references,other,scene.Scene_Reference{scene=f.x,loaded=f.x})
    core.world_settle(w)
    history.edits_reset(&f.edits,w)
    section_edit_set(s,f.r)
    testing.expect(t,transform_set(s,f.c,{{7,0,0},1,{1,1,1}}))
    testing.expect(t,history.edits_commit(&f.edits,w,&f.selection))
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
    testing.expect(t,history.edits_commit(&f.edits,w,&f.selection))
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
    testing.expect(t,history.edits_commit(&f.edits,w,&f.selection))
    core.edit(&f.world.references,f.r).held=true
    testing.expect_value(t,scene_save(s,"world.scene"),Document_Error.None)
    testing.expect(t,document_dirty(s),"a section not written keeps the document unsaved")
    testing.expect(t,strings.contains(string(s.toast[:s.toast_length]),"was not saved"))
}

@(test)
the_map_shows_each_section_by_its_box_and_the_api_reads_it_and_turns_it_in_the_view :: proc(t:^testing.T) {
    f:=new(Sections_Fixture)
    defer free(f)
    if !testing.expect(t,sections_fixture_init(t,f,"map")) {return}
    defer sections_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    m:World_Map
    defer core.value_free(&m,type_info_of(World_Map))
    // From above a box turned around the vertical is its four corners; from a side, its height down the map.
    turned:=core.edit(&f.world.transforms,f.r)
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
    server:=api.Server{max_response=1<<16}
    method:=api.Method{params_id=Api_Section_View_Params,result_id=Api_Section}
    params:Api_Section_View_Params;copy(params.entity[:],"0000000000000002")
    base.text_set(params.state[:],"Off")
    viewed:Api_Section
    call:=api.Call{server=&server,method=&method,params=&params,result=&viewed,allocator=context.temp_allocator}
    api_section_view(s,&call)
    testing.expect(t,call.failed && strings.contains(call.error.message,"Unloaded"),call.error.message)
    base.text_set(params.state[:],"Unloaded")
    call=api.Call{server=&server,method=&method,params=&params,result=&viewed,allocator=context.temp_allocator}
    api_section_view(s,&call)
    testing.expect(t,!call.failed && viewed.view=="Unloaded",viewed.view)
    listed:Api_Sections_Result
    listing_method:=api.Method{result_id=Api_Sections_Result}
    listing:=api.Call{server=&server,method=&listing_method,result=&listed,allocator=context.temp_allocator}
    api_sections(s,&listing)
    testing.expect(t,!listing.failed && len(listed.sections)==1 && listed.sections[0].name=="Layer" && listed.sections[0].rule==.Manual && listed.sections[0].cost.entities==1)
}

@(test)
a_reference_a_step_makes_loads_in_that_step_and_what_hangs_from_a_reference_gone_goes_with_it :: proc(t:^testing.T) {
    f:=new(Sections_Fixture)
    defer free(f)
    if !testing.expect(t,sections_fixture_init(t,f,"made",.Unloaded)) {return}
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
    testing.expect_value(t,scene.section_wanted(&f.world.views,pasted,core.at(&f.world.references,core.row_of(&f.world.references,pasted))),scene.Section_State.Unloaded)
    sections_watched(s,&f.watch,w)
    testing.expect_value(t,core.at(&f.world.references,core.row_of(&f.world.references,pasted)).state,scene.Section_State.Active)
    _,overridden:=section_view(s,w,pasted)
    testing.expect(t,!overridden,"waiting for its step is no view of the user")
    sections_sync(s)
    testing.expect(t,history.edits_commit(&f.edits,w,&f.selection))
    core.world_settle(w)
    loaded:=entity_children(w,pasted)
    testing.expect(t,len(loaded)==1 && core.at(&f.world.references,core.row_of(&f.world.references,pasted)).loaded==f.x,"the step loaded it")
    sections_watch(s,&f.watch,w)
    sections_watched(s,&f.watch,w)
    testing.expect(t,len(f.world.views.items)==0 && len(f.watch.made)==0,"after its step the view gives it back")
    crate:=loaded[0] if len(loaded)>0 else core.NONE
    testing.expect(t,history.undo(&f.edits,w,&f.selection))
    testing.expect(t,!entity_alive(w,pasted) && !entity_alive(w,crate),"its undo takes both")
    testing.expect(t,history.redo(&f.edits,w,&f.selection))
    pasted=api_entity(w,api_entity_id(w,pasted))
    // A reference that goes outside the undo takes what hangs from it, outside the undo too.
    sections_watch(s,&f.watch,w)
    sections_watched(s,&f.watch,w)
    hung:=sections_test_entity(f,0x99,"Crate",f.r,{})
    core.edit(&f.world.references,f.r).loaded=f.x
    core.world_settle(w)
    history.edits_reset(&f.edits,w)
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
    if !testing.expect(t,sections_fixture_init(t,f,"derived")) {return}
    defer sections_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    history.edits_reset(&f.edits,w)
    // A library moves the entity in Edit, as a Bone_Attachment does, and the journal takes it.
    core.edit(&f.world.transforms,f.a).position={0,2,0}
    history.edits_take_derived(&f.edits,w,core.Transform,f.a)
    testing.expect(t,!history.edits_commit(&f.edits,w,&f.selection) && f.edits.error==.No_Change,"what a library derived is no step")
    // An edit of the user stays a step, and its undo goes back to where the library put it.
    testing.expect(t,transform_set(s,f.a,{{3,0,0},1,{1,1,1}}))
    testing.expect(t,history.edits_commit(&f.edits,w,&f.selection))
    testing.expect(t,history.undo(&f.edits,w,&f.selection))
    testing.expect_value(t,entity_local(w,f.a).position,[3]f32{0,2,0})
    // While a gesture is open what changed is the user's, and the journal does not take it.
    opened,ready:=edit_open(s,"Transform")
    testing.expect(t,ready)
    core.edit(&f.world.transforms,f.a).position={5,0,0}
    history.edits_take_derived(&f.edits,w,core.Transform,f.a)
    edit_close(s,opened)
    testing.expect(t,history.edits_commit(&f.edits,w,&f.selection),"the edit inside the gesture stays a step")
}

@(test)
what_a_section_load_resolves_in_the_document_is_no_part_of_the_next_step :: proc(t:^testing.T) {
    f:=new(Sections_Fixture)
    defer free(f)
    if !testing.expect(t,sections_fixture_init(t,f,"resolved")) {return}
    defer sections_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    // A names the crate of the section, which is not loaded yet.
    core.add(&f.world.links,f.a,Sections_Link{})
    core.world_settle(w)
    history.edits_reset(&f.edits,w)
    links_table:=-1
    for info,i in w.info.tables {if info.type==Sections_Link {links_table=i}}
    append(&f.world.unresolved.items,scene.Unresolved_Reference{entity=f.a,table=base.name_hash("Sections_Link"),offset=0,target=SECTIONS_TEST_LOCAL})
    // The section loads and the resolve gives the field its entity.
    scene.references_resolve(w)
    link,_:=core.get(&f.world.links,f.a)
    testing.expect_value(t,link.target,f.c)
    testing.expect_value(t,len(f.world.unresolved.resolved),1)
    sections_resolved(s,w)
    testing.expect(t,!history.edits_commit(&f.edits,w,&f.selection) && f.edits.error==.No_Change,"what the load resolved is no step")
    // The next edit of the user holds only its own rows, and its undo keeps the field.
    testing.expect(t,transform_set(s,f.a,{{3,0,0},1,{1,1,1}}))
    testing.expect(t,history.edits_commit(&f.edits,w,&f.selection))
    testing.expect_value(t,len(f.edits.steps),1)
    for rows in f.edits.steps[0].tables {
        testing.expect(t,rows.table!=links_table,"the step does not hold the field the load resolved")
    }
    testing.expect(t,history.undo(&f.edits,w,&f.selection))
    link,_=core.get(&f.world.links,f.a)
    testing.expect(t,link.target==f.c && entity_local(w,f.a).position==[3]f32{0,0,0})
    // Once taken, the same resolve is not taken again over an edit of the user.
    core.edit(&f.world.links,f.a).target=f.r
    sections_resolved(s,w)
    testing.expect(t,history.edits_commit(&f.edits,w,&f.selection),"the edit of the user stays a step")
    // The drop of the section gives the field none back, outside the undo too.
    core.edit(&f.world.links,f.a).target=f.c
    testing.expect(t,history.edits_commit(&f.edits,w,&f.selection))
    steps:=len(f.edits.steps)
    inside:=make([]bool,int(core.entity_index(f.c))+1,context.temp_allocator)
    inside[core.entity_index(f.c)]=true
    scene.references_release(w,inside,nil)
    link,_=core.get(&f.world.links,f.a)
    testing.expect_value(t,link.target,core.NONE)
    sections_resolved(s,w)
    testing.expect(t,!history.edits_commit(&f.edits,w,&f.selection) && f.edits.error==.No_Change,"what the drop released is no step")
    testing.expect_value(t,len(f.edits.steps),steps)
}
