package scene

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"

@(private="file") Section_Test_Lamp :: struct {range:f32}
@(private="file") Section_Test_Link :: struct {target:core.Entity}
// Draws a far form of its own, as a terrain does.
@(component,far)
@(private="file") Section_Test_Ground :: struct {height:f32}

// A World with what sections need, as the generator makes one.
@(private="file")
Section_World :: struct {
    using world:core.Test_World,
    ids:core.Table(core.Id),
    names:core.Table(core.Name),
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    disabled:core.Table(core.Disabled),
    keeps:core.Table(core.Keep),
    references:core.Table(Scene_Reference),
    members:core.Table(Section_Member),
    held:core.Table(Section_Held),
    dormants:core.Table(Dormant),
    tombstones:core.Table(Tombstone),
    roaming:core.Table(Roaming),
    lamps:core.Table(Section_Test_Lamp),
    links:core.Table(Section_Test_Link),
    sources:core.Table(Prefab_Source),
    grounds:core.Table(Section_Test_Ground),
    kept:core.Table(Far_Kept),
    hierarchy:core.Hierarchy,
    unresolved:Unresolved_References,
    records:Section_Records,
    root:Scene_Root,
}

// A project with that World and its assets in a temporary folder, and the
// loads and requests of its sections.
@(private="file")
Section_Fixture :: struct {
    folder:string,
    types:asset.Types,
    info:core.World_Info,
    assets:host.Assets,
    app:host.App,
    world:^Section_World,
    loads:Section_Loads,
    loading:Section_Loading,
    requests:Section_Requests,
    views:Section_Views,
    problems:^core.Problems,
}

@(private="file")
section_fixture_open :: proc(t:^testing.T,f:^Section_Fixture,name:string) -> bool {
    f.folder=base.test_folder(t,fmt.tprintf("sections-%s",name))
    if f.folder=="" {return false}
    f.info=core.test_info(t,Section_World,test_types) or_return
    asset.types_init(&f.types)
    if !testing.expect(t,host.assets_init(&f.assets,{root=f.folder,capacity=8})) {return false}
    f.app={info=&f.info,assets=&f.assets,allocator=context.allocator}
    f.world=cast(^Section_World)host.app_world_create(&f.app)
    f.problems=new(core.Problems)
    return testing.expect(t,f.world!=nil)
}

@(private="file")
section_fixture_close :: proc(f:^Section_Fixture) {
    section_loads_free(&f.loads)
    delete(f.requests.queue.items)
    delete(f.views.items)
    free(f.problems)
    host.app_world_free(&f.app,f.world)
    delete(f.app.worlds)
    host.assets_destroy(&f.assets)
    asset.types_destroy(&f.types)
    core.test_info_destroy(&f.info)
}

@(private="file")
section_ref :: proc(f:^Section_Fixture) -> core.World_Ref {return host.app_world_ref(&f.app,f.world)}

// A frame of what sections run: their states, then the fields that wait for them.
@(private="file")
section_frame :: proc(f:^Section_Fixture) {
    w:=section_ref(f)
    scene_sections(w,&f.app,&f.world.references,&f.requests,&f.loads,&f.loading,core.ref(&f.world.root),core.ref(&f.views),nil,f.problems)
    core.world_settle(w)
    scene_references(w,&f.world.unresolved,core.read(&f.world.ids))
    core.world_settle(w)
}

@(private="file")
section_save :: proc(t:^testing.T,f:^Section_Fixture,doc:^asset.Scene,name:string) {
    testing.expect_value(t,asset.scene_save(doc,fmt.tprintf("%s/%s",f.folder,name)),asset.Error.None)
    asset.scene_destroy(doc)
}

@(private="file")
section_entity :: proc(f:^Section_Fixture,id:base.Entity_Id) -> core.Entity {return core.entity_of(&f.world.entities,id)}

// How many entities of the world have an Id.
@(private="file")
section_ids :: proc(f:^Section_Fixture,id:base.Entity_Id) -> (count:int) {
    ids:=core.raw(&f.world.ids)
    for row in 0..<core.raw_count(ids) {
        if (^core.Id)(core.raw_value(ids,type_info_of(core.Id),row)).value==id {count+=1}
    }
    return
}

@(private="file") SECTION_ROOT :: base.Asset_Id{0x6a,1}
@(private="file") SECTION_ROOM :: base.Asset_Id{0x6a,2}

