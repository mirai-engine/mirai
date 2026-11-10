package editor

import "base:runtime"

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import erender "mirai:engine/render"
import scene "mirai:engine/scene"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

Prefab_Test_World :: struct {
    entities:core.Entities,
    ids:core.Table(core.Id),
    names:core.Table(core.Name),
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    disabled:core.Table(core.Disabled),
    lamps:core.Table(Prefab_Test_Lamp),
    point_lights:core.Table(erender.Point_Light),
    instances:core.Table(scene.Prefab_Instance),
    members:core.Table(scene.Prefab_Member),
    hierarchy:core.Hierarchy,
}

// A component a scene saves and the API writes.
Prefab_Test_Lamp :: struct {intensity,range:f32,target:core.Entity,uses:u32 `mirai:"hidden"`}

prefab_test_clear :: proc(data:rawptr) -> bool {
    w:=cast(^Prefab_Test_World)data
    core.table_clear(&w.ids)
    core.table_clear(&w.names)
    core.table_clear(&w.transforms)
    core.table_clear(&w.parents)
    core.table_clear(&w.disabled)
    core.table_clear(&w.lamps)
    core.table_clear(&w.point_lights)
    core.table_clear(&w.instances)
    core.table_clear(&w.members)
    core.hierarchy_clear(&w.hierarchy)
    return core.entities_clear(&w.entities)
}

prefab_test_init :: proc(data:rawptr,allocator:runtime.Allocator) -> bool {
    context.allocator=allocator
    w:=cast(^Prefab_Test_World)data
    core.entities_init(&w.entities)
    core.table_init(&w.ids,"Id")
    core.table_init(&w.names,"Name")
    core.table_init(&w.transforms,"Transform")
    core.table_init(&w.parents,"Parent")
    core.table_init(&w.disabled,"Disabled")
    core.table_init(&w.lamps,"Prefab_Test_Lamp")
    core.table_init(&w.point_lights,"Point_Light")
    core.table_init(&w.instances,"Prefab_Instance")
    core.table_init(&w.members,"Prefab_Member")
    w.ids.base,w.names.base,w.transforms.base,w.parents.base,w.disabled.base=true,true,true,true,true
    return len(w.entities.generation)>0
}

prefab_test_destroy :: proc(data:rawptr) {
    w:=cast(^Prefab_Test_World)data
    core.entities_destroy(&w.entities)
    core.table_destroy(&w.ids)
    core.table_destroy(&w.names)
    core.table_destroy(&w.transforms)
    core.table_destroy(&w.parents)
    core.table_destroy(&w.disabled)
    core.table_destroy(&w.lamps)
    core.table_destroy(&w.point_lights)
    core.table_destroy(&w.instances)
    core.table_destroy(&w.members)
    core.value_free(&w.hierarchy,type_info_of(core.Hierarchy))
}

prefab_test_copy :: proc(dst,src:rawptr) -> bool {
    dst,src:=cast(^Prefab_Test_World)dst,cast(^Prefab_Test_World)src
    return core.entities_copy(&dst.entities,&src.entities) && core.table_copy(&dst.ids,&src.ids) && core.table_copy(&dst.names,&src.names) && core.table_copy(&dst.transforms,&src.transforms) && core.table_copy(&dst.parents,&src.parents) && core.table_copy(&dst.disabled,&src.disabled) && core.table_copy(&dst.lamps,&src.lamps) && core.table_copy(&dst.point_lights,&src.point_lights) && core.table_copy(&dst.instances,&src.instances) && core.table_copy(&dst.members,&src.members) && core.value_copy(&dst.hierarchy,&src.hierarchy,type_info_of(core.Hierarchy))
}

prefab_test_swap :: proc(a,b:rawptr) {
    a,b:=(^Prefab_Test_World)(a),(^Prefab_Test_World)(b)
    a.entities,b.entities=b.entities,a.entities
    core.table_swap(&a.ids,&b.ids);core.table_swap(&a.names,&b.names);core.table_swap(&a.transforms,&b.transforms);core.table_swap(&a.parents,&b.parents);core.table_swap(&a.disabled,&b.disabled);core.table_swap(&a.lamps,&b.lamps);core.table_swap(&a.point_lights,&b.point_lights);core.table_swap(&a.instances,&b.instances);core.table_swap(&a.members,&b.members)
    a.hierarchy,b.hierarchy=b.hierarchy,a.hierarchy
}

