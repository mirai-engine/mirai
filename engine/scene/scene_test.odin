package scene

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"

@(private="file") Scene_Test_Lamp :: struct {range:f32,intensity:f32 `mirai:"was=power"`}
@(private="file") Scene_Test_Link :: struct {target:core.Entity}
@(private="file") Scene_Test_Shape :: enum u8 {Cube,Ramp}
@(private="file")
Scene_Test_Block :: struct {
    size:[3]f32 `mirai:"min=0,max=100"`,
    shape:Scene_Test_Shape,
    material:base.Asset_Id,
    link:core.Entity,
}

@(private="file")
Scene_Test :: struct {
    using world:core.Test_World,
    ids:core.Table(core.Id),
    names:core.Table(core.Name),
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    lamps:core.Table(Scene_Test_Lamp),
    references:core.Table(Scene_Reference),
    links:core.Table(Scene_Test_Link),
    blocks:core.Table(Scene_Test_Block),
    unresolved:Unresolved_References,
}

@(private="file") TEST_LAMP :: base.Asset_Id{0x1a,1}

@(private="file")
lamp_write :: proc(t:^testing.T,types:^asset.Types,path:string,range:f32) -> (lamp:asset.Scene) {
    asset.scene_init(&lamp,types,TEST_LAMP)
    lamp.doc.flags+={.Prefab}
    asset.scene_entity_add(&lamp,1,0,"Lamp")
    asset.scene_entity_add(&lamp,2,1,"Bulb")
    light:=Scene_Test_Lamp{range,1}
    asset.scene_set(&lamp,2,"Scene_Test_Lamp",&light)
    testing.expect_value(t,asset.scene_save(&lamp,path),asset.Error.None)
    return
}

// A project with lamps in a temporary folder of assets, and a World of it
// that its application made.
@(private="file")
Scene_Test_Project :: struct {
    folder:string,
    types:asset.Types,
    info:core.World_Info,
    assets:host.Assets,
    app:host.App,
    world:^Scene_Test,
}

@(private="file")
scene_test_project_open :: proc(t:^testing.T,p:^Scene_Test_Project,name:string) -> bool {
    p.folder=base.test_folder(t,fmt.tprintf("scene-%s",name))
    if p.folder=="" {return false}
    asset.types_init(&p.types)
    p.info=core.test_info(t,Scene_Test,test_types) or_return
    if !testing.expect(t,host.assets_init(&p.assets,{root=p.folder,capacity=8})) {return false}
    p.app={info=&p.info,assets=&p.assets,allocator=context.allocator}
    p.world=cast(^Scene_Test)host.app_world_create(&p.app)
    return testing.expect(t,p.world!=nil)
}

@(private="file")
scene_test_project_close :: proc(p:^Scene_Test_Project) {
    host.app_world_free(&p.app,p.world)
    delete(p.app.worlds)
    host.assets_destroy(&p.assets)
    asset.types_destroy(&p.types)
    core.test_info_destroy(&p.info)
}

// The ranges of the lamps of the world, in the order of its table.
@(private="file")
scene_test_ranges :: proc(f:^Scene_Test) -> []f32 {
    lamps:=core.read(&f.lamps)
    ranges:=make([]f32,core.count(lamps),context.temp_allocator)
    for &range,row in ranges {range=core.at(lamps,row).range}
    return ranges
}

@(test)
a_load_brings_instances_up_to_date_with_their_prefabs_unless_the_assets_are_cooked :: proc(t:^testing.T) {
    p:Scene_Test_Project
    if !scene_test_project_open(t,&p,"resolve") {return}
    defer scene_test_project_close(&p)
    lamp_path:=fmt.tprintf("%s/lamp.scene",p.folder)
    lamp:=lamp_write(t,&p.types,lamp_path,1)
    level:asset.Scene;asset.scene_init(&level,&p.types,{0x1a,2});defer asset.scene_destroy(&level)
    _,placed:=asset.scene_instantiate(&level,&lamp,TEST_LAMP,0)
    testing.expect_value(t,placed,asset.Error.None)
    testing.expect_value(t,asset.scene_save(&level,fmt.tprintf("%s/level.scene",p.folder)),asset.Error.None)
    asset.scene_destroy(&lamp)
    // The prefab changes after the scene was saved.
    lamp=lamp_write(t,&p.types,lamp_path,5)
    asset.scene_destroy(&lamp)

    w:=host.app_world_ref(&p.app,p.world)
    _,error:=load(w,&p.app,"level.scene")
    testing.expect_value(t,error,Error.None)
    testing.expect(t,slice.equal(scene_test_ranges(p.world),[]f32{5}))
    // A cooked folder was resolved by its cook: its files are loaded as they are.
    p.assets.indexed=true
    _,error=load(w,&p.app,"level.scene")
    testing.expect_value(t,error,Error.None)
    testing.expect(t,slice.equal(scene_test_ranges(p.world),[]f32{1}))
}

// A lamp as a scene saved it before its fields changed: power is intensity
// now, and flicker is gone.
@(private="file") Scene_Test_Old_Lamp :: struct {power:f32,flicker:i32}
@(private="file") Scene_Test_Gone :: struct {speed:f32}