// A level with a room it streams, 10 m along x, and a switch that names the
// lamp of the room; the room has a lamp, a chest with a lid, a crate, a shelf
// with a book, and a wanderer.
@(private="file")
section_level_write :: proc(t:^testing.T,f:^Section_Fixture) {
    at :: proc(x,y:f32) -> core.Transform {return {position={x,y,0},rotation=1,scale={1,1,1}}}
    root:asset.Scene;asset.scene_init(&root,&f.types,asset.KIND_SCENE,SECTION_ROOT)
    asset.scene_entity_add(&root,1,0,"Room")
    asset.scene_set(&root,1,"Transform",&core.Transform{position={10,0,0},rotation=1,scale={1,1,1}})
    asset.scene_set(&root,1,"Scene_Reference",&Scene_Reference{scene=SECTION_ROOM,rule=.Spatial,extents={20,20,20}})
    asset.scene_entity_add(&root,2,0,"Switch")
    asset.scene_set(&root,2,"Section_Test_Link",&Section_Test_Link{core.Entity(id_in(1,10))})
    section_save(t,f,&root,"root.scene")
    room:asset.Scene;asset.scene_init(&room,&f.types,asset.KIND_SCENE,SECTION_ROOM)
    Thing :: struct {id,parent:base.Entity_Id,name:string,x,y,range:f32}
    things:=[]Thing{{10,0,"Lamp",1,0,1},{11,0,"Chest",0,0,2},{16,11,"Lid",0,1,6},{12,0,"Crate",0,0,3},{13,0,"Shelf",5,0,0},{14,13,"Book",0,1,4},{15,0,"Wanderer",2,0,0}}
    for thing in things {
        asset.scene_entity_add(&room,thing.id,thing.parent,thing.name)
        pose:=at(thing.x,thing.y)
        asset.scene_set(&room,thing.id,"Transform",&pose)
        if thing.range>0 {asset.scene_set(&room,thing.id,"Section_Test_Lamp",&Section_Test_Lamp{thing.range})}
    }
    section_save(t,f,&room,"room.scene")
}

// A room streamed loaded and off holds what it loaded, asked on lets go of
// it; dropped, what changed in it sleeps (a chest
// opened, a book whose shelf went, a coin added), what was destroyed leaves a
// tombstone, what roams hangs from the root, and the switch that named its
// lamp waits for it again; loaded again, all of it is there before it joins,
// once, and the switch names the new lamp.
@(test)
a_streamed_section_holds_and_comes_back_as_it_was_left :: proc(t:^testing.T) {
    f:Section_Fixture
    if !section_fixture_open(t,&f,"stream") {return}
    defer section_fixture_close(&f)
    section_level_write(t,&f)
    w:=section_ref(&f)
    if _,error:=load(w,&f.app,"root.scene");!testing.expect_value(t,error,Error.None) {return}
    room,switch_:=section_entity(&f,1),section_entity(&f,2)
    LINK:=base.name_hash("Section_Test_Link")
    testing.expect_value(t,unresolved_target(&f.world.unresolved,switch_,LINK,0),id_in(1,10))

    section_stream(&f.requests,room,.Loaded)
    section_frame(&f)
    links_before:=core.version(&f.world.links)
    section_frame(&f)
    reference,_:=core.get(&f.world.references,room)
    testing.expect_value(t,reference.state,Section_State.Active)
    testing.expect_value(t,section_state(reference),Section_State.Loaded)
    testing.expect(t,reference.loaded==SECTION_ROOM && reference.held,"it joins off")
    lamp:=section_entity(&f,id_in(1,10))
    testing.expect(t,core.alive(&f.world.entities,lamp) && row_has(&f.world.held,lamp) && row_has(&f.world.disabled,lamp),"what it loaded is held")
    link,_:=core.get(&f.world.links,switch_)
    testing.expect_value(t,link.target,lamp)
    testing.expect(t,core.version(&f.world.links)>links_before,"the field resolved is stamped")
    testing.expect(t,len(f.world.unresolved.resolved)==1 && f.world.unresolved.resolved[0].entity==switch_,"and said to be the load's, not an edit")

    section_stream(&f.requests,room,.Active)
    section_frame(&f)
    testing.expect(t,!row_has(&f.world.disabled,lamp) && !row_has(&f.world.held,lamp),"on, it lets go of what it held")

    // A view of the editor shows it off over what streams, and lets go of it as it was.
    section_view(&f.views,room,.Loaded)
    section_frame(&f)
    reference,_=core.get(&f.world.references,room)
    testing.expect(t,reference.held && reference.streamed==.Active && row_has(&f.world.held,lamp),"the view holds it; what streams stays")
    section_view(&f.views,room,{},false)
    section_frame(&f)
    testing.expect(t,!row_has(&f.world.held,lamp),"without the view it is on again")

    chest,crate,book,wanderer:=section_entity(&f,id_in(1,11)),section_entity(&f,id_in(1,12)),section_entity(&f,id_in(1,14)),section_entity(&f,id_in(1,15))
    core.edit(&f.world.lamps,chest).range=9
    core.edit(&f.world.lamps,book).range=8
    core.destroy(&f.world.entities,crate)
    core.add(&f.world.roaming,wanderer,Roaming{})
    coin:=core.create(&f.world.entities)
    core.add(&f.world.ids,coin,core.Id{777})
    core.add(&f.world.parents,coin,core.Parent{room,10})
    core.add(&f.world.transforms,coin,core.Transform{position={3,0,0},rotation=1,scale={1,1,1}})
    core.world_settle(w)

    // The shelf did not change and goes; the book on it did, and stays where it is.
    section_stream(&f.requests,room,.Unloaded)
    section_frame(&f)
    testing.expect(t,!core.alive(&f.world.entities,lamp),"what did not change goes")
    for x in ([]core.Entity{chest,book,coin}) {
        testing.expect(t,row_has(&f.world.dormants,x) && row_has(&f.world.disabled,x) && row_has(&f.world.held,x),"what changed sleeps, off because of its section")
    }
    testing.expect(t,!core.alive(&f.world.entities,section_entity(&f,id_in(1,16))),"the lid, as it was, goes")
    parent,_:=core.get(&f.world.parents,book)
    pose,_:=core.get(&f.world.transforms,book)
    testing.expect_value(t,parent.entity,room)
    testing.expect_value(t,pose.position,[3]f32{5,1,0})
    testing.expect(t,core.alive(&f.world.entities,wanderer) && !row_has(&f.world.parents,wanderer) && !row_has(&f.world.dormants,wanderer),"what roams hangs from the root")
    pose,_=core.get(&f.world.transforms,wanderer)
    testing.expect_value(t,pose.position,[3]f32{12,0,0})
    buried:=map[base.Entity_Id]bool{}
    defer delete(buried)
    for row in 0..<core.raw_count(core.raw(&f.world.tombstones)) {buried[(^Tombstone)(core.raw_value(core.raw(&f.world.tombstones),type_info_of(Tombstone),row)).id]=true}
    testing.expect(t,buried[id_in(1,12)] && buried[id_in(1,15)] && len(buried)==2,"the crate and the wanderer leave tombstones")
    link,_=core.get(&f.world.links,switch_)
    testing.expect_value(t,link.target,core.NONE)
    testing.expect_value(t,unresolved_target(&f.world.unresolved,switch_,LINK,0),id_in(1,10))
    testing.expect(t,len(f.world.unresolved.resolved)==1 && f.world.unresolved.resolved[0].entity==switch_,"the none the drop wrote is said to be the drop's, not an edit")
    saved:asset.Scene
    if _,error:=capture(w,&saved,&f.types,{kind=asset.KIND_SCENE,id=SECTION_ROOT});testing.expect_value(t,error,Error.None) {
        named,_:=asset.scene_get(&saved,2,"Section_Test_Link",Section_Test_Link)
        testing.expect_value(t,named.target,core.Entity(id_in(1,10)))
        asset.scene_destroy(&saved)
    }
    testing.expect_value(t,len(f.world.records.items),0)

    section_stream(&f.requests,room,.Active)
    section_frame(&f)
    section_frame(&f)
    chest=section_entity(&f,id_in(1,11))
    testing.expect_value(t,section_ids(&f,id_in(1,11)),1)
    opened,_:=core.get(&f.world.lamps,chest)
    testing.expect_value(t,opened.range,9)
    lid:=section_entity(&f,id_in(1,16))
    parent,_=core.get(&f.world.parents,lid)
    testing.expect_value(t,parent.entity,chest)
    testing.expect_value(t,section_ids(&f,id_in(1,12)),0)
    testing.expect_value(t,section_ids(&f,id_in(1,15)),1)
    book=section_entity(&f,id_in(1,14))
    parent,_=core.get(&f.world.parents,book)
    pose,_=core.get(&f.world.transforms,book)
    testing.expect(t,parent.entity==room && pose.position==[3]f32{5,1,0},"the book is where it was left")
    testing.expect(t,core.alive(&f.world.entities,coin) && !row_has(&f.world.dormants,coin) && !row_has(&f.world.disabled,coin),"what was added turns on")
    testing.expect_value(t,core.raw_count(core.raw(&f.world.dormants)),0)
    testing.expect_value(t,core.raw_count(core.raw(&f.world.tombstones)),0)
    lamp=section_entity(&f,id_in(1,10))
    link,_=core.get(&f.world.links,switch_)
    testing.expect(t,link.target==lamp && lamp!=core.NONE,"the switch names the lamp that came")

    // What it took from what slept stays changed: dropped again, it sleeps again.
    section_stream(&f.requests,room,.Unloaded)
    section_frame(&f)
    testing.expect(t,row_has(&f.world.dormants,chest) && !core.alive(&f.world.entities,lamp))
}

