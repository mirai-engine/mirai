package scene

import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:std/base"

@(private="file") Update_Lamp :: struct {range:f32,heat:f32 `mirai:"transient"`}
@(private="file") Update_Link :: struct {target:core.Entity}

@(private="file")
Update_World :: struct {
    entities:core.Entities,
    ids:core.Table(core.Id),
    names:core.Table(core.Name),
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    lamps:core.Table(Update_Lamp),
    links:core.Table(Update_Link),
    instances:core.Table(Prefab_Instance),
    members:core.Table(Prefab_Member),
    hierarchy:core.Hierarchy,
}

@(private="file")
Update_Fixture :: struct {
    w:Update_World,
    tables:[8]core.Table_Info,
    storages:[1]core.Storage_Info,
    info:core.World_Info,
    types:asset.Types,
}

@(private="file")
update_fixture_init :: proc(f:^Update_Fixture) -> core.World_Ref {
    w:=&f.w
    core.entities_init(&w.entities)
    core.table_init(&w.ids,"Id");core.table_init(&w.names,"Name");core.table_init(&w.transforms,"Transform")
    core.table_init(&w.parents,"Parent");core.table_init(&w.lamps,"Update_Lamp");core.table_init(&w.links,"Update_Link")
    core.table_init(&w.instances,"Prefab_Instance");core.table_init(&w.members,"Prefab_Member")
    f.tables={
        {name="Id",type=core.Id,info=type_info_of(core.Id),offset=offset_of(Update_World,ids)},
        {name="Name",type=core.Name,info=type_info_of(core.Name),offset=offset_of(Update_World,names)},
        {name="Transform",type=core.Transform,info=type_info_of(core.Transform),offset=offset_of(Update_World,transforms)},
        {name="Parent",type=core.Parent,info=type_info_of(core.Parent),offset=offset_of(Update_World,parents)},
        {name="Update_Lamp",type=Update_Lamp,info=type_info_of(Update_Lamp),offset=offset_of(Update_World,lamps)},
        {name="Update_Link",type=Update_Link,info=type_info_of(Update_Link),offset=offset_of(Update_World,links)},
        {name="Prefab_Instance",type=Prefab_Instance,info=type_info_of(Prefab_Instance),offset=offset_of(Update_World,instances)},
        {name="Prefab_Member",type=Prefab_Member,info=type_info_of(Prefab_Member),offset=offset_of(Update_World,members)},
    }
    f.storages={{name="Hierarchy",type=core.Hierarchy,info=type_info_of(core.Hierarchy),offset=offset_of(Update_World,hierarchy)}}
    f.info={entities=offset_of(Update_World,entities),tables=f.tables[:],storages=f.storages[:]}
    asset.types_init(&f.types)
    return core.world_ref(w,&f.info)
}

@(private="file")
update_fixture_destroy :: proc(f:^Update_Fixture) {
    w:=&f.w
    asset.types_destroy(&f.types)
    core.table_destroy(&w.ids);core.table_destroy(&w.names);core.table_destroy(&w.transforms)
    core.table_destroy(&w.parents);core.table_destroy(&w.lamps);core.table_destroy(&w.links)
    core.table_destroy(&w.instances);core.table_destroy(&w.members)
    core.value_free(&w.hierarchy,type_info_of(core.Hierarchy))
    core.entities_destroy(&w.entities)
}

@(private="file")
update_settle :: proc(w:^Update_World) {
    core.table_settle(&w.ids,&w.entities);core.table_settle(&w.names,&w.entities);core.table_settle(&w.transforms,&w.entities)
    core.table_settle(&w.parents,&w.entities);core.table_settle(&w.lamps,&w.entities);core.table_settle(&w.links,&w.entities)
    core.table_settle(&w.instances,&w.entities);core.table_settle(&w.members,&w.entities)
    core.hierarchy_settle(&w.hierarchy,core.read(&w.parents),&w.entities)
    core.entities_settle(&w.entities)
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
    update_settle(&f.w)
    return
}

@(test)
an_update_writes_what_differs_onto_the_entities_that_have_the_ids_of_a_document :: proc(t:^testing.T) {
    f:Update_Fixture
    ref:=update_fixture_init(&f)
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
    update_settle(w)

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
    testing.expect(t,!core.has(&w.links,lamp) && core.get(&w.links,bulb).target==other)
    shade:=core.entity_of(&w.entities,50)
    parent,_:=core.get(core.read(&w.parents),shade)
    testing.expect(t,shade!=core.NONE && parent.entity==lamp && core.get(&w.links,shade).target==bulb && core.has(&w.transforms,shade))
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
    testing.expect(t,error==.None && report.dangling==1 && core.get(&w.links,bulb).target==core.NONE)
}

