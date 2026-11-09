package foliage

import "core:slice"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"
import physics "plugins:physics/runtime"
import sim "plugins:physics/runtime/sim"

@(private="file")
Removal_World :: struct {
    entities:core.Entities,
    ids:core.Table(core.Id),
    parents:core.Table(core.Parent),
    foliages:core.Table(Foliage),
    removed:core.Table(Foliage_Removed),
}

@(private="file")
Removal_Test :: struct {
    w:Removal_World,
    info:core.World_Info,
    tables:[4]core.Table_Info,
    data:Foliage_Data,
    removals:Foliage_Removals,
    requests:Foliage_Requests,
    problems:core.Problems,
    network:core.Network,
    app:host.App,
}

@(private="file")
removal_settle :: proc(w:^Removal_World) {
    core.table_settle(&w.ids,&w.entities);core.table_settle(&w.parents,&w.entities)
    core.table_settle(&w.foliages,&w.entities);core.table_settle(&w.removed,&w.entities)
    core.entities_settle(&w.entities)
}

// A world of Foliage and what is taken out of them, with one source of id.
@(private="file")
removal_init :: proc(r:^Removal_Test,id:base.Asset_Id) -> ^Source {
    w:=&r.w
    core.entities_init(&w.entities)
    core.table_init(&w.ids,"Id");core.table_init(&w.parents,"Parent");core.table_init(&w.foliages,"Foliage");core.table_init(&w.removed,"Foliage_Removed")
    r.tables={
        {name="Id",type=core.Id,info=type_info_of(core.Id),offset=offset_of(Removal_World,ids)},
        {name="Parent",type=core.Parent,info=type_info_of(core.Parent),offset=offset_of(Removal_World,parents)},
        {name="Foliage",type=Foliage,info=type_info_of(Foliage),offset=offset_of(Removal_World,foliages)},
        {name="Foliage_Removed",type=Foliage_Removed,info=type_info_of(Foliage_Removed),offset=offset_of(Removal_World,removed)},
    }
    r.info=core.World_Info{entities=offset_of(Removal_World,entities),tables=r.tables[:]}
    r.app=host.App{allocator=context.allocator}
    r.network.role=.Server
    append(&r.data.entries,Data_Entry{id=id,epoch=1})
    return &r.data.entries[0].source
}

@(private="file")
removal_destroy :: proc(r:^Removal_Test) {
    w:=&r.w
    core.table_destroy(&w.ids);core.table_destroy(&w.parents);core.table_destroy(&w.foliages);core.table_destroy(&w.removed)
    core.entities_destroy(&w.entities)
    for &entry in r.data.entries {source_destroy(&entry.source)}
    delete(r.data.entries)
    removals_destroy(&r.removals)
    delete(r.requests.removes.items)
}

// A Foliage of the source of the world, with an Id when id is not 0.
@(private="file")
removal_foliage :: proc(r:^Removal_Test,id:base.Entity_Id) -> core.Entity {
    e:=core.create(&r.w.entities)
    if id!=0 {core.add(&r.w.ids,e,core.Id{value=id})}
    core.add(&r.w.foliages,e,Foliage{source=r.data.entries[0].id})
    removal_settle(&r.w)
    return e
}

@(private="file")
removal_step :: proc(r:^Removal_Test) {
    w:=&r.w
    foliage_removals(&r.removals,&r.requests,&w.removed,core.read(&w.foliages),core.read(&w.ids),core.ref(&r.data),core.ref(&r.network),core.commands(w,&r.info),&r.app,&r.problems)
    removal_settle(w)
}

