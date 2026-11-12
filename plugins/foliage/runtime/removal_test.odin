package foliage

import "core:slice"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import wire "mirai:net"
import "mirai:std/base"
import mm "mirai:std/math"
import render "mirai:engine/render"
import "mirai:std/serial"
import physics "plugins:physics/runtime"

@(private)
@(test_world)
Removal_World :: struct {
    using world:Test_World,
    ids:core.Table(core.Id),
    parents:core.Table(core.Parent),
    transforms:core.Table(core.Transform),
    foliages:core.Table(Foliage),
    worlds:core.Table(core.World_Transform),
    removed:core.Table(Foliage_Removed),
    marked:core.Table(Foliage_Marked),
    data:Foliage_Data,
    removals:Foliage_Removals,
    marks:Foliage_Marks,
    requests:Foliage_Requests,
    network:core.Network,
}

@(private="file")
Removal_Test :: struct {
    using w:Removal_World,
    problems:core.Problems,
    app:host.App,
}

// A world of Foliage and what is taken out of them, with one source of id: nil when it could not be made.
@(private="file")
removal_init :: proc(t:^testing.T,r:^Removal_Test,id:base.Asset_Id) -> ^Source {
    if !test_world_init(t,&r.w) {return nil}
    r.app=host.App{allocator=context.allocator}
    r.network.role=.Server
    append(&r.data.entries,Data_Entry{id=id,epoch=1})
    return &r.data.entries[0].source
}

@(private="file")
removal_destroy :: proc(r:^Removal_Test) {test_world_destroy(&r.w)}

// A Foliage of the source of the world, with an Id when id is not 0.
@(private="file")
removal_foliage :: proc(r:^Removal_Test,id:base.Entity_Id) -> core.Entity {
    e:=core.create(&r.w.entities)
    if id!=0 {core.add(&r.w.ids,e,core.Id{value=id})}
    core.add(&r.w.foliages,e,Foliage{source=r.data.entries[0].id})
    test_world_settle(&r.w)
    return e
}

@(private="file")
removal_step :: proc(r:^Removal_Test) {
    w:=&r.w
    foliage_removals(&r.removals,&r.requests,&w.removed,core.read(&w.foliages),core.read(&w.ids),core.ref(&r.data),core.ref(&r.network),core.commands(w,test_world_info(w)),r.app.allocator,&r.problems)
    test_world_settle(w)
}