// What of the scene of a section is not in it any more: of the section
// loaded, what was destroyed since it loaded, not what roams in it; dropped,
// its tombstones, what roamed away among them.
@(test)
a_section_says_which_entities_of_its_scene_are_gone :: proc(t:^testing.T) {
    f:Section_Fixture
    if !section_fixture_open(t,&f,"gone") {return}
    defer section_fixture_close(&f)
    section_level_write(t,&f)
    w:=section_ref(&f)
    if _,error:=load(w,&f.app,"root.scene");!testing.expect_value(t,error,Error.None) {return}
    room:=section_entity(&f,1)
    gone:=make([dynamic]base.Entity_Id,context.temp_allocator)
    documents:=assets_documents(f.app.assets)
    testing.expect(t,section_gone(w,documents,room,&gone) && len(gone)==0,"never loaded, nothing of it is gone")
    testing.expect(t,!section_gone(w,documents,section_entity(&f,2),&gone),"what is not a section says nothing")
    section_stream(&f.requests,room,.Active)
    section_frame(&f)
    section_frame(&f)
    core.destroy(&f.world.entities,section_entity(&f,id_in(1,12)))
    core.add(&f.world.roaming,section_entity(&f,id_in(1,15)),Roaming{})
    core.world_settle(w)
    testing.expect(t,section_gone(w,documents,room,&gone))
    testing.expect_value(t,len(gone),1)
    testing.expect(t,len(gone)==1 && gone[0]==id_in(1,12),"loaded, what was destroyed is gone and what roams in it is not")

    // Without its record, as a saved game loads it, its scene says what it had.
    records:=core.world_storage_of(w,Section_Records)
    saved_records:=records.items
    records.items=nil
    clear(&gone)
    testing.expect(t,section_gone(w,documents,room,&gone))
    testing.expect(t,len(gone)==1 && gone[0]==id_in(1,12),"without a record, what its scene has and the section does not")
    testing.expect(t,!section_gone(w,{},room,&gone),"without its record or its scene it cannot tell")
    records.items=saved_records

    section_stream(&f.requests,room,.Unloaded)
    section_frame(&f)
    clear(&gone)
    testing.expect(t,section_gone(w,documents,room,&gone))
    testing.expect(t,len(gone)==2 && slice.contains(gone[:],id_in(1,12)) && slice.contains(gone[:],id_in(1,15)),"dropped, its tombstones")
}

