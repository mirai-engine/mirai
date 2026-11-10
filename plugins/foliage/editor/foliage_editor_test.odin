package foliage_editor

import "core:fmt"
import "core:math/linalg"
import "core:os"
import "core:slice"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"
import foliage "plugins:foliage/runtime"

@(private="file")
Foliage_Test_World :: struct {
    entities:core.Entities,
    ids:core.Table(core.Id),
    names:core.Table(core.Name),
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    foliages:core.Table(foliage.Foliage),
}

@(private="file")
test_tables :: proc() -> [5]core.Table_Info {
    return {
        {name="Id",type=core.Id,info=type_info_of(core.Id),offset=offset_of(Foliage_Test_World,ids)},
        {name="Name",type=core.Name,info=type_info_of(core.Name),offset=offset_of(Foliage_Test_World,names)},
        {name="Transform",type=core.Transform,info=type_info_of(core.Transform),offset=offset_of(Foliage_Test_World,transforms)},
        {name="Parent",type=core.Parent,info=type_info_of(core.Parent),offset=offset_of(Foliage_Test_World,parents)},
        {name="Foliage",type=foliage.Foliage,info=type_info_of(foliage.Foliage),offset=offset_of(Foliage_Test_World,foliages)},
    }
}

// The source the registry holds for a foliage, unsaved or on disk.
@(private="file")
held_source :: proc(t:^testing.T,a:^host.Assets,id:base.Asset_Id) -> (s:foliage.Source) {
    testing.expect(t,foliage.foliage_read(&s,a,id))
    return
}

@(private="file")
manual_count :: proc(s:^foliage.Source) -> (count:int) {
    for cell in s.cells {count+=len(cell.manual)}
    return
}

@(private="file")
override_count :: proc(s:^foliage.Source,kind:foliage.Override_Kind) -> (count:int) {
    for cell in s.cells {for o in cell.overrides {if o.kind==kind {count+=1}}}
    return
}