// A component the scene keeps with another layout loads by field names: what
// both have comes back, a renamed field by the name it had, a field the scene
// lacks starts at its default, and one the world lacks is reported with the
// scene and the component, as is a component the world does not have.
@(test)
a_scene_saved_with_another_layout_of_a_component_loads_it_by_field_names :: proc(t:^testing.T) {
    p:Scene_Test_Project
    if !scene_test_project_open(t,&p,"migrate") {return}
    defer scene_test_project_close(&p)
    old:asset.Scene;asset.scene_init(&old,&p.types,{0x3a,1});defer asset.scene_destroy(&old)
    asset.scene_entity_add(&old,1,0,"Lamp")
    testing.expect_value(t,asset.scene_set(&old,1,"Scene_Test_Lamp",&Scene_Test_Old_Lamp{power=4,flicker=7}),asset.Error.None)
    testing.expect_value(t,asset.scene_set(&old,1,"Scene_Test_Gone",&Scene_Test_Gone{speed=2}),asset.Error.None)
    path:=fmt.tprintf("%s/old.scene",p.folder)
    testing.expect_value(t,asset.scene_save(&old,path),asset.Error.None)

    file:asset.Asset
    if !testing.expect_value(t,asset.asset_load(&file,path),asset.Error.None) {return}
    defer asset.asset_close(&file)
    stored:=make([dynamic]Stored,context.temp_allocator)
    _,error:=instantiate(host.app_world_ref(&p.app,p.world),&file,&p.types,{stored=&stored})
    testing.expect_value(t,error,Error.None)
    core.world_settle(host.app_world_ref(&p.app,p.world))
    if !testing.expect_value(t,len(stored),2) {return}
    lamp,gone:=stored[0],stored[1]
    if lamp.unknown {lamp,gone=gone,lamp}
    testing.expect(t,lamp.component=="Scene_Test_Lamp" && !lamp.unknown && slice.equal(lamp.removed,[]string{"flicker"}) && len(lamp.incompatible)==0 && lamp.scene==base.Asset_Id{0x3a,1})
    testing.expect(t,gone.component=="Scene_Test_Gone" && gone.unknown)
    text,warning:=stored_text(lamp,"old.scene")
    testing.expect(t,warning && strings.contains(text,"old.scene") && strings.contains(text,"Scene_Test_Lamp") && strings.contains(text,"flicker"),text)
    lamps:=core.read(&p.world.lamps)
    if !testing.expect_value(t,core.count(lamps),1) {return}
    testing.expect_value(t,core.at(lamps,0),Scene_Test_Lamp{range=0,intensity=4})
}

// A room referenced twice by a level: its entities hang from each reference
// with Ids combined with the reference's, the same in every load and never
// repeated; a scene that references itself and a prefab that references a
// scene do not load, and a reference to a scene that is not there is counted.
@(test)
a_referenced_scene_hangs_from_each_reference_with_its_own_ids :: proc(t:^testing.T) {
    p:Scene_Test_Project
    if !scene_test_project_open(t,&p,"reference") {return}
    defer scene_test_project_close(&p)
    ROOM :: base.Asset_Id{0x2a,1}
    LEVEL :: base.Asset_Id{0x2a,2}
    room:asset.Scene;asset.scene_init(&room,&p.types,ROOM);defer asset.scene_destroy(&room)
    asset.scene_entity_add(&room,1,0,"Lamp")
    light:=Scene_Test_Lamp{3,1}
    asset.scene_set(&room,1,"Scene_Test_Lamp",&light)
    testing.expect_value(t,asset.scene_save(&room,fmt.tprintf("%s/room.scene",p.folder)),asset.Error.None)
    level:asset.Scene;asset.scene_init(&level,&p.types,LEVEL);defer asset.scene_destroy(&level)
    for id in ([2]base.Entity_Id{10,20}) {
        asset.scene_entity_add(&level,id,0,"Room")
        asset.scene_set(&level,id,"Scene_Reference",&Scene_Reference{scene=ROOM})
    }
    asset.scene_entity_add(&level,30,0,"Gone")
    asset.scene_set(&level,30,"Scene_Reference",&Scene_Reference{scene={0x2a,9}})
    // Fields of the level that name the lamp of the first room and what the missing scene would hold.
    asset.scene_entity_add(&level,40,0,"Switch")
    asset.scene_set(&level,40,"Scene_Test_Link",&Scene_Test_Link{core.Entity(id_in(10,1))})
    asset.scene_entity_add(&level,41,0,"Far switch")
    asset.scene_set(&level,41,"Scene_Test_Link",&Scene_Test_Link{core.Entity(id_in(30,1))})
    testing.expect_value(t,asset.scene_save(&level,fmt.tprintf("%s/level.scene",p.folder)),asset.Error.None)

    w:=host.app_world_ref(&p.app,p.world)
    report,error:=load(w,&p.app,"level.scene")
    testing.expect_value(t,error,Error.None)
    testing.expect_value(t,report.sections,2)
    testing.expect_value(t,report.missing,1)
    testing.expect(t,slice.equal(scene_test_ranges(p.world),[]f32{3,3}),"the room under each reference")
    links:=core.read(&p.world.links)
    for row in 0..<core.count(links) {
        e:=core.entity_at(links,row)
        id,_:=core.get(&p.world.ids,e)
        target:=core.at(links,row).target
        if id.value==40 {
            got,_:=core.get(&p.world.ids,target)
            testing.expect_value(t,got.value,id_in(10,1))
        } else {
            testing.expect_value(t,target,core.NONE)
            testing.expect_value(t,unresolved_target(&p.world.unresolved,e,base.name_hash("Scene_Test_Link"),0),id_in(30,1))
        }
    }
    ids:=core.read(&p.world.ids)
    seen:[dynamic]base.Entity_Id;defer delete(seen)
    for row in 0..<core.count(ids) {
        id:=core.at(ids,row).value
        testing.expect(t,!slice.contains(seen[:],id),"no Id repeats")
        append(&seen,id)
    }
    testing.expect(t,slice.contains(seen[:],id_in(10,1)) && slice.contains(seen[:],id_in(20,1)))
    lamps:=core.read(&p.world.lamps)
    parents:=core.read(&p.world.parents)
    for row in 0..<core.count(lamps) {
        parent,_:=core.get(parents,core.entity_at(lamps,row))
        reference,_:=core.get(ids,parent.entity)
        testing.expect(t,reference.value==10 || reference.value==20,"it hangs from its reference")
    }

    // A section loaded apart joins the world under its reference.
    late:=core.create(&p.world.entities)
    core.add(&p.world.ids,late,core.Id{50})
    core.add(&p.world.references,late,Scene_Reference{scene=ROOM})
    core.settle(&p.info,p.world,nil)
    job,begun:=section_load_begin(&p.app,w,late)
    testing.expect_value(t,begun,Error.None)
    if job!=nil {
        for !load_step(job,all=true) {}
        _,joined:=section_load_end(job,w,late)
        testing.expect_value(t,joined,Error.None)
        core.settle(&p.info,p.world,nil)
        testing.expect_value(t,len(scene_test_ranges(p.world)),3)
        found:=false
        for row in 0..<core.count(&p.world.ids) {found||=core.at(&p.world.ids,row).value==id_in(50,1)}
        testing.expect(t,found,"its lamp has the Id of the reference combined with its own")
    }

    // A loop references a hall that references the loop.
    LOOP :: base.Asset_Id{0x2a,3}
    HALL :: base.Asset_Id{0x2a,4}
    for pair in ([2][2]base.Asset_Id{{LOOP,HALL},{HALL,LOOP}}) {
        doc:asset.Scene;asset.scene_init(&doc,&p.types,pair[0]);defer asset.scene_destroy(&doc)
        asset.scene_entity_add(&doc,1,0,"Next")
        asset.scene_set(&doc,1,"Scene_Reference",&Scene_Reference{scene=pair[1]})
        testing.expect_value(t,asset.scene_save(&doc,fmt.tprintf("%s/%s.scene",p.folder,"loop" if pair[0]==LOOP else "hall")),asset.Error.None)
    }
    _,error=load(w,&p.app,"loop.scene")
    testing.expect_value(t,error,Error.Cycle)
    testing.expect(t,slice.equal(scene_test_ranges(p.world),[]f32{3,3,3}),"a load that fails leaves the world as it was")
}