// A load begun before a scene replaced the world names an entity of the world
// that was, which may be alive in the new one: it goes, and nothing of it
// joins the new world.
@(test)
a_scene_that_replaces_the_world_takes_the_sections_loading :: proc(t:^testing.T) {
    f:Section_Fixture
    if !section_fixture_open(t,&f,"replace") {return}
    defer section_fixture_close(&f)
    section_level_write(t,&f)
    MENU :: base.Asset_Id{0x6a,9}
    menu:asset.Scene;asset.scene_init(&menu,&f.types,asset.KIND_SCENE,MENU)
    asset.scene_entity_add(&menu,1,0,"Title")
    asset.scene_entity_add(&menu,2,0,"Button")
    section_save(t,&f,&menu,"menu.scene")
    w:=section_ref(&f)
    if _,error:=load(w,&f.app,"root.scene");!testing.expect_value(t,error,Error.None) {return}
    room:=section_entity(&f,1)
    section_stream(&f.requests,room,.Active)
    section_frame(&f)
    busy:=false
    for l in f.loads.items {busy||=l.job!=nil && l.entity==room}
    testing.expect(t,busy,"the room is loading")
    job,error:=load_begin(&f.app,MENU)
    if !testing.expect_value(t,error,Error.None) {return}
    load_step(job)
    _,error=load_end(job,w)
    testing.expect_value(t,error,Error.None)
    testing.expect(t,core.alive(&f.world.entities,room),"the handle of the room names the title now")
    section_frame(&f)
    section_frame(&f)
    testing.expect_value(t,core.raw_count(core.raw(&f.world.lamps)),0)
    for l in f.loads.items {testing.expect(t,l.job==nil,"the load of the world that was went")}
}

@(private="file") SECTION_A :: base.Asset_Id{0x6b,1}
@(private="file") SECTION_B :: base.Asset_Id{0x6b,2}

// a.scene references b.scene, which references a.scene, both by hand: the
// second does not load, and its problem names the scenes around it.
@(test)
a_section_inside_its_own_scene_names_the_scenes_around_it :: proc(t:^testing.T) {
    f:Section_Fixture
    if !section_fixture_open(t,&f,"cycle") {return}
    defer section_fixture_close(&f)
    a:asset.Scene;asset.scene_init(&a,&f.types,asset.KIND_SCENE,SECTION_A)
    asset.scene_entity_add(&a,1,0,"B")
    asset.scene_set(&a,1,"Scene_Reference",&Scene_Reference{scene=SECTION_B,rule=.Manual,state=.Unloaded})
    section_save(t,&f,&a,"a.scene")
    b:asset.Scene;asset.scene_init(&b,&f.types,asset.KIND_SCENE,SECTION_B)
    asset.scene_entity_add(&b,5,0,"A again")
    asset.scene_set(&b,5,"Scene_Reference",&Scene_Reference{scene=SECTION_A,rule=.Manual,state=.Unloaded})
    section_save(t,&f,&b,"b.scene")
    w:=section_ref(&f)
    if _,error:=load(w,&f.app,"a.scene");!testing.expect_value(t,error,Error.None) {return}
    section_request(&f.requests,section_entity(&f,1),.Active)
    section_frame(&f)
    section_frame(&f)
    inner:=section_entity(&f,id_in(1,5))
    if !testing.expect(t,inner!=core.NONE,"b loaded") {return}
    section_request(&f.requests,inner,.Active)
    section_frame(&f)
    problem:=core.problem_find(f.problems,inner,"scene.section")
    if testing.expect(t,problem!=nil) {
        text:=base.text_get(problem.text[:])
        testing.expect(t,strings.contains(text,"a.scene > b.scene > a.scene"),text)
    }
    reference,_:=core.get(&f.world.references,inner)
    testing.expect_value(t,reference.failed,SECTION_A)
    for l in f.loads.items {testing.expect(t,l.job==nil)}
}

@(private="file") SECTION_FIRST :: base.Asset_Id{0x6c,1}
@(private="file") SECTION_SECOND :: base.Asset_Id{0x6c,2}

