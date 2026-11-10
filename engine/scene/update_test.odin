package scene

import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:std/base"

@(private="file") Update_Lamp :: struct {range:f32,heat:f32 `mirai:"transient"`}
@(private="file") Update_Link :: struct {target:core.Entity}

@(private="file")
Update_World :: struct {
    using world:core.Test_World,
    ids:core.Table(core.Id),
    names:core.Table(core.Name),
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    disabled:core.Table(core.Disabled),
    lamps:core.Table(Update_Lamp),
    links:core.Table(Update_Link),
    instances:core.Table(Prefab_Instance),
    members:core.Table(Prefab_Member),
    hierarchy:core.Hierarchy,
}

@(private="file")
Update_Fixture :: struct {
    w:Update_World,
    types:asset.Types,
}

@(private="file")
update_fixture_init :: proc(t:^testing.T,f:^Update_Fixture) -> (ref:core.World_Ref,ok:bool) {
    core.test_world_init(t,&f.w,test_types) or_return
    asset.types_init(&f.types)
    return core.test_world_ref(&f.w),true
}

@(private="file")
update_fixture_destroy :: proc(f:^Update_Fixture) {
    asset.types_destroy(&f.types)
    core.test_world_destroy(&f.w)
}

@(private="file")
update_entity :: proc(w:^Update_World,id:base.Entity_Id,name:string,parent:core.Entity) -> core.Entity {
    e:=core.create(&w.entities)
    label:core.Name
    copy(label.text[:len(label.text)-1],name)
    core.add(&w.ids,e,core.Id{id})
    core.add(&w.names,e,label)
    core.add(&w.transforms,e,core.TRANSFORM_IDENTITY)
    if parent!=core.NONE {core.add(&w.parents,e,core.Parent{entity=parent})}
    return e
}

// The document written onto the world, and the world settled.
@(private="file")
update_put :: proc(t:^testing.T,f:^Update_Fixture,ref:core.World_Ref,document:^asset.Scene,scope:[]base.Entity_Id) -> (report:Report,error:Error) {
    data,bytes_error:=asset.scene_bytes(document,context.temp_allocator)
    testing.expect_value(t,bytes_error,asset.Error.None)
    file:asset.Asset
    testing.expect_value(t,asset.asset_open(&file,data),asset.Error.None)
    defer asset.asset_close(&file)
    report,error=update(ref,&file,&f.types,{scope=scope})
    core.test_world_settle(&f.w)
    return
}

@(test)
an_update_writes_what_differs_onto_the_entities_that_have_the_ids_of_a_document :: proc(t:^testing.T) {
    f:Update_Fixture
    ref,made:=update_fixture_init(t,&f)
    if !made {return}
    defer update_fixture_destroy(&f)
    w:=&f.w
    other:=update_entity(w,9,"Other",core.NONE)
    room:=update_entity(w,1,"Room",core.NONE)
    lamp:=update_entity(w,2,"Lamp",room)
    bulb:=update_entity(w,3,"Bulb",lamp)
    cable:=update_entity(w,4,"Cable",bulb)
    core.add(&w.lamps,bulb,Update_Lamp{range=1,heat=7})
    core.add(&w.links,bulb,Update_Link{other})
    core.add(&w.links,lamp,Update_Link{bulb})
    core.test_world_settle(w)

    // A capture written back changes nothing, and what it names outside stays named.
    document:asset.Scene
    _,captured:=capture(ref,&document,&f.types,{root=room,outside=true,id={7,7}})
    testing.expect_value(t,captured,Error.None)
    defer asset.scene_destroy(&document)
    outside,_:=asset.scene_get(&document,3,"Update_Link",Update_Link)
    testing.expect_value(t,base.Entity_Id(outside.target),base.Entity_Id(9))
    scope:=[]base.Entity_Id{1,2,3,4}
    alive:=w.entities.alive
    report,error:=update_put(t,&f,ref,&document,scope)
    testing.expect(t,error==.None && report.components==0 && report.entities==4 && w.entities.alive==alive)

    // The document changes a value, a name and a component, turns one off, adds an entity and drops another.
    light:=Update_Lamp{range=5}
    asset.scene_set(&document,3,"Update_Lamp",&light)
    asset.scene_component_turn(&document,3,base.name_hash("Update_Lamp"),true)
    asset.scene_entity_rename(&document,2,"Desk lamp")
    links,_:=asset.scene_component(&document,"Update_Link")
    asset.scene_component_remove(&document,links,2)
    asset.scene_entity_add(&document,50,2,"Shade")
    aim:=Update_Link{core.Entity(3)}
    asset.scene_set(&document,50,"Update_Link",&aim)
    asset.scene_entities_remove(&document,{4})
    report,error=update_put(t,&f,ref,&document,scope)
    testing.expect(t,error==.None && report.components>0)

    held:=(^Update_Lamp)(core.raw_find(core.raw(&w.lamps),type_info_of(Update_Lamp),bulb))^
    _,turned,_:=core.raw_state(core.raw(&w.lamps),bulb)
    testing.expect(t,held==Update_Lamp{range=5,heat=7} && turned,"the value follows the document, what it does not save stays, and it is off")
    testing.expect_value(t,core.name_get(core.read(&w.names),lamp),"Desk lamp")
    testing.expect(t,!core.has(&w.links,lamp) && core.at(&w.links,core.row_of(&w.links,bulb)).target==other)
    shade:=core.entity_of(&w.entities,50)
    parent,_:=core.get(&w.parents,shade)
    testing.expect(t,shade!=core.NONE && parent.entity==lamp && core.at(&w.links,core.row_of(&w.links,shade)).target==bulb && core.has(&w.transforms,shade))
    testing.expect(t,!core.alive(&w.entities,cable) && core.alive(&w.entities,bulb) && core.alive(&w.entities,other))
    report,error=update_put(t,&f,ref,&document,scope)
    testing.expect(t,error==.None && report.components==0,"the world holds what the document says")

    // An entity that stays under one that goes: nothing changes.
    asset.scene_entity_reparent(&document,3,1,0)
    asset.scene_entities_remove(&document,{2},false)
    _,error=update_put(t,&f,ref,&document,{1,2,3,50})
    testing.expect(t,error==.Invalid && core.alive(&w.entities,lamp) && core.alive(&w.entities,shade))

    // A reference to nothing names none.
    lost:=Update_Link{core.Entity(777)}
    asset.scene_set(&document,3,"Update_Link",&lost)
    asset.scene_entities_remove(&document,{50})
    report,error=update_put(t,&f,ref,&document,nil)
    testing.expect(t,error==.None && report.dangling==1 && core.at(&w.links,core.row_of(&w.links,bulb)).target==core.NONE)
}