@(test)
foliage_strokes_and_selections_are_steps_of_undo_kept_unsaved :: proc(t:^testing.T) {
    directory,_:=os.temp_directory(context.temp_allocator)
    root:=fmt.tprintf("%s/mirai-foliage-tool-%d",directory,os.get_pid())
    path:=fmt.tprintf("%s/meadow.foliage",root)
    relative:="meadow.foliage"
    testing.expect_value(t,os.make_directory_all(root),nil)
    defer os.remove(root);defer os.remove(path)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=root,capacity=8})) {return}
    defer host.assets_destroy(&assets)
    // A type that the generator scatters over cell (0,0), on disk.
    source:foliage.Source
    defer foliage.source_destroy(&source)
    source.info={seed=5,revision=1}
    grass:=foliage.source_type_add(&source,"grass",{1,1})
    grass.density=0.02
    foliage.source_cell(&source,{0,0},true).generate=true
    id:=base.Asset_Id{61,62}
    bytes,error:=foliage.source_bytes(&source,id,&assets.types)
    if !testing.expect_value(t,error,asset.Error.None) {return}
    testing.expect_value(t,os.write_entire_file(path,bytes),nil)
    delete(bytes)
    host.assets_scan(&assets)
    disk,_:=serial.file_read(path)
    defer delete(disk)
    world:Foliage_Test_World
    core.entities_init(&world.entities)
    core.table_init(&world.ids,"Id");core.table_init(&world.names,"Name");core.table_init(&world.transforms,"Transform")
    core.table_init(&world.parents,"Parent");core.table_init(&world.foliages,"Foliage")
    defer {
        core.table_destroy(&world.ids);core.table_destroy(&world.names);core.table_destroy(&world.transforms)
        core.table_destroy(&world.parents);core.table_destroy(&world.foliages);core.entities_destroy(&world.entities)
    }
    tables:=test_tables()
    info:=core.World_Info{entities=offset_of(Foliage_Test_World,entities),tables=tables[:]}
    ref:=core.world_ref(&world,&info)
    meadow:=core.create(&world.entities)
    core.add(&world.ids,meadow,core.Id{value=base.Entity_Id(100)})
    core.add(&world.transforms,meadow,core.TRANSFORM_IDENTITY)
    core.add(&world.foliages,meadow,foliage.Foliage{source=id,revision=1})
    core.world_settle(ref)
    selection:editor.Selection;defer delete(selection.entities)
    edits:editor.Edits;defer editor.edits_free(&edits)
    editor.edits_reset(&edits,ref)
    app:=host.App{allocator=context.allocator,assets=&assets}
    s:=editor.Session{app=&app,info=&info,edit_world=&world,assets_root=root,headless=true,selection=&selection,edits=&edits}
    tool:Foliage_Tool;tool_ready(&tool);defer foliage_tool_free(&tool)
    editor.selection_set(&selection,{meadow})
    foliages:=core.read(&world.foliages)
    owner:=mm.Transform{rotation=1,scale={1,1,1}}
    prepare :: proc(t:^testing.T,s:^editor.Session,tool:^Foliage_Tool,foliages:core.Read(foliage.Foliage),e:core.Entity) -> bool {
        foliage_sync(s,tool,foliages,s.app.assets)
        return testing.expect(t,edit_prepare(tool,s.app.assets,s.app.allocator,foliages,e))
    }
    step :: proc(t:^testing.T,s:^editor.Session,tool:^Foliage_Tool,ref:core.World_Ref,label:string) {
        testing.expect(t,edit_commit(s,tool,ref,s.app.assets,label))
        testing.expect(t,editor.edits_commit(s.edits,ref,s.selection))
    }
    random:=mm.rng_make(9,1)

    // A stroke of paint puts three instances in memory; the disk keeps what it had.
    if !prepare(t,&s,&tool,foliages,meadow) {return}
    edit_baseline(&tool)
    for point in ([3][3]f32{{2,0,2},{4,0,3},{40,0,5}}) {paint_instance(&tool.edit.source,&tool.edit.source.types[0],point,{0,1,0},&random,nil)}
    step(t,&s,&tool,ref,"Paint foliage")
    held:=held_source(t,&assets,id)
    testing.expect_value(t,manual_count(&held),3)
    testing.expect_value(t,held.info.revision,u32(2))
    foliage.source_destroy(&held)
    _,unsaved:=asset.registry_memory_find(&assets.registry,relative)
    testing.expect(t,unsaved,"the stroke stays in the memory of the registry")
    on_disk,_:=serial.file_read(path);testing.expect(t,string(on_disk)==string(disk));delete(on_disk)
    testing.expect_value(t,core.at(foliages,0).revision,u32(2))

    // Erase takes out the manual instance under it and the generated ones near it.
    if !prepare(t,&s,&tool,foliages,meadow) {return}
    edit_baseline(&tool)
    draws:=mm.rng_make(1)
    testing.expect(t,erase_touch(&tool.edit.source,nil,[]u32{tool.type},{2,0,2},6,&tool.work,0,&draws))
    step(t,&s,&tool,ref,"Erase foliage")
    held=held_source(t,&assets,id)
    testing.expect(t,manual_count(&held)<3)
    deleted:=override_count(&held,.Deleted)
    foliage.source_destroy(&held)

    // A generated instance moved inside its cell becomes Moved; out of it, Deleted and a manual one.
    if !prepare(t,&s,&tool,foliages,meadow) {return}
    edit_baseline(&tool)
    ref_generated,placed,found:=instance_of_batch(&tool.edit.source,nil,{0,0},tool.type,0,&tool.work)
    if !testing.expect(t,found && ref_generated.id&foliage.MANUAL==0) {return}
    world_place:=instance_world(placed,owner)
    world_place.position+={0.5,0,0.5}
    next,moved:=instance_set(&tool.edit.source,nil,ref_generated,instance_local(world_place,owner,placed.type))
    testing.expect(t,moved && next==ref_generated)
    step(t,&s,&tool,ref,"Move foliage instance")
    held=held_source(t,&assets,id)
    testing.expect_value(t,override_count(&held,.Moved),1)
    foliage.source_destroy(&held)
    if !prepare(t,&s,&tool,foliages,meadow) {return}
    edit_baseline(&tool)
    world_place.position={70,0,70}
    next,moved=instance_set(&tool.edit.source,nil,next,instance_local(world_place,owner,placed.type))
    testing.expect(t,moved && next.coord==[2]i32{2,2} && next.id&foliage.MANUAL!=0,"out of its cell it is a manual instance of the other")
    step(t,&s,&tool,ref,"Move foliage instance")
    held=held_source(t,&assets,id)
    testing.expect_value(t,override_count(&held,.Moved),0)
    testing.expect_value(t,override_count(&held,.Deleted),deleted+1)
    foliage.source_destroy(&held)

    // Delete takes out the manual one.
    if !prepare(t,&s,&tool,foliages,meadow) {return}
    edit_baseline(&tool)
    testing.expect(t,instance_delete(&tool.edit.source,next))
    step(t,&s,&tool,ref,"Delete foliage instance")
    held=held_source(t,&assets,id)
    testing.expect(t,foliage.source_cell(&held,{2,2})==nil || len(foliage.source_cell(&held,{2,2}).manual)==0)
    foliage.source_destroy(&held)
    testing.expect_value(t,core.at(foliages,0).revision,u32(6))

    // Undo goes back through each step, and redo forward.
    for revision:=u32(5);revision>=1;revision-=1 {
        testing.expect(t,editor.undo(&edits,ref,&selection))
        foliage_sync(&s,&tool,foliages,app.assets)
        testing.expect_value(t,core.at(foliages,0).revision,revision)
        held=held_source(t,&assets,id)
        testing.expect_value(t,held.info.revision,revision)
        foliage.source_destroy(&held)
    }
    held=held_source(t,&assets,id)
    testing.expect_value(t,manual_count(&held),0)
    testing.expect_value(t,len(held.cells[0].overrides),0)
    foliage.source_destroy(&held)
    testing.expect(t,editor.redo(&edits,ref,&selection))
    foliage_sync(&s,&tool,foliages,app.assets)
    held=held_source(t,&assets,id)
    testing.expect_value(t,manual_count(&held),3)
    foliage.source_destroy(&held)
}

