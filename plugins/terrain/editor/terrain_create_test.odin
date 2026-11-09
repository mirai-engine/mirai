package terrain_editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:editor"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:platform"
import terrain "plugins:terrain/runtime"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/geom"
import "mirai:std/serial"
import "mirai:ui"

@(private)
Create_Test_World :: struct {
    entities:core.Entities,
    ids:core.Table(core.Id),
    names:core.Table(core.Name),
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    meshes:core.Table(erender.Mesh_Renderer),
    terrains:core.Table(terrain.Terrain),
}

@(test)
a_canceled_stroke_takes_back_its_head_and_keeps_the_history :: proc(t:^testing.T) {
    tool:Terrain_Tool
    defer terrain_tool_free(&tool)
    testing.expect(t,terrain.source_make(&tool.stroke.source,.Heightfield,{3,1,3},1,4))
    tool.stroke.id={0xabcd,0xdef0};tool.stroke.revision=1
    for i in 0..<editor.REVISION_STEPS_CAPACITY {append(&tool.steps,Step{source={u64(i+1),0},from=1,to=2})}
    if !testing.expect(t,stroke_baseline(&tool)) {return}
    head:=editor.revision_head(&tool.history,tool.stroke.id,1)
    if !testing.expect(t,head!=nil) {return}
    change:=terrain.source_edit(&tool.stroke.source,{kind=.Raise,center={0,0,0},radius=1,amount=2})
    testing.expect(t,change.changed)
    stroke_changed(&tool.stroke,change)
    testing.expect_value(t,terrain.source_value(head,{1,0,1}),f32(0))
    stroke_cancel(&tool)
    testing.expect_value(t,terrain.source_value(&tool.stroke.source,{1,0,1}),f32(0))
    testing.expect(t,tool.stroke.id!={} && !tool.stroke.dirty_any,"the source stays, as its file holds it")
    testing.expect_value(t,len(tool.steps),editor.REVISION_STEPS_CAPACITY)
    for &step,i in tool.steps {testing.expect_value(t,step.source,base.Asset_Id{u64(i+1),0})}
}

@(private)
create_test_world_init :: proc(w:^Create_Test_World) {
    core.entities_init(&w.entities)
    core.table_init(&w.ids,"Id");core.table_init(&w.names,"Name")
    core.table_init(&w.transforms,"Transform");core.table_init(&w.parents,"Parent")
    core.table_init(&w.meshes,"Mesh_Renderer");core.table_init(&w.terrains,"Terrain")
}

@(private)
create_test_world_destroy :: proc(w:^Create_Test_World) {
    core.table_destroy(&w.ids);core.table_destroy(&w.names)
    core.table_destroy(&w.transforms);core.table_destroy(&w.parents)
    core.table_destroy(&w.meshes);core.table_destroy(&w.terrains)
    core.entities_destroy(&w.entities)
}

@(private)
create_test_tables :: proc() -> [6]core.Table_Info {
    return {
        {name="Id",type=core.Id,info=type_info_of(core.Id),offset=offset_of(Create_Test_World,ids)},
        {name="Name",type=core.Name,info=type_info_of(core.Name),offset=offset_of(Create_Test_World,names)},
        {name="Transform",type=core.Transform,info=type_info_of(core.Transform),offset=offset_of(Create_Test_World,transforms)},
        {name="Parent",type=core.Parent,info=type_info_of(core.Parent),offset=offset_of(Create_Test_World,parents)},
        {name="Mesh_Renderer",type=erender.Mesh_Renderer,info=type_info_of(erender.Mesh_Renderer),offset=offset_of(Create_Test_World,meshes)},
        {name="Terrain",type=terrain.Terrain,info=type_info_of(terrain.Terrain),offset=offset_of(Create_Test_World,terrains)},
    }
}

@(private)
create_test_settle :: proc(world,shared,ed:rawptr) {
    w:=cast(^Create_Test_World)world
    core.table_settle(&w.ids,&w.entities);core.table_settle(&w.names,&w.entities)
    core.table_settle(&w.transforms,&w.entities);core.table_settle(&w.parents,&w.entities)
    core.table_settle(&w.meshes,&w.entities);core.table_settle(&w.terrains,&w.entities)
    core.entities_settle(&w.entities)
}

@(private)
create_test_frame :: proc(t:^testing.T,s:^editor.Session,tool:^Terrain_Tool,input:^ui.Input) {
    platform.frame_begin(s.app.platform)
    ui.frame_begin(s.gui.ctx,input^)
    if ui.panel(s.gui.ctx,ui.id(s.gui.ctx,"test_panel"),{width=ui.fixed(240),height=ui.FIT,offset={20,20},padding=ui.padding_all(10)}) {
        terrain_creation_panel(s,tool,editor.edited_world(s),s.app)
    }
    frame:=ui.frame_end(s.gui.ctx)
    testing.expect(t,!frame.overflow)
    testing.expect_value(t,s.gui.ctx.stats.layout_errors,u32(0))
    ui.input_next_frame(input)
}

