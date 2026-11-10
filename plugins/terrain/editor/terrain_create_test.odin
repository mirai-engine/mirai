package terrain_editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/history"
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
    using world:core.Test_World,
    ids:core.Table(core.Id),
    names:core.Table(core.Name),
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    meshes:core.Table(erender.Mesh_Renderer),
    terrains:core.Table(terrain.Terrain),
    worlds:core.Table(core.World_Transform),
    overrides:core.Table(erender.Material_Override),
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
    world:Create_Test_World
    if !core.test_world_init(t,&world,test_types) {return}
    defer core.test_world_destroy(&world)
    ref:=core.test_world_ref(&world)
    owner:=core.create(&world.entities)
    core.add(&world.terrains,owner,terrain.Terrain{source={1,1},revision=1})
    core.add(&world.worlds,owner,core.World_Transform{})
    core.world_settle(ref)
    // On the heap: with the session and the app, a context on the stack of a test thread overflows it.
    ctx:=new(ui.Context);defer free(ctx)
    if !testing.expect(t,ui.context_init(ctx,{})) {return}
    defer ui.context_destroy(ctx)
    app:=host.App{allocator=context.allocator,platform=p}
    selection:history.Selection;defer delete(selection.entities)
    history.selection_set(&selection,{owner})
    viewport:editor.Viewport
    gui:=editor.Editor_Ui{ctx=ctx,begun=true}
    s:=editor.Session{app=&app,info=ref.info,edit_world=&world,headless=true,selection=&selection,viewport=&viewport,gui=&gui}
    editor.tool_set(&s,"terrain",true)
    tool:Terrain_Tool;tool_ready(&tool);defer terrain_tool_free(&tool)
    tool.create_source=.Heightmap
    tool.stroke.entity,tool.stroke.id=owner,{1,1}
    id:=ui.id_derive(ctx,PANEL_SCOPE,"panel")
    // A selected terrain shows its modes, not the controls to create another.
    for kind in ([2]terrain.Source_Kind{.Heightfield,.Volume}) {
        tool.stroke.source.kind=kind
        input:=ui.Input{size={1000,900},pointer_absent=true,dt=1.0/60}
        for _ in 0..<2 {create_test_tool_panel_frame(t,&s,&tool,ref,&input)}
        _,found:=ui.widget_rect(ctx,ui.id_derive(ctx,id,"create"))
        testing.expectf(t,!found,"%v: a selected terrain shows New terrain",kind)
    }
    history.selection_clear(&selection)
    input:=ui.Input{size={1000,900},pointer_absent=true,dt=1.0/60}
    create_test_tool_panel_frame(t,&s,&tool,ref,&input)
    testing.expect(t,tool.stroke.id=={})
    for kind in ([2]terrain.Source_Kind{.Heightfield,.Volume}) {
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
terrain_creation_separates_heightfield_and_volume_and_keeps_undo :: proc(t:^testing.T) {
    create_test_plane(t,.Heightfield)
    create_test_plane(t,.Volume)
}

@(private)
create_test_plane :: proc(t:^testing.T,kind:terrain.Source_Kind) {
    root:=base.test_folder(t,"terrain")
    path:=fmt.tprintf("%s/terrain/%s.terrain",root,terrain_kind_name(kind))
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=root,capacity=8})) {return}
    defer host.assets_destroy(&assets)
    p,error:=platform.create({headless=true,fixed_dt=1.0/60})
    if !testing.expect_value(t,error,platform.Error.None) || p==nil {return}
    defer platform.destroy(p)
    world:Create_Test_World
    if !core.test_world_init(t,&world,test_types) {return}
    defer core.test_world_destroy(&world)
    ref:=core.test_world_ref(&world)
    ctx:=new(ui.Context);defer free(ctx)
    if !testing.expect(t,ui.context_init(ctx,{})) {return}
    defer ui.context_destroy(ctx)
    app:=host.App{allocator=context.allocator,assets=&assets,platform=p}
    selection:history.Selection;defer delete(selection.entities)
    edits:history.Edits;defer history.edits_free(&edits)
    history.edits_reset(&edits,ref)
    viewport:editor.Viewport
    gui:=editor.Editor_Ui{ctx=ctx,begun=true}
    s:=editor.Session{app=&app,info=ref.info,edit_world=&world,assets_root=root,headless=true,selection=&selection,edits=&edits,viewport=&viewport,gui=&gui,id_state=331}
    tool:Terrain_Tool;tool_ready(&tool);defer terrain_tool_free(&tool)
    testing.expect_value(t,tool.create_kind,terrain.Source_Kind.Heightfield)
    tool.samples,tool.depth,tool.chunk_cells=5,5,4
    input:=ui.Input{size={800,600},pointer_absent=true,dt=1.0/60}
    create_test_frame(t,&s,&tool,&input)
    create_test_click(t,&s,&tool,&input,"source_kind")
    list:=ui.id_derive(ctx,ui.id(ctx,"source_kind"),"list")
    index:=int(kind)
    for option in 0..<2 {
        rect,found:=ui.widget_rect(ctx,ui.id_derive(ctx,list,"row",option+1))
        testing.expect(t,found && rect.w>=200)
    }
    create_test_click_id(t,&s,&tool,&input,ui.id_derive(ctx,list,"row",index+1))
    testing.expect_value(t,tool.create_kind,kind)
    create_test_frame(t,&s,&tool,&input)
    create_test_click(t,&s,&tool,&input,"create")
    if !testing.expect(t,history.edits_commit(&edits,ref,&selection)) {return}
    testing.expect_value(t,len(world.terrains.values),1)
    owner:=history.selection_active(&selection)
    testing.expect(t,core.has(&world.terrains,owner))
    testing.expect_value(t,edits.cursor,1)
    source:terrain.Source;defer terrain.source_destroy(&source)
    testing.expect(t,!os.exists(path))
    if !testing.expect(t,terrain.terrain_read(&source,&assets,core.at(&world.terrains,core.row_of(&world.terrains,owner)).source)) {return}
    testing.expect_value(t,source.kind,kind)
    // Every kind starts with one layer that covers all of it.
    testing.expect_value(t,source.layer_count,u32(1))
    testing.expect_value(t,terrain.source_weights_at(&source,terrain.source_origin(&source)),[4]f32{1,0,0,0})
    if kind==.Volume {testing.expect_value(t,source.distances.size,[3]int{5,5,5})} else {testing.expect_value(t,source.heights.size,[3]int{5,1,5})}
    testing.expect(t,history.undo(&edits,ref,&selection))
    testing.expect_value(t,len(world.terrains.values),0)
    testing.expect(t,!editor.file_exists(&s,path))
    testing.expect(t,history.redo(&edits,ref,&selection))
    testing.expect_value(t,len(world.terrains.values),1)
    testing.expect_value(t,history.selection_active(&selection),owner)
    testing.expect(t,editor.file_exists(&s,path) && !os.exists(path))
}