// A session over Prefab_Test_World with an assets folder of its own. It
// stays where prefab_fixture_init found it.
@(private)
Prefab_Fixture :: struct {
    world:Prefab_Test_World,
    tables:[9]core.Table_Info,
    storages:[4]core.Storage_Info,
    info:core.World_Info,
    assets:host.Assets,
    app:host.App,
    viewport:Viewport,
    selection:Selection,
    inspector:Inspector,
    edits:Edits,
    document:Document,
    using editor:Prefab_Fixture_Editor,
    outliner:Outliner,
    g:Editor_Ui,
    ai:Ai,
    root:string,
    s:Session,
}

@(private)
prefab_fixture_init :: proc(f:^Prefab_Fixture,name:string) -> bool {
    f.tables={
        {name="Id",type=core.Id,info=type_info_of(core.Id),offset=offset_of(Prefab_Test_World,ids)},
        {name="Name",type=core.Name,info=type_info_of(core.Name),offset=offset_of(Prefab_Test_World,names)},
        {name="Transform",type=core.Transform,info=type_info_of(core.Transform),offset=offset_of(Prefab_Test_World,transforms)},
        {name="Parent",type=core.Parent,info=type_info_of(core.Parent),offset=offset_of(Prefab_Test_World,parents)},
        {name="Disabled",type=core.Disabled,info=type_info_of(core.Disabled),offset=offset_of(Prefab_Test_World,disabled)},
        {name="Prefab_Test_Lamp",type=Prefab_Test_Lamp,info=type_info_of(Prefab_Test_Lamp),offset=offset_of(Prefab_Test_World,lamps)},
        {name="Point_Light",type=erender.Point_Light,info=type_info_of(erender.Point_Light),offset=offset_of(Prefab_Test_World,point_lights)},
        {name="Prefab_Instance",type=scene.Prefab_Instance,info=type_info_of(scene.Prefab_Instance),offset=offset_of(Prefab_Test_World,instances)},
        {name="Prefab_Member",type=scene.Prefab_Member,info=type_info_of(scene.Prefab_Member),offset=offset_of(Prefab_Test_World,members)},
    }
    f.storages={{type=Prefabs,place=.Editor,offset=offset_of(Prefab_Fixture_Editor,prefabs)},{type=core.Hierarchy,info=type_info_of(core.Hierarchy),offset=offset_of(Prefab_Test_World,hierarchy)},
        {type=Collab,place=.Editor,offset=offset_of(Prefab_Fixture_Editor,collab)},{name="Api",type=Api,info=type_info_of(Api),place=.Editor,offset=offset_of(Prefab_Fixture_Editor,api)}}
    f.info=core.World_Info{tables=f.tables[:],storages=f.storages[:],clear=prefab_test_clear,copy=prefab_test_copy,swap=prefab_test_swap,
        sizes={.World=size_of(Prefab_Test_World),.Shared=0,.Editor=0},aligns={.World=align_of(Prefab_Test_World),.Shared=1,.Editor=1},
        init={.World=prefab_test_init,.Shared=nil,.Editor=nil},destroy={.World=prefab_test_destroy,.Shared=nil,.Editor=nil}}
    prefab_test_init(&f.world,context.allocator)
    f.root=project.path_absolute(fmt.tprintf(".mirai/test-prefabs-%s-%d",name,os.get_pid()))
    os.remove_all(f.root)
    if os.make_directory_all(f.root)!=nil {return false}
    asset.types_init(&f.assets.types)
    asset.registry_init(&f.assets.registry,f.root)
    f.app=host.App{assets=&f.assets,info=&f.info,allocator=context.allocator}
    f.s=Session{info=&f.info,edit_world=&f.world,editor_world=&f.editor,assets_root=f.root,app=&f.app,gui=&f.g,viewport=&f.viewport,selection=&f.selection,inspector=&f.inspector,edits=&f.edits,document=&f.document,outliner=&f.outliner,ai=&f.ai}
    return true
}