// A load in phases: it reads and instantiates apart, warms what the scene
// uses, and trades the World only at its end; the requests made meanwhile
// wait, and what the run holds (its requests) goes on in the World loaded.
@(test)
a_scene_loads_in_phases_and_replaces_the_world_at_its_end :: proc(t:^testing.T) {
    p:Scene_Test_Project
    if !scene_test_project_open(t,&p,"phases") {return}
    defer scene_test_project_close(&p)
    LEVEL :: base.Asset_Id{0x3a,1}
    level:asset.Scene;asset.scene_init(&level,&p.types,LEVEL);defer asset.scene_destroy(&level)
    light:=Scene_Test_Lamp{7,1}
    asset.scene_entity_add(&level,1,0,"Lamp")
    asset.scene_set(&level,1,"Scene_Test_Lamp",&light)
    testing.expect_value(t,asset.scene_save(&level,fmt.tprintf("%s/level.scene",p.folder)),asset.Error.None)
    host.assets_scan(&p.assets)

    w:=host.app_world_ref(&p.app,p.world)
    job,error:=load_begin(&p.app,LEVEL)
    testing.expect_value(t,error,Error.None)
    if job==nil {return}
    progress:=load_progress(job)
    testing.expect_value(t,progress.phase,Load_Phase.Reading)
    testing.expect_value(t,len(scene_test_ranges(p.world)),0)
    for !load_step(job,all=true) {}
    _,error=load_end(job,w)
    testing.expect_value(t,error,Error.None)
    testing.expect(t,slice.equal(scene_test_ranges(p.world),[]f32{7}),"the World holds the scene once it ends")

    _,missing:=load_begin(&p.app,base.Asset_Id{0x3a,9})
    testing.expect_value(t,missing,Error.Not_Found)
}

// The bytes of a scene with a lamp on each of count entities, whose lamps
// do not decompress when broken: what a load reads after it made the
// entities. The content hash follows the bytes.
@(private="file")
scene_test_lamps :: proc(t:^testing.T,types:^asset.Types,id:base.Asset_Id,count:int,range:f32,broken:bool) -> []u8 {
    level:asset.Scene;asset.scene_init(&level,types,id);defer asset.scene_destroy(&level)
    light:=Scene_Test_Lamp{range,1}
    for e in 1..=count {
        asset.scene_entity_add(&level,base.Entity_Id(e),0,"Lamp")
        asset.scene_set(&level,base.Entity_Id(e),"Scene_Test_Lamp",&light)
    }
    data,error:=asset.scene_bytes(&level,context.temp_allocator)
    if !testing.expect_value(t,error,asset.Error.None) || !broken {return data}
    file:asset.Asset
    if !testing.expect(t,asset.asset_open(&file,data,context.temp_allocator)==.None) {return nil}
    view,_:=asset.scene_view(&file,types)
    entry:asset.Chunk_Entry
    for &component in view.components {
        if component.name=="Scene_Test_Lamp" {entry=asset.blob_chunk(&file.blob,component.table.columns[1].chunk)}
    }
    asset.asset_close(&file)
    if !testing.expect_value(t,entry.compression,asset.Compression.LZ) {return nil}
    mem.set(&data[entry.offset],0xff,int(entry.size))
    (cast(^asset.Header)raw_data(data)).content_hash=asset.blob_hash(data)
    return data
}