// A Volume made on a Heightfield joins it and its field is the ground,
// solid down to the bottom of its box: what is dug there has a floor.
@(test)
a_named_terrain_takes_the_name_and_a_missing_heightmap_says_its_path :: proc(t:^testing.T) {
    root:=base.test_folder(t,"terrain")
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=root,capacity=8})) {return}
    defer host.assets_destroy(&assets)
    world:Create_Test_World
    if !core.test_world_init(t,&world,test_types) {return}
    defer core.test_world_destroy(&world)
    ref:=core.test_world_ref(&world)
    app:=host.App{allocator=context.allocator,assets=&assets}
    selection:history.Selection;defer delete(selection.entities)
    edits:history.Edits;defer history.edits_free(&edits)
    history.edits_reset(&edits,ref)
    viewport:editor.Viewport
    s:=editor.Session{app=&app,info=ref.info,edit_world=&world,assets_root=root,headless=true,selection=&selection,edits=&edits,viewport=&viewport,id_state=631}
    tool:Terrain_Tool;tool_ready(&tool);defer terrain_tool_free(&tool)
    tool.create_kind,tool.create_source=.Heightfield,.Heightmap
    missing:=fmt.tprintf("%s/source/none.png",root)
    tool.heightmap_length=copy(tool.heightmap_path[:],missing)
    s.toast_length=0
    testing.expect_value(t,terrain_create(&s,&tool,ref,app.assets,app.allocator,name="Island"),core.NONE)
    said:=string(s.toast[:s.toast_length])
    testing.expectf(t,strings.contains(said,missing),"the error names the file it tried: %s",said)
    tool.create_source,tool.samples,tool.chunk_cells=.Plane,5,4
    e:=terrain_create(&s,&tool,ref,app.assets,app.allocator,at={0,0,0},placed=true,name="Island")
    if !testing.expect(t,e!=core.NONE && history.edits_commit(&edits,ref,&selection)) {return}
    name:=core.edit(&world.names,e)
    testing.expect(t,name!=nil && base.text_get(name.text[:])=="Island","the entity takes the name")
    testing.expect(t,editor.file_exists(&s,fmt.tprintf("%s/terrain/Island.terrain",root)),"the file takes the name")
}