// The game asks to take out a manual tree and generated instances: the end
// that decides puts them in one entity of Foliage_Removed for each cell, under
// the Foliage, once, and the cells show and collide without them. A client
// asks nothing.
@(test)
instances_taken_out_are_one_entity_for_each_cell_that_the_cell_leaves_out :: proc(t:^testing.T) {
    r:Removal_Test
    defer removal_destroy(&r)
    s:=removal_init(t,&r,{61,62})
    if s==nil {return}
    s.info.seed=7
    tree:=source_type_add(s,"tree",{2,2})
    tree.density,tree.collision,tree.size=0.01,.Capsule,{0.3,4,0}
    source_cell(s,{0,0},true).generate=true
    coord,manual:=source_instance_add(s,tree.id,{40,0,5},u32(mm.quat_pack(1,10)),{1,1})
    for &cell,i in s.cells {cell.version=u32(i+1)}
    work:Build_Work
    defer build_work_destroy(&work)
    cell_build(s,source_cell(s,{0,0}),{},&work)
    if !testing.expect(t,len(work.placed)>2) {return}
    generated,other:=work.placed[1].id,work.placed[2].id
    generated_count:=len(work.placed)
    wood:=removal_foliage(&r,500)
    bare:=removal_foliage(&r,0)
    // A client asks nothing.
    r.network.role=.Client
    foliage_remove(&r.requests,{wood,coord,MANUAL|u64(manual)})
    removal_step(&r)
    testing.expect_value(t,core.count(&r.w.removed),0)
    r.network.role=.Server
    foliage_remove(&r.requests,{wood,coord,MANUAL|u64(manual)})
    foliage_remove(&r.requests,{wood,coord,MANUAL|u64(manual)})
    foliage_remove(&r.requests,{wood,{0,0},generated})
    foliage_remove(&r.requests,{wood,{0,0},generated_id(tree.id,9999)})
    foliage_remove(&r.requests,{wood,{5,5},MANUAL|u64(manual)})
    foliage_remove(&r.requests,{bare,coord,MANUAL|u64(manual)})
    removal_step(&r)
    removed:=&r.w.removed
    testing.expect_value(t,core.count(removed),2)
    for row in 0..<core.count(removed) {
        e:=core.entity_at(removed,row)
        parent,_:=core.get(&r.w.parents,e)
        page:=core.at(removed,row)
        testing.expect(t,parent.entity==wood && page.foliage==500,"it hangs from its Foliage and names it by its Id")
        testing.expect(t,page.count==1 && page.instances[0].id==(page.coord==coord?MANUAL|u64(manual):generated),"one entity for each cell, with what was taken out of it once")
    }
    testing.expect(t,r.problems.count>0,"a Foliage without an Id says why it cannot")
    // The same again writes nothing.
    seen:core.Seen
    _=core.touched(&r.w.removed,&seen)
    foliage_remove(&r.requests,{wood,coord,MANUAL|u64(manual)})
    removal_step(&r)
    testing.expect(t,!core.touched(&r.w.removed,&seen))
    // Another of the generated cell goes to its entity, and the other cell keeps its hash.
    gone:=removed_owner(&r.removals,wood)
    _,manual_hash:=removed_cell(gone,coord)
    foliage_remove(&r.requests,{wood,{0,0},other})
    removal_step(&r)
    removal_step(&r)
    testing.expect_value(t,core.count(&r.w.removed),2)
    gone=removed_owner(&r.removals,wood)
    if !testing.expect(t,gone!=nil && len(gone.items)==3) {return}
    testing.expect(t,removed_owner(&r.removals,bare)==nil)
    _,hash:=removed_cell(gone,coord)
    testing.expect_value(t,hash,manual_hash)
    ids,cell_hash:=removed_cell(gone,{0,0})
    testing.expect(t,len(ids)==2 && slice.contains(ids,generated) && slice.contains(ids,other) && cell_hash!=0)
    cell_build(s,source_cell(s,{0,0}),{},&work,ids)
    testing.expect_value(t,len(work.placed),generated_count-2)
    for p in work.placed {testing.expect(t,p.id!=generated && p.id!=other,"the cell leaves them out")}
    // Their collision goes with them: the manual tree's cell has no body, the generated one fewer shapes.
    simulation:physics.Physics_State
    if !testing.expect(t,physics.test_state_make(&simulation)) {return}
    defer physics.state_destroy(&simulation)
    fp:Foliage_Physics
    defer core.value_free(&fp,type_info_of(Foliage_Physics))
    collision:physics.Collision_Settings
    types:=make([dynamic]Type_Shape,context.temp_allocator)
    type_shapes(nil,nil,s,nil,&types)
    {complete,enough:=physics_owner_build(&fp,&simulation,&collision,wood,s,{scale={1,1,1},rotation=1},types[:]);testing.expect(t,complete && enough)}
    shapes:=int(simulation.world.shape_count)
    body:physics.Body_Handle
    for cell in fp.cells {if cell.coord=={0,0} {body=cell.body}}
    {complete,enough:=physics_owner_build(&fp,&simulation,&collision,wood,s,{scale={1,1,1},rotation=1},types[:],nil,false,gone);testing.expect(t,complete && enough)}
    testing.expect_value(t,int(simulation.world.shape_count),shapes-3)
    for cell in fp.cells {
        if cell.coord==coord {testing.expect(t,cell.body=={},"a cell without an instance that collides has no body")}
        if cell.coord=={0,0} {testing.expect(t,body!={} && cell.body==body,"the generated cell keeps its body: only the shapes of what left go")}
    }
    // A hit on a shape names the instance it is.
    for cell in fp.cells {
        if cell.body=={} {continue}
        for shape in fp.shapes[cell.first:][:cell.count] {
            if shape.handle=={} {continue}
            hit,found:=shape_instance(&simulation,cell.body,shape.handle)
            testing.expect(t,found && hit.foliage==wood && hit.coord==cell.coord && hit.instance!=generated && hit.instance!=other)
        }
    }
    // Taking the entity of a cell away puts its instances back.
    removed=&r.w.removed
    for row in 0..<core.count(removed) {
        if core.at(removed,row).coord==coord {core.destroy(&r.w.entities,core.entity_at(removed,row));break}
    }
    test_world_settle(&r.w)
    removal_step(&r)
    gone=removed_owner(&r.removals,wood)
    testing.expect(t,gone!=nil && len(gone.items)==2)
    ids,_=removed_cell(gone,coord)
    testing.expect_value(t,len(ids),0)
    // Its tree collides again, and the generated cell keeps its body.
    {complete,enough:=physics_owner_build(&fp,&simulation,&collision,wood,s,{scale={1,1,1},rotation=1},types[:],nil,false,gone);testing.expect(t,complete && enough)}
    testing.expect_value(t,int(simulation.world.shape_count),shapes-2)
    for cell in fp.cells {
        if cell.coord==coord {testing.expect(t,cell.body!={})}
        if cell.coord=={0,0} {testing.expect_value(t,cell.body,body)}
    }
}

