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
    hierarchy:core.Hierarchy,
}

@(private="file")
Update_Fixture :: struct {
    w:Update_World,
    tables:[6]core.Table_Info,
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
    f.tables={
        {name="Id",type=core.Id,info=type_info_of(core.Id),offset=offset_of(Update_World,ids)},
        {name="Name",type=core.Name,info=type_info_of(core.Name),offset=offset_of(Update_World,names)},
        {name="Transform",type=core.Transform,info=type_info_of(core.Transform),offset=offset_of(Update_World,transforms)},
        {name="Parent",type=core.Parent,info=type_info_of(core.Parent),offset=offset_of(Update_World,parents)},
        {name="Update_Lamp",type=Update_Lamp,info=type_info_of(Update_Lamp),offset=offset_of(Update_World,lamps)},
        {name="Update_Link",type=Update_Link,info=type_info_of(Update_Link),offset=offset_of(Update_World,links)},
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
    core.value_free(&w.hierarchy,type_info_of(core.Hierarchy))
    core.entities_destroy(&w.entities)
}

@(private="file")
update_settle :: proc(w:^Update_World) {
    core.table_settle(&w.ids,&w.entities);core.table_settle(&w.names,&w.entities);core.table_settle(&w.transforms,&w.entities)
    core.table_settle(&w.parents,&w.entities);core.table_settle(&w.lamps,&w.entities);core.table_settle(&w.links,&w.entities)
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