// A seat kept across scenes waits for the body it names in the scene that
// comes, and names it once it is there.
@(test)
what_is_kept_across_scenes_keeps_the_fields_it_waits_for :: proc(t:^testing.T) {
    f:Section_Fixture
    if !section_fixture_open(t,&f,"keep") {return}
    defer section_fixture_close(&f)
    first:asset.Scene;asset.scene_init(&first,&f.types,asset.KIND_SCENE,SECTION_FIRST)
    asset.scene_entity_add(&first,1,0,"Seat")
    section_save(t,&f,&first,"first.scene")
    second:asset.Scene;asset.scene_init(&second,&f.types,asset.KIND_SCENE,SECTION_SECOND)
    asset.scene_entity_add(&second,40,0,"Body")
    section_save(t,&f,&second,"second.scene")
    w:=section_ref(&f)
    if _,error:=load(w,&f.app,"first.scene");!testing.expect_value(t,error,Error.None) {return}
    seat:=section_entity(&f,1)
    core.add(&f.world.keeps,seat,core.Keep{})
    core.add(&f.world.links,seat,Section_Test_Link{})
    append(&f.world.unresolved.items,Unresolved_Reference{seat,base.name_hash("Section_Test_Link"),0,40})
    core.world_settle(w)
    job,error:=load_begin(&f.app,SECTION_SECOND)
    if !testing.expect_value(t,error,Error.None) {return}
    load_step(job)
    _,error=load_end(job,w)
    testing.expect_value(t,error,Error.None)
    references_resolve(w)
    seat=section_entity(&f,1)
    link,kept:=core.get(&f.world.links,seat)
    testing.expect(t,kept,"the seat passed")
    testing.expect(t,link.target==section_entity(&f,40) && link.target!=core.NONE,"it names the body of the scene that came")
}

@(private="file") SECTION_OUTER :: base.Asset_Id{0x6d,1}
@(private="file") SECTION_HALL :: base.Asset_Id{0x6d,2}
@(private="file") SECTION_VAULT :: base.Asset_Id{0x6d,3}

// A vault inside a hall: dropping the hall drops the vault first, whose gold
// changed, so the reference of the vault stays asleep with the gold under
// it; loaded again, the hall gives the vault back and the vault its gold.
@(test)
a_section_inside_a_dropped_one_keeps_what_changed_in_it :: proc(t:^testing.T) {
    f:Section_Fixture
    if !section_fixture_open(t,&f,"nested") {return}
    defer section_fixture_close(&f)
    outer:asset.Scene;asset.scene_init(&outer,&f.types,asset.KIND_SCENE,SECTION_OUTER)
    asset.scene_entity_add(&outer,1,0,"Hall")
    asset.scene_set(&outer,1,"Scene_Reference",&Scene_Reference{scene=SECTION_HALL,rule=.Manual})
    section_save(t,&f,&outer,"outer.scene")
    hall:asset.Scene;asset.scene_init(&hall,&f.types,asset.KIND_SCENE,SECTION_HALL)
    asset.scene_entity_add(&hall,20,0,"Door")
    asset.scene_set(&hall,20,"Section_Test_Lamp",&Section_Test_Lamp{1})
    asset.scene_entity_add(&hall,21,0,"Vault")
    asset.scene_set(&hall,21,"Scene_Reference",&Scene_Reference{scene=SECTION_VAULT,rule=.Manual})
    section_save(t,&f,&hall,"hall.scene")
    vault:asset.Scene;asset.scene_init(&vault,&f.types,asset.KIND_SCENE,SECTION_VAULT)
    asset.scene_entity_add(&vault,30,0,"Gold")
    asset.scene_set(&vault,30,"Section_Test_Lamp",&Section_Test_Lamp{5})
    asset.scene_entity_add(&vault,31,0,"Dust")
    asset.scene_set(&vault,31,"Section_Test_Lamp",&Section_Test_Lamp{0.5})
    section_save(t,&f,&vault,"vault.scene")
    w:=section_ref(&f)
    if _,error:=load(w,&f.app,"outer.scene");!testing.expect_value(t,error,Error.None) {return}
    for _ in 0..<4 {section_frame(&f)}
    VAULT_ID:=id_in(1,21)
    gold:=section_entity(&f,id_in(VAULT_ID,30))
    if !testing.expect(t,gold!=core.NONE,"the hall and its vault loaded") {return}
    core.edit(&f.world.lamps,gold).range=50

    hall_entity:=section_entity(&f,1)
    section_request(&f.requests,hall_entity,.Unloaded)
    section_frame(&f)
    reference:=section_entity(&f,VAULT_ID)
    testing.expect(t,row_has(&f.world.dormants,reference),"the vault holds what changed in it: its reference stays")
    testing.expect(t,row_has(&f.world.dormants,gold),"the gold sleeps")
    parent,_:=core.get(&f.world.parents,gold)
    testing.expect_value(t,parent.entity,reference)
    testing.expect_value(t,section_ids(&f,id_in(VAULT_ID,31)),0)
    testing.expect_value(t,section_ids(&f,id_in(1,20)),0)

    section_request(&f.requests,hall_entity,.Active)
    for _ in 0..<4 {section_frame(&f)}
    gold=section_entity(&f,id_in(VAULT_ID,30))
    testing.expect_value(t,section_ids(&f,id_in(VAULT_ID,30)),1)
    value,_:=core.get(&f.world.lamps,gold)
    testing.expect_value(t,value.range,50)
    testing.expect_value(t,section_ids(&f,id_in(VAULT_ID,31)),1)
    testing.expect_value(t,core.raw_count(core.raw(&f.world.dormants)),0)
}