@(test)
a_volume_created_on_a_heightfield_is_filled_with_its_ground :: proc(t:^testing.T) {
    root:=base.test_folder(t,"terrain")
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=root,capacity=8})) {return}
    defer host.assets_destroy(&assets)
    world:Create_Test_World
    if !core.test_world_init(t,&world,test_types) {return}
    defer core.test_world_destroy(&world)
    ref:=core.test_world_ref(&world)
    app:=host.App{allocator=context.allocator,assets=&assets}
    selection:history.Selection;defer delete(selection.entities)
    edits:history.Edits;defer history.edits_free(&edits)
    history.edits_reset(&edits,ref)
    viewport:editor.Viewport
    s:=editor.Session{app=&app,info=ref.info,edit_world=&world,assets_root=root,headless=true,selection=&selection,edits=&edits,viewport=&viewport,id_state=523}
    tool:Terrain_Tool;tool_ready(&tool);defer terrain_tool_free(&tool)
    tool.create_kind=.Heightfield;tool.samples,tool.depth,tool.chunk_cells=17,9,8
    // The ground is a root: where it stands is its Transform.
    ground:=terrain_create(&s,&tool,ref,app.assets,app.allocator,at={10,0,10},placed=true)
    if !testing.expect(t,ground!=core.NONE && history.edits_commit(&edits,ref,&selection)) {return}
    tool.create_kind=.Volume
    owner:=terrain_create(&s,&tool,ref,app.assets,app.allocator,at={10,0,10},placed=true,ground=ground)
    if !testing.expect(t,owner!=core.NONE && history.edits_commit(&edits,ref,&selection)) {return}
    marker,_:=core.get(&world.terrains,owner)
    testing.expect_value(t,marker.ground,editor.api_entity_id(ref,ground))
    volume:terrain.Source;defer terrain.source_destroy(&volume)
    if !testing.expect(t,terrain.terrain_read(&volume,&assets,marker.source)) {return}
    for z in 0..<17 {for y in 0..<9 {for x in 0..<17 {
        value:=terrain.source_value(&volume,{x,y,z})
        if !testing.expectf(t,y<4?value<0:y>4?value>0:value==0,"the sample %v of the Volume is %v, the ground at the sample 4 along y",[3]int{x,y,z},value) {return}
    }}}
}

@(test)
heightmap_dialog_creates_scaled_terrain_with_one_undo_step :: proc(t:^testing.T) {
    create_test_heightmap(t,.Heightfield)
}

