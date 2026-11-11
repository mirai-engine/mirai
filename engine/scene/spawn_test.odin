package scene

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:slice"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"

@(private) Spawn_Test_Light :: struct {range,intensity:f32}
@(private) Spawn_Test_Link :: struct {target:core.Entity}

@(private)
@(test_world)
Spawn_Test_World :: struct {
    using world:Test_World,
    ids:core.Table(core.Id),
    names:core.Table(core.Name),
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    lights:core.Table(Spawn_Test_Light),
    links:core.Table(Spawn_Test_Link),
    instances:core.Table(Prefab_Instance),
    members:core.Table(Prefab_Member),
    pendings:core.Table(Prefab_Pending),
    disabled:core.Table(core.Disabled),
    forms:Prefab_Forms,
}

@(private="file") SPAWN_BULB :: base.Asset_Id{0x5b,1}
@(private="file") SPAWN_LAMP :: base.Asset_Id{0x5b,2}
@(private="file") SPAWN_LIGHT :: "Spawn_Test_Light"
@(private="file") SPAWN_LINK :: "Spawn_Test_Link"

// A project in a temporary folder with two Worlds of its application: one
// spawns from the forms it keeps, the other reads the prefab at every spawn.
@(private="file")
Spawn_Test :: struct {
    folder:string,
    types:asset.Types,
    info:core.World_Info,
    assets:host.Assets,
    app:host.App,
    kept,read:^Spawn_Test_World,
}

@(private="file")
spawn_test_open :: proc(t:^testing.T,p:^Spawn_Test,name:string) -> bool {
    p.folder=base.test_folder(t,fmt.tprintf("spawn-%s",name))
    if p.folder=="" {return false}
    asset.types_init(&p.types)
    p.info=test_info(t,Spawn_Test_World) or_return
    if !testing.expect(t,host.assets_init(&p.assets,{root=p.folder,capacity=2*PREFAB_FORMS})) {return false}
    p.app={info=&p.info,assets=&p.assets,allocator=context.allocator}
    p.kept=cast(^Spawn_Test_World)host.app_world_create(&p.app)
    p.read=cast(^Spawn_Test_World)host.app_world_create(&p.app)
    return testing.expect(t,p.kept!=nil && p.read!=nil)
}

@(private="file")
spawn_test_close :: proc(p:^Spawn_Test) {
    host.app_world_free(&p.app,p.kept)
    host.app_world_free(&p.app,p.read)
    delete(p.app.worlds)
    host.assets_destroy(&p.assets)
    asset.types_destroy(&p.types)
    test_info_destroy(&p.info)
}

// A bulb whose glass names it.
@(private="file")
spawn_test_bulb :: proc(bulb:^asset.Scene,types:^asset.Types,range:f32) {
    asset.scene_init(bulb,types,SPAWN_BULB)
    bulb.doc.flags+={.Prefab}
    asset.scene_entity_add(bulb,1,0,"Bulb")
    asset.scene_entity_add(bulb,2,1,"Glass")
    light:=Spawn_Test_Light{range,1}
    asset.scene_set(bulb,1,SPAWN_LIGHT,&light)
    link:=Spawn_Test_Link{core.Entity(1)}
    asset.scene_set(bulb,2,SPAWN_LINK,&link)
}

// A lamp that places a bulb, sets its intensity and names it.
@(private="file")
spawn_test_lamp :: proc(t:^testing.T,lamp:^asset.Scene,types:^asset.Types,bulb:^asset.Scene) {
    asset.scene_init(lamp,types,SPAWN_LAMP)
    lamp.doc.flags+={.Prefab}
    asset.scene_entity_add(lamp,1,0,"Lamp")
    inner,placed:=asset.scene_instantiate(lamp,bulb,SPAWN_BULB,1)
    testing.expect_value(t,placed,asset.Error.None)
    light,_:=asset.scene_get(lamp,inner,SPAWN_LIGHT,Spawn_Test_Light)
    light.intensity=4
    asset.scene_set(lamp,inner,SPAWN_LIGHT,&light)
    testing.expect_value(t,asset.scene_override_add(lamp,inner,base.name_hash(SPAWN_LIGHT),"intensity"),asset.Error.None)
    link:=Spawn_Test_Link{core.Entity(inner)}
    asset.scene_set(lamp,1,SPAWN_LINK,&link)
}

// The same prefab placed in both Worlds, from the forms of one and read anew
// in the other: the same report.
@(private="file")
spawn_test_both :: proc(t:^testing.T,p:^Spawn_Test,s:Spawn,loc:=#caller_location) -> core.Entity {
    kept,kept_error:=spawn_placed(core.commands_of(host.app_world_ref(&p.app,p.kept)),&p.assets,s,&p.kept.forms)
    read,read_error:=spawn_placed(core.commands_of(host.app_world_ref(&p.app,p.read)),&p.assets,s,nil)
    testing.expect_value(t,kept_error,Error.None,loc=loc)
    testing.expect_value(t,read_error,Error.None,loc=loc)
    testing.expect(t,kept.root==read.root && kept.root!=core.NONE && kept.entities==read.entities && kept.components==read.components && kept.dangling==read.dangling,"both report the same",loc=loc)
    return kept.root
}