@(private="file") SECTION_FIELD_ROOT :: base.Asset_Id{0x6b,1}
@(private="file") SECTION_FIELD :: base.Asset_Id{0x6b,2}

// A field streamed 10 m along x whose ground draws a far form of its own: it
// hangs from a shelf that goes when the field unloads, and holds a patch.
// Loaded and off, the ground stays on while the rest is held; dropped, it
// stays on with its patch, from the reference, where it was, and the rest
// goes; loaded again, it is the ground of the field, under the new shelf,
// and nothing is there twice.
@(test)
what_draws_a_far_form_of_its_own_stays_on_while_its_section_is_not_loaded :: proc(t:^testing.T) {
    f:Section_Fixture
    if !section_fixture_open(t,&f,"far") {return}
    defer section_fixture_close(&f)
    at :: proc(x,y:f32) -> core.Transform {return {position={x,y,0},rotation=1,scale={1,1,1}}}
    root:asset.Scene;asset.scene_init(&root,&f.types,asset.KIND_SCENE,SECTION_FIELD_ROOT)
    asset.scene_entity_add(&root,1,0,"Field")
    pose:=at(10,0)
    asset.scene_set(&root,1,"Transform",&pose)
    asset.scene_set(&root,1,"Scene_Reference",&Scene_Reference{scene=SECTION_FIELD,rule=.Spatial,extents={20,20,20}})
    section_save(t,&f,&root,"root.scene")
    field:asset.Scene;asset.scene_init(&field,&f.types,asset.KIND_SCENE,SECTION_FIELD)
    Thing :: struct {id,parent:base.Entity_Id,name:string,x:f32}
    for thing in ([]Thing{{1,0,"Shelf",5},{2,1,"Ground",1},{3,2,"Patch",1},{4,0,"Lamp",2}}) {
        asset.scene_entity_add(&field,thing.id,thing.parent,thing.name)
        local:=at(thing.x,0)
        asset.scene_set(&field,thing.id,"Transform",&local)
    }
    asset.scene_set(&field,2,"Section_Test_Ground",&Section_Test_Ground{3})
    asset.scene_set(&field,4,"Section_Test_Lamp",&Section_Test_Lamp{1})
    section_save(t,&f,&field,"field.scene")
    w:=section_ref(&f)
    if _,error:=load(w,&f.app,"root.scene");!testing.expect_value(t,error,Error.None) {return}
    reference_entity:=section_entity(&f,1)

    section_stream(&f.requests,reference_entity,.Loaded)
    section_frame(&f)
    section_frame(&f)
    ground,patch,lamp:=section_entity(&f,id_in(1,2)),section_entity(&f,id_in(1,3)),section_entity(&f,id_in(1,4))
    shelf:=section_entity(&f,id_in(1,1))
    testing.expect(t,core.alive(&f.world.entities,ground) && core.alive(&f.world.entities,patch),"it loaded")
    testing.expect(t,row_has(&f.world.held,lamp) && row_has(&f.world.held,shelf),"loaded and off, what it loaded is held")
    testing.expect(t,!row_has(&f.world.held,ground) && !row_has(&f.world.disabled,ground),"but not its ground")

    // Dropped: the ground stays on, with its patch, from the reference, where it was.
    section_stream(&f.requests,reference_entity,.Unloaded)
    section_frame(&f)
    reference,_:=core.get(&f.world.references,reference_entity)
    testing.expect(t,reference.loaded=={},"it dropped")
    testing.expect(t,!core.alive(&f.world.entities,lamp) && !core.alive(&f.world.entities,shelf),"what did not change goes")
    testing.expect(t,core.alive(&f.world.entities,ground) && core.alive(&f.world.entities,patch),"the ground stays, with what hangs from it")
    testing.expect(t,row_has(&f.world.kept,ground) && !row_has(&f.world.dormants,ground) && !row_has(&f.world.disabled,ground) && !core.entity_off(&f.world.entities,ground),"on")
    above,_:=core.get(&f.world.parents,ground)
    testing.expect_value(t,above.entity,reference_entity)
    local,_:=core.get(&f.world.transforms,ground)
    testing.expect_value(t,local.position,[3]f32{6,0,0})
    below,_:=core.get(&f.world.parents,patch)
    testing.expect_value(t,below.entity,ground)
    height,_:=core.get(&f.world.grounds,ground)
    testing.expect_value(t,height.height,f32(3))

    // Loaded again and on: the ground is the field's again, under the new shelf.
    section_stream(&f.requests,reference_entity,.Active)
    section_frame(&f)
    section_frame(&f)
    reference,_=core.get(&f.world.references,reference_entity)
    testing.expect(t,reference.loaded==SECTION_FIELD,"it loaded")
    testing.expect_value(t,section_entity(&f,id_in(1,2)),ground)
    testing.expect_value(t,section_entity(&f,id_in(1,3)),patch)
    for id in 1..=4 {testing.expectf(t,section_ids(&f,id_in(1,base.Entity_Id(id)))==1,"entity %d is there once",id)}
    testing.expect_value(t,core.raw_count(core.raw(&f.world.grounds)),1)
    testing.expect(t,!row_has(&f.world.kept,ground) && !core.entity_off(&f.world.entities,ground),"it is not kept any more, and on")
    shelf=section_entity(&f,id_in(1,1))
    above,_=core.get(&f.world.parents,ground)
    testing.expect_value(t,above.entity,shelf)
    local,_=core.get(&f.world.transforms,ground)
    testing.expect_value(t,local.position,[3]f32{1,0,0})
    below,_=core.get(&f.world.parents,patch)
    testing.expect_value(t,below.entity,ground)
    lamp=section_entity(&f,id_in(1,4))
    testing.expect(t,core.alive(&f.world.entities,lamp) && !core.entity_off(&f.world.entities,lamp))
}