@(private)
prefab_fixture_destroy :: proc(f:^Prefab_Fixture) {
    prefabs_free(&f.s)
    document_previous_free(&f.document)
    edits_free(&f.edits)
    core.value_free(&f.inspector,type_info_of(Inspector))
    delete(f.selection.entities)
    delete(f.app.worlds)
    asset.registry_destroy(&f.assets.registry)
    asset.types_destroy(&f.assets.types)
    prefab_test_destroy(&f.world)
    os.remove_all(f.root)
    delete(f.root)
}

@(private)
Prefab_Fixture_Editor :: struct {prefabs:Prefabs,collab:Collab,api:Api}

// Commits what was edited, as the end of a frame does.
@(private)
prefab_fixture_step :: proc(f:^Prefab_Fixture) {
    edits_commit(&f.edits,edited_world(&f.s),&f.selection)
}

@(private="file")
prefab_fixture_find :: proc(f:^Prefab_Fixture,id:base.Entity_Id) -> core.Entity {
    return api_entity(edited_world(&f.s),id)
}

// A crate with a lid and a lamp on it that looks at the lid.
@(private)
prefab_test_crate :: proc(f:^Prefab_Fixture,parent:=core.NONE) -> (crate,lid,lamp:core.Entity) {
    s:=&f.s
    crate=entity_create(s,{name="Crate",named=true,parent=parent})
    lid=entity_create(s,{name="Lid",named=true,parent=crate})
    lamp=entity_create(s,{name="Lamp",named=true,parent=lid})
    core.add(&f.world.lamps,lamp,Prefab_Test_Lamp{intensity=2,range=3,target=lid})
    core.world_settle(edited_world(s))
    return
}

// The member of an instance with a name; NONE without one.
@(private)
prefab_test_named :: proc(f:^Prefab_Fixture,root:core.Entity,name:string) -> core.Entity {
    w:=edited_world(&f.s)
    for member in prefab_members(w,root) {
        if entity_name(w,member.entity)==name {return member.entity}
    }
    return core.NONE
}

// Whether the instance of root holds an override of an entity: component "" is the entity itself.
@(private)
prefab_test_has :: proc(f:^Prefab_Fixture,root,e:core.Entity,component:string,kind:asset.Override_Kind,path:string) -> bool {
    overrides,_:=prefab_overrides_of(&f.s,root)
    id:=api_entity_id(edited_world(&f.s),e)
    hash:=component==""?0:base.name_hash(component)
    for &override in overrides {
        if override.entity==id && override.component==hash && override.kind==kind && prefab_override_text(&override)==path {return true}
    }
    return false
}

// An edit of the lamp of an entity, as one step.
@(private="file")
lamp_set :: proc(f:^Prefab_Fixture,e:core.Entity,intensity:f32) {
    value,_:=core.get(core.read(&f.world.lamps),e)
    value.intensity=intensity
    core.add(&f.world.lamps,e,value)
    core.world_settle(edited_world(&f.s))
    prefab_fixture_step(f)
}

@(private="file")
lamp_of :: proc(f:^Prefab_Fixture,e:core.Entity) -> Prefab_Test_Lamp {
    value,_:=core.get(core.read(&f.world.lamps),e)
    return value
}

// The lamp of a prefab file becomes another, as a change made outside the editor.
@(private="file")
lamp_file_set :: proc(t:^testing.T,f:^Prefab_Fixture,file:string,lamp:base.Entity_Id,intensity,range:f32) -> bool {
    edited:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&edited,&f.assets.types,file),asset.Error.None) {return false}
    defer asset.scene_destroy(&edited)
    value,_:=asset.scene_get(&edited,lamp,"Prefab_Test_Lamp",Prefab_Test_Lamp)
    value.intensity,value.range=intensity,range
    asset.scene_set(&edited,lamp,"Prefab_Test_Lamp",&value)
    if !testing.expect_value(t,asset.scene_save(&edited,file),asset.Error.None) {return false}
    _=asset.registry_scan(&f.assets.registry)
    return true
}