// A game finds the instances the world shows, with collision or not, in a
// sphere or a box of the world, and where one stands; not those taken out.
@(test)
the_instances_a_game_finds_are_those_the_world_shows :: proc(t:^testing.T) {
    r:Removal_Test
    defer removal_destroy(&r)
    s:=removal_init(t,&r,{63,64})
    if s==nil {return}
    tree:=source_type_add(s,"tree",{2,2})
    tree.collision=.Capsule
    tree_id:=tree.id
    grass_id:=source_type_add(s,"grass",{3,3}).id
    one:=u32(mm.quat_pack(1,10))
    coord,cut:=source_instance_add(s,tree_id,{40,0,5},one,{1,1})
    _,kept:=source_instance_add(s,grass_id,{41,0,5},one,{1,2})
    _,far:=source_instance_add(s,tree_id,{200,0,5},one,{1,1})
    for &cell,i in s.cells {cell.version=u32(i+1)}
    wood:=removal_foliage(&r,700)
    core.add(&r.w.worlds,wood,core.World_Transform{transform={position={1000,0,0},rotation=1,scale={1,1,1}}})
    test_world_settle(&r.w)
    foliage_remove(&r.requests,{wood,coord,MANUAL|u64(cut)})
    removal_step(&r)
    removal_step(&r)
    data,removals:=core.ref(&r.data),core.ref(&r.removals)
    found:=make([dynamic]Foliage_Found,context.temp_allocator)
    testing.expect(t,foliage_in_sphere(&found,{1041,0,5},3,data,{},removals,core.read(&r.w.foliages),core.read(&r.w.worlds)))
    if !testing.expect_value(t,len(found),1) {return}
    testing.expect(t,found[0].plant==Foliage_Plant{wood,coord,MANUAL|u64(kept)} && found[0].type==grass_id,"the grass, which does not collide; the tree taken out is not there")
    testing.expect(t,found[0].transform.position==[3]f32{1041,0,5} && found[0].transform.scale==[3]f32{1,2,1})
    clear(&found)
    testing.expect(t,foliage_in_box(&found,{1000,-1,0},{1300,1,10},data,{},removals,core.read(&r.w.foliages),core.read(&r.w.worlds)))
    testing.expect_value(t,len(found),2)
    plant,shown:=foliage_plant({wood,{6,0},MANUAL|u64(far)},data,{},removals,core.read(&r.w.foliages),core.read(&r.w.worlds))
    testing.expect(t,shown && plant.type==tree_id && plant.transform.position==[3]f32{1200,0,5})
    _,shown=foliage_plant({wood,coord,MANUAL|u64(cut)},data,{},removals,core.read(&r.w.foliages),core.read(&r.w.worlds))
    testing.expect(t,!shown,"taken out, the world does not show it")
}