@(test)
a_canceled_stroke_puts_back_what_the_file_held :: proc(t:^testing.T) {
    directory,_:=os.temp_directory(context.temp_allocator)
    root:=fmt.tprintf("%s/mirai-foliage-cancel-%d",directory,os.get_pid())
    path:=fmt.tprintf("%s/patch.foliage",root)
    testing.expect_value(t,os.make_directory_all(root),nil)
    defer os.remove(root);defer os.remove(path)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=root,capacity=8})) {return}
    defer host.assets_destroy(&assets)
    source:foliage.Source
    defer foliage.source_destroy(&source)
    source.info={seed=1,revision=3}
    foliage.source_type_add(&source,"moss",{2,2})
    id:=base.Asset_Id{71,72}
    bytes,_:=foliage.source_bytes(&source,id,&assets.types)
    _=os.write_entire_file(path,bytes)
    delete(bytes)
    host.assets_scan(&assets)
    app:=host.App{allocator=context.allocator,assets=&assets}
    s:=editor.Session{app=&app,assets_root=root,headless=true}
    tool:Foliage_Tool;tool_ready(&tool);defer foliage_tool_free(&tool)
    foliage.source_destroy(&tool.edit.source)
    testing.expect(t,foliage.foliage_read(&tool.edit.source,&assets,id))
    tool.edit.id,tool.edit.revision,tool.edit.ready=id,3,true
    edit_baseline(&tool)
    random:=mm.rng_make(3,1)
    paint_instance(&tool.edit.source,&tool.edit.source.types[0],{1,0,1},{0,1,0},&random,nil)
    testing.expect(t,edit_preview(&s,&tool,app.assets))
    held:=held_source(t,&assets,id)
    testing.expect_value(t,manual_count(&held),1)
    foliage.source_destroy(&held)
    edit_cancel(&s,&tool,app.assets)
    held=held_source(t,&assets,id)
    testing.expect_value(t,manual_count(&held),0)
    foliage.source_destroy(&held)
    testing.expect_value(t,manual_count(&tool.edit.source),0)
}