@(private)
create_test_click :: proc(t:^testing.T,s:^editor.Session,tool:^Terrain_Tool,input:^ui.Input,name:string) {
    create_test_click_id(t,s,tool,input,ui.id(s.gui.ctx,name))
}

@(private)
create_test_click_id :: proc(t:^testing.T,s:^editor.Session,tool:^Terrain_Tool,input:^ui.Input,id:ui.Id) {
    rect,found:=ui.widget_rect(s.gui.ctx,id)
    if !testing.expect(t,found) {return}
    input.pointer_absent=false;input.pointer={rect.x+rect.w*0.5,rect.y+rect.h*0.5}
    create_test_frame(t,s,tool,input)
    ui.input_button(input,.Left,true)
    create_test_frame(t,s,tool,input)
    ui.input_button(input,.Left,false)
    create_test_frame(t,s,tool,input)
}

@(test)
terrain_panel_hides_creation_while_a_terrain_is_selected_and_reaches_it_on_short_windows :: proc(t:^testing.T) {
    p,error:=platform.create({headless=true,fixed_dt=1.0/60})
    if !testing.expect_value(t,error,platform.Error.None) || p==nil {return}
    defer platform.destroy(p)
    world:Operand_Test_World
    create_test_world_init(&world.base);defer create_test_world_destroy(&world.base)
    core.table_init(&world.worlds,"World_Transform");defer core.table_destroy(&world.worlds)
    core.table_init(&world.overrides,"Material_Override");defer core.table_destroy(&world.overrides)
    tables:=operand_test_tables()
    info:=core.World_Info{entities=offset_of(Operand_Test_World,base)+offset_of(Create_Test_World,entities),tables=tables[:],settle=operand_test_settle}
    ref:=core.world_ref(&world,&info)
    owner:=core.create(&world.entities)
    core.add(&world.terrains,owner,terrain.Terrain{source={1,1},revision=1})
    core.add(&world.worlds,owner,core.World_Transform{})
    core.world_settle(ref)
    // On the heap: with the session and the app, a context on the stack of a test thread overflows it.
    ctx:=new(ui.Context);defer free(ctx)
    if !testing.expect(t,ui.context_init(ctx,{})) {return}
    defer ui.context_destroy(ctx)
    app:=host.App{allocator=context.allocator,platform=p}
    selection:editor.Selection;defer delete(selection.entities)
    editor.selection_set(&selection,{owner})
    viewport:editor.Viewport
    gui:=editor.Editor_Ui{ctx=ctx,begun=true}
    s:=editor.Session{app=&app,info=&info,edit_world=&world,headless=true,selection=&selection,viewport=&viewport,gui=&gui}
    editor.tool_set(&s,"terrain",true)
    tool:Terrain_Tool;tool_ready(&tool);defer terrain_tool_free(&tool)
    tool.create_source=.Heightmap
    tool.stroke.entity,tool.stroke.id=owner,{1,1}
    id:=ui.id_derive(ctx,PANEL_SCOPE,"panel")
    // A selected terrain shows its modes, not the controls to create another.
    for kind in ([2]terrain.Source_Kind{.Heightfield,.Mesh}) {
        tool.stroke.source.kind=kind
        input:=ui.Input{size={1000,900},pointer_absent=true,dt=1.0/60}
        for _ in 0..<2 {create_test_tool_panel_frame(t,&s,&tool,ref,&input)}
        _,found:=ui.widget_rect(ctx,ui.id_derive(ctx,id,"create"))
        testing.expectf(t,!found,"%v: a selected terrain shows New terrain",kind)
    }
    editor.selection_clear(&selection)
    input:=ui.Input{size={1000,900},pointer_absent=true,dt=1.0/60}
    create_test_tool_panel_frame(t,&s,&tool,ref,&input)
    testing.expect(t,tool.stroke.id=={})
    for kind in ([2]terrain.Source_Kind{.Heightfield,.Mesh}) {
        tool.create_kind=kind
        for height in ([2]f32{600,900}) {
            input=ui.Input{size={1000,height},pointer_absent=true,dt=1.0/60}
            tool.scroll=0
            for _ in 0..<2 {create_test_tool_panel_frame(t,&s,&tool,ref,&input)}
            panel,found:=ui.widget_rect(ctx,id)
            testing.expect(t,found && panel.y==328 && panel.y+panel.h<=height-ctx.theme.margin+0.01)
            tool.scroll=1e6
            create_test_tool_panel_frame(t,&s,&tool,ref,&input)
            button,button_found:=ui.widget_rect(ctx,ui.id_derive(ctx,id,"create"))
            testing.expectf(t,button_found && button.y>=panel.y && button.y+button.h<=height-ctx.theme.margin,"%v at %g: New terrain is outside viewport: %v",kind,height,button)
            if height==600 {testing.expect(t,tool.scroll.y>0)}
        }
    }
}