// Both Worlds settled hold the same rows of the same entities in every table.
@(private="file")
spawn_test_same :: proc(t:^testing.T,p:^Spawn_Test,loc:=#caller_location) {
    a,b:=host.app_world_ref(&p.app,p.kept),host.app_world_ref(&p.app,p.read)
    core.world_settle(a)
    core.world_settle(b)
    testing.expect_value(t,core.world_entities(a).alive,core.world_entities(b).alive,loc=loc)
    for &info in p.info.tables {
        if info.place!=.World {continue}
        from,to:=core.world_table_at(a,&info),core.world_table_at(b,&info)
        bytes:=len(from.entities)*info.info.size
        same:=slice.equal(from.entities[:],to.entities[:]) && slice.equal(from.off[:],to.off[:]) && from.on==to.on
        same=same && (bytes==0 || mem.compare_ptrs(from.values.data,to.values.data,bytes)==0)
        testing.expectf(t,same,"the rows of %s differ",info.name,loc=loc)
    }
}

@(private="file")
Spawn_Test_Count :: struct {
    backing:runtime.Allocator,
    count:int,
}

@(private="file")
spawn_test_count :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]u8,runtime.Allocator_Error) {
    c:=(^Spawn_Test_Count)(data)
    #partial switch mode {
    case .Alloc,.Alloc_Non_Zeroed,.Resize,.Resize_Non_Zeroed:
        if size>0 {c.count+=1}
    }
    return c.backing.procedure(c.backing.data,mode,size,alignment,old_memory,old_size,loc)
}

// A prefab spawned again is placed from the form its World keeps: the world
// it gives is the one reading the prefab anew gives, with the prefab it
// places, what it set on it and the entities it names, and it allocates
// nothing but the entities and their rows. The form goes when a file it was
// read from changes, and stays in its World when the World is copied.
@(test)
a_prefab_spawned_again_is_placed_as_read_anew_from_the_form_its_world_keeps :: proc(t:^testing.T) {
    p:Spawn_Test
    if !spawn_test_open(t,&p,"forms") {return}
    defer spawn_test_close(&p)
    bulb,lamp:asset.Scene
    spawn_test_bulb(&bulb,&p.types,1)
    testing.expect_value(t,asset.scene_save(&bulb,fmt.tprintf("%s/bulb.scene",p.folder)),asset.Error.None)
    spawn_test_lamp(t,&lamp,&p.types,&bulb)
    testing.expect_value(t,asset.scene_save(&lamp,fmt.tprintf("%s/lamp.scene",p.folder)),asset.Error.None)
    asset.scene_destroy(&bulb)
    asset.scene_destroy(&lamp)
    testing.expect(t,host.assets_scan(&p.assets))
    // Loaded, as a scene that names them loads them: a spawn places them in the call.
    testing.expect(t,host.assets_scene(&p.assets,SPAWN_BULB)!=nil && host.assets_scene(&p.assets,SPAWN_LAMP)!=nil)

    counted:=Spawn_Test_Count{backing=context.allocator}
    counted_temp:=Spawn_Test_Count{backing=context.temp_allocator}
    context.allocator={spawn_test_count,&counted}
    context.temp_allocator={spawn_test_count,&counted_temp}
    forms:=&p.kept.forms
    at:=core.Transform{position={1,2,3},rotation=1,scale={1,1,1}}

    first:=spawn_test_both(t,&p,{prefab=SPAWN_LAMP,transform=at})
    testing.expect_value(t,forms.prepared,1)
    spawn_test_both(t,&p,{prefab=SPAWN_LAMP,transient=true})
    spawn_test_same(t,&p)
    spawn_test_both(t,&p,{prefab=SPAWN_LAMP,parent=first,transform=at})
    spawn_test_same(t,&p)
    testing.expect_value(t,forms.prepared,1)
    testing.expect_value(t,len(forms.items),1)
    testing.expect_value(t,len(forms.items[0].sources),2)
    // What a spawn asks of the allocators of its call, its entities and rows aside, which the tables of the World hold.
    before:=counted.count+counted_temp.count
    _,read_error:=spawn_placed(core.commands_of(host.app_world_ref(&p.app,p.read)),&p.assets,{prefab=SPAWN_LAMP},nil)
    testing.expect(t,read_error==.None && counted.count+counted_temp.count>before,"reading the prefab allocates")
    before=counted.count+counted_temp.count
    _,kept_error:=spawn_placed(core.commands_of(host.app_world_ref(&p.app,p.kept)),&p.assets,{prefab=SPAWN_LAMP},forms)
    testing.expect_value(t,kept_error,Error.None)
    testing.expect_value(t,counted.count+counted_temp.count-before,0)
    spawn_test_same(t,&p)

    // The copy is no instance of a document and holds what the prefab does: the bulb at its intensity, named by the lamp
    // and by its glass. Its root alone says the prefab it is of; the bulb the lamp places is of no prefab here.
    w:=p.kept
    testing.expect_value(t,core.count(&w.members),0)
    lit,found:=core.get(&w.links,first)
    light,has_light:=core.get(&w.lights,lit.target)
    testing.expect(t,found && has_light && light.range==1 && light.intensity==4)
    placed,of_prefab:=prefab_instance(host.app_world_ref(&p.app,p.kept),first)
    testing.expect(t,of_prefab && placed.prefab==SPAWN_LAMP && placed.stamp==0)
    _,inner_placed:=prefab_instance(host.app_world_ref(&p.app,p.kept),lit.target)
    testing.expect(t,!inner_placed)

    // The bulb changes in memory, as an editor holds it unsaved: the lamp is read again, once.
    spawn_test_bulb(&bulb,&p.types,5)
    data,encoded:=asset.scene_bytes(&bulb)
    testing.expect_value(t,encoded,asset.Error.None)
    testing.expect_value(t,asset.registry_memory_set(&p.assets.registry,"bulb.scene",data),asset.Error.None)
    delete(data)
    asset.scene_destroy(&bulb)
    testing.expect(t,host.assets_reload(&p.assets,SPAWN_BULB))
    for _ in 0..<2 {
        changed:=spawn_test_both(t,&p,{prefab=SPAWN_LAMP})
        spawn_test_same(t,&p)
        lit,_=core.get(&w.links,changed)
        light,_=core.get(&w.lights,lit.target)
        testing.expect(t,light.range==5 && light.intensity==4)
    }
    testing.expect_value(t,forms.prepared,2)
    testing.expect_value(t,len(forms.items),1)

    // A copy of the World, and the World copied back over, as a rollback does: the forms stay where they were made.
    other:=cast(^Spawn_Test_World)host.app_world_create(&p.app)
    if !testing.expect(t,other!=nil) {return}
    defer host.app_world_free(&p.app,other)
    testing.expect(t,core.world_copy(&p.info,other,p.kept))
    testing.expect_value(t,len(other.forms.items),0)
    _,copy_error:=spawn_prefab(core.commands_of(host.app_world_ref(&p.app,other)),&p.assets,{prefab=SPAWN_LAMP})
    testing.expect_value(t,copy_error,Error.None)
    testing.expect_value(t,other.forms.prepared,1)
    testing.expect(t,core.world_copy(&p.info,p.kept,other))
    testing.expect(t,core.world_copy(&p.info,p.read,other))
    testing.expect_value(t,len(forms.items),1)
    spawn_test_both(t,&p,{prefab=SPAWN_LAMP})
    spawn_test_same(t,&p)
    testing.expect_value(t,forms.prepared,2)
}