@(test)
the_brush_fills_to_its_density_with_spacing_and_stands_on_the_ground :: proc(t:^testing.T) {
    random:=mm.rng_make(4,2)
    testing.expect_value(t,paint_count(1,2,12,&random),1)    // π·4 ≈ 12.6: one more, or none
    testing.expect_value(t,paint_count(1,2,20,&random),0)
    near:=[2]Near{{type=1,position={0,0,0}},{type=2,position={0.6,0,0}}}
    testing.expect(t,!spaced({0.2,0,0},near[:],1,1),"within half a step of one")
    testing.expect(t,spaced({0.6,0,0},near[:],1,1),"an instance of another type takes no room of it")
    // On a flat ground 2 m up, a point on it is grounded with its offset, one over it is not.
    samples:=3
    heights:=make([]f32,samples*samples)
    defer delete(heights)
    for &h in heights {h=2}
    ground:=foliage.Ground_Cell{samples=samples,heights=heights}
    flags,offset:=grounded(ground,{5,2.1,5})
    testing.expect(t,flags==foliage.INSTANCE_GROUNDED && abs(offset-0.1)<1e-5)
    flags,_=grounded(ground,{5,4,5})
    testing.expect_value(t,flags,u32(0))
    flags,_=grounded({},{5,0,5})
    testing.expect_value(t,flags,u32(0))
    for _ in 0..<50 {
        p:=disc_point({0,0,0},{0,1,0},3,&random)
        testing.expect(t,p.x*p.x+p.z*p.z<=9+1e-3 && abs(p.y)<1e-4)
    }
}

// An imported foliage has revision 0 in its Foliage and its file: undo goes
// back to 0, the runtime keeps it there and the tool puts back what the file held.
@(test)
a_move_of_an_imported_foliage_is_undone_back_to_revision_zero :: proc(t:^testing.T) {
    directory,_:=os.temp_directory(context.temp_allocator)
    root:=fmt.tprintf("%s/mirai-foliage-zero-%d",directory,os.get_pid())
    path:=fmt.tprintf("%s/imported.foliage",root)
    testing.expect_value(t,os.make_directory_all(root),nil)
    defer os.remove(root);defer os.remove(path)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=root,capacity=8})) {return}
    defer host.assets_destroy(&assets)
    source:foliage.Source
    defer foliage.source_destroy(&source)
    fern:=foliage.source_type_add(&source,"fern",{3,3})
    foliage.source_instance_add(&source,fern.id,{2,0,2},u32(mm.quat_pack(1,10)),{1,1},0,0)
    id:=base.Asset_Id{81,82}
    bytes,error:=foliage.source_bytes(&source,id,&assets.types)
    if !testing.expect_value(t,error,asset.Error.None) {return}
    testing.expect_value(t,os.write_entire_file(path,bytes),nil)
    delete(bytes)
    host.assets_scan(&assets)
    world:Foliage_Test_World
    core.entities_init(&world.entities)
    core.table_init(&world.ids,"Id");core.table_init(&world.names,"Name");core.table_init(&world.transforms,"Transform")
    core.table_init(&world.parents,"Parent");core.table_init(&world.foliages,"Foliage")
    defer {
        core.table_destroy(&world.ids);core.table_destroy(&world.names);core.table_destroy(&world.transforms)
        core.table_destroy(&world.parents);core.table_destroy(&world.foliages);core.entities_destroy(&world.entities)
    }
    tables:=test_tables()
    info:=core.World_Info{entities=offset_of(Foliage_Test_World,entities),tables=tables[:]}
    ref:=core.world_ref(&world,&info)
    patch:=core.create(&world.entities)
    core.add(&world.ids,patch,core.Id{value=base.Entity_Id(200)})
    core.add(&world.transforms,patch,core.TRANSFORM_IDENTITY)
    core.add(&world.foliages,patch,foliage.Foliage{source=id})
    core.world_settle(ref)
    selection:editor.Selection;defer delete(selection.entities)
    edits:editor.Edits;defer editor.edits_free(&edits)
    editor.edits_reset(&edits,ref)
    app:=host.App{allocator=context.allocator,assets=&assets}
    s:=editor.Session{app=&app,info=&info,edit_world=&world,assets_root=root,headless=true,selection=&selection,edits=&edits}
    tool:Foliage_Tool;tool_ready(&tool);defer foliage_tool_free(&tool)
    editor.selection_set(&selection,{patch})
    foliages:=core.read(&world.foliages)
    data:foliage.Foliage_Data
    defer {for &entry in data.entries {foliage.source_destroy(&entry.source)};delete(data.entries)}
    problems:core.Problems
    // A frame: the runtime reads the source before the tool syncs.
    frame :: proc(s:^editor.Session,tool:^Foliage_Tool,data:^foliage.Foliage_Data,foliages:core.Read(foliage.Foliage),problems:^core.Problems) {
        foliage.foliage_load(data,foliages,s.app.assets,s.app.allocator,problems)
        foliage_sync(s,tool,foliages,s.app.assets)
    }
    x_of :: proc(t:^testing.T,a:^host.Assets,id:base.Asset_Id) -> f32 {
        held:=held_source(t,a,id)
        defer foliage.source_destroy(&held)
        cell:=foliage.source_cell(&held,{0,0})
        if !testing.expect(t,cell!=nil && len(cell.manual)==1) {return -1}
        return cell.manual[0].position.x
    }
    frame(&s,&tool,&data,foliages,&problems)
    testing.expect_value(t,core.at(foliages,0).revision,u32(0))
    if !testing.expect(t,edit_prepare(&tool,app.assets,app.allocator,foliages,patch)) {return}
    edit_baseline(&tool)
    instance,placed,found:=instance_of_batch(&tool.edit.source,nil,{0,0},fern.id,0,&tool.work)
    if !testing.expect(t,found) {return}
    placed.position.x+=3
    _,moved:=instance_set(&tool.edit.source,nil,instance,placed)
    testing.expect(t,moved)
    testing.expect(t,edit_commit(&s,&tool,ref,app.assets,"Move foliage instance"))
    testing.expect(t,editor.edits_commit(&edits,ref,&selection))
    frame(&s,&tool,&data,foliages,&problems)
    testing.expect_value(t,core.at(foliages,0).revision,u32(1))
    testing.expect(t,abs(x_of(t,&assets,id)-5)<1e-4)

    testing.expect(t,editor.undo(&edits,ref,&selection))
    frame(&s,&tool,&data,foliages,&problems)
    testing.expect_value(t,core.at(foliages,0).revision,u32(0))
    testing.expect(t,abs(x_of(t,&assets,id)-2)<1e-4,"undo puts the instance back")
    frame(&s,&tool,&data,foliages,&problems)
    testing.expect_value(t,core.at(foliages,0).revision,u32(0))

    testing.expect(t,editor.redo(&edits,ref,&selection))
    frame(&s,&tool,&data,foliages,&problems)
    testing.expect_value(t,core.at(foliages,0).revision,u32(1))
    testing.expect(t,abs(x_of(t,&assets,id)-5)<1e-4,"redo moves it again")
}