// A load instantiates in another World and trades contents with the world
// only when every entity got there: one that fails halfway leaves the world
// as it was, and one that works replaces it.
@(test)
a_load_that_fails_halfway_leaves_the_world_as_it_was :: proc(t:^testing.T) {
    p:Scene_Test_Project
    if !scene_test_project_open(t,&p,"halfway") {return}
    defer scene_test_project_close(&p)
    Level :: struct {name:string,id:base.Asset_Id,range:f32,broken:bool}
    levels:=[3]Level{{"first.scene",{0x1b,1},2,false},{"broken.scene",{0x1b,2},3,true},{"second.scene",{0x1b,3},4,false}}
    for level in levels {
        data:=scene_test_lamps(t,&p.types,level.id,64,level.range,level.broken)
        if !testing.expect(t,data!=nil && serial.file_write_atomic(fmt.tprintf("%s/%s",p.folder,level.name),data)==.None) {return}
    }
    w:=host.app_world_ref(&p.app,p.world)
    _,error:=load(w,&p.app,"first.scene")
    if !testing.expect_value(t,error,Error.None) {return}
    first:=core.entity_of(&p.world.entities,base.Entity_Id(1))
    testing.expect_value(t,p.world.entities.alive,64)

    _,error=load(w,&p.app,"broken.scene")
    testing.expect_value(t,error,Error.Corrupt)
    testing.expect_value(t,p.world.entities.alive,64)
    testing.expect_value(t,core.entity_of(&p.world.entities,base.Entity_Id(1)),first)
    ranges:=scene_test_ranges(p.world)
    testing.expect(t,len(ranges)==64 && ranges[0]==2 && ranges[63]==2)
    testing.expect_value(t,host.app_world_count(&p.app),1)

    _,error=load(w,&p.app,"second.scene")
    testing.expect_value(t,error,Error.None)
    testing.expect_value(t,p.world.entities.alive,64)
    testing.expect(t,!core.alive(&p.world.entities,first))
    ranges=scene_test_ranges(p.world)
    testing.expect(t,len(ranges)==64 && ranges[0]==4 && ranges[63]==4)
}

// The shape of input.Drivable: Entity fields of a component.
@(private="file") Scene_Test_Drivable :: struct {seat,camera:core.Entity}

@(private="file")
Scene_Test_World :: struct {
    using world:core.Test_World,
    ids:core.Table(core.Id),
    names:core.Table(core.Name),
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    worlds:core.Table(core.World_Transform),
    drivables:core.Table(Scene_Test_Drivable) `mirai:"name=Drivable"`,
    references:core.Table(Scene_Reference),
    members:core.Table(Section_Member),
    dormants:core.Table(Dormant),
    tombstones:core.Table(Tombstone),
    disabled:core.Table(core.Disabled),
    held:core.Table(Section_Held),
    hierarchy:core.Hierarchy,
    propagation:core.Propagation,
    jumps:core.Jumps,
    time:core.Time,
    frame:core.Frame_Time,
}

// transforms_propagate as the late phase of a generated world calls it.
@(private="file")
scene_test_propagate :: proc(world,shared,editor,app:rawptr) {
    w:=cast(^Scene_Test_World)world
    core.transforms_propagate(core.read(&w.transforms),core.ref(&w.hierarchy),&w.worlds,&w.propagation,&w.jumps,w.frame)
    core.table_settle(&w.worlds,&w.entities)
}

@(private="file")
Scene_Test_Fixture :: struct {
    w:Scene_Test_World,
    steps:[1]core.Step_Info,
    order:[1]i32,
}

@(private="file")
scene_fixture_init :: proc(t:^testing.T,s:^Scene_Test_Fixture) -> (ref:core.World_Ref,ok:bool) {
    core.test_world_init(t,&s.w,test_types) or_return
    s.steps={{name="transforms_propagate",library="core",call=scene_test_propagate}}
    info:=core.test_world_info(&s.w)
    info.steps=s.steps[:]
    info.order[.Game][.Late]=s.order[:]
    return core.test_world_ref(&s.w),true
}

@(private="file")
scene_fixture_destroy :: proc(s:^Scene_Test_Fixture) {core.test_world_destroy(&s.w)}

// Saving a scene saves its references and not what hangs from them, which
// their own scenes keep; a saved game keeps all of it.
@(test)
a_capture_leaves_out_what_hangs_from_a_reference :: proc(t:^testing.T) {
    s:Scene_Test_Fixture
    ref,ready:=scene_fixture_init(t,&s)
    if !ready {return}
    defer scene_fixture_destroy(&s)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    w:=&s.w
    room,lamp:=core.create(&w.entities),core.create(&w.entities)
    core.add(&w.ids,room,core.Id{1});core.add(&w.ids,lamp,core.Id{id_in(1,7)})
    core.add(&w.references,room,Scene_Reference{scene={9,9}})
    core.add(&w.parents,lamp,core.Parent{entity=room})
    core.add(&w.members,lamp,Section_Member{7})
    core.test_world_settle(w)
    for sections in ([2]bool{false,true}) {
        document:asset.Scene
        _,error:=capture(ref,&document,&types,{id={1,2},sections=sections})
        testing.expect_value(t,error,Error.None)
        testing.expect_value(t,asset.scene_entity_count(&document),sections?2:1)
        _,referenced:=asset.scene_get(&document,1,"Scene_Reference",Scene_Reference)
        testing.expect(t,referenced)
        asset.scene_destroy(&document)
    }
    // The section alone, as its own scene: its entities with the Ids of that scene.
    section:asset.Scene
    _,error:=capture(ref,&section,&types,{id={9,9},section=room})
    testing.expect_value(t,error,Error.None)
    testing.expect_value(t,asset.scene_entity_count(&section),1)
    _,found:=asset.scene_entity_find(&section,7)
    testing.expect(t,found,"the lamp has its Id of the room")
    asset.scene_destroy(&section)
}

// A section loaded and off holds what hangs from it under Disabled and keeps
// its reference on; on again, it turns on only what it turned off.
@(test)
a_section_off_holds_what_hangs_from_it_and_lets_go_only_of_that :: proc(t:^testing.T) {
    s:Scene_Test_Fixture
    ref,ready:=scene_fixture_init(t,&s)
    if !ready {return}
    defer scene_fixture_destroy(&s)
    w:=&s.w
    room,lamp,dark:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    core.add(&w.references,room,Scene_Reference{scene={9,9},state=.Loaded})
    core.add(&w.parents,lamp,core.Parent{room,0});core.add(&w.parents,dark,core.Parent{room,1})
    core.add(&w.disabled,dark,core.Disabled{})
    core.test_world_settle(w)
    section_hold(ref,room,true)
    core.test_world_settle(w)
    testing.expect(t,core.has(&w.disabled,lamp) && core.has(&w.disabled,dark) && !core.has(&w.disabled,room))
    testing.expect(t,core.has(&w.references,room),"its state can still be asked")
    section_hold(ref,room,false)
    core.test_world_settle(w)
    testing.expect(t,!core.has(&w.disabled,lamp),"what it turned off turns on")
    testing.expect(t,core.has(&w.disabled,dark),"what its author turned off stays off")
}