@(private)
create_test_heightmap :: proc(t:^testing.T,kind:terrain.Source_Kind) {
    root:=base.test_folder(t,"terrain")
    path:=fmt.tprintf("%s/height16.png",root)
    saved:=fmt.tprintf("%s/terrain/%s.terrain",root,terrain_kind_name(kind))
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
    if !core.test_world_init(t,&world,test_types) {return}
    defer core.test_world_destroy(&world)
    ref:=core.test_world_ref(&world)
    ctx:=new(ui.Context);defer free(ctx)
    if !testing.expect(t,ui.context_init(ctx,{})) {return}
    defer ui.context_destroy(ctx)
    app:=host.App{allocator=context.allocator,assets=&assets,platform=p}
    selection:history.Selection;defer delete(selection.entities)
    edits:history.Edits;defer history.edits_free(&edits)
    history.edits_reset(&edits,ref)
    viewport:editor.Viewport
    viewport.orbit.target={7,8,9}
    gui:=editor.Editor_Ui{ctx=ctx,begun=true}
    s:=editor.Session{app=&app,info=ref.info,edit_world=&world,assets_root=root,headless=true,selection=&selection,edits=&edits,viewport=&viewport,gui=&gui,id_state=731}
    tool:Terrain_Tool;tool_ready(&tool);defer terrain_tool_free(&tool)
    tool.create_kind=kind;tool.create_source=.Heightmap;tool.height_scale=20;tool.height_offset=-3;tool.cell=0.5;tool.chunk_cells=4
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
    testing.expect(t,history.edits_commit(&edits,ref,&selection))
    if !testing.expect_value(t,len(world.terrains.values),1) {return}
    testing.expect_value(t,edits.cursor,1)
    e:=history.selection_active(&selection)
    testing.expect(t,core.has(&world.terrains,e) && core.has(&world.ids,e))
    testing.expect_value(t,core.at(&world.transforms,core.row_of(&world.transforms,e)).position,[3]f32{7,0,9})
    testing.expect(t,!core.has(&world.meshes,e),"a terrain shows the materials of its source")
    marker:=core.at(&world.terrains,core.row_of(&world.terrains,e))
    testing.expect(t,marker.solid && marker.revision==1)
    source:terrain.Source;defer terrain.source_destroy(&source)
    if !testing.expect(t,terrain.terrain_read(&source,&assets,marker.source) && !os.exists(saved)) {return}
    testing.expect_value(t,source.kind,kind)
    testing.expect_value(t,source.cell,f32(0.5))
    values:=[6]u16{0,1,255,256,32768,65535}
    testing.expect_value(t,source.samples,[3]u32{3,1,2})
    // Its file keeps them to the step of its heights, finer than 8 bits.
    for value,i in values {testing.expect_value(t,terrain.source_value(&source,{i%3,0,i/3}),terrain.height_quantize(f32(value)/65535*20-3))}
    testing.expect(t,history.undo(&edits,ref,&selection))
    testing.expect_value(t,len(world.terrains.values),0)
    testing.expect(t,!editor.file_exists(&s,saved))
    testing.expect(t,history.redo(&edits,ref,&selection))
    testing.expect_value(t,len(world.terrains.values),1)
    testing.expect_value(t,world.terrains.values[0],marker)
}