// A field that never loaded shows its ground alone, kept, where it is in its
// scene; loading it, the ground is the field's, under the shelf, with the
// patch of the load under it.
@(test)
a_section_that_never_loaded_shows_what_draws_a_far_form_of_its_own :: proc(t:^testing.T) {
    f:Section_Fixture
    if !section_fixture_open(t,&f,"far_never") {return}
    defer section_fixture_close(&f)
    at :: proc(x,y:f32) -> core.Transform {return {position={x,y,0},rotation=1,scale={1,1,1}}}
    root:asset.Scene;asset.scene_init(&root,&f.types,asset.KIND_SCENE,SECTION_FIELD_ROOT)
    asset.scene_entity_add(&root,1,0,"Field")
    pose:=at(10,0)
    asset.scene_set(&root,1,"Transform",&pose)
    asset.scene_set(&root,1,"Scene_Reference",&Scene_Reference{scene=SECTION_FIELD,rule=.Spatial,extents={20,20,20}})
    section_save(t,&f,&root,"root.scene")
    field:asset.Scene;asset.scene_init(&field,&f.types,asset.KIND_SCENE,SECTION_FIELD)
    Thing :: struct {id,parent:base.Entity_Id,name:string,x:f32}
    for thing in ([]Thing{{1,0,"Shelf",5},{2,1,"Ground",1},{3,2,"Patch",1},{4,0,"Lamp",2}}) {
        asset.scene_entity_add(&field,thing.id,thing.parent,thing.name)
        local:=at(thing.x,0)
        asset.scene_set(&field,thing.id,"Transform",&local)
    }
    asset.scene_set(&field,2,"Section_Test_Ground",&Section_Test_Ground{3})
    asset.scene_set(&field,4,"Section_Test_Lamp",&Section_Test_Lamp{1})
    section_save(t,&f,&field,"field.scene")
    w:=section_ref(&f)
    if _,error:=load(w,&f.app,"root.scene");!testing.expect_value(t,error,Error.None) {return}
    reference_entity:=section_entity(&f,1)

    section_stream(&f.requests,reference_entity,.Unloaded)
    section_frame(&f)
    reference,_:=core.get(&f.world.references,reference_entity)
    testing.expect(t,reference.loaded=={} && reference.far==SECTION_FIELD,"it did not load; its far forms are of its scene")
    ground:=section_entity(&f,id_in(1,2))
    testing.expect(t,core.alive(&f.world.entities,ground) && row_has(&f.world.kept,ground) && !core.entity_off(&f.world.entities,ground),"its ground shows")
    for id in ([]base.Entity_Id{1,3,4}) {testing.expectf(t,section_ids(&f,id_in(1,id))==0,"entity %d of the field is not there",id)}
    above,_:=core.get(&f.world.parents,ground)
    testing.expect_value(t,above.entity,reference_entity)
    local,_:=core.get(&f.world.transforms,ground)
    testing.expect_value(t,local.position,[3]f32{6,0,0})
    height,_:=core.get(&f.world.grounds,ground)
    testing.expect_value(t,height.height,f32(3))
    // Another frame reads nothing again.
    section_frame(&f)
    testing.expect_value(t,core.raw_count(core.raw(&f.world.grounds)),1)

    section_stream(&f.requests,reference_entity,.Active)
    section_frame(&f)
    section_frame(&f)
    reference,_=core.get(&f.world.references,reference_entity)
    testing.expect(t,reference.loaded==SECTION_FIELD,"it loaded")
    testing.expect_value(t,section_entity(&f,id_in(1,2)),ground)
    for id in 1..=4 {testing.expectf(t,section_ids(&f,id_in(1,base.Entity_Id(id)))==1,"entity %d is there once",id)}
    testing.expect(t,!row_has(&f.world.kept,ground),"the field took it back")
    shelf,patch:=section_entity(&f,id_in(1,1)),section_entity(&f,id_in(1,3))
    above,_=core.get(&f.world.parents,ground)
    testing.expect_value(t,above.entity,shelf)
    below,_:=core.get(&f.world.parents,patch)
    testing.expect_value(t,below.entity,ground)
    local,_=core.get(&f.world.transforms,ground)
    testing.expect_value(t,local.position,[3]f32{1,0,0})

    // Loaded and off, then dropped: the ground stays on, kept, never held.
    states:=[]Section_State{.Loaded,.Unloaded,.Loaded,.Active,.Loaded,.Unloaded}
    for state in states {
        section_stream(&f.requests,reference_entity,state)
        section_frame(&f)
        section_frame(&f)
        ground=section_entity(&f,id_in(1,2))
        // Loaded and off it hangs from the shelf, which its section holds; dropped, it is on.
        testing.expectf(t,core.alive(&f.world.entities,ground) && !row_has(&f.world.held,ground),"%v: the ground is not held",state)
        if state==.Unloaded {testing.expectf(t,!core.entity_off(&f.world.entities,ground),"%v: the ground is on",state)}
        testing.expectf(t,section_ids(&f,id_in(1,2))==1,"%v: once",state)
    }
}