@(private)
create_test_tool_panel_frame :: proc(t:^testing.T,s:^editor.Session,tool:^Terrain_Tool,world:core.World_Ref,input:^ui.Input) {
    platform.frame_begin(s.app.platform)
    ui.frame_begin(s.gui.ctx,input^)
    s.gui.tool_top,s.gui.tool_width=328,280
    terrain_panel(s,tool,world,s.app,{})
    frame:=ui.frame_end(s.gui.ctx)
    testing.expect(t,!frame.overflow)
    testing.expect_value(t,s.gui.ctx.stats.layout_errors,u32(0))
    ui.input_next_frame(input)
}

@(test)
terrain_creation_separates_heightfield_mesh_and_volume_and_keeps_undo :: proc(t:^testing.T) {
    create_test_plane(t,.Heightfield,0)
    create_test_plane(t,.Mesh,0)
    create_test_plane(t,.Mesh,8)
    create_test_plane(t,.Volume,0)
}

@(private)
create_test_plane :: proc(t:^testing.T,kind:terrain.Source_Kind,depth:f32) {
    directory,_:=os.temp_directory(context.temp_allocator)
    root:=fmt.tprintf("%s/mirai-terrain-kinds-%d",directory,os.get_pid())
    path:=fmt.tprintf("%s/terrain/%s.terrain",root,terrain_kind_name(kind))
    testing.expect_value(t,os.make_directory_all(root),nil)
    defer os.remove(root);defer os.remove(fmt.tprintf("%s/terrain",root));defer os.remove(path)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=root,capacity=8})) {return}
    defer host.assets_destroy(&assets)
    p,error:=platform.create({headless=true,fixed_dt=1.0/60})
    if !testing.expect_value(t,error,platform.Error.None) || p==nil {return}
    defer platform.destroy(p)
    world:Create_Test_World
    create_test_world_init(&world);defer create_test_world_destroy(&world)
    tables:=create_test_tables()
    info:=core.World_Info{entities=offset_of(Create_Test_World,entities),tables=tables[:],settle=create_test_settle}
    ref:=core.world_ref(&world,&info)
    ctx:=new(ui.Context);defer free(ctx)
    if !testing.expect(t,ui.context_init(ctx,{})) {return}
    defer ui.context_destroy(ctx)
    app:=host.App{allocator=context.allocator,assets=&assets,platform=p}
    selection:editor.Selection;defer delete(selection.entities)
    edits:editor.Edits;defer editor.edits_free(&edits)
    editor.edits_reset(&edits,ref)
    viewport:editor.Viewport
    gui:=editor.Editor_Ui{ctx=ctx,begun=true}
    s:=editor.Session{app=&app,info=&info,edit_world=&world,assets_root=root,headless=true,selection=&selection,edits=&edits,viewport=&viewport,gui=&gui,id_state=331}
    tool:Terrain_Tool;tool_ready(&tool);defer terrain_tool_free(&tool)
    testing.expect_value(t,tool.create_kind,terrain.Source_Kind.Mesh)
    testing.expect_value(t,tool.solid_depth,f32(8))
    tool.samples,tool.depth,tool.chunk_cells=5,5,4
    input:=ui.Input{size={800,600},pointer_absent=true,dt=1.0/60}
    create_test_frame(t,&s,&tool,&input)
    create_test_click(t,&s,&tool,&input,"source_kind")
    list:=ui.id_derive(ctx,ui.id(ctx,"source_kind"),"list")
    index:=kind==.Heightfield?0:kind==.Mesh?1:2
    for option in 0..<3 {
        rect,found:=ui.widget_rect(ctx,ui.id_derive(ctx,list,"row",option+1))
        testing.expect(t,found && rect.w>=200)
    }
    create_test_click_id(t,&s,&tool,&input,ui.id_derive(ctx,list,"row",index+1))
    testing.expect_value(t,tool.create_kind,kind)
    tool.solid_depth=depth
    create_test_frame(t,&s,&tool,&input)
    _,has_solid:=ui.widget_rect(ctx,ui.id(ctx,"create_solid"))
    testing.expect_value(t,has_solid,kind==.Mesh)
    create_test_click(t,&s,&tool,&input,"create")
    if !testing.expect(t,editor.edits_commit(&edits,ref,&selection)) {return}
    testing.expect_value(t,len(world.terrains.values),1)
    owner:=editor.selection_active(&selection)
    testing.expect(t,core.has(&world.terrains,owner))
    testing.expect_value(t,edits.cursor,1)
    source:terrain.Source;defer terrain.source_destroy(&source)
    testing.expect(t,!os.exists(path))
    if !testing.expect(t,terrain.terrain_read(&source,&assets,core.get(&world.terrains,owner).source)) {return}
    testing.expect_value(t,source.kind,kind)
    // Every kind starts with one layer that covers all of it.
    testing.expect_value(t,source.layer_count,u32(1))
    testing.expect_value(t,terrain.source_weights_at(&source,terrain.source_origin(&source)),[4]f32{1,0,0,0})
    if kind==.Mesh {
        testing.expect_value(t,len(source.distances.pages),0)
        mesh:geom.Mesh_Buffer;geom.mesh_buffer_init(&mesh);defer geom.mesh_buffer_destroy(&mesh)
        testing.expect(t,terrain.source_mesh_collect(&source,&mesh))
        testing.expect_value(t,geom.mesh_is_closed(mesh.positions[:],mesh.indices[:]),depth>0)
        testing.expect(t,abs(geom.mesh_volume(mesh.positions[:],mesh.indices[:])-16*depth)<0.001)
    } else if kind==.Volume {testing.expect_value(t,source.distances.size,[3]int{5,5,5})} else {testing.expect_value(t,source.heights.size,[3]int{5,1,5})}
    testing.expect(t,editor.undo(&edits,ref,&selection))
    testing.expect_value(t,len(world.terrains.values),0)
    testing.expect(t,!editor.file_exists(&s,path))
    testing.expect(t,editor.redo(&edits,ref,&selection))
    testing.expect_value(t,len(world.terrains.values),1)
    testing.expect_value(t,editor.selection_active(&selection),owner)
    testing.expect(t,editor.file_exists(&s,path) && !os.exists(path))
}