// A parent at (1,0,0) with a child 2 m above it, captured as a document.
@(private="file")
scene_fixture_document :: proc(t:^testing.T,s:^Scene_Test_Fixture,ref:core.World_Ref,types:^asset.Types,file:^asset.Asset) -> bool {
    w:=&s.w
    parent,child:=core.create(&w.entities),core.create(&w.entities)
    core.add(&w.ids,parent,core.Id{1});core.add(&w.ids,child,core.Id{2})
    core.add(&w.transforms,parent,core.Transform{position={1,0,0},rotation=1,scale={1,1,1}})
    core.add(&w.transforms,child,core.Transform{position={0,2,0},rotation=1,scale={1,1,1}})
    core.add(&w.parents,child,core.Parent{entity=parent})
    core.test_world_settle(w)
    document:asset.Scene
    _,error:=capture(ref,&document,types,{id={1,2}})
    if !testing.expect_value(t,error,Error.None) {return false}
    defer asset.scene_destroy(&document)
    out:serial.Writer;serial.writer_init(&out,0,context.allocator);defer serial.writer_destroy(&out)
    if !testing.expect(t,asset.scene_write(&document,&out)==.None) {return false}
    return testing.expect(t,asset.asset_open(file,serial.writer_bytes(&out),context.allocator)==.None)
}

// Instantiating gives each entity its Transform and leaves its world
// transform to the propagation, which a load runs before it returns.
@(test)
instantiated_entities_get_their_world_transforms_from_the_propagation :: proc(t:^testing.T) {
    s:Scene_Test_Fixture
    ref,ready:=scene_fixture_init(t,&s)
    if !ready {return}
    defer scene_fixture_destroy(&s)
    w:=&s.w
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    file:asset.Asset
    if !scene_fixture_document(t,&s,ref,&types,&file) {return}
    defer asset.asset_close(&file)

    core.test_world_clear(w)
    made:[2]core.Entity
    report,made_error:=instantiate(ref,&file,&types,{entities=made[:]})
    if !testing.expect_value(t,made_error,Error.None) {return}
    core.test_world_settle(w)
    testing.expect_value(t,report.entities,2)
    testing.expect_value(t,core.count(&w.transforms),2)
    testing.expect_value(t,core.count(&w.worlds),0)

    app:=host.App{allocator=context.allocator}
    propagate(ref,&app)
    testing.expect_value(t,core.count(&w.worlds),2)
    for e in made {
        local,_:=core.get(&w.transforms,e)
        placed,found:=core.get(&w.worlds,e)
        testing.expect(t,found && (local.position=={1,0,0} && placed.position==[3]f32{1,0,0} || local.position=={0,2,0} && placed.position==[3]f32{1,2,0}))
    }
}

// Two copies of a document spawned to stay in one frame, beside the entities
// it came from, each get Ids of their own: the world captures with no
// Duplicate_Id.
@(test)
copies_spawned_to_stay_get_ids_of_their_own :: proc(t:^testing.T) {
    s:Scene_Test_Fixture
    ref,ready:=scene_fixture_init(t,&s)
    if !ready {return}
    defer scene_fixture_destroy(&s)
    w:=&s.w
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    file:asset.Asset
    if !scene_fixture_document(t,&s,ref,&types,&file) {return}
    defer asset.asset_close(&file)

    for _ in 0..<2 {
        _,error:=instantiate(ref,&file,&types,{fresh=true})
        if !testing.expect_value(t,error,Error.None) {return}
    }
    core.test_world_settle(w)
    testing.expect_value(t,core.count(&w.ids),6)
    seen:=make(map[base.Entity_Id]bool,context.temp_allocator)
    for id in w.ids.values {seen[id.value]=true}
    testing.expect_value(t,len(seen),6)
    document:asset.Scene
    _,error:=capture(ref,&document,&types,{id={1,2}})
    testing.expect_value(t,error,Error.None)
    asset.scene_destroy(&document)
}

// A prefab whose root drives through its child camera, spawned twice as the
// spawn plugin does (transient): each copy's root names its own child, and a
// reference to an entity left out of the prefab becomes none.
@(test)
spawned_prefabs_keep_their_entity_references_inside :: proc(t:^testing.T) {
    s:Scene_Test_Fixture
    ref,ready:=scene_fixture_init(t,&s)
    if !ready {return}
    defer scene_fixture_destroy(&s)
    w:=&s.w
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)

    outside,root,camera:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    core.add(&w.ids,outside,core.Id{7});core.add(&w.ids,root,core.Id{1});core.add(&w.ids,camera,core.Id{2})
    core.add(&w.parents,camera,core.Parent{entity=root})
    core.add(&w.drivables,root,Scene_Test_Drivable{seat=outside,camera=camera})
    core.test_world_settle(w)
    document:asset.Scene
    captured,capture_error:=capture(ref,&document,&types,{root=root,id={3,4}})
    if !testing.expect_value(t,capture_error,Error.None) {return}
    testing.expect_value(t,captured.dangling,1)
    defer asset.scene_destroy(&document)
    document.doc.flags+={.Prefab}
    out:serial.Writer;serial.writer_init(&out,0,context.allocator);defer serial.writer_destroy(&out)
    if !testing.expect(t,asset.scene_write(&document,&out)==.None) {return}
    file:asset.Asset
    if !testing.expect(t,asset.asset_open(&file,serial.writer_bytes(&out),context.allocator)==.None) {return}
    defer asset.asset_close(&file)
    _,rooted:=asset.prefab_root(&document)
    testing.expect(t,rooted && asset.asset_prefab(&file),"what is under one entity is a scene with one root, written as a prefab")

    core.test_world_clear(w)
    made:[2][2]core.Entity
    for &copy in made {
        report,error:=instantiate(ref,&file,&types,{transient=true,entities=copy[:]})
        if !testing.expect_value(t,error,Error.None) {return}
        testing.expect_value(t,report.root,copy[0])
        testing.expect_value(t,report.dangling,0)
    }
    core.test_world_settle(w)
    for copy in made {
        drivable,found:=core.get(&w.drivables,copy[0])
        testing.expect(t,found)
        testing.expect_value(t,drivable.camera,copy[1])
        testing.expect_value(t,drivable.seat,core.NONE)
    }
}