@(test)
the_generate_brush_turns_on_the_cells_under_it_and_off_again :: proc(t:^testing.T) {
    source:foliage.Source
    defer foliage.source_destroy(&source)
    fern:=foliage.source_type_add(&source,"fern",{3,3})
    foliage.source_instance_add(&source,fern.id,{40,0,8},u32(mm.quat_pack(1,10)),{1,1},0,0)
    // A disc of 4 m around (32, 8) meets cells (0,0) and (1,0), and no other.
    testing.expect(t,generate_touch(&source,{32,0,8},4,true))
    testing.expect_value(t,len(source.cells),2)
    for cell in source.cells {testing.expect(t,cell.generate && cell.coord.y==0 && (cell.coord.x==0 || cell.coord.x==1))}
    testing.expect(t,!generate_touch(&source,{32,0,8},4,true),"again it changes nothing")
    testing.expect(t,foliage.source_valid(&source))
    // Off: the cell that holds nothing else goes, the one with a manual instance stays.
    testing.expect(t,generate_touch(&source,{32,0,8},4,false))
    if testing.expect_value(t,len(source.cells),1) {testing.expect(t,source.cells[0].coord==[2]i32{1,0} && !source.cells[0].generate && len(source.cells[0].manual)==1)}
}

@(test)
instances_placed_on_the_ground_lean_with_it_when_it_changes :: proc(t:^testing.T) {
    source:foliage.Source
    defer foliage.source_destroy(&source)
    fern:=foliage.source_type_add(&source,"fern",{3,3})
    fern.align,fern.tilt=1,0
    samples:=5
    owner:=foliage.Ground_Owner{samples=u32(samples)}
    defer foliage.ground_owner_destroy(&owner)
    heights,_,_:=foliage.ground_tile(&owner,{0,0})
    for &h in heights {h=2}
    random:=mm.rng_make(9,1)
    coord,id:=paint_instance(&source,fern,{6,2,6},{0,1,0},&random,&owner)
    cell:=foliage.source_cell(&source,coord)
    testing.expect_value(t,cell.manual[foliage.manual_find(cell,id)].flags,foliage.INSTANCE_GROUNDED|foliage.INSTANCE_ALIGNED)
    // The gizmo turns it: it stands as it was turned on the flat ground.
    work:foliage.Build_Work
    defer foliage.build_work_destroy(&work)
    ref:=Instance_Ref{coord,foliage.MANUAL|u64(id)}
    placed,found:=instance_placed(&source,&owner,ref,&work)
    if !testing.expect(t,found) {return}
    turned:=placed
    turned.rotation=mm.Quat(quaternion(w=0.9238795,x=0.38268343,y=0,z=0))
    ref,_=instance_set(&source,&owner,ref,turned)
    again,_:=instance_placed(&source,&owner,ref,&work)
    testing.expect(t,abs(linalg.dot(again.rotation,turned.rotation))>0.999,"it keeps the rotation the gizmo gave it")
    // The ground becomes a slope that rises 1 m a metre along x: it leans with it.
    for z in 0..<samples {for x in 0..<samples {heights[z*samples+x]=f32(x)*foliage.CELL_SIZE/f32(samples-1)}}
    sloped,_:=instance_placed(&source,&owner,ref,&work)
    slope:=foliage.ground_slope(1,{-0.70710677,0.70710677,0})
    testing.expect(t,abs(linalg.dot(sloped.rotation,slope*turned.rotation))>0.999,"the slope leans it")
    testing.expect(t,abs(sloped.position.y-6)<1e-3,"and it stands on the slope")
}