// A Volume made on a Heightfield joins it and its field is the ground,
// solid down to the bottom of its box: what is dug there has a floor.
@(test)
a_named_terrain_takes_the_name_and_a_missing_heightmap_says_its_path :: proc(t:^testing.T) {
    directory,_:=os.temp_directory(context.temp_allocator)
    root:=fmt.tprintf("%s/mirai-terrain-named-%d",directory,os.get_pid())
    testing.expect_value(t,os.make_directory_all(root),nil)
    defer os.remove_all(root)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=root,capacity=8})) {return}
    defer host.assets_destroy(&assets)
    world:Create_Test_World
    create_test_world_init(&world);defer create_test_world_destroy(&world)
    tables:=create_test_tables()
    info:=core.World_Info{entities=offset_of(Create_Test_World,entities),tables=tables[:],settle=create_test_settle}
    ref:=core.world_ref(&world,&info)
    app:=host.App{allocator=context.allocator,assets=&assets}
    selection:editor.Selection;defer delete(selection.entities)
    edits:editor.Edits;defer editor.edits_free(&edits)
    editor.edits_reset(&edits,ref)
    viewport:editor.Viewport
    s:=editor.Session{app=&app,info=&info,edit_world=&world,assets_root=root,headless=true,selection=&selection,edits=&edits,viewport=&viewport,id_state=631}
    tool:Terrain_Tool;tool_ready(&tool);defer terrain_tool_free(&tool)
    tool.create_kind,tool.create_source=.Heightfield,.Heightmap
    missing:=fmt.tprintf("%s/source/none.png",root)
    tool.heightmap_length=copy(tool.heightmap_path[:],missing)
    s.toast_length=0
    testing.expect_value(t,terrain_create(&s,&tool,ref,&app,name="Island"),core.NONE)
    said:=string(s.toast[:s.toast_length])
    testing.expectf(t,strings.contains(said,missing),"the error names the file it tried: %s",said)
    tool.create_source,tool.samples,tool.chunk_cells=.Plane,5,4
    e:=terrain_create(&s,&tool,ref,&app,at={0,0,0},placed=true,name="Island")
    if !testing.expect(t,e!=core.NONE && editor.edits_commit(&edits,ref,&selection)) {return}
    name:=core.get(&world.names,e)
    testing.expect(t,name!=nil && base.text_get(name.text[:])=="Island","the entity takes the name")
    testing.expect(t,editor.file_exists(&s,fmt.tprintf("%s/terrain/Island.terrain",root)),"the file takes the name")
}