// asset declares the two components of the instances for a document, where
// it cannot name the ones of a world: any drift of names, kinds or order
// between them would read one as the other wrongly.
@(test)
the_components_of_prefab_instances_are_the_ones_asset_declares :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    Pair :: struct {world,document:typeid}
    for pair in ([]Pair{{Prefab_Instance,asset.Instance},{Prefab_Member,asset.Member}}) {
        world,document:=type_info_of(pair.world),type_info_of(pair.document)
        testing.expect(t,world.size==document.size && world.align==document.align)
    }
    world_instance,_:=asset.types_index(&types,Prefab_Instance)
    document_instance,_:=asset.types_index(&types,asset.Instance)
    world_member,_:=asset.types_index(&types,Prefab_Member)
    document_member,_:=asset.types_index(&types,asset.Member)
    testing.expect_value(t,types.hashes[world_instance],types.hashes[document_instance])
    testing.expect_value(t,types.hashes[world_member],types.hashes[document_member])
    testing.expect(t,types.hashes[world_instance]!=types.hashes[world_member])
    testing.expect_value(t,asset.COMPONENT_INSTANCE,"Prefab_Instance")
    testing.expect_value(t,asset.COMPONENT_MEMBER,"Prefab_Member")
}

@(private="file")
update_file :: proc(t:^testing.T,document:^asset.Scene,file:^asset.Asset) -> bool {
    data,bytes_error:=asset.scene_bytes(document,context.temp_allocator)
    return testing.expect_value(t,bytes_error,asset.Error.None) && testing.expect_value(t,asset.asset_open(file,data),asset.Error.None)
}

@(test)
the_instances_of_a_document_are_components_of_its_entities_and_a_copy_has_none :: proc(t:^testing.T) {
    f:Update_Fixture
    ref:=update_fixture_init(&f)
    defer update_fixture_destroy(&f)
    w:=&f.w
    LAMP :: base.Asset_Id{0x1a,2}
    lamp,level:asset.Scene
    asset.scene_init(&lamp,&f.types,asset.KIND_PREFAB,LAMP);defer asset.scene_destroy(&lamp)
    asset.scene_entity_add(&lamp,1,0,"Lamp")
    asset.scene_entity_add(&lamp,2,1,"Bulb")
    lamp.info.root=1
    asset.scene_init(&level,&f.types,asset.KIND_SCENE,{0x1a,3});defer asset.scene_destroy(&level)
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
    update_settle(w)
    testing.expect_value(t,error,Error.None)
    root,bulb:=core.entity_of(&w.entities,root_id),core.entity_of(&w.entities,bulb_id)
    of_bulb,instance,member:=prefab_instance_of(ref,bulb)
    testing.expect(t,root!=core.NONE && of_bulb==root && instance.prefab==LAMP && member.source==2)
    of_room,_,_:=prefab_instance_of(ref,core.entity_of(&w.entities,100))
    testing.expect_value(t,of_room,core.NONE)

    // A capture gives the document its instances back.
    captured:asset.Scene
    _,error=capture(ref,&captured,&f.types,{kind=asset.KIND_SCENE,id={0x1a,3}})
    testing.expect_value(t,error,Error.None)
    defer asset.scene_destroy(&captured)
    _,source,linked:=asset.scene_member(&captured,bulb_id)
    testing.expect(t,asset.scene_entity_instance(&captured,bulb_id)==root_id && linked && source==2)

    // A prefab that places the Lamp, copied while the world runs: its entities are of no instance.
    desk:asset.Scene
    asset.scene_init(&desk,&f.types,asset.KIND_PREFAB,{0x1a,4});defer asset.scene_destroy(&desk)
    asset.scene_entity_add(&desk,1,0,"Desk")
    desk.info.root=1
    asset.scene_instantiate(&desk,&lamp,LAMP,1)
    copied:asset.Asset
    if !update_file(t,&desk,&copied) {return}
    defer asset.asset_close(&copied)
    rows:=[2]int{core.count(&w.instances),core.count(&w.members)}
    report:Report
    report,error=instantiate(ref,&copied,&f.types,{fresh=true})
    update_settle(w)
    testing.expect(t,error==.None && report.entities==3 && rows==[2]int{core.count(&w.instances),core.count(&w.members)})
}