// A game that takes out thousands of instances of a few cells holds them in
// an entity, and so a network object, for each REMOVED_PAGE of a cell: an
// entity with room takes them before another is made.
@(test)
thousands_of_instances_taken_out_of_a_few_cells_are_a_few_entities :: proc(t:^testing.T) {
    r:Removal_Test
    defer removal_destroy(&r)
    s:=removal_init(t,&r,{63,64})
    if s==nil {return}
    s.info.seed=3
    grass:=source_type_add(s,"grass",{1,1})
    grass.density=1
    cells:=[3][2]i32{{0,0},{1,0},{0,1}}
    for coord in cells {source_cell(s,coord,true).generate=true}
    meadow:=removal_foliage(&r,700)
    work:Build_Work
    defer build_work_destroy(&work)
    all:=make([dynamic]Foliage_Plant,context.temp_allocator)
    for coord in cells {
        cell_build(s,source_cell(s,coord),{},&work)
        for p in work.placed {append(&all,Foliage_Plant{meadow,coord,p.id})}
    }
    if !testing.expect(t,len(all)>2500) {return}
    // Cells interleaved, as a game harvests them, a tick's room at a time.
    slice.sort_by(all[:],proc(a,b:Foliage_Plant) -> bool {return a.instance%7<b.instance%7 || a.instance%7==b.instance%7 && a.instance<b.instance})
    room:=int(FOLIAGE_SETTINGS_DEFAULT.removes)
    reserve(&r.requests.removes.items,room)
    for start:=0;start<len(all);start+=room {
        for request in all[start:min(start+room,len(all))] {foliage_remove(&r.requests,request)}
        removal_step(&r)
    }
    removal_step(&r)
    entities:=0
    gone:=removed_owner(&r.removals,meadow)
    if !testing.expect(t,gone!=nil) {return}
    for coord in cells {
        ids,_:=removed_cell(gone,coord)
        entities+=(len(ids)+REMOVED_PAGE-1)/REMOVED_PAGE
        cell_build(s,source_cell(s,coord),{},&work,ids)
        testing.expect_value(t,len(work.placed),0)
    }
    testing.expect_value(t,len(gone.items),len(all))
    testing.expect_value(t,core.count(&r.w.removed),entities)
    testing.expect(t,entities<=len(all)/100,"a few entities for thousands of instances")
    // A tick without requests writes nothing.
    seen:core.Seen
    _=core.touched(&r.w.removed,&seen)
    removal_step(&r)
    testing.expect(t,!core.touched(&r.w.removed,&seen))
}