@(test)
a_volume_created_on_a_heightfield_is_filled_with_its_ground :: proc(t:^testing.T) {
    directory,_:=os.temp_directory(context.temp_allocator)
    root:=fmt.tprintf("%s/mirai-terrain-ground-%d",directory,os.get_pid())
    testing.expect_value(t,os.make_directory_all(root),nil)
    defer os.remove_all(root)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=root,capacity=8})) {return}
    defer host.assets_destroy(&assets)
    world:Create_Test_World
    create_test_world_init(&world);defer create_test_world_destroy(&world)
    tables:=create_test_tables()
    info:=core.World_Info{entities=offset_of(Create_Test_World,entities),tables=tables[:],settle=create_test_settle}
    ref:=core.world_ref(&world,&info)
    app:=host.App{allocator=context.allocator,assets=&assets}
    selection:editor.Selection;defer delete(selection.entities)
    edits:editor.Edits;defer editor.edits_free(&edits)
    editor.edits_reset(&edits,ref)
    viewport:editor.Viewport
    s:=editor.Session{app=&app,info=&info,edit_world=&world,assets_root=root,headless=true,selection=&selection,edits=&edits,viewport=&viewport,id_state=523}
    tool:Terrain_Tool;tool_ready(&tool);defer terrain_tool_free(&tool)
    tool.create_kind=.Heightfield;tool.samples,tool.depth,tool.chunk_cells=17,9,8
    // The ground is a root: where it stands is its Transform.
    ground:=terrain_create(&s,&tool,ref,&app,at={10,0,10},placed=true)
    if !testing.expect(t,ground!=core.NONE && editor.edits_commit(&edits,ref,&selection)) {return}
    tool.create_kind=.Volume
    owner:=terrain_create(&s,&tool,ref,&app,at={10,0,10},placed=true,ground=ground)
    if !testing.expect(t,owner!=core.NONE && editor.edits_commit(&edits,ref,&selection)) {return}
    marker:=core.get(&world.terrains,owner)
    testing.expect_value(t,marker.ground,editor.api_entity_id(ref,ground))
    volume:terrain.Source;defer terrain.source_destroy(&volume)
    if !testing.expect(t,terrain.terrain_read(&volume,&assets,marker.source)) {return}
    for z in 0..<17 {for y in 0..<9 {for x in 0..<17 {
        value:=terrain.source_value(&volume,{x,y,z})
        if !testing.expectf(t,y<4?value<0:y>4?value>0:value==0,"the sample %v of the Volume is %v, the ground at the sample 4 along y",[3]int{x,y,z},value) {return}
    }}}
}

@(test)
mesh_terrain_creation_from_selection_preserves_authoring_and_undo :: proc(t:^testing.T) {
    directory,_:=os.temp_directory(context.temp_allocator)
    root:=fmt.tprintf("%s/mirai-terrain-selection-%d",directory,os.get_pid())
    path:=fmt.tprintf("%s/terrain/3D Terrain.terrain",root)
    testing.expect_value(t,os.make_directory_all(root),nil)
    defer os.remove(root);defer os.remove(fmt.tprintf("%s/terrain",root));defer os.remove(path)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=root,capacity=8})) {return}
    defer host.assets_destroy(&assets)
    world:Create_Test_World
    create_test_world_init(&world);defer create_test_world_destroy(&world)
    tables:=create_test_tables()
    info:=core.World_Info{entities=offset_of(Create_Test_World,entities),tables=tables[:],settle=create_test_settle}
    ref:=core.world_ref(&world,&info)
    app:=host.App{allocator=context.allocator,assets=&assets}
    selection:editor.Selection;defer delete(selection.entities)
    edits:editor.Edits;defer editor.edits_free(&edits)
    s:=editor.Session{app=&app,info=&info,edit_world=&world,assets_root=root,headless=true,selection=&selection,edits=&edits,id_state=971}
    owner:=editor.entity_create(&s,{preset=.Cube,name="Rock",transform={position={4,5,6},rotation=1,scale={2,3,4}}})
    core.world_settle(ref)
    static:=core.get(&world.meshes,owner)^
    static.materials[0]={71,72};core.add(&world.meshes,owner,static)
    core.world_settle(ref)
    transform:=core.get(&world.transforms,owner)^
    editor.selection_set(&selection,{owner})
    editor.edits_reset(&edits,ref)
    tool:Terrain_Tool;tool_ready(&tool);defer terrain_tool_free(&tool)
    tool.create_source=.Selection;tool.create_kind=.Heightfield
    terrain_create(&s,&tool,ref,&app)
    testing.expect(t,!edits.open && !edits.commit && !os.exists(path))
    testing.expect_value(t,len(world.terrains.values),0)
    tool.create_kind=.Mesh
    terrain_create(&s,&tool,ref,&app)
    if !testing.expect(t,editor.edits_commit(&edits,ref,&selection)) {return}
    testing.expect_value(t,world.entities.alive,1)
    testing.expect(t,core.has(&world.terrains,owner))
    testing.expect_value(t,core.get(&world.transforms,owner)^,transform)
    // The material it showed over its mesh is the one of the source.
    testing.expect(t,!core.has(&world.meshes,owner))
    testing.expect_value(t,editor.selection_active(&selection),owner)
    source:terrain.Source;defer terrain.source_destroy(&source)
    loaded:=terrain.terrain_read(&source,&assets,core.get(&world.terrains,owner).source)
    testing.expect(t,loaded && source.kind==.Mesh && len(source.distances.pages)==0 && !os.exists(path))
    testing.expect_value(t,source.layers[0].material,static.materials[0])
    testing.expect(t,editor.undo(&edits,ref,&selection))
    testing.expect(t,!core.has(&world.terrains,owner))
    testing.expect_value(t,core.get(&world.meshes,owner)^,static)
    testing.expect_value(t,core.get(&world.transforms,owner)^,transform)
    testing.expect(t,editor.redo(&edits,ref,&selection))
    testing.expect(t,core.has(&world.terrains,owner))
}