@(test)
failed_terrain_save_preserves_redo_snapshot_scene_and_committed_bytes :: proc(t:^testing.T) {
    root:=base.test_folder(t,"terrain")
    saved:=fmt.tprintf("%s/terrain/Heightfield Terrain.terrain",root)
    relative:="terrain/Heightfield Terrain.terrain"
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=root,capacity=8})) {return}
    defer host.assets_destroy(&assets)
    world:Create_Test_World
    if !core.test_world_init(t,&world,test_types) {return}
    defer core.test_world_destroy(&world)
    ref:=core.test_world_ref(&world)
    app:=host.App{allocator=context.allocator,assets=&assets}
    selection:history.Selection;defer delete(selection.entities)
    edits:history.Edits;defer history.edits_free(&edits)
    history.edits_reset(&edits,ref)
    viewport:editor.Viewport
    s:=editor.Session{app=&app,info=ref.info,edit_world=&world,assets_root=root,headless=true,selection=&selection,edits=&edits,viewport=&viewport,id_state=419}
    tool:Terrain_Tool;tool_ready(&tool);defer terrain_tool_free(&tool)
    tool.create_kind=.Heightfield;tool.samples,tool.chunk_cells=5,4
    terrain_create(&s,&tool,ref,app.assets,app.allocator)
    core.test_world_settle(&world)
    if !testing.expect_value(t,len(world.terrains.values),1) {return}
    owner:=world.terrains.entities[0]
    id:=world.terrains.values[0].source
    operand:=editor.entity_create(&s,{name="Operand"})
    core.add(&world.meshes,operand,erender.Mesh_Renderer{shape=.Cube})
    core.test_world_settle(&world)
    history.selection_set(&selection,{owner,operand})
    history.edits_reset(&edits,ref)
    original:=test_held(t,&assets,relative)
    defer delete(original)
    tool.assets=&assets
    tool.stroke={id=id,entity=owner,revision=1,active=true,changed=true}
    if !testing.expect(t,terrain.terrain_read(&tool.stroke.source,&assets,id)) {return}
    if !testing.expect(t,stroke_baseline(&tool)) {return}
    change:=terrain.source_edit(&tool.stroke.source,{kind=.Raise,center={0,0,0},radius=1,amount=2})
    if !testing.expect(t,change.changed && change.error==.None) {return}
    cached_values:=raw_data(tool.stroke.source.heights.pages[0].values)
    stroke_end(&s,&tool,ref,app.assets)
    if !testing.expect(t,history.edits_commit(&edits,ref,&selection)) {return}
    testing.expect_value(t,edits.cursor,1)
    testing.expect_value(t,len(edits.steps),1)
    testing.expect_value(t,core.at(&world.terrains,core.row_of(&world.terrains,owner)).revision,u32(2))
    testing.expect_value(t,tool.stroke.id,id)
    testing.expect_value(t,tool.stroke.revision,u32(2))
    testing.expect_value(t,raw_data(tool.stroke.source.heights.pages[0].values),cached_values)
    testing.expect(t,!tool.stroke.active && !tool.stroke.changed)
    committed:=test_held(t,&assets,relative)
    defer delete(committed)
    testing.expect(t,string(committed)!=string(original))
    testing.expect(t,!os.exists(saved))
    redo_values:[25]f32
    for &value,i in redo_values {value=terrain.source_value(&tool.stroke.source,{i%5,0,i/5})}
    if !testing.expect(t,history.undo(&edits,ref,&selection)) {return}
    terrain_sync(&s,&tool,core.read(&world.terrains),app.assets)
    restored:=test_held(t,&assets,relative)
    defer delete(restored)
    testing.expect_value(t,string(restored),string(original))
    testing.expect_value(t,core.at(&world.terrains,core.row_of(&world.terrains,owner)).revision,u32(1))
    serial_before,bytes_before:=edits.serial,edits.bytes
    stats_before:=edits.stats
    stroke_free(&tool)
    tool.stroke={id=id,entity=owner,revision=1,active=true,changed=true}
    if !testing.expect(t,terrain.terrain_read(&tool.stroke.source,&assets,id)) {return}
    change=terrain.source_edit(&tool.stroke.source,{kind=.Raise,center={0,0,0},radius=1,amount=9})
    if !testing.expect(t,change.changed && change.error==.None) {return}
    // A height the format refuses: the file cannot be written.
    terrain.grid_set(&tool.stroke.source.heights,0,0,2*terrain.HEIGHT_LIMIT)
    stroke_end(&s,&tool,ref,app.assets,consume=operand,label="Subtract terrain")
    testing.expect_value(t,string(s.toast[:s.toast_length]),"The terrain could not be written")
    testing.expect_value(t,edits.cursor,0)
    testing.expect_value(t,len(edits.steps),1)
    testing.expect_value(t,edits.serial,serial_before)
    testing.expect_value(t,edits.bytes,bytes_before)
    testing.expect_value(t,edits.stats,stats_before)
    testing.expect(t,!edits.open && !edits.commit)
    testing.expect_value(t,core.at(&world.terrains,core.row_of(&world.terrains,owner)).revision,u32(1))
    testing.expect_value(t,editor.revision_applied(&tool.history,id).revision,u32(1))
    testing.expect(t,core.alive(&world.entities,operand) && core.has(&world.meshes,operand))
    testing.expect_value(t,len(selection.entities),2)
    testing.expect_value(t,history.selection_active(&selection),operand)
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
    if !testing.expect(t,history.redo(&edits,ref,&selection)) {return}
    terrain_sync(&s,&tool,core.read(&world.terrains),app.assets)
    testing.expect_value(t,core.at(&world.terrains,core.row_of(&world.terrains,owner)).revision,u32(2))
    testing.expect_value(t,editor.revision_applied(&tool.history,id).revision,u32(2))
    after_redo:=test_held(t,&assets,relative)
    defer delete(after_redo)
    testing.expect_value(t,string(after_redo),string(committed))
}