@(test)
a_prefab_operation_is_one_step_of_the_rows_of_its_instance :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    if !testing.expect(t,prefab_fixture_init(f,"steps")) {return}
    defer prefab_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    other:=entity_create(s,{name="Other",named=true})
    crate,_,lamp:=prefab_test_crate(f)
    edits_reset(&f.edits,w)

    // Creating: the entities stay, linked, and the prefab is an unsaved file of the step.
    id,created:=prefab_create(s,crate,"crate")
    if !testing.expect_value(t,created,Prefab_Error.None) {return}
    file:=scene_file(s,"crate.prefab")
    testing.expect(t,!os.exists(file) && file_exists(s,file),"the prefab waits for Save in memory")
    of_crate,_:=prefab_link_of(w,crate)
    of_lamp,linked:=prefab_link_of(w,lamp)
    testing.expect(t,of_crate.root && of_crate.asset==id && linked && !of_lamp.root && of_lamp.instance==crate && of_lamp.source==api_entity_id(w,lamp))
    testing.expect(t,len(f.edits.steps)==1 && len(f.edits.steps[0].files)==1)

    // Placing: new entities, and a step that holds their rows alone.
    placed,instantiated:=prefab_instantiate(s,id,{position={4,0,0}})
    root:=api_entity(w,placed)
    if !testing.expect(t,instantiated==.None && root!=core.NONE) {return}
    testing.expect(t,len(f.edits.steps)==2 && entity_alive(w,other) && entity_alive(w,crate) && entity_local(w,root).position==[3]f32{4,0,0})
    members:=prefab_members(w,root)
    testing.expect_value(t,len(members),3)
    inside:=make(map[core.Entity]bool,context.temp_allocator)
    for member in members {inside[member.entity]=true}
    for &rows in f.edits.steps[1].tables {
        for e in rows.entities {testing.expect(t,inside[e],"a row of the step is of the instance")}
    }
    testing.expect(t,lamp_of(f,prefab_test_named(f,root,"Lamp")).target==prefab_test_named(f,root,"Lid"),"the references of a member name the members")

    // The history carries the instance as it carries any row.
    testing.expect(t,undo(&f.edits,w,&f.selection))
    testing.expect(t,!entity_alive(w,root) && core.count(&f.world.instances)==1 && core.count(&f.world.members)==3)
    testing.expect(t,redo(&f.edits,w,&f.selection))
    again:=api_entity(w,placed)
    of_again,_:=prefab_link_of(w,again)
    testing.expect(t,again!=core.NONE && of_again.root && of_again.asset==id && len(prefab_members(w,again))==3)
    // Undoing the creation takes the link and the file with it.
    testing.expect(t,undo(&f.edits,w,&f.selection) && undo(&f.edits,w,&f.selection))
    files_settle(s)
    _,still:=prefab_link_of(w,crate)
    testing.expect(t,!still && entity_alive(w,crate) && !file_exists(s,file))
}