@(test)
the_search_finds_types_by_any_part_of_their_name :: proc(t:^testing.T) {
    testing.expect(t,type_matches("Fern_Large",""))
    testing.expect(t,type_matches("Fern_Large","large"))
    testing.expect(t,type_matches("Fern_Large"," FERN "))
    testing.expect(t,!type_matches("Fern_Large","grass"))
    testing.expect(t,!type_matches("Fern","Fern_Large"))
}

@(test)
a_click_takes_one_type_ctrl_adds_or_takes_out_and_shift_takes_a_range :: proc(t:^testing.T) {
    tool:Foliage_Tool;tool_ready(&tool);defer foliage_tool_free(&tool)
    shown:=[]u32{4,7,2,9}
    types_click(&tool,shown,7,false,false)
    testing.expect(t,slice.equal(tool.painted[:],[]u32{7}) && tool.type==7)
    types_click(&tool,shown,9,true,false)
    testing.expect(t,slice.equal(tool.painted[:],[]u32{7,9}) && tool.type==9,"Ctrl adds and shows it")
    types_click(&tool,shown,9,true,false)
    testing.expect(t,slice.equal(tool.painted[:],[]u32{7}) && tool.type==7,"and takes it out, showing another")
    types_click(&tool,shown,7,true,false)
    testing.expect(t,slice.equal(tool.painted[:],[]u32{7}),"the last one stays")
    // Shift: from the last one taken alone or added, in the order of the list.
    types_click(&tool,shown,4,false,false)
    types_click(&tool,shown,2,false,true)
    testing.expect(t,slice.equal(tool.painted[:],[]u32{4,7,2}) && tool.type==2)
    types_click(&tool,shown,9,false,false)
    types_click(&tool,shown,7,false,true)
    testing.expect(t,slice.equal(tool.painted[:],[]u32{7,2,9}),"backwards too")
    types_click(&tool,shown,4,true,false)
    types_click(&tool,shown,7,true,true)
    testing.expect(t,slice.equal(tool.painted[:],[]u32{7,2,9,4}),"with Ctrl it keeps the others")
    // An anchor the search hides takes only the one clicked.
    types_click(&tool,[]u32{2,9},9,false,true)
    testing.expect(t,slice.equal(tool.painted[:],[]u32{9}))
}