// What the world uses one of, as a sky.
@(component,single)
@(private="file") Scene_Test_Sky :: struct {luminance:f32}

@(private="file")
Sky_World :: struct {
    using world:core.Test_World,
    ids:core.Table(core.Id),
    names:core.Table(core.Name),
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    skies:core.Table(Scene_Test_Sky),
}

// A prefab placed in a scene document loads with it as rows of the root, and
// its sky comes off as that of a section or of a prefab placed while playing,
// before the sky of the root in the document too: the root's rules. Turned on,
// it rules; turned off again, the root's is on again.
@(test)
the_sky_of_a_prefab_in_a_scene_document_loads_off :: proc(t:^testing.T) {
    w:Sky_World
    if !core.test_world_init(t,&w) {return}
    defer core.test_world_destroy(&w)
    ref:=core.test_world_ref(&w)

    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    doc:asset.Scene
    if !testing.expect_value(t,asset.scene_init(&doc,&types,{0x5c,1}),asset.Error.None) {return}
    defer asset.scene_destroy(&doc)
    PLACED,ROOT_SKY :: base.Entity_Id(1),base.Entity_Id(5)
    asset.scene_entity_add(&doc,PLACED,0,"Placed")
    asset.scene_entity_add(&doc,ROOT_SKY,0,"Sky")
    asset.scene_set(&doc,PLACED,"Scene_Test_Sky",&Scene_Test_Sky{2})
    asset.scene_set(&doc,ROOT_SKY,"Scene_Test_Sky",&Scene_Test_Sky{1000})
    asset.scene_instance_set(&doc,PLACED,{prefab={0x5d,1}})
    asset.scene_member_set(&doc,PLACED,PLACED,1)
    out:serial.Writer;serial.writer_init(&out,0,context.allocator);defer serial.writer_destroy(&out)
    if !testing.expect(t,asset.scene_write(&doc,&out)==.None) {return}
    file:asset.Asset
    if !testing.expect(t,asset.asset_open(&file,serial.writer_bytes(&out),context.allocator)==.None) {return}
    defer asset.asset_close(&file)

    _,error:=instantiate(ref,&file,&types)
    if !testing.expect_value(t,error,Error.None) {return}
    core.world_settle(ref)
    placed,root:=core.NONE,core.NONE
    for id,row in w.ids.values {
        if id.value==PLACED {placed=w.ids.entities[row]}
        if id.value==ROOT_SKY {root=w.ids.entities[row]}
    }
    on :: proc(w:^Sky_World,e:core.Entity) -> bool {
        on,_,_:=core.raw_state(core.raw(&w.skies),e)
        return on
    }
    testing.expect(t,on(&w,root) && !on(&w,placed),"the sky of the root rules; that of the prefab loads off")
    core.enable(&w.skies,placed)
    core.world_settle(ref)
    testing.expect(t,on(&w,placed) && !on(&w,root),"turned on, the prefab's rules")
    core.disable(&w.skies,placed)
    core.world_settle(ref)
    testing.expect(t,on(&w,root) && !on(&w,placed),"turned off, the root's is on again")
}

@(private="file") UNTRUSTED_BLOCK :: Scene_Test_Block{size={1,2,3},shape=.Ramp,material=TEST_LAMP,link=core.Entity(2)}
@(private="file") UNTRUSTED_ROOM :: base.Asset_Id{0x4a,1}
@(private="file") UNTRUSTED_GUEST_ROOM :: base.Asset_Id{0x4a,2}

// A project whose assets have the lamp prefab and a room scene, with a folder
// of a player mounted under levels/ that has a room of its own.
@(private="file")
untrusted_project_open :: proc(t:^testing.T,p:^Scene_Test_Project,name:string) -> (guest:string,ok:bool) {
    if !scene_test_project_open(t,p,name) {return}
    guest=base.test_folder(t,fmt.tprintf("scene-%s-guest",name))
    if guest=="" {return}
    lamp:=lamp_write(t,&p.types,fmt.tprintf("%s/lamp.scene",p.folder),1)
    asset.scene_destroy(&lamp)
    for room in ([2]base.Asset_Id{UNTRUSTED_ROOM,UNTRUSTED_GUEST_ROOM}) {
        doc:asset.Scene;asset.scene_init(&doc,&p.types,room);defer asset.scene_destroy(&doc)
        asset.scene_entity_add(&doc,1,0,"Lamp")
        asset.scene_set(&doc,1,"Scene_Test_Lamp",&Scene_Test_Lamp{5,1})
        if !testing.expect_value(t,asset.scene_save(&doc,fmt.tprintf("%s/room.scene",room==UNTRUSTED_ROOM?p.folder:guest)),asset.Error.None) {return}
    }
    host.assets_scan(&p.assets)
    _,mounted:=host.assets_mount(&p.assets,guest,"levels")
    return guest,testing.expect_value(t,mounted,asset.Error.None)
}