@(test)
heightmap_dialog_creates_scaled_terrain_with_one_undo_step :: proc(t:^testing.T) {
    create_test_heightmap(t,.Heightfield,0)
    create_test_heightmap(t,.Mesh,0)
    create_test_heightmap(t,.Mesh,8)
}

@(private)
create_test_heightmap :: proc(t:^testing.T,kind:terrain.Source_Kind,depth:f32) {
    directory,_:=os.temp_directory(context.temp_allocator)
    root:=fmt.tprintf("%s/mirai-terrain-create-%d",directory,os.get_pid())
    path:=fmt.tprintf("%s/height16.png",root)
    saved:=fmt.tprintf("%s/terrain/%s.terrain",root,terrain_kind_name(kind))
    testing.expect_value(t,os.make_directory_all(root),nil)
    defer os.remove(root)
    defer os.remove(fmt.tprintf("%s/terrain",root))
    defer os.remove(saved)
    defer os.remove(path)
    png:=[?]u8{
        0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a,0x00,0x00,0x00,0x0d,0x49,0x48,0x44,0x52,
        0x00,0x00,0x00,0x03,0x00,0x00,0x00,0x02,0x10,0x00,0x00,0x00,0x00,0xe8,0x8f,0xe5,
        0x85,0x00,0x00,0x00,0x19,0x49,0x44,0x41,0x54,0x78,0x01,0x01,0x0e,0x00,0xf1,0xff,
        0x00,0x00,0x00,0x00,0x01,0x00,0xff,0x00,0x01,0x00,0x80,0x00,0xff,0xff,0x0d,0x13,
        0x03,0x80,0x8e,0x9a,0x14,0x47,0x00,0x00,0x00,0x00,0x49,0x45,0x4e,0x44,0xae,0x42,
        0x60,0x82,
    }
    testing.expect_value(t,serial.file_write_atomic(path,png[:]),serial.File_Error.None)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=root,capacity=8})) {return}
    defer host.assets_destroy(&assets)
    p,error:=platform.create({headless=true,fixed_dt=1.0/60})
    if !testing.expect_value(t,error,platform.Error.None) || p==nil {return}
    defer platform.destroy(p)
    world:Create_Test_World
    create_test_world_init(&world);defer create_test_world_destroy(&world)
    tables:=create_test_tables()
    info:=core.World_Info{entities=offset_of(Create_Test_World,entities),tables=tables[:],settle=create_test_settle}
    ref:=core.world_ref(&world,&info)
    ctx:=new(ui.Context);defer free(ctx)
    if !testing.expect(t,ui.context_init(ctx,{})) {return}
    defer ui.context_destroy(ctx)
    app:=host.App{allocator=context.allocator,assets=&assets,platform=p}
    selection:editor.Selection;defer delete(selection.entities)
    edits:editor.Edits;defer editor.edits_free(&edits)
    editor.edits_reset(&edits,ref)
    viewport:editor.Viewport
    viewport.orbit.target={7,8,9}
    gui:=editor.Editor_Ui{ctx=ctx,begun=true}
    s:=editor.Session{app=&app,info=&info,edit_world=&world,assets_root=root,headless=true,selection=&selection,edits=&edits,viewport=&viewport,gui=&gui,id_state=731}
    tool:Terrain_Tool;tool_ready(&tool);defer terrain_tool_free(&tool)
    tool.create_kind=kind;tool.create_source=.Heightmap;tool.solid_depth=depth;tool.height_scale=20;tool.height_offset=-3;tool.cell=0.5;tool.chunk_cells=4
    input:=ui.Input{size={800,600},pointer_absent=true,dt=1.0/60}
    create_test_frame(t,&s,&tool,&input)
    create_test_click(t,&s,&tool,&input,"heightmap")
    testing.expect(t,platform.dialog_pending(p))
    testing.expect(t,platform.dialog_answer(p,""))
    create_test_frame(t,&s,&tool,&input)
    testing.expect_value(t,tool.heightmap_length,0)
    testing.expect_value(t,world.entities.alive,0)
    testing.expect(t,!os.exists(saved))
    create_test_click(t,&s,&tool,&input,"heightmap")
    testing.expect(t,platform.dialog_answer(p,path))
    create_test_frame(t,&s,&tool,&input)
    testing.expect_value(t,string(tool.heightmap_path[:tool.heightmap_length]),path)
    testing.expect(t,!platform.dialog_pending(p))
    create_test_click(t,&s,&tool,&input,"heightmap")
    testing.expect(t,platform.dialog_answer(p,"",failed=true))
    create_test_frame(t,&s,&tool,&input)
    testing.expect_value(t,string(tool.heightmap_path[:tool.heightmap_length]),path)
    testing.expect_value(t,world.entities.alive,0)
    create_test_click(t,&s,&tool,&input,"create")
    testing.expect(t,editor.edits_commit(&edits,ref,&selection))
    if !testing.expect_value(t,len(world.terrains.values),1) {return}
    testing.expect_value(t,edits.cursor,1)
    e:=editor.selection_active(&selection)
    testing.expect(t,core.has(&world.terrains,e) && core.has(&world.ids,e))
    testing.expect_value(t,core.get(&world.transforms,e).position,[3]f32{7,0,9})
    testing.expect(t,!core.has(&world.meshes,e),"a terrain shows the materials of its source")
    marker:=core.get(&world.terrains,e)^
    testing.expect(t,marker.solid && marker.revision==1)
    source:terrain.Source;defer terrain.source_destroy(&source)
    if !testing.expect(t,terrain.terrain_read(&source,&assets,marker.source) && !os.exists(saved)) {return}
    testing.expect_value(t,source.kind,kind)
    testing.expect_value(t,source.cell,f32(0.5))
    values:=[6]u16{0,1,255,256,32768,65535}
    if kind==.Heightfield {
        testing.expect_value(t,source.samples,[3]u32{3,1,2})
        // Its file keeps them to the step of its heights, finer than 8 bits.
        for value,i in values {testing.expect_value(t,terrain.source_value(&source,{i%3,0,i/3}),terrain.height_quantize(f32(value)/65535*20-3))}
    } else {
        testing.expect_value(t,len(source.distances.pages),0)
        mesh:geom.Mesh_Buffer;geom.mesh_buffer_init(&mesh);defer geom.mesh_buffer_destroy(&mesh)
        testing.expect(t,terrain.source_mesh_collect(&source,&mesh))
        testing.expect_value(t,geom.mesh_is_closed(mesh.positions[:],mesh.indices[:]),depth>0)
        for value,i in values {
            expected:=[3]f32{(f32(i%3)-1)*0.5,f32(value)/65535*20-3,(f32(i/3)-0.5)*0.5}
            found:=false
            for p in mesh.positions {if p==expected {found=true;break}}
            testing.expectf(t,found,"%v heightmap lost sample %d at %v",kind,i,expected)
        }
    }
    testing.expect(t,editor.undo(&edits,ref,&selection))
    testing.expect_value(t,len(world.terrains.values),0)
    testing.expect(t,!editor.file_exists(&s,saved))
    testing.expect(t,editor.redo(&edits,ref,&selection))
    testing.expect_value(t,len(world.terrains.values),1)
    testing.expect_value(t,world.terrains.values[0],marker)
}