@(test)
the_overrides_of_an_instance_are_derived_reverted_and_applied_without_writing_files :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    if !testing.expect(t,prefab_fixture_init(f,"overrides")) {return}
    defer prefab_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    crate,_,lamp:=prefab_test_crate(f)
    edits_reset(&f.edits,w)
    id,created:=prefab_create(s,crate,"crate")
    if !testing.expect_value(t,created,Prefab_Error.None) {return}
    file:=scene_file(s,"crate.prefab")
    placed,_:=prefab_instantiate(s,id,{})
    root:=api_entity(w,placed)
    copy,lid:=prefab_test_named(f,root,"Lamp"),prefab_test_named(f,root,"Lid")
    none,known:=prefab_overrides_of(s,root)
    testing.expect(t,known && len(none)==0)

    lamp_set(f,copy,9)
    testing.expect(t,prefab_test_has(f,root,copy,"Prefab_Test_Lamp",.Field,"intensity"))
    _,unknown:=prefab_revert(s,copy,{"Prefab_Test_Lamp.range"})
    testing.expect_value(t,unknown,Prefab_Error.Unknown_Path)
    reverted,revert_error:=prefab_revert(s,copy,nil)
    testing.expect(t,revert_error==.None && reverted==1 && lamp_of(f,copy).intensity==2)

    // A value and an entity added, applied: every instance follows and the file stays in memory.
    lamp_set(f,copy,7)
    sticker:=entity_create(s,{name="Sticker",named=true,parent=lid})
    core.world_settle(w)
    prefab_fixture_step(f)
    testing.expect(t,prefab_test_has(f,root,sticker,"",.Child,"") && prefab_test_has(f,root,copy,"Prefab_Test_Lamp",.Field,"intensity"))
    read,_:=file_read(s,file)
    before:=strings.clone(string(read),context.temp_allocator)
    applied,apply_error:=prefab_apply(s,root,nil,true)
    testing.expect(t,apply_error==.None && applied==2)
    testing.expect(t,lamp_of(f,lamp).intensity==7 && prefab_test_named(f,crate,"Sticker")!=core.NONE && !os.exists(file))
    of_sticker,member:=prefab_link_of(w,sticker)
    left,_:=prefab_overrides_of(s,root)
    testing.expect(t,member && of_sticker.instance==root && len(left)==0,"what was applied is the prefab's, and the entity added a member")
    registered,_,_:=prefab_file(s,id)
    first,_:=core.get(core.read(&f.world.instances),crate)
    second,_:=core.get(core.read(&f.world.instances),root)
    testing.expect(t,first.stamp==registered.content_hash && second.stamp==registered.content_hash)

    // Undone, the instances and the file are as before it; done again, as after.
    testing.expect(t,undo(&f.edits,w,&f.selection))
    files_settle(s)
    read,_=file_read(s,file)
    testing.expect(t,lamp_of(f,lamp).intensity==2 && prefab_test_named(f,crate,"Sticker")==core.NONE && string(read)==before)
    testing.expect(t,prefab_test_has(f,root,sticker,"",.Child,"") && lamp_of(f,copy).intensity==7)
    testing.expect(t,redo(&f.edits,w,&f.selection))
    files_settle(s)
    testing.expect(t,lamp_of(f,lamp).intensity==7 && prefab_test_named(f,crate,"Sticker")!=core.NONE)

    // Save writes it.
    _,saved:=assets_save_all(s)
    testing.expect(t,saved && os.exists(file))
}

@(test)
unlinking_gives_back_what_a_prefab_placed_and_a_variant_applies_to_its_base :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    if !testing.expect(t,prefab_fixture_init(f,"nested")) {return}
    defer prefab_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    yard:=entity_create(s,{name="Yard",named=true})
    crate,_,lamp:=prefab_test_crate(f,yard)
    lamp_id:=api_entity_id(w,lamp)
    edits_reset(&f.edits,w)
    crate_id,_:=prefab_create(s,crate,"crate")
    yard_id,created:=prefab_create(s,yard,"yard")
    if !testing.expect_value(t,created,Prefab_Error.None) {return}
    // The crate is of the yard now: the scene holds one instance, and the yard's file the other.
    of_crate,_:=prefab_link_of(w,crate)
    testing.expect(t,core.count(&f.world.instances)==1 && of_crate.instance==yard && !of_crate.root && prefab_contains(s,yard_id,crate_id))

    testing.expect_value(t,prefab_unlink(s,yard,false),Prefab_Error.None)
    of_crate,_=prefab_link_of(w,crate)
    of_lamp,_:=prefab_link_of(w,lamp)
    _,yard_linked:=prefab_link_of(w,yard)
    testing.expect(t,!yard_linked && of_crate.root && of_crate.asset==crate_id && of_lamp.instance==crate && of_lamp.source==lamp_id)
    testing.expect(t,core.count(&f.world.instances)==1 && core.count(&f.world.members)==3)
    testing.expect(t,undo(&f.edits,w,&f.selection))
    of_crate,_=prefab_link_of(w,crate)
    testing.expect(t,of_crate.instance==yard && core.count(&f.world.members)==4)
    testing.expect_value(t,prefab_unlink(s,crate,true),Prefab_Error.None)
    testing.expect(t,core.count(&f.world.instances)==0 && core.count(&f.world.members)==0)

    // A variant of the crate: what an instance of it changes goes through it into the crate.
    variant,made:=prefab_variant_create(s,crate_id,"crate_red")
    chain:=prefab_variant_chain(s,variant)
    testing.expect(t,made==.None && file_exists(s,scene_file(s,"crate_red.prefab")) && len(chain)==1 && chain[0]==crate_id)
    placed,instantiated:=prefab_instantiate(s,variant,{})
    root:=api_entity(w,placed)
    if !testing.expect(t,instantiated==.None && root!=core.NONE) {return}
    link,_:=prefab_link_of(w,root)
    testing.expect_value(t,prefab_variant_of(s,w,link),crate_id)
    lamp_set(f,prefab_test_named(f,root,"Lamp"),5)
    _,plain:=prefab_apply(s,crate,nil,true,.Base)
    testing.expect_value(t,plain,Prefab_Error.Not_Instance)
    applied,apply_error:=prefab_apply(s,root,nil,true,.Base)
    testing.expect(t,apply_error==.None && applied==1)
    loaded,found:=prefab_scene_load(s,crate_id)
    if !testing.expect(t,found) {return}
    defer prefab_scene_free(loaded)
    in_base,_:=asset.scene_get(loaded,lamp_id,"Prefab_Test_Lamp",Prefab_Test_Lamp)
    testing.expect_value(t,in_base.intensity,f32(5))
    left,known:=prefab_overrides_of(s,root)
    testing.expect(t,known && len(left)==0)
}