// The game asks to take out a manual tree and generated instances: the end
// that decides puts them in one entity of Foliage_Removed for each cell, under
// the Foliage, once, and the cells show and collide without them. A client
// asks nothing.
@(test)
instances_taken_out_are_one_entity_for_each_cell_that_the_cell_leaves_out :: proc(t:^testing.T) {
    r:Removal_Test
    defer removal_destroy(&r)
    s:=removal_init(&r,{61,62})
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
    testing.expect_value(t,core.count(core.read(&r.w.removed)),0)
    r.network.role=.Server
    foliage_remove(&r.requests,{wood,coord,MANUAL|u64(manual)})
    foliage_remove(&r.requests,{wood,coord,MANUAL|u64(manual)})
    foliage_remove(&r.requests,{wood,{0,0},generated})
    foliage_remove(&r.requests,{wood,{0,0},generated_id(tree.id,9999)})
    foliage_remove(&r.requests,{wood,{5,5},MANUAL|u64(manual)})
    foliage_remove(&r.requests,{bare,coord,MANUAL|u64(manual)})
    removal_step(&r)
    removed:=core.read(&r.w.removed)
    testing.expect_value(t,core.count(removed),2)
    for row in 0..<core.count(removed) {
        e:=core.entity_at(removed,row)
        parent,_:=core.get(core.read(&r.w.parents),e)
        page:=core.at(removed,row)
        testing.expect(t,parent.entity==wood && page.foliage==500,"it hangs from its Foliage and names it by its Id")
        testing.expect(t,page.count==1 && page.instances[0].id==(page.coord==coord?MANUAL|u64(manual):generated),"one entity for each cell, with what was taken out of it once")
    }
    testing.expect(t,r.problems.count>0,"a Foliage without an Id says why it cannot")
    // The same again writes nothing.
    version:=core.version(core.read(&r.w.removed))
    foliage_remove(&r.requests,{wood,coord,MANUAL|u64(manual)})
    removal_step(&r)
    testing.expect_value(t,core.version(core.read(&r.w.removed)),version)
    // Another of the generated cell goes to its entity, and the other cell keeps its hash.
    gone:=removed_owner(&r.removals,wood)
    _,manual_hash:=removed_cell(gone,coord)
    foliage_remove(&r.requests,{wood,{0,0},other})
    removal_step(&r)
    removal_step(&r)
    testing.expect_value(t,core.count(core.read(&r.w.removed)),2)
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
    w_sim:sim.World
    if !testing.expect(t,sim.world_init(&w_sim,sim.world_desc_default())) {return}
    defer sim.world_destroy(&w_sim)
    fp:Foliage_Physics
    defer core.value_free(&fp,type_info_of(Foliage_Physics))
    collision:physics.Collision_Settings
    testing.expect(t,physics_owner_build(&fp,&w_sim,&collision,wood,s,{scale={1,1,1},rotation=1}))
    shapes:=int(w_sim.shape_count)
    testing.expect(t,physics_owner_build(&fp,&w_sim,&collision,wood,s,{scale={1,1,1},rotation=1},nil,false,nil,0,gone))
    testing.expect_value(t,int(w_sim.shape_count),shapes-3)
    for cell in fp.cells {if cell.coord==coord {testing.expect(t,cell.body=={},"a cell without an instance that collides has no body")}}
    // A hit on a shape names the instance it is.
    for cell in fp.cells {
        if cell.body=={} || cell.count==0 {continue}
        hit,found:=shape_instance(&fp,&w_sim,cell.body,fp.shapes[cell.first])
        testing.expect(t,found && hit.foliage==wood && hit.coord==cell.coord && hit.instance!=generated && hit.instance!=other)
    }
    // Taking the entity of a cell away puts its instances back.
    removed=core.read(&r.w.removed)
    for row in 0..<core.count(removed) {
        if core.at(removed,row).coord==coord {core.destroy(&r.w.entities,core.entity_at(removed,row));break}
    }
    removal_settle(&r.w)
    removal_step(&r)
    gone=removed_owner(&r.removals,wood)
    testing.expect(t,gone!=nil && len(gone.items)==2)
    ids,_=removed_cell(gone,coord)
    testing.expect_value(t,len(ids),0)
}

// A game that takes out thousands of instances of a few cells holds them in
// an entity, and so a network object, for each REMOVED_PAGE of a cell: an
// entity with room takes them before another is made.
@(test)
thousands_of_instances_taken_out_of_a_few_cells_are_a_few_entities :: proc(t:^testing.T) {
    r:Removal_Test
    defer removal_destroy(&r)
    s:=removal_init(&r,{63,64})
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
    testing.expect_value(t,core.count(core.read(&r.w.removed)),entities)
    testing.expect(t,entities<=len(all)/100,"a few entities for thousands of instances")
    // A tick without requests writes nothing.
    version:=core.version(core.read(&r.w.removed))
    removal_step(&r)
    testing.expect_value(t,core.version(core.read(&r.w.removed)),version)
}

// A saved game names a manual instance by its id, so it is the same one
// after the level changes under it: an instance taken out before it and
// another added do not make it name a different one. One the level deleted
// takes nothing out.
@(test)
a_saved_game_takes_out_the_same_instance_after_its_source_is_edited :: proc(t:^testing.T) {
    r:Removal_Test
    defer removal_destroy(&r)
    s:=removal_init(&r,{65,66})
    source_type_add(s,"bush",{3,3})
    rotation:=u32(mm.quat_pack(1,10))
    _,first:=source_instance_add(s,0,{2,0,2},rotation,{1,1})
    _,cut:=source_instance_add(s,0,{4,0,4},rotation,{1,1})
    source_instance_add(s,0,{6,0,6},rotation,{1,1})
    wood:=removal_foliage(&r,500)
    foliage_remove(&r.requests,{wood,{0,0},MANUAL|u64(cut)})
    removal_step(&r)
    if !testing.expect_value(t,core.count(core.read(&r.w.removed)),1) {return}
    // What the saved game keeps: the entity's component, written as a row of a document. The level is its asset.
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    taken:=core.at(core.read(&r.w.removed),0)
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
    level:=removal_init(&loaded,{65,66})
    file:asset.Asset
    testing.expect_value(t,asset.asset_open(&file,bytes),asset.Error.None)
    _,read:=source_read(level,&file,&types)
    asset.asset_close(&file)
    if !testing.expect(t,read) {return}
    again:=removal_foliage(&loaded,500)
    page:=core.create(&loaded.w.entities)
    core.add(&loaded.w.parents,page,core.Parent{entity=again})
    core.add(&loaded.w.removed,page,saved)
    removal_settle(&loaded.w)
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