@(private="file")
update_file :: proc(t:^testing.T,document:^asset.Scene,file:^asset.Asset) -> bool {
    data,bytes_error:=asset.scene_bytes(document,context.temp_allocator)
    return testing.expect_value(t,bytes_error,asset.Error.None) && testing.expect_value(t,asset.asset_open(file,data),asset.Error.None)
}

@(test)
the_instances_of_a_document_are_components_of_its_entities_and_a_copy_has_none :: proc(t:^testing.T) {
    f:Update_Fixture
    ref,made:=update_fixture_init(t,&f)
    if !made {return}
    defer update_fixture_destroy(&f)
    w:=&f.w
    LAMP :: base.Asset_Id{0x1a,2}
    lamp,level:asset.Scene
    asset.scene_init(&lamp,&f.types,LAMP);defer asset.scene_destroy(&lamp)
    asset.scene_entity_add(&lamp,1,0,"Lamp")
    asset.scene_entity_add(&lamp,2,1,"Bulb")
    asset.scene_init(&level,&f.types,{0x1a,3});defer asset.scene_destroy(&level)
    asset.scene_entity_add(&level,100,0,"Room")
    root_id,placed:=asset.scene_instantiate(&level,&lamp,LAMP,100)
    testing.expect_value(t,placed,asset.Error.None)
    bulb_id:base.Entity_Id
    members,_:=asset.scene_instance_members(&level,root_id)
    for member in members {if member.source==2 {bulb_id=member.entity}}

    file:asset.Asset
    if !update_file(t,&level,&file) {return}
    defer asset.asset_close(&file)
    _,error:=instantiate(ref,&file,&f.types)
    core.test_world_settle(w)
    testing.expect_value(t,error,Error.None)
    root,bulb:=core.entity_of(&w.entities,root_id),core.entity_of(&w.entities,bulb_id)
    of_bulb,instance,member:=prefab_instance_of(ref,bulb)
    testing.expect(t,root!=core.NONE && of_bulb==root && instance.prefab==LAMP && member.source==2)
    of_room,_,_:=prefab_instance_of(ref,core.entity_of(&w.entities,100))
    testing.expect_value(t,of_room,core.NONE)

    // A capture gives the document its instances back.
    captured:asset.Scene
    _,error=capture(ref,&captured,&f.types,{id={0x1a,3}})
    testing.expect_value(t,error,Error.None)
    defer asset.scene_destroy(&captured)
    _,source,linked:=asset.scene_member(&captured,bulb_id)
    testing.expect(t,asset.scene_entity_instance(&captured,bulb_id)==root_id && linked && source==2)

    // A prefab that places the Lamp, copied while the world runs: its entities are of no instance.
    desk:asset.Scene
    asset.scene_init(&desk,&f.types,{0x1a,4});defer asset.scene_destroy(&desk)
    asset.scene_entity_add(&desk,1,0,"Desk")
    asset.scene_instantiate(&desk,&lamp,LAMP,1)
    copied:asset.Asset
    if !update_file(t,&desk,&copied) {return}
    defer asset.asset_close(&copied)
    rows:=[2]int{core.count(&w.instances),core.count(&w.members)}
    report:Report
    report,error=instantiate(ref,&copied,&f.types,{fresh=true})
    core.test_world_settle(w)
    testing.expect(t,error==.None && report.entities==3 && rows==[2]int{core.count(&w.instances),core.count(&w.members)})
}