@(test)
failed_terrain_save_preserves_redo_snapshot_scene_and_committed_bytes :: proc(t:^testing.T) {
    directory,_:=os.temp_directory(context.temp_allocator)
    root:=fmt.tprintf("%s/mirai-terrain-save-%d",directory,os.get_pid())
    saved:=fmt.tprintf("%s/terrain/Heightfield Terrain.terrain",root)
    relative:="terrain/Heightfield Terrain.terrain"
    testing.expect_value(t,os.make_directory_all(root),nil)
    defer os.remove(root)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=root,capacity=8})) {return}
    defer host.assets_destroy(&assets)
    world:Create_Test_World
    create_test_world_init(&world);defer create_test_world_destroy(&world)
    tables:=create_test_tables()
    info:=core.World_Info{entities=offset_of(Create_Test_World,entities),tables=tables[:],settle=create_test_settle}
    ref:=core.world_ref(&world,&info)
    app:=host.App{allocator=context.allocator,assets=&assets}
    selection:editor.Selection;defer delete(selection.entities)
    edits:editor.Edits;defer editor.edits_free(&edits)
    editor.edits_reset(&edits,ref)
    viewport:editor.Viewport
    s:=editor.Session{app=&app,info=&info,edit_world=&world,assets_root=root,headless=true,selection=&selection,edits=&edits,viewport=&viewport,id_state=419}
    tool:Terrain_Tool;tool_ready(&tool);defer terrain_tool_free(&tool)
    tool.create_kind=.Heightfield;tool.samples,tool.chunk_cells=5,4
    terrain_create(&s,&tool,ref,&app)
    create_test_settle(&world,nil,nil)
    if !testing.expect_value(t,len(world.terrains.values),1) {return}
    owner:=world.terrains.entities[0]
    id:=world.terrains.values[0].source
    operand:=editor.entity_create(&s,{preset=.Cube,name="Operand"})
    create_test_settle(&world,nil,nil)
    editor.selection_set(&selection,{owner,operand})
    editor.edits_reset(&edits,ref)
    original:=test_held(t,&assets,relative)
    defer delete(original)
    tool.assets=&assets
    tool.stroke={id=id,entity=owner,revision=1,active=true,changed=true}
    if !testing.expect(t,terrain.terrain_read(&tool.stroke.source,&assets,id)) {return}
    if !testing.expect(t,stroke_baseline(&tool)) {return}
    change:=terrain.source_edit(&tool.stroke.source,{kind=.Raise,center={0,0,0},radius=1,amount=2})
    if !testing.expect(t,change.changed && change.error==.None) {return}
    cached_values:=raw_data(tool.stroke.source.heights.pages[0].values)
    stroke_end(&s,&tool,ref,&app)
    if !testing.expect(t,editor.edits_commit(&edits,ref,&selection)) {return}
    testing.expect_value(t,edits.cursor,1)
    testing.expect_value(t,len(edits.steps),1)
    testing.expect_value(t,core.get(&world.terrains,owner).revision,u32(2))
    testing.expect_value(t,tool.stroke.id,id)
    testing.expect_value(t,tool.stroke.revision,u32(2))
    testing.expect_value(t,raw_data(tool.stroke.source.heights.pages[0].values),cached_values)
    testing.expect(t,!tool.stroke.active && !tool.stroke.changed && !tool.stroke.applied_once)
    committed:=test_held(t,&assets,relative)
    defer delete(committed)
    testing.expect(t,string(committed)!=string(original))
    testing.expect(t,!os.exists(saved))
    redo_values:[25]f32
    for &value,i in redo_values {value=terrain.source_value(&tool.stroke.source,{i%5,0,i/5})}
    if !testing.expect(t,editor.undo(&edits,ref,&selection)) {return}
    terrain_sync(&s,&tool,core.read(&world.terrains),&app)
    restored:=test_held(t,&assets,relative)
    defer delete(restored)
    testing.expect_value(t,string(restored),string(original))
    testing.expect_value(t,core.get(&world.terrains,owner).revision,u32(1))
    serial_before,bytes_before:=edits.serial,edits.bytes
    stats_before:=edits.stats
    stroke_free(&tool)
    tool.stroke={id=id,entity=owner,revision=1,active=true,changed=true}
    if !testing.expect(t,terrain.terrain_read(&tool.stroke.source,&assets,id)) {return}
    change=terrain.source_edit(&tool.stroke.source,{kind=.Raise,center={0,0,0},radius=1,amount=9})
    if !testing.expect(t,change.changed && change.error==.None) {return}
    // A height the format refuses: the file cannot be written.
    terrain.grid_set(&tool.stroke.source.heights,0,0,2*terrain.HEIGHT_LIMIT)
    stroke_end(&s,&tool,ref,&app,consume=operand,label="Subtract terrain")
    testing.expect_value(t,string(s.toast[:s.toast_length]),"The terrain could not be written")
    testing.expect_value(t,edits.cursor,0)
    testing.expect_value(t,len(edits.steps),1)
    testing.expect_value(t,edits.serial,serial_before)
    testing.expect_value(t,edits.bytes,bytes_before)
    testing.expect_value(t,edits.stats,stats_before)
    testing.expect(t,!edits.open && !edits.commit)
    testing.expect_value(t,core.get(&world.terrains,owner).revision,u32(1))
    testing.expect_value(t,editor.revision_applied(&tool.history,id).revision,u32(1))
    testing.expect(t,core.alive(&world.entities,operand) && core.has(&world.meshes,operand))
    testing.expect_value(t,len(selection.entities),2)
    testing.expect_value(t,editor.selection_active(&selection),operand)
    testing.expect(t,tool.stroke.id=={} && len(tool.stroke.source.heights.pages)==0)
    // The step to revision 2 still holds what redo brings back.
    testing.expect_value(t,len(tool.steps),1)
    at:=editor.revision_find(&tool.history,id,1,2)
    if !testing.expect(t,at>=0 && len(tool.steps[at].heights.pages)==1) {return}
    redo_step:=&tool.steps[at]
    testing.expect_value(t,redo_step.info.revision,u32(2))
    for value,i in redo_values {testing.expect_value(t,redo_step.heights.pages[0].page.values[i],value)}
    after_failure:=test_held(t,&assets,relative)
    defer delete(after_failure)
    testing.expect_value(t,string(after_failure),string(original))
    if !testing.expect(t,editor.redo(&edits,ref,&selection)) {return}
    terrain_sync(&s,&tool,core.read(&world.terrains),&app)
    testing.expect_value(t,core.get(&world.terrains,owner).revision,u32(2))
    testing.expect_value(t,editor.revision_applied(&tool.history,id).revision,u32(2))
    after_redo:=test_held(t,&assets,relative)
    defer delete(after_redo)
    testing.expect_value(t,string(after_redo),string(committed))
}

// What git and the tools know of the kinds of the plugin without loading it.
@(test)
the_manifest_declares_the_asset_kinds_the_plugin_registers :: proc(t:^testing.T) {
    m,error:=project.plugin_read(#directory+"../plugin.mirai")
    testing.expect_value(t,error.code,project.Error_Code.None)
    testing.expect_value(t,editor.asset_kinds_differ(TERRAIN_KINDS_DEFAULT.provider,&m),"")
}