// A saved game names a manual instance by its id, so it is the same one
// after the level changes under it: an instance taken out before it and
// another added do not make it name a different one. One the level deleted
// takes nothing out.
@(test)
a_saved_game_takes_out_the_same_instance_after_its_source_is_edited :: proc(t:^testing.T) {
    r:Removal_Test
    defer removal_destroy(&r)
    s:=removal_init(t,&r,{65,66})
    if s==nil {return}
    source_type_add(s,"bush",{3,3})
    rotation:=u32(mm.quat_pack(1,10))
    _,first:=source_instance_add(s,0,{2,0,2},rotation,{1,1})
    _,cut:=source_instance_add(s,0,{4,0,4},rotation,{1,1})
    source_instance_add(s,0,{6,0,6},rotation,{1,1})
    wood:=removal_foliage(&r,500)
    foliage_remove(&r.requests,{wood,{0,0},MANUAL|u64(cut)})
    removal_step(&r)
    if !testing.expect_value(t,core.count(&r.w.removed),1) {return}
    // What the saved game keeps: the entity's component, written as a row of a document. The level is its asset.
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    taken:=core.at(&r.w.removed,0)
    document:asset.Document;asset.document_init(&document,asset.fourcc("SAVE"),{1,2});defer asset.document_destroy(&document)
    _,put:=asset.document_put_row(&document,&types,"removed",&taken)
    testing.expect_value(t,put,asset.Error.None)
    writer:serial.Writer;serial.writer_init(&writer);defer serial.writer_destroy(&writer)
    testing.expect_value(t,asset.document_write(&document,&writer),asset.Error.None)
    game:asset.Asset
    testing.expect_value(t,asset.asset_open(&game,serial.writer_bytes(&writer)),asset.Error.None)
    defer asset.asset_close(&game)
    row,row_error:=asset.asset_row(&game,&types,"removed",Foliage_Removed)
    if !testing.expect_value(t,row_error,asset.Error.None) {return}
    saved:=row^
    testing.expect_value(t,saved,taken)
    // The level changes: the instance before the one cut is deleted, another is added.
    testing.expect(t,source_instance_remove(s,{0,0},first))
    source_instance_add(s,0,{1,0,8},rotation,{1,1})
    bytes,error:=source_bytes(s,{65,66},&types)
    defer delete(bytes)
    if !testing.expect_value(t,error,asset.Error.None) {return}
    // Loading the game: a world with the edited level and the saved entity.
    loaded:Removal_Test
    defer removal_destroy(&loaded)
    level:=removal_init(t,&loaded,{65,66})
    if level==nil {return}
    file:asset.Asset
    testing.expect_value(t,asset.asset_open(&file,bytes),asset.Error.None)
    _,read:=source_read(level,&file,&types)
    asset.asset_close(&file)
    if !testing.expect(t,read) {return}
    again:=removal_foliage(&loaded,500)
    page:=core.create(&loaded.w.entities)
    core.add(&loaded.w.parents,page,core.Parent{entity=again})
    core.add(&loaded.w.removed,page,saved)
    test_world_settle(&loaded.w)
    removal_step(&loaded)
    ids,_:=removed_cell(removed_owner(&loaded.removals,again),{0,0})
    work:Build_Work
    defer build_work_destroy(&work)
    cell_build(level,source_cell(level,{0,0}),{},&work,ids)
    testing.expect_value(t,len(work.placed),2)
    for p in work.placed {testing.expect(t,p.position!=[3]f32{4,0,4},"the instance cut is still out, and no other")}
    // The level deletes the instance cut: its id takes nothing out.
    testing.expect(t,source_instance_remove(level,{0,0},cut))
    cell_build(level,source_cell(level,{0,0}),{},&work,ids)
    testing.expect_value(t,len(work.placed),2)
}