@(test)
a_scene_opened_after_its_prefab_changed_follows_it_and_keeps_what_its_instances_set :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    if !testing.expect(t,prefab_fixture_init(f,"reopen")) {return}
    defer prefab_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    crate,_,lamp:=prefab_test_crate(f)
    edits_reset(&f.edits,w)
    id,created:=prefab_create(s,crate,"crate")
    if !testing.expect_value(t,created,Prefab_Error.None) {return}
    placed,_:=prefab_instantiate(s,id,{})
    copy:=prefab_test_named(f,api_entity(w,placed),"Lamp")
    lamp_set(f,copy,9)
    lamp_id,copy_id:=api_entity_id(w,lamp),api_entity_id(w,copy)
    testing.expect_value(t,scene_save(s,"level.scene"),Document_Error.None)
    _,saved:=assets_save_all(s)
    testing.expect(t,saved)

    if !lamp_file_set(t,f,scene_file(s,"crate.prefab"),lamp_id,5,8) {return}
    stale:=0
    for state in prefab_instances(s) {stale+=int(state.stale)}
    testing.expect_value(t,stale,2)

    testing.expect_value(t,scene_open(s,"level.scene"),Document_Error.None)
    testing.expect(t,len(f.edits.steps)==0 && !document_dirty(s),"the instances were brought up to date before the World took them")
    first,second:=lamp_of(f,api_entity(w,lamp_id)),lamp_of(f,api_entity(w,copy_id))
    testing.expect(t,first.intensity==5 && first.range==8 && second.intensity==9 && second.range==8,"what the instance set stays over the new file")
    for state in prefab_instances(s) {testing.expect(t,!state.stale)}
    root:=api_entity(w,placed)
    overrides,known:=prefab_overrides_of(s,root)
    testing.expect(t,known && len(overrides)==1 && prefab_test_has(f,root,api_entity(w,copy_id),"Prefab_Test_Lamp",.Field,"intensity"))
}

@(test)
an_instance_whose_base_is_not_held_keeps_what_it_has_when_it_is_refreshed :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    if !testing.expect(t,prefab_fixture_init(f,"unknown")) {return}
    defer prefab_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    crate,_,lamp:=prefab_test_crate(f)
    edits_reset(&f.edits,w)
    id,created:=prefab_create(s,crate,"crate")
    if !testing.expect_value(t,created,Prefab_Error.None) {return}
    _,saved:=assets_save_all(s)
    testing.expect(t,saved)
    placed,_:=prefab_instantiate(s,id,{})
    root:=api_entity(w,placed)
    copy:=prefab_test_named(f,root,"Lamp")
    lamp_set(f,copy,9)

    // The file is another, and this editor never held the one the instances were made with.
    if !lamp_file_set(t,f,scene_file(s,"crate.prefab"),api_entity_id(w,lamp),5,8) {return}
    prefabs_state_free(&f.prefabs)
    _,known:=prefab_overrides_of(s,root)
    testing.expect(t,!known,"nothing says what the instance set")
    report,refreshed:=prefab_refresh(s,{})
    testing.expect(t,refreshed==.None && report.prefabs==1 && report.instances==2 && report.failed==0)
    testing.expect(t,lamp_of(f,copy).intensity==9 && lamp_of(f,copy).range==3 && lamp_of(f,lamp).intensity==2,"what differs from the file stays")
    registered,_,_:=prefab_file(s,id)
    instance,_:=core.get(core.read(&f.world.instances),root)
    testing.expect_value(t,instance.stamp,registered.content_hash)
    _,known=prefab_overrides_of(s,root)
    testing.expect(t,known && prefab_test_has(f,root,copy,"Prefab_Test_Lamp",.Field,"range") && prefab_test_has(f,root,copy,"Prefab_Test_Lamp",.Field,"intensity"))
    again,_:=prefab_refresh(s,{})
    testing.expect_value(t,again.instances,0)
}