// A block linked to a lamp, the level a player made, as a file of the guest
// folder; edit changes it first.
@(private="file")
untrusted_level_write :: proc(t:^testing.T,types:^asset.Types,path:string,id:base.Asset_Id,edit:proc(level:^asset.Scene)) -> bool {
    level:asset.Scene;asset.scene_init(&level,types,id);defer asset.scene_destroy(&level)
    asset.scene_entity_add(&level,1,0,"Block")
    asset.scene_entity_add(&level,2,0,"Lamp")
    block:=UNTRUSTED_BLOCK
    asset.scene_set(&level,1,"Scene_Test_Block",&block)
    asset.scene_set(&level,2,"Scene_Test_Lamp",&Scene_Test_Lamp{3,1})
    if edit!=nil {edit(&level)}
    return testing.expect_value(t,asset.scene_save(&level,path),asset.Error.None)
}

@(private="file")
untrusted_block_set :: proc(level:^asset.Scene,block:Scene_Test_Block) {
    block:=block
    asset.scene_set(level,1,"Scene_Test_Block",&block)
}

// A level whose file the game did not ship loads only what the game lets a
// player author, with values its fields allow and references to what is
// there; anything else fails saying what failed, and leaves the world as it was.
@(test)
an_untrusted_level_loads_only_what_its_rules_allow :: proc(t:^testing.T) {
    p:Scene_Test_Project
    guest,ok:=untrusted_project_open(t,&p,"untrusted")
    defer scene_test_project_close(&p)
    if !ok {return}
    allowed:=[]typeid{Scene_Test_Block,Scene_Test_Lamp}
    referencing:=[]typeid{Scene_Test_Block,Scene_Test_Lamp,Scene_Reference}
    w:=host.app_world_ref(&p.app,p.world)
    if !untrusted_level_write(t,&p.types,fmt.tprintf("%s/ok.scene",guest),{0x4a,9},nil) {return}
    report,error:=load_untrusted(w,&p.app,"levels/ok.scene",{components=allowed,max_entities=2})
    if !testing.expect_value(t,error,Error.None) {return}
    testing.expect_value(t,report.entities,2)
    first:=core.entity_of(&p.world.entities,base.Entity_Id(1))
    blocks:=core.read(&p.world.blocks)
    if !testing.expect_value(t,core.count(blocks),1) {return}
    lamp,_:=core.get(&p.world.ids,core.at(blocks,0).link)
    testing.expect_value(t,lamp.value,base.Entity_Id(2))

    Case :: struct {
        name:string,
        edit:proc(level:^asset.Scene),
        rules:Untrusted,
        error:Error,
        component,field:string,
        fault:serial.Value_Fault,
    }
    cases:=[]Case{
        {"too many entities",nil,{components=allowed,max_entities=1},.Too_Large,"","",.None},
        {"too many bytes",nil,{components=allowed,max_bytes=64},.Too_Large,"","",.None},
        {"a component not listed",proc(l:^asset.Scene) {asset.scene_set(l,1,"Scene_Test_Link",&Scene_Test_Link{core.Entity(2)})},{components=allowed},.Not_Allowed,"Scene_Test_Link","",.None},
        {"a float that is not finite",proc(l:^asset.Scene) {b:=UNTRUSTED_BLOCK;b.size[1]=transmute(f32)u32(0x7fc00000);untrusted_block_set(l,b)},{components=allowed},.Out_Of_Range,"Scene_Test_Block","size[1]",.Not_Finite},
        {"a float over its max",proc(l:^asset.Scene) {b:=UNTRUSTED_BLOCK;b.size[2]=500;untrusted_block_set(l,b)},{components=allowed},.Out_Of_Range,"Scene_Test_Block","size[2]",.Above_Max},
        {"a float under its min",proc(l:^asset.Scene) {b:=UNTRUSTED_BLOCK;b.size[0]=-1;untrusted_block_set(l,b)},{components=allowed},.Out_Of_Range,"Scene_Test_Block","size[0]",.Below_Min},
        {"an enum that is none of its values",proc(l:^asset.Scene) {b:=UNTRUSTED_BLOCK;b.shape=Scene_Test_Shape(9);untrusted_block_set(l,b)},{components=allowed},.Out_Of_Range,"Scene_Test_Block","shape",.Not_A_Choice},
        {"an entity outside the level",proc(l:^asset.Scene) {b:=UNTRUSTED_BLOCK;b.link=core.Entity(99);untrusted_block_set(l,b)},{components=allowed},.Unknown_Reference,"Scene_Test_Block","link",.Refused},
        {"an asset the game does not have",proc(l:^asset.Scene) {b:=UNTRUSTED_BLOCK;b.material={0x77,7};untrusted_block_set(l,b)},{components=allowed},.Unknown_Reference,"Scene_Test_Block","material",.Refused},
        {"an instance of a prefab the game does not have",proc(l:^asset.Scene) {
            other:asset.Scene;asset.scene_init(&other,l.types,{0x77,8});defer asset.scene_destroy(&other)
            asset.scene_entity_add(&other,1,0,"Other")
            asset.scene_instantiate(l,&other,{0x77,8},0)
        },{components=allowed},.Unknown_Reference,"","",.None},
        {"a reference to a scene of a player",proc(l:^asset.Scene) {
            asset.scene_entity_add(l,3,0,"Room")
            asset.scene_set(l,3,"Scene_Reference",&Scene_Reference{scene=UNTRUSTED_GUEST_ROOM})
        },{components=referencing},.Not_Allowed,"Scene_Reference","",.None},
        {"a reference to a scene that is not there",proc(l:^asset.Scene) {
            asset.scene_entity_add(l,3,0,"Room")
            asset.scene_set(l,3,"Scene_Reference",&Scene_Reference{scene={0x77,9}})
        },{components=referencing},.Unknown_Reference,"Scene_Reference","scene",.Refused},
        // What the rules allow loads, and replaces the world.
        {"any component of the world",proc(l:^asset.Scene) {asset.scene_set(l,1,"Scene_Test_Link",&Scene_Test_Link{core.Entity(2)})},{},.None,"","",.None},
        {"a reference to a scene the game ships",proc(l:^asset.Scene) {
            asset.scene_entity_add(l,3,0,"Room")
            asset.scene_set(l,3,"Scene_Reference",&Scene_Reference{scene=UNTRUSTED_ROOM})
        },{components=referencing},.None,"","",.None},
    }
    for c,i in cases {
        if !untrusted_level_write(t,&p.types,fmt.tprintf("%s/case%d.scene",guest,i),{0x4a,10+u64(i)},c.edit) {return}
        report,error=load_untrusted(w,&p.app,fmt.tprintf("levels/case%d.scene",i),c.rules)
        testing.expectf(t,error==c.error,"%s: %v, not %v",c.name,error,c.error)
        if c.error==.None {continue}
        testing.expectf(t,untrusted_text(report,error)!="","%s: says what failed",c.name)
        testing.expectf(t,report.refused.component==c.component,"%s: component %q",c.name,report.refused.component)
        testing.expectf(t,base.text_get(report.refused.field[:])==c.field,"%s: field %q",c.name,base.text_get(report.refused.field[:]))
        testing.expectf(t,report.refused.fault==c.fault,"%s: fault %v",c.name,report.refused.fault)
        testing.expectf(t,p.world.entities.alive==2 && core.entity_of(&p.world.entities,base.Entity_Id(1))==first,"%s: the world is as it was",c.name)
        blocks=core.read(&p.world.blocks)
        testing.expectf(t,core.count(blocks)==1 && core.at(blocks,0).size==UNTRUSTED_BLOCK.size,"%s: the block is as it was",c.name)
    }
}