// The entity of a cell is one fragment of the protocol whose ids change
// apart: one more id taken out sends its own entries and the count, a small
// part of what its creation sends a client that comes later.
@(test)
an_instance_taken_out_later_sends_a_small_part_of_its_cell :: proc(t:^testing.T) {
    schema:serial.Schema;serial.schema_init(&schema);defer serial.schema_destroy(&schema)
    index,added:=serial.schema_add(&schema,Foliage_Removed)
    testing.expect(t,added,schema.error)
    p:wire.Protocol;wire.protocol_init(&p);defer wire.protocol_destroy(&p)
    type,registered:=wire.type_register(&p,"Foliage_Removed",{{schema=&schema,type=index}})
    if !testing.expect(t,added && registered,"a page of a cell fits in an object") {return}
    wire.protocol_seal(&p)
    desc:=&p.types[type]
    testing.expect(t,desc.words<=wire.MAX_STATE_WORDS)
    // The change bits of the count and of each entry.
    bit_of :: proc(desc:^wire.Object_Type,offset:uintptr) -> int {
        for leaf in desc.leaves {if uintptr(leaf.source)==offset {return int(leaf.bit)}}
        return -1
    }
    count_bit:=bit_of(desc,offset_of(Foliage_Removed,count))
    if !testing.expect(t,count_bit>=0) {return}
    entries:=offset_of(Foliage_Removed,instances)
    first:=bit_of(desc,entries)
    testing.expect(t,first>=0 && first!=count_bit)
    for k in 0..<REMOVED_PAGE {
        bit:=bit_of(desc,entries+uintptr(k*size_of(Removed_Instance)))
        if !testing.expect(t,bit>=0 && bit!=count_bit) {return}
        sent:=int(desc.bit_max_bits[count_bit])+int(desc.bit_max_bits[bit])
        if !testing.expect(t,sent*16<desc.max_bits,"one id taken out sends a sixteenth of the cell at most") {return}
    }
}

@(private="file")
marks_step :: proc(r:^Removal_Test) {
    w:=&r.w
    foliage_marks(&r.marks,&r.requests,&w.marked,core.read(&w.foliages),core.read(&w.ids),core.ref(&r.network),core.commands(w,test_world_info(w)),r.app.allocator,&r.problems)
    test_world_settle(w)
}

// The game marks instances in play (burnt, wet): the end that decides keeps
// each mark of a cell in one entity, a later mark of an instance changes its
// entry, the cell shows them over its own look, and taking the entity away
// gives them their look back. A client asks nothing.
@(test)
marks_of_play_are_one_entry_for_each_instance_of_their_cell :: proc(t:^testing.T) {
    r:Removal_Test
    defer removal_destroy(&r)
    s:=removal_init(t,&r,{65,66})
    if s==nil {return}
    tree:=source_type_add(s,"tree",{2,2})
    coord,manual:=source_instance_add(s,tree.id,{40,0,5},u32(mm.quat_pack(1,10)),{1,1})
    source_instance_add(s,tree.id,{45,0,5},u32(mm.quat_pack(1,10)),{1,1})
    wood:=removal_foliage(&r,800)
    plant:=Foliage_Plant{wood,coord,MANUAL|u64(manual)}
    r.network.role=.Client
    foliage_mark(&r.requests,plant,{0.1,0.1,0.1},0)
    marks_step(&r)
    testing.expect_value(t,core.count(&r.w.marked),0)
    r.network.role=.Server
    foliage_mark(&r.requests,plant,{0.1,0.1,0.1},0)
    marks_step(&r)
    foliage_mark(&r.requests,plant,{0.2,0.2,0.2},1)
    marks_step(&r)
    marks_step(&r)
    testing.expect_value(t,core.count(&r.w.marked),1)
    page:=core.at(&r.w.marked,0)
    testing.expect(t,page.foliage==800 && page.coord==coord && page.count==1,"one entry, changed in place")
    wet:=render.batch_color({0.2,0.2,0.2},1)
    testing.expect_value(t,page.instances[0].color,wet)
    marks,hash:=marked_cell(marked_owner(&r.marks,wood),coord)
    testing.expect(t,len(marks)==1 && hash!=0)
    work:Build_Work
    defer build_work_destroy(&work)
    cell_build(s,source_cell(s,coord),{},&work)
    marks_apply(work.placed[:],marks)
    for p in work.placed {testing.expect(t,p.colored==(p.id==plant.instance) && (!p.colored || p.color==wet),"only the marked one")}
    // Without the entity, the cell has no marks.
    core.destroy(&r.w.entities,core.entity_at(&r.w.marked,0))
    test_world_settle(&r.w)
    marks_step(&r)
    marks,hash=marked_cell(marked_owner(&r.marks,wood),coord)
    testing.expect(t,len(marks)==0 && hash==0)
}