@(test)
a_copy_of_an_instance_is_another_and_a_member_keeps_its_place :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    if !testing.expect(t,prefab_fixture_init(f,"copies")) {return}
    defer prefab_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    crate,lid,lamp:=prefab_test_crate(f)
    edits_reset(&f.edits,w)
    id,created:=prefab_create(s,crate,"crate")
    if !testing.expect_value(t,created,Prefab_Error.None) {return}

    whole:=entities_duplicate(s,{crate})
    core.world_settle(w)
    if !testing.expect_value(t,len(whole),1) {return}
    link,linked:=prefab_link_of(w,whole[0])
    testing.expect(t,linked && link.root && link.asset==id && len(prefab_members(w,whole[0]))==3 && core.count(&f.world.instances)==2)
    testing.expect(t,lamp_of(f,prefab_test_named(f,whole[0],"Lamp")).target==prefab_test_named(f,whole[0],"Lid"))

    one:=entities_duplicate(s,{lamp})
    core.world_settle(w)
    prefab_fixture_step(f)
    if !testing.expect_value(t,len(one),1) {return}
    _,member:=prefab_link_of(w,one[0])
    testing.expect(t,!member && entity_parent(w,one[0])==lid && prefab_test_has(f,crate,one[0],"",.Child,""),"the copy of a member is an entity its instance added")

    testing.expect(t,prefab_member_locked(s,w,lamp) && !prefab_member_locked(s,w,crate) && !prefab_member_locked(s,w,one[0]))
    testing.expect(t,!entity_reparent(s,lamp,core.NONE) && entity_parent(w,lamp)==lid)
    _,locked:=prefab_create(s,lamp,"lamp")
    testing.expect_value(t,locked,Prefab_Error.Member_Locked)
}

// The editors of a shared session, each over its own copy of the assets.
@(private="file")
prefab_collab_join :: proc(f:^Prefab_Fixture,role:Collab_Role) {
    w:=edited_world(&f.s)
    core.world_settle(w)
    edits_reset(&f.edits,w)
    st:=new(Collab_State)
    st.role,st.phase,st.self=role,.Joined,role==.Host?0:1
    st.peers[role==.Host?1:0].used=true
    st.peers[1].joined=true
    collab_tables_build(&f.s,st)
    collab_journal_reset(&f.s,st)
    f.collab.state=st
}

@(private="file")
prefab_collab_leave :: proc(f:^Prefab_Fixture) {
    st:=f.collab.state
    for &peer in st.peers {
        for message in peer.out {delete(message)}
        delete(peer.out);delete(peer.file_bytes)
    }
    for path in st.files_out {delete(path)}
    delete(st.files_out)
    collab_tables_free(st)
    journal_reading(&f.edits,false)
    free(st)
    f.collab.state=nil
}

// An update of the session at one end, and what it queued for its peer
// arriving at the other in order.
@(private="file")
prefab_collab_send :: proc(f,to:^Prefab_Fixture) {
    st:=f.collab.state
    collab_edits_send(&f.s,st)
    collab_files_send(&f.s,st)
    peer:=&st.peers[st.role==.Host?1:0]
    for message in peer.out {
        collab_receive(&to.s,to.collab.state,st.role==.Host?-1:1,message,0)
        delete(message)
    }
    clear(&peer.out)
}