@(test)
the_type_of_a_selected_instance_is_taken_alone_and_removed_types_leave_the_selection :: proc(t:^testing.T) {
    tool:Foliage_Tool;tool_ready(&tool);defer foliage_tool_free(&tool)
    fern:=foliage.source_type_add(&tool.edit.source,"fern",{1,1}).id
    moss:=foliage.source_type_add(&tool.edit.source,"moss",{2,2}).id
    types_click(&tool,[]u32{fern,moss},fern,false,false)
    types_click(&tool,[]u32{fern,moss},moss,true,false)
    type_reveal(&tool,fern)
    testing.expect(t,slice.equal(tool.painted[:],[]u32{fern}) && tool.type==fern && tool.reveal==fern)
    foliage.source_type_remove(&tool.edit.source,fern)
    types_keep(&tool)
    testing.expect(t,slice.equal(tool.painted[:],[]u32{moss}) && tool.type==moss,"one stays selected while there are types")
}

@(test)
instances_are_counted_by_cell_and_again_only_where_a_cell_or_its_ground_changed :: proc(t:^testing.T) {
    s:foliage.Source
    defer foliage.source_destroy(&s)
    s.info={seed=7}
    fern:=foliage.source_type_add(&s,"fern",{1,1})
    fern.density=0.05
    fern_id:=fern.id
    moss:=foliage.source_type_add(&s,"moss",{2,2}).id
    up:=u32(mm.quat_pack(1,10))
    for x in ([3]f32{1,2,3}) {foliage.source_instance_add(&s,fern_id,{x,0,1},up,{1,1})}
    for x in ([2]f32{40,41}) {foliage.source_instance_add(&s,moss,{x,0,1},up,{1,1})}
    foliage.source_cell(&s,{2,0},true).generate=true
    versions:u32
    for &cell in s.cells {versions+=1;cell.version=versions}
    points:[dynamic]foliage.Generated
    defer delete(points)
    foliage.scatter(s.info.seed,{2,0},s.types[0],&points)
    generated:=u32(len(points))
    testing.expect(t,generated>0)
    // A ground over the generated cell with no surface yet: none stands there.
    ground:=foliage.Ground_Owner{samples=2,revision=1}
    defer foliage.ground_owner_destroy(&ground)
    heights,_,tile:=foliage.ground_tile(&ground,{2,0})
    tile.revision=1
    work:foliage.Build_Work
    defer foliage.build_work_destroy(&work)
    c:Counts
    defer counts_free(&c)
    key:=Counts_Key{entity=core.Entity(1),epoch=1,loads=1,ground=1}
    total :: proc(c:^Counts,type:u32) -> u32 {count,_:=counts_total(c,type);return count}

    // Within its budget it counts some cells and says nothing until it counted them all.
    testing.expect_value(t,counts_update(&c,&s,key,&ground,&work,2),2)
    _,known:=counts_total(&c,fern_id)
    testing.expect(t,!known && c.pending)
    testing.expect_value(t,counts_update(&c,&s,key,&ground,&work,2),1)
    testing.expect(t,total(&c,fern_id)==3 && total(&c,moss)==2)
    cell,cell_known:=counts_cell(&c,{1,0})
    testing.expect(t,cell_known && cell==2)
    testing.expect_value(t,counts_update(&c,&s,key,&ground,&work),0)

    // Another manual instance: only its cell is counted again.
    foliage.source_instance_add(&s,moss,{42,0,1},up,{1,1})
    foliage.source_cell(&s,{1,0}).version=versions+1
    key.loads=2
    testing.expect_value(t,counts_update(&c,&s,key,&ground,&work),1)
    testing.expect_value(t,total(&c,moss),3)
    // The ground of the generated cell is known: its points stand on it.
    for &h in heights {h=0}
    ground.revision,ground.tiles[0].revision=2,2
    key.ground=2
    testing.expect_value(t,counts_update(&c,&s,key,&ground,&work),1)
    testing.expect_value(t,total(&c,fern_id),3+generated)
    testing.expect_value(t,count_text(1234567),"1,234,567")
    testing.expect_value(t,count_text(12),"12")
}

// What git and the tools know of the kinds of the plugin without loading it.
@(test)
the_manifest_declares_the_asset_kinds_the_plugin_registers :: proc(t:^testing.T) {
    m,error:=project.plugin_read(#directory+"../plugin.mirai")
    testing.expect_value(t,error.code,project.Error_Code.None)
    testing.expect_value(t,editor.asset_kinds_differ(FOLIAGE_KINDS_DEFAULT.provider,&m),"")
}