// A World keeps so many forms and no more: the prefab spawned longest ago
// gives its place, and is read again when it is spawned.
@(test)
the_forms_a_world_keeps_are_bounded_and_the_one_spawned_longest_ago_goes :: proc(t:^testing.T) {
    p:Spawn_Test
    if !spawn_test_open(t,&p,"bound") {return}
    defer spawn_test_close(&p)
    for at in 0..=PREFAB_FORMS {
        crate:asset.Scene
        asset.scene_init(&crate,&p.types,{0x5c,u64(at)+1})
        crate.doc.flags+={.Prefab}
        asset.scene_entity_add(&crate,1,0,"Crate")
        testing.expect_value(t,asset.scene_save(&crate,fmt.tprintf("%s/crate%d.scene",p.folder,at)),asset.Error.None)
        asset.scene_destroy(&crate)
    }
    testing.expect(t,host.assets_scan(&p.assets))
    for at in 0..=PREFAB_FORMS {testing.expect(t,host.assets_scene(&p.assets,{0x5c,u64(at)+1})!=nil)}
    c:=core.commands_of(host.app_world_ref(&p.app,p.kept))
    forms:=&p.kept.forms
    for at in 0..=PREFAB_FORMS {
        _,error:=spawn_prefab(c,&p.assets,{prefab={0x5c,u64(at)+1},transient=true})
        testing.expect_value(t,error,Error.None)
    }
    testing.expect_value(t,len(forms.items),PREFAB_FORMS)
    testing.expect_value(t,forms.prepared,PREFAB_FORMS+1)
    testing.expect(t,forms.bytes>0 && forms.bytes<=PREFAB_FORMS_BYTES)
    // The last one is kept, the first one is not.
    _,error:=spawn_prefab(c,&p.assets,{prefab={0x5c,u64(PREFAB_FORMS)+1},transient=true})
    testing.expect(t,error==.None && forms.prepared==PREFAB_FORMS+1)
    _,error=spawn_prefab(c,&p.assets,{prefab={0x5c,1},transient=true})
    testing.expect(t,error==.None && forms.prepared==PREFAB_FORMS+2 && len(forms.items)==PREFAB_FORMS)
}