// The instances of one editor reach the others as the rows of their entities,
// and the prefab an operation wrote as an unsaved file: nothing else travels.
@(test)
prefab_instances_travel_a_session_as_rows_and_their_prefab_as_an_unsaved_file :: proc(t:^testing.T) {
    host:=new(Prefab_Fixture);defer free(host)
    if !testing.expect(t,prefab_fixture_init(host,"collab-host")) {return}
    defer prefab_fixture_destroy(host)
    guest:=new(Prefab_Fixture);defer free(guest)
    if !testing.expect(t,prefab_fixture_init(guest,"collab-guest")) {return}
    defer prefab_fixture_destroy(guest)
    prefab_collab_join(host,.Host)
    defer prefab_collab_leave(host)
    prefab_collab_join(guest,.Guest)
    defer prefab_collab_leave(guest)
    hw,gw:=edited_world(&host.s),edited_world(&guest.s)

    crate,_,_:=prefab_test_crate(host)
    prefab_fixture_step(host)
    crate_id:=api_entity_id(hw,crate)
    prefab_collab_send(host,guest)
    testing.expect(t,prefab_fixture_find(guest,crate_id)!=core.NONE)

    id,created:=prefab_create(&host.s,crate,"group")
    if !testing.expect_value(t,created,Prefab_Error.None) {return}
    prefab_collab_send(host,guest)
    there:=prefab_fixture_find(guest,crate_id)
    link,linked:=prefab_link_of(gw,there)
    file:=scene_file(&guest.s,"group.prefab")
    testing.expect(t,linked && link.root && link.asset==id && core.count(&guest.world.members)==3)
    testing.expect(t,file_exists(&guest.s,file) && !os.exists(file),"the prefab came as an unsaved file")
    _,known:=prefab_overrides_of(&guest.s,there)
    testing.expect(t,known,"the guest compares its instance with the prefab it received")

    // An instance placed there: its entities and the rows that name its root arrive in one update.
    placed,instantiated:=prefab_instantiate(&host.s,id,{position={2,0,0}})
    if !testing.expect_value(t,instantiated,Prefab_Error.None) {return}
    prefab_collab_send(host,guest)
    root:=prefab_fixture_find(guest,placed)
    testing.expect(t,root!=core.NONE && len(prefab_members(gw,root))==3 && core.count(&guest.world.instances)==2,"each member names the root made with it")

    // The host applies what a guest did and sends it back to it; an undo there goes the same way.
    testing.expect_value(t,prefab_unlink(&guest.s,there,false),Prefab_Error.None)
    prefab_collab_send(guest,host)
    testing.expect(t,core.count(&host.world.instances)==1 && core.count(&host.world.members)==3)
    prefab_collab_send(host,guest)
    move:=history_undo(&guest.s)
    testing.expect(t,move.done && move.error=="",move.error)
    prefab_fixture_step(guest)
    prefab_collab_send(guest,host)
    prefab_collab_send(host,guest)
    testing.expect(t,core.count(&host.world.instances)==2 && core.count(&host.world.members)==6 && core.count(&guest.world.instances)==2)
}

@(test)
an_asset_is_named_by_its_path_with_or_without_its_extension_or_by_its_id :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    if !testing.expect(t,prefab_fixture_init(f,"asset-resolve")) {return}
    defer prefab_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    root:=entity_create(s,{name="Crate",named=true})
    core.world_settle(w)
    edits_reset(&f.edits,w)
    crate,created:=prefab_create(s,root,"crate")
    if !testing.expect_value(t,created,Prefab_Error.None) {return}
    _=asset.registry_scan(&f.assets.registry)
    b:=strings.builder_make(context.temp_allocator)
    fmt.sbprintf(&b,"%016x%016x",crate[0],crate[1])
    id:=strings.to_string(b)
    cases:=[?]struct{name,kinds,says:string}{
        {"crate.prefab",".prefab",""},
        {"crate",".prefab",""},
        {"crate","",""},
        {id,".prefab",""},
        {"crat",".prefab","crate.prefab"},
        {"prefabs/crat",".prefab","crate.prefab"},
        {"crate",".mesh","no .mesh"},
    }
    for c in cases {
        got,problem:=asset_resolve(s,c.name,c.kinds)
        testing.expectf(t,(c.says=="")==(problem=="") && strings.contains(problem,c.says),"%s: %s",c.name,problem)
        if c.says=="" {testing.expect_value(t,got,crate)}
    }
}