// An entity of a section that is not loaded, copied from the scene of the
// section by its Id in the world: it and what hangs from it, a root without
// Ids, placed where it is asked; nothing else of the scene.
@(test)
a_member_of_a_section_is_copied_from_its_scene :: proc(t:^testing.T) {
    f:Section_Fixture
    if !section_fixture_open(t,&f,"member") {return}
    defer section_fixture_close(&f)
    section_level_write(t,&f)
    w:=section_ref(&f)
    if _,error:=load(w,&f.app,"root.scene");!testing.expect_value(t,error,Error.None) {return}
    before:=core.raw_count(core.raw(&f.world.lamps))
    at:=core.Transform{position={3,4,5},rotation=1,scale={1,1,1}}
    report,error:=spawn_member(core.commands_of(w),f.app.assets,SECTION_ROOM,1,id_in(1,11),at)
    if !testing.expect_value(t,error,Error.None) {return}
    core.world_settle(w)
    testing.expect_value(t,report.entities,2)
    chest:=report.root
    pose,_:=core.get(&f.world.transforms,chest)
    testing.expect_value(t,pose.position,[3]f32{3,4,5})
    testing.expect(t,!core.has(&f.world.parents,chest) && !core.has(&f.world.ids,chest) && !core.has(&f.world.members,chest),"a root without Ids")
    lamp,_:=core.get(&f.world.lamps,chest)
    testing.expect_value(t,lamp.range,2)
    testing.expect_value(t,core.raw_count(core.raw(&f.world.lamps)),before+2)
    _,error=spawn_member(core.commands_of(w),f.app.assets,SECTION_ROOM,1,id_in(1,99),at)
    testing.expect_value(t,error,Error.Not_Found)
}

// An allocator that serves `remaining` requests of its owner and refuses the rest.
@(private="file")
Memory_Limit :: struct {owner:runtime.Allocator,remaining:int}

@(private="file")
memory_limit_proc :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    limit:=(^Memory_Limit)(data)
    if mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed {
        if limit.remaining<=0 {return nil,.Out_Of_Memory}
        limit.remaining-=1
    }
    return limit.owner.procedure(limit.owner.data,mode,size,alignment,old_memory,old_size,loc)
}

// A record that has no memory to look at the tables, or to list what its
// section turns on, says so and waits: the look that finds memory takes it.
@(test)
a_record_without_memory_to_look_waits_for_the_next_look :: proc(t:^testing.T) {
    f:Section_Fixture
    if !section_fixture_open(t,&f,"memory") {return}
    defer section_fixture_close(&f)
    section_level_write(t,&f)
    w:=section_ref(&f)
    if _,error:=load(w,&f.app,"root.scene");!testing.expect_value(t,error,Error.None) {return}
    room:=section_entity(&f,1)
    section_stream(&f.requests,room,.Active)
    section_frame(&f)
    section_frame(&f)
    records:=core.world_storage_of(w,Section_Records)
    record:=records_find(records,room)
    if !testing.expect(t,record!=nil && records.looks==0) {return}
    limit:=Memory_Limit{owner=context.allocator}
    Step :: enum {Look,Hold}
    for step in Step {
        done,refused:=false,false
        for served in 0..<64 {
            error:Error
            switch step {
            case .Look:
                delete(record.seen)
                record.seen=nil
                if !record.look {record.look=true;records.looks+=1}
            case .Hold:
                if !testing.expect_value(t,section_hold(w,room,true),Error.None) {return}
                core.world_settle(w)
            }
            {
                limit.remaining=served
                context.allocator={memory_limit_proc,&limit}
                error=records_look(w) if step==.Look else section_hold(w,room,false)
            }
            core.world_settle(w)
            done=error==.None
            if !done {
                testing.expect_value(t,error,Error.Out_Of_Memory)
                testing.expect(t,record.look && records.looks==1,"it still waits for a look")
            }
            if done {break}
            refused=true
        }
        testing.expectf(t,done && refused,"%v: refused without memory, and with it it goes through",step)
        testing.expect_value(t,records_look(w),Error.None)
        testing.expect(t,!record.look && records.looks==0 && len(record.seen)==len(w.info.tables))
    }
}