// Whatever the file of a level holds, random bytes or random values, its load
// returns: it fails leaving the world as it was or loads, and frees all it took.
@(test)
an_untrusted_level_of_random_bytes_or_values_never_crashes :: proc(t:^testing.T) {
    p:Scene_Test_Project
    guest,ok:=untrusted_project_open(t,&p,"hostile")
    defer scene_test_project_close(&p)
    if !ok {return}
    allowed:=[]typeid{Scene_Test_Block,Scene_Test_Lamp,Scene_Reference}
    w:=host.app_world_ref(&p.app,p.world)
    path:=fmt.tprintf("%s/hostile.scene",guest)
    rng:=base.rng_make(0x5eed)
    floats:=[]f32{transmute(f32)u32(0x7fc00000),transmute(f32)u32(0x7f800000),transmute(f32)u32(0xff800000),max(f32),-max(f32),0,1,99,100.5,-0.5}
    assets:=[]base.Asset_Id{{},TEST_LAMP,UNTRUSTED_ROOM,UNTRUSTED_GUEST_ROOM,{0x77,1}}
    pick :: proc(rng:^base.Rng,below:int) -> int {return int(base.rng_u64(rng)%u64(below))}
    tracking:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracking,context.allocator)
    defer mem.tracking_allocator_destroy(&tracking)
    loaded,refused:=0,0
    for round in 0..<300 {
        runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
        level:asset.Scene;asset.scene_init(&level,&p.types,{0x5a,u64(round)})
        count:=1+pick(&rng,48)
        for e in 1..=count {
            asset.scene_entity_add(&level,base.Entity_Id(e),pick(&rng,3)==0?base.Entity_Id(1+pick(&rng,e)):0,"E")
            switch pick(&rng,3) {
            case 0:
                b:Scene_Test_Block
                for &v in b.size {v=floats[pick(&rng,len(floats))]}
                b.shape=Scene_Test_Shape(pick(&rng,3))
                b.material=assets[pick(&rng,len(assets))]
                b.link=core.Entity(pick(&rng,count+8))
                asset.scene_set(&level,base.Entity_Id(e),"Scene_Test_Block",&b)
            case 1:
                asset.scene_set(&level,base.Entity_Id(e),"Scene_Test_Lamp",&Scene_Test_Lamp{floats[pick(&rng,len(floats))],1})
            case 2:
                r:=Scene_Reference{scene=assets[pick(&rng,len(assets))],rule=Section_Rule(pick(&rng,4)),extents={floats[pick(&rng,len(floats))],1,1}}
                asset.scene_set(&level,base.Entity_Id(e),"Scene_Reference",&r)
            }
        }
        data,written:=asset.scene_bytes(&level,context.temp_allocator)
        asset.scene_destroy(&level)
        if !testing.expect_value(t,written,asset.Error.None) {return}
        switch round%4 {
        case 1:
            // Random bytes.
            data=make([]u8,pick(&rng,4096),context.temp_allocator)
            for &b in data {b=u8(base.rng_u32(&rng))}
        case 2,3:
            // Bytes of the file changed at random; then its hash made to match them again.
            for _ in 0..<1+pick(&rng,8) {data[pick(&rng,len(data))]=u8(base.rng_u32(&rng))}
            if round%4==3 && len(data)>=asset.HEADER_SIZE {(cast(^asset.Header)raw_data(data)).content_hash=asset.blob_hash(data)}
        }
        if !testing.expect(t,serial.file_write_atomic(path,data)==.None) {return}
        alive:=p.world.entities.alive
        saved:=context.allocator
        context.allocator=mem.tracking_allocator(&tracking)
        report,error:=load_untrusted(w,&p.app,round%2==0?"levels/hostile.scene":path,{components=allowed,max_entities=40,max_bytes=1<<16})
        _=untrusted_text(report,error)
        context.allocator=saved
        if error==.None {loaded+=1} else {
            refused+=1
            testing.expectf(t,p.world.entities.alive==alive,"round %d: a load that fails (%v) leaves the world as it was",round,error)
        }
        testing.expectf(t,len(tracking.allocation_map)==0 && len(tracking.bad_free_array)==0,"round %d: the load frees all it took",round)
    }
    testing.expect(t,loaded>0 && refused>0,"some levels load and some do not")
}
