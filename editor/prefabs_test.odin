package editor

import "base:runtime"

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

Prefab_Test_World :: struct {
    entities:core.Entities,
    ids:core.Table(core.Id),
    names:core.Table(core.Name),
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    disabled:core.Table(core.Disabled),
    lamps:core.Table(Prefab_Test_Lamp),
    point_lights:core.Table(erender.Point_Light),
    hierarchy:core.Hierarchy,
}

// A component a scene saves and the API writes.
Prefab_Test_Lamp :: struct {intensity,range:f32,target:core.Entity,uses:u32 `mirai:"hidden"`}

prefab_test_clear :: proc(data:rawptr) -> bool {
    w:=cast(^Prefab_Test_World)data
    core.table_clear(&w.ids)
    core.table_clear(&w.names)
    core.table_clear(&w.transforms)
    core.table_clear(&w.parents)
    core.table_clear(&w.disabled)
    core.table_clear(&w.lamps)
    core.table_clear(&w.point_lights)
    core.hierarchy_clear(&w.hierarchy)
    return core.entities_clear(&w.entities)
}

prefab_test_init :: proc(data:rawptr,allocator:runtime.Allocator) -> bool {
    context.allocator=allocator
    w:=cast(^Prefab_Test_World)data
    core.entities_init(&w.entities)
    core.table_init(&w.ids,"Id")
    core.table_init(&w.names,"Name")
    core.table_init(&w.transforms,"Transform")
    core.table_init(&w.parents,"Parent")
    core.table_init(&w.disabled,"Disabled")
    core.table_init(&w.lamps,"Prefab_Test_Lamp")
    core.table_init(&w.point_lights,"Point_Light")
    w.ids.base,w.names.base,w.transforms.base,w.parents.base,w.disabled.base=true,true,true,true,true
    return len(w.entities.generation)>0
}

prefab_test_destroy :: proc(data:rawptr) {
    w:=cast(^Prefab_Test_World)data
    core.entities_destroy(&w.entities)
    core.table_destroy(&w.ids)
    core.table_destroy(&w.names)
    core.table_destroy(&w.transforms)
    core.table_destroy(&w.parents)
    core.table_destroy(&w.disabled)
    core.table_destroy(&w.lamps)
    core.table_destroy(&w.point_lights)
    core.value_free(&w.hierarchy,type_info_of(core.Hierarchy))
}

prefab_test_copy :: proc(dst,src:rawptr) -> bool {
    dst,src:=cast(^Prefab_Test_World)dst,cast(^Prefab_Test_World)src
    return core.entities_copy(&dst.entities,&src.entities) && core.table_copy(&dst.ids,&src.ids) && core.table_copy(&dst.names,&src.names) && core.table_copy(&dst.transforms,&src.transforms) && core.table_copy(&dst.parents,&src.parents) && core.table_copy(&dst.disabled,&src.disabled) && core.table_copy(&dst.lamps,&src.lamps) && core.table_copy(&dst.point_lights,&src.point_lights) && core.value_copy(&dst.hierarchy,&src.hierarchy,type_info_of(core.Hierarchy))
}

prefab_test_swap :: proc(a,b:rawptr) {
    a,b:=(^Prefab_Test_World)(a),(^Prefab_Test_World)(b)
    a.entities,b.entities=b.entities,a.entities
    core.table_swap(&a.ids,&b.ids);core.table_swap(&a.names,&b.names);core.table_swap(&a.transforms,&b.transforms);core.table_swap(&a.parents,&b.parents);core.table_swap(&a.disabled,&b.disabled);core.table_swap(&a.lamps,&b.lamps);core.table_swap(&a.point_lights,&b.point_lights)
    a.hierarchy,b.hierarchy=b.hierarchy,a.hierarchy
}

@(test)
prefab_selection_and_file_overrides_share_the_undo_history :: proc(t:^testing.T) {
    world:Prefab_Test_World
    core.entities_init(&world.entities)
    core.table_init(&world.ids,"Id")
    core.table_init(&world.names,"Name")
    core.table_init(&world.transforms,"Transform")
    core.table_init(&world.parents,"Parent")
    defer core.entities_destroy(&world.entities)
    defer core.table_destroy(&world.ids)
    defer core.table_destroy(&world.names)
    defer core.table_destroy(&world.transforms)
    defer core.table_destroy(&world.parents)
    defer core.value_free(&world.hierarchy,type_info_of(core.Hierarchy))
    tables:=[5]core.Table_Info{
        {name="Id",type=core.Id,info=type_info_of(core.Id),offset=offset_of(Prefab_Test_World,ids)},
        {name="Name",type=core.Name,info=type_info_of(core.Name),offset=offset_of(Prefab_Test_World,names)},
        {name="Transform",type=core.Transform,info=type_info_of(core.Transform),offset=offset_of(Prefab_Test_World,transforms)},
        {name="Parent",type=core.Parent,info=type_info_of(core.Parent),offset=offset_of(Prefab_Test_World,parents)},
        {name="Disabled",type=core.Disabled,info=type_info_of(core.Disabled),offset=offset_of(Prefab_Test_World,disabled)},
    }
    storages:=[2]core.Storage_Info{{type=Prefabs,place=.Editor},{type=core.Hierarchy,info=type_info_of(core.Hierarchy),offset=offset_of(Prefab_Test_World,hierarchy)}}
    info:=core.World_Info{tables=tables[:],storages=storages[:],clear=prefab_test_clear,copy=prefab_test_copy,swap=prefab_test_swap,
        sizes={.World=size_of(Prefab_Test_World),.Shared=0,.Editor=0},aligns={.World=align_of(Prefab_Test_World),.Shared=1,.Editor=1},
        init={.World=prefab_test_init,.Shared=nil,.Editor=nil},destroy={.World=prefab_test_destroy,.Shared=nil,.Editor=nil}}
    root:=project.path_absolute(fmt.tprintf(".mirai/test-prefabs-%d",os.get_pid()),context.temp_allocator)
    testing.expect(t,!os.exists(root))
    if os.exists(root) {return}
    os.make_directory_all(root)
    defer os.remove_all(root)
    assets:host.Assets
    asset.types_init(&assets.types)
    defer asset.types_destroy(&assets.types)
    asset.registry_init(&assets.registry,root)
    defer asset.registry_destroy(&assets.registry)
    app:=host.App{assets=&assets,info=&info,allocator=context.allocator}
    defer delete(app.worlds)
    viewport:Viewport
    selection:Selection
    inspector:Inspector
    edits:Edits
    document:Document
    prefabs:Prefabs
    ai:=new(Ai)
    defer free(ai)
    g:Editor_Ui
    outliner:Outliner
    // The session and the UI context are large: off the stack of the test.
    s:=new(Session)
    defer free(s)
    s.info,s.edit_world,s.editor_world,s.assets_root,s.app=&info,&world,&prefabs,root,&app
    s.gui,s.viewport,s.selection,s.inspector,s.edits,s.document,s.outliner,s.ai=&g,&viewport,&selection,&inspector,&edits,&document,&outliner,ai
    defer delete(selection.entities)
    defer core.value_free(&inspector,type_info_of(Inspector))
    defer edits_free(&edits)
    defer document_previous_free(&document)
    defer prefabs_free(s)
    w:=edited_world(s)
    first:=entity_create(s,{name="First",transform={position={2,0,0},rotation=1,scale={1,1,1}}})
    second:=entity_create(s,{name="Second",transform={position={6,0,0},rotation=1,scale={1,1,1}}})
    core.world_settle(w)
    first_id,second_id:=api_entity_id(w,first),api_entity_id(w,second)
    edits_reset(&edits,w)
    prefabs_follow(s,&prefabs)
    selection_set(&selection,{first,second})
    testing.expect(t,!prefab_action_disabled(s,.Prefab_Create))
    testing.expect(t,os.write_entire_file(fmt.tprintf("%s/blocked",root),[]u8{1})==nil)
    _,failed:=prefab_create_entities(s,selection.entities[:],"blocked/pair")
    testing.expect_value(t,failed,Prefab_Error.Write_Failed)
    testing.expect_value(t,world.entities.alive,2)
    testing.expect_value(t,len(selection.entities),2)
    testing.expect_value(t,edits.cursor,0)
    testing.expect_value(t,entity_parent(w,first),core.NONE)
    testing.expect_value(t,entity_parent(w,second),core.NONE)
    id,error:=prefab_create_entities(s,selection.entities[:],"pair")
    testing.expect_value(t,error,Prefab_Error.None)
    if error!=.None {return}
    testing.expect_value(t,edits.cursor,1)
    testing.expect_value(t,len(document.previous.instances),1)
    group:=selection_active(&selection)
    group_id:=api_entity_id(w,group)
    first,second=api_entity(w,first_id),api_entity(w,second_id)
    selection_clear(&selection)
    testing.expect_value(t,selection_click_target(s,w,first,false),group)
    testing.expect_value(t,selection_click_target(s,w,first,true),first)
    selection_set(&selection,{group})
    testing.expect_value(t,selection_click_target(s,w,first,false),first)
    selection_set(&selection,{first})
    testing.expect_value(t,selection_click_target(s,w,second,false),second)
    selection_set(&selection,{group})
    testing.expect_value(t,entity_parent(w,first),group)
    testing.expect_value(t,entity_parent(w,second),group)
    testing.expect_value(t,entity_world(w,first).position,([3]f32{2,0,0}))
    testing.expect_value(t,entity_world(w,second).position,([3]f32{6,0,0}))
    file:=fmt.tprintf("%s/pair.prefab",root)
    testing.expect(t,os.exists(file))
    testing.expect(t,undo(&edits,w,&selection))
    prefabs_follow(s,&prefabs)
    testing.expect(t,!os.exists(file) && len(document.previous.instances)==0)
    testing.expect_value(t,world.entities.alive,2)
    testing.expect_value(t,len(selection.entities),2)
    testing.expect(t,redo(&edits,w,&selection))
    prefabs_follow(s,&prefabs)
    testing.expect(t,os.exists(file) && len(document.previous.instances)==1)
    group=api_entity(w,group_id)
    group_placement:=core.to_math(core.Transform{{11,7,-3},quaternion(x=0,y=0.6,z=0,w=0.8),{2,3,4}})
    transform_set(s,group,group_placement)
    edits_commit(&edits,w,&selection)
    prefabs_follow(s,&prefabs)
    selection_set(&selection,{group})
    testing.expect(t,prefab_action_disabled(s,.Prefab_Apply) && prefab_action_disabled(s,.Prefab_Revert))
    testing.expect_value(t,len(document.previous.overrides),0)
    root_field:=inspect_component(s,w,core.Transform,{group})
    testing.expect_value(t,len(inspect_default(s,w,root_field.t,group)),0)
    testing.expect(t,!inspect_changed(&root_field,int(offset_of(core.Transform,position)),12))
    testing.expect(t,!inspect_changed(&root_field,int(offset_of(core.Transform,rotation)),16))
    testing.expect(t,!inspect_changed(&root_field,int(offset_of(core.Transform,scale)),12))
    placement_cursor:=edits.cursor
    inspect_reset(&root_field,0,size_of(core.Transform))
    edits_commit(&edits,w,&selection)
    testing.expect_value(t,entity_local(w,group),group_placement)
    testing.expect_value(t,edits.cursor,placement_cursor)
    first=api_entity(w,first_id)
    selection_set(&selection,{first})
    testing.expect(t,prefab_action_disabled(s,.Prefab_Create))
    inherited_position:=entity_local(w,first).position
    changed_transform:=entity_local(w,first)
    changed_transform.position.x+=4
    transform_set(s,first,changed_transform)
    edits_commit(&edits,w,&selection)
    inherited_field:=inspect_component(s,w,core.Transform,{first})
    position_offset:=int(offset_of(core.Transform,position))
    testing.expect(t,inspect_changed(&inherited_field,position_offset,12))
    mixed_field:=inspect_component(s,w,core.Transform,{group,first})
    testing.expect(t,inspect_changed(&mixed_field,position_offset,12))
    inspect_reset(&mixed_field,position_offset,12)
    edits_commit(&edits,w,&selection)
    testing.expect_value(t,entity_local(w,group),group_placement)
    testing.expect_value(t,entity_local(w,first).position,inherited_position)
    testing.expect(t,!inspect_changed(&inherited_field,position_offset,12))
    testing.expect_value(t,api_entity_id(w,first),first_id)
    testing.expect(t,entity_rename(s,first,"Changed"))
    testing.expect_value(t,entity_name(w,first),"Changed")
    edits_commit(&edits,w,&selection)
    prefabs_follow(s,&prefabs)
    testing.expect_value(t,len(document.previous.overrides),1)
    testing.expect(t,!prefab_action_disabled(s,.Prefab_Apply))
    count,apply_error:=prefab_apply(s,first,nil)
    testing.expect(t,apply_error==.None && count==1)
    testing.expect_value(t,entity_local(w,api_entity(w,group_id)),group_placement)
    loaded,found:=prefab_scene_load(s,id)
    testing.expect(t,found)
    if found {
        row,_:=asset.scene_entity_find(loaded,first_id)
        testing.expect_value(t,base.text_get(asset.scene_names(loaded)[row][:]),"Changed")
        root_value,_:=asset.scene_get(loaded,group_id,"Transform",core.Transform)
        testing.expect_value(t,root_value,core.TRANSFORM_IDENTITY)
        prefab_scene_free(loaded)
    }
    testing.expect(t,undo(&edits,w,&selection))
    prefabs_follow(s,&prefabs)
    testing.expect(t,!prefab_action_disabled(s,.Prefab_Revert))
    loaded,found=prefab_scene_load(s,id)
    testing.expect(t,found)
    if found {
        row,_:=asset.scene_entity_find(loaded,first_id)
        testing.expect_value(t,base.text_get(asset.scene_names(loaded)[row][:]),"First")
        prefab_scene_free(loaded)
    }
    testing.expect(t,redo(&edits,w,&selection))
    prefabs_follow(s,&prefabs)
    testing.expect(t,prefab_action_disabled(s,.Prefab_Revert))
    testing.expect(t,undo(&edits,w,&selection))
    prefabs_follow(s,&prefabs)
    first=selection_active(&selection)
    reverted,revert_error:=prefab_revert(s,first,nil)
    testing.expect(t,revert_error==.None && reverted==1)
    testing.expect_value(t,entity_name(w,api_entity(w,first_id)),"First")
    testing.expect_value(t,entity_local(w,api_entity(w,group_id)),group_placement)
    group=api_entity(w,group_id)
    first,second=api_entity(w,first_id),api_entity(w,second_id)
    entity_rename(s,first,"First changed")
    entity_rename(s,second,"Second changed")
    edits_commit(&edits,w,&selection)
    prefabs_follow(s,&prefabs)
    reverted,revert_error=prefab_revert(s,first,nil)
    testing.expect(t,revert_error==.None && reverted==1)
    first,second=api_entity(w,first_id),api_entity(w,second_id)
    testing.expect_value(t,entity_name(w,first),"First")
    testing.expect_value(t,entity_name(w,second),"Second changed")
    entity_rename(s,first,"First changed")
    edits_commit(&edits,w,&selection)
    prefabs_follow(s,&prefabs)
    group=api_entity(w,group_id)
    selection_set(&selection,{group})
    testing.expect(t,!prefab_action_disabled(s,.Prefab_Apply) && !prefab_action_disabled(s,.Prefab_Revert))
    count,apply_error=prefab_apply(s,group,nil,true)
    testing.expect(t,apply_error==.None && count==2)
    loaded,found=prefab_scene_load(s,id)
    testing.expect(t,found)
    if found {
        row,_:=asset.scene_entity_find(loaded,first_id)
        testing.expect_value(t,base.text_get(asset.scene_names(loaded)[row][:]),"First changed")
        row,_=asset.scene_entity_find(loaded,second_id)
        testing.expect_value(t,base.text_get(asset.scene_names(loaded)[row][:]),"Second changed")
        prefab_scene_free(loaded)
    }
    testing.expect(t,undo(&edits,w,&selection))
    prefabs_follow(s,&prefabs)
    group=api_entity(w,group_id)
    reverted,revert_error=prefab_revert(s,group,nil,true)
    testing.expect(t,revert_error==.None && reverted==2)
    testing.expect_value(t,entity_name(w,api_entity(w,first_id)),"First")
    testing.expect_value(t,entity_name(w,api_entity(w,second_id)),"Second")
    testing.expect_value(t,entity_local(w,api_entity(w,group_id)),group_placement)
    group=api_entity(w,group_id)
    before:=edits.cursor
    testing.expect_value(t,prefab_unlink(s,group,false),Prefab_Error.None)
    testing.expect_value(t,edits.cursor,before+1)
    testing.expect(t,!prefab_linked(s))
    group=api_entity(w,group_id)
    unlinked_field:=inspect_component(s,w,core.Transform,{group})
    testing.expect(t,inspect_changed(&unlinked_field,position_offset,12))
    testing.expect(t,undo(&edits,w,&selection))
    prefabs_follow(s,&prefabs)
    testing.expect(t,prefab_linked(s))
    ctx:=new(ui.Context)
    defer free(ctx)
    testing.expect(t,ui.context_init(ctx,{}))
    defer ui.context_destroy(ctx)
    g.ctx=ctx
    for size in ([2][2]f32{{1440,900},{800,420}}) {
        for _ in 0..<3 {
            ui.frame_begin(ctx,{size=size,pointer_absent=true})
            if ui.box(ctx,{width=ui.fixed(240),height=ui.FIT,gap=4,align_y=.Center}) {
                identity_row(s,w,selection_active(&selection))
            }
            frame:=ui.frame_end(ctx)
            testing.expect(t,!frame.overflow && ctx.stats.layout_errors==0)
        }
        _,visible:=ui.widget_rect(ctx,ui.id(ctx,"prefab_open"))
        _,saves:=ui.widget_rect(ctx,ui.id(ctx,"variant_save"))
        testing.expect(t,visible && saves,"the icon opens the prefab and Save variant shows beside Apply")
        action_row:=f32(-1)
        action_labels:=[3]string{"Apply changes","Revert all","Unlink"}
        for action,action_index in ([3]Action{.Prefab_Apply,.Prefab_Revert,.Prefab_Unlink}) {
            rect,shown:=ui.widget_rect(ctx,shell_id(&g,"action",int(action)+1+64))
            testing.expect(t,shown && rect.w==22 && rect.h==ctx.theme.control)
            if action_row<0 {action_row=rect.y}
            testing.expect_value(t,rect.y,action_row)
            // The tip shows once the pointer rested on the button.
            for _ in 0..<int(ui.TOOLTIP_DELAY*60)+2 {
                ui.frame_begin(ctx,{size=size,pointer={rect.x+rect.w/2,rect.y+rect.h/2},dt=1.0/60})
                if ui.box(ctx,{width=ui.fixed(240),height=ui.FIT,gap=4,align_y=.Center}) {
                    identity_row(s,w,selection_active(&selection))
                }
                ui.frame_end(ctx)
            }
            testing.expect_value(t,ctx.tooltip,action_labels[action_index])
        }
        selected:=selection_active(&selection)
        first=api_entity(w,first_id)
        selection_set(&selection,{first})
        ui.frame_begin(ctx,{size=size,pointer_absent=true})
        if ui.box(ctx,{width=ui.fixed(240),height=ui.FIT,gap=4,align_y=.Center}) {identity_row(s,w,first)}
        ui.frame_end(ctx)
        // A member reverts only itself.
        _,revert:=ui.widget_rect(ctx,shell_id(&g,"action",int(Action.Prefab_Revert)+1+64))
        _,apply:=ui.widget_rect(ctx,shell_id(&g,"action",int(Action.Prefab_Apply)+1+64))
        _,unlink:=ui.widget_rect(ctx,shell_id(&g,"action",int(Action.Prefab_Unlink)+1+64))
        testing.expect(t,revert && !apply && !unlink)
        group=api_entity(w,group_id)
        selection_set(&selection,{group})
        ui.frame_begin(ctx,{size=size,pointer_absent=true})
        if ui.box(ctx,{width=ui.fixed(240),height=ui.FIT,direction=.Column}) {
            transform_rows(s,w)
        }
        ui.frame_end(ctx)
        for paint in ctx.paints[:ctx.paint_count] {testing.expect(t,paint.icon!=.Revert)}
        selection_set(&selection,{selected})
    }
    testing.expect(t,redo(&edits,w,&selection))
    prefabs_follow(s,&prefabs)
    group=api_entity(w,group_id)
    selection_set(&selection,{group})
    before=edits.cursor
    _,error=prefab_create(s,group,"single")
    testing.expect_value(t,error,Prefab_Error.None)
    testing.expect_value(t,edits.cursor,before+1)
    testing.expect(t,undo(&edits,w,&selection))
    prefabs_follow(s,&prefabs)
    testing.expect(t,!prefab_linked(s) && !os.exists(fmt.tprintf("%s/single.prefab",root)))
    testing.expect(t,redo(&edits,w,&selection))
    prefabs_follow(s,&prefabs)
    testing.expect(t,prefab_linked(s))
    file_open_path(s,"single.prefab")
    testing.expect_value(t,g.modal,Modal.None)
    testing.expect(t,.Open in s.requests)
    testing.expect_value(t,scene_open(s,"single.prefab"),Document_Error.None)
    prefabs_follow(s,&prefabs)
    group=api_entity(w,group_id)
    entity_rename(s,group,"Saved prefab")
    edits_commit(&edits,w,&selection)
    testing.expect_value(t,scene_save(s),Document_Error.None)
    saved:asset.Scene
    testing.expect_value(t,asset.scene_load(&saved,&assets.types,fmt.tprintf("%s/single.prefab",root)),asset.Error.None)
    defer asset.scene_destroy(&saved)
    testing.expect_value(t,saved.doc.kind,asset.KIND_PREFAB)
    testing.expect_value(t,saved.info.root,group_id)
    row,_:=asset.scene_entity_find(&saved,group_id)
    testing.expect_value(t,base.text_get(asset.scene_names(&saved)[row][:]),"Saved prefab")
    scene_new(s)
    // A prefab let go on the scene replaces the World between frames, after the render of the
    // frame it was let go in, which draws the World its fixed phase ran on.
    alive:=world.entities.alive
    s.requests={} // the Open above was run by hand
    placement_commit(s,w,Drag{kind=.Asset,asset_kind=asset.KIND_PREFAB,asset_id=id},Pick{},true)
    testing.expect_value(t,world.entities.alive,alive)
    testing.expect_value(t,s.requests,Requests{.Prefab_Place})
    requests_run(s)
    testing.expect(t,world.entities.alive>alive)
    testing.expect_value(t,len(selection.entities),1)
    if len(selection.entities)==1 {
        link,linked:=prefab_link_of(s,api_entity_id(w,selection.entities[0]))
        testing.expect(t,linked && link.root && link.asset==id)
    }
    scene_new(s)
    placed,place_error:=prefab_instantiate(s,id,{position={9,5,1},rotation={0,0.6,0,0.8},scale_multiplier={2,3,4}})
    testing.expect_value(t,place_error,Prefab_Error.None)
    prefabs_follow(s,&prefabs)
    testing.expect_value(t,len(document.previous.overrides),0)
    placed_entity:=api_entity(w,placed)
    placement:=entity_local(w,placed_entity)
    reverted,revert_error=prefab_revert(s,placed_entity,nil)
    testing.expect(t,revert_error==.None && reverted==0)
    testing.expect_value(t,entity_local(w,api_entity(w,placed)),placement)
    scene_new(s)
    plain:=entity_create(s,{name="Plain",transform={position={7,2,3},rotation=1,scale={2,3,4}}})
    core.world_settle(w)
    selection_set(&selection,{plain})
    edits_commit(&edits,w,&selection)
    c:=inspect_component(s,w,core.Transform,{plain})
    scale_offset:=int(offset_of(core.Transform,scale))
    testing.expect(t,inspect_changed(&c,scale_offset,12))
    inspect_reset(&c,scale_offset,12)
    edits_commit(&edits,w,&selection)
    testing.expect_value(t,entity_local(w,plain).position,[3]f32{7,2,3})
    testing.expect_value(t,entity_local(w,plain).scale,[3]f32{1,1,1})
    testing.expect(t,!inspect_changed(&c,scale_offset,12))
    testing.expect(t,undo(&edits,w,&selection))
    testing.expect_value(t,entity_local(w,plain).scale,[3]f32{2,3,4})
    viewport_init(&viewport)
    defer viewport_free(&viewport)
    viewport.size={1440,900}
    viewport.orbit.distance=37
    original_camera:=viewport.orbit
    original_cursor:=edits.cursor
    original_state:=edits_state(&edits)
    base.text_set(ai.prompt[:],"Scene draft")
    ai.prompt_length=len("Scene draft")
    ai.selected=7
    testing.expect_value(t,document_open_tab(s,"single.prefab"),Document_Error.None)
    defer documents_free(s)
    testing.expect_value(t,len(s.documents),2)
    testing.expect_value(t,s.active_document,1)
    testing.expect(t,document_is_prefab(s) && viewport.preview_sun)
    testing.expect_value(t,string(ai.prompt[:ai.prompt_length]),"Scene draft")
    testing.expect_value(t,ai.selected,7)
    prefab_world:=edited_world(s)
    root_entity:=document_root(s,prefab_world)
    testing.expect(t,root_entity!=core.NONE)
    entity_rename(s,root_entity,"Changed in tab")
    edits_commit(&edits,prefab_world,&selection)
    viewport.orbit.distance=9
    viewport.preview_sun=false
    prefab_cursor:=edits.cursor
    for size in ([2][2]f32{{1440,900},{800,420}}) {
        for _ in 0..<3 {
            ui.frame_begin(ctx,{size=size,pointer_absent=true})
            documents_build(s)
            frame:=ui.frame_end(ctx)
            testing.expect(t,!frame.overflow && ctx.stats.layout_errors==0)
        }
    }
    testing.expect(t,document_activate(s,0))
    testing.expect_value(t,s.edit_world,rawptr(&world))
    testing.expect_value(t,edits.cursor,original_cursor)
    testing.expect_value(t,edits_state(&edits),original_state)
    testing.expect_value(t,viewport.orbit,original_camera)
    testing.expect_value(t,selection_active(&selection),plain)
    testing.expect_value(t,string(ai.prompt[:ai.prompt_length]),"Scene draft")
    testing.expect_value(t,ai.selected,7)
    testing.expect_value(t,document_open_tab(s,"single.prefab"),Document_Error.None)
    testing.expect_value(t,len(s.documents),2)
    testing.expect_value(t,edits.cursor,prefab_cursor)
    testing.expect_value(t,string(ai.prompt[:ai.prompt_length]),"Scene draft")
    testing.expect_value(t,viewport.orbit.distance,f32(9))
    testing.expect(t,!viewport.preview_sun)
    testing.expect_value(t,entity_name(prefab_world,root_entity),"Changed in tab")
    testing.expect(t,undo(&edits,prefab_world,&selection))
    testing.expect_value(t,entity_name(prefab_world,root_entity),"Saved prefab")
    testing.expect(t,redo(&edits,prefab_world,&selection))
    child:=entity_create(s,{name="New child"})
    edits_commit(&edits,prefab_world,&selection)
    testing.expect_value(t,entity_parent(prefab_world,child),root_entity)
    entities_delete(s,{root_entity})
    core.world_settle(prefab_world)
    testing.expect(t,entity_alive(prefab_world,root_entity))
    testing.expect(t,!entity_reparent(s,root_entity,child))
    saved_tabs,kept:=documents_save_restart(s,root)
    testing.expect(t,kept && os.exists(saved_tabs))
    document_close(s,1)
    testing.expect_value(t,g.modal,Modal.Confirm)
    confirm_resolve(s,.Cancel)
    testing.expect_value(t,len(s.documents),2)
    document_activate(s,0)
    testing.expect_value(t,document_open_tab(s,"missing.prefab"),Document_Error.Not_Found)
    testing.expect_value(t,len(s.documents),2)
    testing.expect_value(t,s.active_document,0)
    // Restore uses fresh worlds after a process restart; keep the stack-owned fixture active on exit.
    document_activate(s,1)
    document_close_active(s)
    testing.expect_value(t,s.active_document,0)
    testing.expect_value(t,documents_restore(s,saved_tabs),"")
    testing.expect_value(t,len(s.documents),2)
    testing.expect_value(t,s.active_document,1)
    testing.expect(t,!viewport.preview_sun)
    testing.expect_value(t,viewport.orbit.distance,f32(9))
    testing.expect(t,document_dirty(s))
    document_activate(s,0)
    testing.expect_value(t,viewport.orbit,original_camera)
}

// A history longer than it keeps drops its oldest steps, not the document:
// the prefabs forget only the versions of the steps it dropped.
@(test)
prefabs_follow_a_history_that_drops_its_oldest_steps :: proc(t:^testing.T) {
    world:Prefab_Test_World
    core.entities_init(&world.entities)
    core.table_init(&world.ids,"Id")
    core.table_init(&world.names,"Name")
    core.table_init(&world.transforms,"Transform")
    core.table_init(&world.parents,"Parent")
    defer core.entities_destroy(&world.entities)
    defer core.table_destroy(&world.ids)
    defer core.table_destroy(&world.names)
    defer core.table_destroy(&world.transforms)
    defer core.table_destroy(&world.parents)
    defer core.value_free(&world.hierarchy,type_info_of(core.Hierarchy))
    tables:=[5]core.Table_Info{
        {name="Id",type=core.Id,info=type_info_of(core.Id),offset=offset_of(Prefab_Test_World,ids)},
        {name="Name",type=core.Name,info=type_info_of(core.Name),offset=offset_of(Prefab_Test_World,names)},
        {name="Transform",type=core.Transform,info=type_info_of(core.Transform),offset=offset_of(Prefab_Test_World,transforms)},
        {name="Parent",type=core.Parent,info=type_info_of(core.Parent),offset=offset_of(Prefab_Test_World,parents)},
        {name="Disabled",type=core.Disabled,info=type_info_of(core.Disabled),offset=offset_of(Prefab_Test_World,disabled)},
    }
    storages:=[2]core.Storage_Info{{type=Prefabs,place=.Editor},{type=core.Hierarchy,info=type_info_of(core.Hierarchy),offset=offset_of(Prefab_Test_World,hierarchy)}}
    info:=core.World_Info{tables=tables[:],storages=storages[:],clear=prefab_test_clear,copy=prefab_test_copy,swap=prefab_test_swap,
        sizes={.World=size_of(Prefab_Test_World),.Shared=0,.Editor=0},aligns={.World=align_of(Prefab_Test_World),.Shared=1,.Editor=1},
        init={.World=prefab_test_init,.Shared=nil,.Editor=nil},destroy={.World=prefab_test_destroy,.Shared=nil,.Editor=nil}}
    root:=project.path_absolute(fmt.tprintf(".mirai/test-prefabs-history-%d",os.get_pid()),context.temp_allocator)
    testing.expect(t,!os.exists(root))
    if os.exists(root) {return}
    os.make_directory_all(root)
    defer os.remove_all(root)
    assets:host.Assets
    asset.types_init(&assets.types)
    defer asset.types_destroy(&assets.types)
    asset.registry_init(&assets.registry,root)
    defer asset.registry_destroy(&assets.registry)
    app:=host.App{assets=&assets,info=&info,allocator=context.allocator}
    defer delete(app.worlds)
    viewport:Viewport
    selection:Selection
    inspector:Inspector
    edits:Edits
    document:Document
    prefabs:Prefabs
    ai:=new(Ai)
    defer free(ai)
    g:Editor_Ui
    outliner:Outliner
    s:=Session{info=&info,edit_world=&world,editor_world=&prefabs,assets_root=root,app=&app,gui=&g,viewport=&viewport,selection=&selection,inspector=&inspector,edits=&edits,document=&document,outliner=&outliner,ai=ai}
    defer delete(selection.entities)
    defer core.value_free(&inspector,type_info_of(Inspector))
    defer edits_free(&edits)
    defer document_previous_free(&document)
    defer prefabs_free(&s)
    w:=edited_world(&s)
    first:=entity_create(&s,{name="First",transform={position={2,0,0},rotation=1,scale={1,1,1}}})
    second:=entity_create(&s,{name="Second",transform={position={6,0,0},rotation=1,scale={1,1,1}}})
    core.world_settle(w)
    first_id,second_id:=api_entity_id(w,first),api_entity_id(w,second)
    edits_reset(&edits,w)
    prefabs_follow(&s,&prefabs)
    selection_set(&selection,{first,second})
    _,error:=prefab_create_entities(&s,selection.entities[:],"pair")
    if !testing.expect_value(t,error,Prefab_Error.None) {return}
    prefabs_follow(&s,&prefabs)
    versions,epoch:=len(prefabs.versions),edits.epoch
    first=api_entity(w,first_id)
    testing.expect(t,versions>0)
    for i in 0..<EDITS_STEP_CAPACITY+1 {
        transform_set(&s,first,core.to_math(core.Transform{{f32(i),0,0},1,{1,1,1}}))
        edits_commit(&edits,w,&selection)
        prefabs_follow(&s,&prefabs)
    }
    testing.expect_value(t,edits.stats.discarded,u64(2))
    testing.expect_value(t,edits.epoch,epoch)
    testing.expect_value(t,prefabs.epoch,epoch)
    testing.expect_value(t,len(prefabs.versions),versions-1)
    testing.expect(t,s.document.previous!=nil && len(s.document.previous.instances)==1)
}

@(test)
prefab_root_placement_is_not_an_override :: proc(t:^testing.T) {
    types:asset.Types
    asset.types_init(&types)
    defer asset.types_destroy(&types)
    prefab:asset.Scene
    testing.expect_value(t,asset.scene_init(&prefab,&types,asset.KIND_PREFAB,{1,2}),asset.Error.None)
    defer asset.scene_destroy(&prefab)
    asset.scene_entity_add(&prefab,1,0,"Root")
    asset.scene_entity_add(&prefab,2,1,"Child")
    prefab.info.root=1
    source:=core.Transform{{1,2,3},quaternion(x=0,y=0,z=0.6,w=0.8),{0.5,0.5,0.5}}
    child_source:=core.TRANSFORM_IDENTITY
    asset.scene_set(&prefab,1,"Transform",&source)
    asset.scene_set(&prefab,2,"Transform",&child_source)
    cap:asset.Scene
    testing.expect_value(t,asset.scene_init(&cap,&types,asset.KIND_SCENE,{3,4}),asset.Error.None)
    defer asset.scene_destroy(&cap)
    instance,root,instance_error:=asset.scene_instantiate(&cap,&prefab,prefab.doc.id,0)
    testing.expect_value(t,instance_error,asset.Error.None)
    child:base.Entity_Id
    for member in cap.members {if member.instance==instance && member.source==2 {child=member.entity}}
    placement:=core.Transform{{7,8,9},quaternion(x=0,y=0.6,z=0,w=0.8),{2,3,4}}
    asset.scene_set(&cap,root,"Transform",&placement)
    transform_hash:=base.name_hash("Transform")
    for field in ([]string{"position","rotation","scale"}) {
        asset.scene_override_add(&cap,root,transform_hash,field)
    }
    hashes:=make(map[u64]string,context.temp_allocator)
    hashes[transform_hash]="Transform"
    selected,selection_error:=prefab_overrides_select(&cap,instance,root,nil,hashes)
    testing.expect(t,selection_error==.None && len(selected)==0)
    _,selection_error=prefab_overrides_select(&cap,instance,root,{"Transform.scale"},hashes)
    testing.expect_value(t,selection_error,Prefab_Error.Unknown_Path)
    // The placement is the instance's without overrides that name it.
    clear(&cap.overrides)
    child_placement:=core.Transform{{3,2,1},quaternion(x=0.6,y=0,z=0,w=0.8),{4,3,2}}
    asset.scene_set(&cap,child,"Transform",&child_placement)
    for field in ([]string{"position","rotation","scale"}) {
        asset.scene_override_add(&cap,child,transform_hash,field)
    }
    source.position={5,6,7};source.rotation=1;source.scale={9,8,7}
    asset.scene_set(&prefab,1,"Transform",&source)
    testing.expect_value(t,asset.scene_instance_update(&cap,instance,&prefab),asset.Error.None)
    actual,_:=asset.scene_get(&cap,root,"Transform",core.Transform)
    testing.expect_value(t,actual,placement)
    actual,_=asset.scene_get(&cap,child,"Transform",core.Transform)
    testing.expect_value(t,actual,child_placement)
    taken,take_error:=prefab_overrides_take(&cap,instance,child,nil,hashes)
    testing.expect(t,take_error==.None && len(taken)==3)
    prefab_overrides_drop(&cap,taken)
    testing.expect_value(t,len(cap.overrides),0)
    testing.expect_value(t,asset.scene_instance_update(&cap,instance,&prefab),asset.Error.None)
    actual,_=asset.scene_get(&cap,root,"Transform",core.Transform)
    testing.expect_value(t,actual,placement)
    actual,_=asset.scene_get(&cap,child,"Transform",core.Transform)
    testing.expect_value(t,actual,child_source)
}

// A session over Prefab_Test_World with an assets folder of its own. It
// stays where prefab_fixture_init found it.
@(private)
Prefab_Fixture :: struct {
    world:Prefab_Test_World,
    tables:[7]core.Table_Info,
    storages:[4]core.Storage_Info,
    info:core.World_Info,
    assets:host.Assets,
    app:host.App,
    viewport:Viewport,
    selection:Selection,
    inspector:Inspector,
    edits:Edits,
    document:Document,
    using editor:Prefab_Fixture_Editor,
    outliner:Outliner,
    g:Editor_Ui,
    ai:Ai,
    root:string,
    s:Session,
}

@(private)
prefab_fixture_init :: proc(f:^Prefab_Fixture,name:string) -> bool {
    f.tables={
        {name="Id",type=core.Id,info=type_info_of(core.Id),offset=offset_of(Prefab_Test_World,ids)},
        {name="Name",type=core.Name,info=type_info_of(core.Name),offset=offset_of(Prefab_Test_World,names)},
        {name="Transform",type=core.Transform,info=type_info_of(core.Transform),offset=offset_of(Prefab_Test_World,transforms)},
        {name="Parent",type=core.Parent,info=type_info_of(core.Parent),offset=offset_of(Prefab_Test_World,parents)},
        {name="Disabled",type=core.Disabled,info=type_info_of(core.Disabled),offset=offset_of(Prefab_Test_World,disabled)},
        {name="Prefab_Test_Lamp",type=Prefab_Test_Lamp,info=type_info_of(Prefab_Test_Lamp),offset=offset_of(Prefab_Test_World,lamps)},
        {name="Point_Light",type=erender.Point_Light,info=type_info_of(erender.Point_Light),offset=offset_of(Prefab_Test_World,point_lights)},
    }
    f.storages={{type=Prefabs,place=.Editor,offset=offset_of(Prefab_Fixture_Editor,prefabs)},{type=core.Hierarchy,info=type_info_of(core.Hierarchy),offset=offset_of(Prefab_Test_World,hierarchy)},
        {type=Collab,place=.Editor,offset=offset_of(Prefab_Fixture_Editor,collab)},{name="Api",type=Api,info=type_info_of(Api),place=.Editor,offset=offset_of(Prefab_Fixture_Editor,api)}}
    f.info=core.World_Info{tables=f.tables[:],storages=f.storages[:],clear=prefab_test_clear,copy=prefab_test_copy,swap=prefab_test_swap,
        sizes={.World=size_of(Prefab_Test_World),.Shared=0,.Editor=0},aligns={.World=align_of(Prefab_Test_World),.Shared=1,.Editor=1},
        init={.World=prefab_test_init,.Shared=nil,.Editor=nil},destroy={.World=prefab_test_destroy,.Shared=nil,.Editor=nil}}
    prefab_test_init(&f.world,context.allocator)
    f.root=project.path_absolute(fmt.tprintf(".mirai/test-prefabs-%s-%d",name,os.get_pid()))
    os.remove_all(f.root)
    if os.make_directory_all(f.root)!=nil {return false}
    asset.types_init(&f.assets.types)
    asset.registry_init(&f.assets.registry,f.root)
    f.app=host.App{assets=&f.assets,info=&f.info,allocator=context.allocator}
    f.s=Session{info=&f.info,edit_world=&f.world,editor_world=&f.editor,assets_root=f.root,app=&f.app,gui=&f.g,viewport=&f.viewport,selection=&f.selection,inspector=&f.inspector,edits=&f.edits,document=&f.document,outliner=&f.outliner,ai=&f.ai}
    return true
}

@(private)
prefab_fixture_destroy :: proc(f:^Prefab_Fixture) {
    prefabs_free(&f.s)
    document_previous_free(&f.document)
    edits_free(&f.edits)
    core.value_free(&f.inspector,type_info_of(Inspector))
    delete(f.selection.entities)
    delete(f.app.worlds)
    asset.registry_destroy(&f.assets.registry)
    asset.types_destroy(&f.assets.types)
    prefab_test_destroy(&f.world)
    os.remove_all(f.root)
    delete(f.root)
}

@(private)
Prefab_Fixture_Editor :: struct {prefabs:Prefabs,collab:Collab,api:Api}

// Commits what was edited, as the end of a frame does, and follows it as the next frame does.
@(private)
prefab_fixture_step :: proc(f:^Prefab_Fixture) {
    edits_commit(&f.edits,edited_world(&f.s),&f.selection)
    prefabs_follow(&f.s,&f.prefabs)
}

@(private="file")
prefab_fixture_find :: proc(f:^Prefab_Fixture,id:base.Entity_Id) -> core.Entity {
    return api_entity(edited_world(&f.s),id)
}

// The overrides of a kind, of the instances placed in the document.
@(private="file")
prefab_fixture_kind :: proc(f:^Prefab_Fixture,kind:asset.Override_Kind) -> (found:[dynamic]asset.Override) {
    found=make([dynamic]asset.Override,context.temp_allocator)
    for override in f.document.previous.overrides {
        if override.kind==kind {append(&found,override)}
    }
    return
}

// The editors of a shared session, each over its own copy of the assets.
@(private="file")
prefab_collab_join :: proc(f:^Prefab_Fixture,role:Collab_Role) {
    w:=edited_world(&f.s)
    core.world_settle(w)
    edits_reset(&f.edits,w)
    // A guest takes the scene of the host between frames: its prefabs follow
    // that history only from the next frame or operation.
    if role==.Host {prefabs_follow(&f.s,&f.prefabs)}
    st:=new(Collab_State)
    st.role,st.phase,st.self=role,.Joined,role==.Host?0:1
    st.peers[role==.Host?1:0].used=true
    st.peers[1].joined=true
    collab_tables_build(&f.s,st)
    collab_journal_reset(&f.s,st)
    f.collab.state=st
}

@(private="file")
prefab_collab_leave :: proc(f:^Prefab_Fixture) {
    st:=f.collab.state
    for &peer in st.peers {
        for message in peer.out {delete(message)}
        delete(peer.out);delete(peer.file_bytes);delete(peer.prefab_bytes)
    }
    for payload in st.prefabs_out {delete(payload)}
    delete(st.prefabs_out)
    collab_tables_free(st)
    journal_reading(&f.edits,false)
    free(st)
    f.collab.state=nil
}

// An update of the session at one end, and what it queued for its peer
// arriving at the other in order.
@(private="file")
prefab_collab_send :: proc(f,to:^Prefab_Fixture) {
    st:=f.collab.state
    collab_edits_send(&f.s,st)
    collab_prefabs_send(&f.s,st)
    peer:=&st.peers[st.role==.Host?1:0]
    for message in peer.out {
        collab_receive(&to.s,to.collab.state,st.role==.Host?-1:1,message,0)
        delete(message)
    }
    clear(&peer.out)
}

@(private="file")
prefab_collab_instances :: proc(f:^Prefab_Fixture) -> int {
    return f.document.previous==nil?0:len(f.document.previous.instances)
}

// Creating a prefab in the host, unlinking it in a guest and undoing that
// there change the prefab records of the other, in the order of the host.
@(test)
prefab_records_of_one_editor_reach_the_others_in_the_order_of_the_host :: proc(t:^testing.T) {
    host:=new(Prefab_Fixture);defer free(host)
    if !testing.expect(t,prefab_fixture_init(host,"collab-host")) {return}
    defer prefab_fixture_destroy(host)
    guest:=new(Prefab_Fixture);defer free(guest)
    if !testing.expect(t,prefab_fixture_init(guest,"collab-guest")) {return}
    defer prefab_fixture_destroy(guest)
    prefab_collab_join(host,.Host)
    defer prefab_collab_leave(host)
    prefab_collab_join(guest,.Guest)
    defer prefab_collab_leave(guest)

    root:=entity_create(&host.s,{name="Root",named=true})
    entity_create(&host.s,{name="Child",named=true,parent=root})
    prefab_fixture_step(host)
    root_id:=api_entity_id(edited_world(&host.s),root)
    prefab_collab_send(host,guest)
    testing.expect(t,prefab_fixture_find(guest,root_id)!=core.NONE)

    _,created:=prefab_create(&host.s,root,"group")
    if !testing.expect_value(t,created,Prefab_Error.None) {return}
    prefab_fixture_step(host)
    prefab_collab_send(host,guest)
    testing.expect(t,prefab_fixture_find(guest,root_id)!=core.NONE,"the root made again under its Id stays")
    if !testing.expect_value(t,prefab_collab_instances(guest),1) {return}
    testing.expect_value(t,guest.document.previous.instances[0],host.document.previous.instances[0])
    testing.expect_value(t,len(guest.document.previous.members),len(host.document.previous.members))
    testing.expect(t,os.exists(fmt.tprintf("%s/group.prefab",guest.root)),"the file of the prefab comes with its records")
    testing.expect(t,prefab_base_find(&guest.prefabs,host.document.previous.instances[0].prefab)!=nil)
    testing.expect_value(t,len(guest.document.previous.overrides),0)

    // The host applies what a guest did and sends it back to it.
    testing.expect_value(t,prefab_unlink(&guest.s,prefab_fixture_find(guest,root_id),false),Prefab_Error.None)
    prefab_fixture_step(guest)
    prefab_collab_send(guest,host)
    testing.expect_value(t,prefab_collab_instances(host),0)
    prefab_collab_send(host,guest)
    testing.expect_value(t,prefab_collab_instances(guest),0)

    // An undo moves the records back across the step, here and there.
    move:=history_undo(&guest.s)
    testing.expect(t,move.done && move.error=="",move.error)
    prefabs_sync(&guest.s,&guest.prefabs)
    testing.expect_value(t,prefab_collab_instances(guest),1)
    prefab_fixture_step(guest)
    testing.expect_value(t,prefab_collab_instances(guest),1)
    prefab_collab_send(guest,host)
    testing.expect_value(t,prefab_collab_instances(host),1)
    testing.expect_value(t,len(host.document.previous.members),len(guest.document.previous.members))
    prefab_collab_send(host,guest)
    testing.expect_value(t,prefab_collab_instances(guest),1)

    // The same by the API, undone before the host sent the unlink back.
    guest.edits.author=EDIT_AUTHOR_API
    testing.expect_value(t,prefab_unlink(&guest.s,prefab_fixture_find(guest,root_id),false),Prefab_Error.None)
    prefab_collab_send(guest,host)
    testing.expect_value(t,prefab_collab_instances(host),0)
    move=history_undo(&guest.s)
    testing.expect(t,move.done && move.error=="",move.error)
    prefabs_sync(&guest.s,&guest.prefabs)
    guest.edits.author=EDIT_AUTHOR_USER
    prefab_collab_send(host,guest)
    prefab_fixture_step(guest)
    prefab_collab_send(guest,host)
    prefab_collab_send(host,guest)
    testing.expect_value(t,prefab_collab_instances(guest),1)
    testing.expect_value(t,prefab_collab_instances(host),1)
}

@(test)
prefab_observation_from_the_world_never_marks_the_root_placement :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    if !testing.expect(t,prefab_fixture_init(f,"placement")) {return}
    defer prefab_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    root:=entity_create(s,{name="Root",named=true,transform={position={1,2,3},rotation=1,scale={1,1,1}}})
    child:=entity_create(s,{name="Child",named=true,parent=root})
    core.world_settle(w)
    edits_reset(&f.edits,w)
    prefabs_follow(s,&f.prefabs)
    root_id,child_id:=api_entity_id(w,root),api_entity_id(w,child)
    _,created:=prefab_create(s,root,"placed")
    if !testing.expect_value(t,created,Prefab_Error.None) {return}
    prefabs_follow(s,&f.prefabs)
    root=prefab_fixture_find(f,root_id)
    transform_set(s,root,core.to_math(core.Transform{{7,8,9},quaternion(x=0,y=0.6,z=0,w=0.8),{2,3,4}}))
    prefab_fixture_step(f)
    testing.expect_value(t,len(f.document.previous.overrides),0)
    // A record that names it is dropped by the next observation, also without a base.
    instance:=f.document.previous.instances[0].id
    append(&f.document.previous.overrides,prefab_override_make(instance,root_id,base.name_hash("Transform"),.Field,"position"))
    f.prefabs.observed=false
    testing.expect_value(t,prefab_observe(s),Prefab_Error.None)
    testing.expect_value(t,len(f.document.previous.overrides),0)
    child=prefab_fixture_find(f,child_id)
    transform_set(s,child,core.to_math(core.Transform{{3,2,1},1,{1,1,1}}))
    prefab_fixture_step(f)
    testing.expect(t,len(f.document.previous.overrides)>=1)
    for &override in f.document.previous.overrides {testing.expect(t,override.entity==child_id && !prefab_placement(&override,root_id))}
}

@(test)
prefab_instances_add_entities_and_turn_members_off_through_updates_apply_and_revert :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    if !testing.expect(t,prefab_fixture_init(f,"places")) {return}
    defer prefab_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    // Root with A (holding C) and B.
    root:=entity_create(s,{name="Root",named=true})
    a:=entity_create(s,{name="A",named=true,parent=root})
    b:=entity_create(s,{name="B",named=true,parent=root})
    c:=entity_create(s,{name="C",named=true,parent=a})
    core.world_settle(w)
    edits_reset(&f.edits,w)
    prefabs_follow(s,&f.prefabs)
    root_id,a_id,b_id,c_id:=api_entity_id(w,root),api_entity_id(w,a),api_entity_id(w,b),api_entity_id(w,c)
    id,created:=prefab_create(s,root,"places")
    if !testing.expect_value(t,created,Prefab_Error.None) {return}
    prefabs_follow(s,&f.prefabs)
    file:=fmt.tprintf("%s/places.prefab",f.root)
    testing.expect_value(t,len(f.document.previous.overrides),0)
    disabled:=u64(0)
    for table in s.info.tables {
        if table.type==core.Disabled {disabled=base.name_hash(table.name)}
    }

    // Members keep the place of the prefab and are turned off instead of deleted; entities go under them.
    a,b,c=prefab_fixture_find(f,a_id),prefab_fixture_find(f,b_id),prefab_fixture_find(f,c_id)
    testing.expect(t,!entity_reparent(s,c,root) && !entity_reparent(s,c,core.NONE))
    entities_delete(s,{b})
    testing.expect(t,prefab_fixture_find(f,b_id)!=core.NONE)
    added:=entity_create(s,{name="Added",named=true,parent=a})
    prefab_fixture_step(f)
    added_id:=api_entity_id(w,added)
    entity_enabled_set(s,prefab_fixture_find(f,b_id),false)
    prefab_fixture_step(f)
    children:=prefab_fixture_kind(f,.Child)
    off:=prefab_fixture_kind(f,.Added)
    testing.expect(t,len(children)==1 && children[0].entity==added_id)
    testing.expect(t,len(off)==1 && off[0].entity==b_id && off[0].component==disabled)
    testing.expect_value(t,len(f.document.previous.overrides),2)

    // A step that changes one value looks again at that member alone.
    transform_set(s,prefab_fixture_find(f,c_id),core.to_math(core.Transform{{0,4,0},1,{1,1,1}}))
    edits_commit(&f.edits,w,&f.selection)
    touched,whole:=prefab_touched(s,&f.prefabs)
    testing.expect(t,!whole && !touched.places && len(touched.ids)==1 && c_id in touched.ids)
    prefabs_follow(s,&f.prefabs)
    total:=len(f.document.previous.overrides)
    testing.expect(t,total>2 && len(prefab_fixture_kind(f,.Field))==total-2)
    for override in prefab_fixture_kind(f,.Field) {testing.expect_value(t,override.entity,c_id)}
    // Undoing the steps forgets what they marked; redoing them marks it again.
    for _ in 0..<3 {
        testing.expect(t,undo(&f.edits,w,&f.selection))
        prefabs_follow(s,&f.prefabs)
    }
    testing.expect_value(t,len(f.document.previous.overrides),0)
    for _ in 0..<3 {
        testing.expect(t,redo(&f.edits,w,&f.selection))
        prefabs_follow(s,&f.prefabs)
    }
    testing.expect_value(t,len(f.document.previous.overrides),total)

    // The prefab changes on disk: what the instance holds survives the refresh.
    edited:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&edited,&f.assets.types,file),asset.Error.None) {return}
    asset.scene_entity_rename(&edited,a_id,"A v2")
    asset.scene_entity_add(&edited,0x77,b_id,"Under B")
    identity:=core.TRANSFORM_IDENTITY
    asset.scene_set(&edited,0x77,"Transform",&identity)
    testing.expect_value(t,asset.scene_save(&edited,file),asset.Error.None)
    asset.scene_destroy(&edited)
    _=asset.registry_scan(&f.assets.registry)
    listed:=prefab_instances(s)
    testing.expect(t,len(listed)==1 && listed[0].stale)
    _,refreshed:=prefab_refresh(s,id)
    testing.expect_value(t,refreshed,Prefab_Error.None)
    prefabs_follow(s,&f.prefabs)
    a,b,added=prefab_fixture_find(f,a_id),prefab_fixture_find(f,b_id),prefab_fixture_find(f,added_id)
    testing.expect_value(t,entity_name(w,a),"A v2")
    testing.expect(t,added!=core.NONE && entity_parent(w,added)==a)
    testing.expect(t,b!=core.NONE && entity_has(w,b,core.Disabled))
    under_b:=core.NONE
    for child in entity_children(w,b) {if entity_name(w,child)=="Under B" {under_b=child}}
    testing.expect(t,under_b!=core.NONE)
    testing.expect(t,len(prefab_fixture_kind(f,.Child))==1 && len(prefab_fixture_kind(f,.Added))==1)

    // Revert, one at a time: the entity added goes, and the member turned off comes back on.
    count,reverted:=prefab_revert(s,added,nil)
    testing.expect(t,reverted==.None && count==1 && prefab_fixture_find(f,added_id)==core.NONE)
    count,reverted=prefab_revert(s,prefab_fixture_find(f,b_id),{"Disabled"})
    testing.expect(t,reverted==.None && count==1)
    testing.expect(t,!entity_has(w,prefab_fixture_find(f,b_id),core.Disabled))
    prefabs_follow(s,&f.prefabs)
    testing.expect_value(t,len(f.document.previous.overrides),total-2) // C keeps its position
    for _ in 0..<2 {
        testing.expect(t,undo(&f.edits,w,&f.selection))
        prefabs_follow(s,&f.prefabs)
    }
    testing.expect_value(t,len(f.document.previous.overrides),total)

    // Apply all: the prefab takes the entity added and B off, and the instance holds nothing of its own.
    applied_count,applied:=prefab_apply(s,prefab_fixture_find(f,root_id),nil,true)
    testing.expectf(t,applied==.None && applied_count==total,"apply: %v %d of %d",applied,applied_count,total)
    prefabs_follow(s,&f.prefabs)
    testing.expect_value(t,len(f.document.previous.overrides),0)
    testing.expect(t,prefab_fixture_find(f,added_id)!=core.NONE)
    _,still_added:=prefab_link_of(s,added_id)
    testing.expect(t,still_added)
    loaded,found:=prefab_scene_load(s,id)
    if !testing.expect(t,found) {return}
    defer prefab_scene_free(loaded)
    table,has_disabled:=asset.scene_component_by_hash(loaded,disabled)
    if testing.expect(t,has_disabled) {
        _,b_off:=asset.scene_component_get(loaded,table,b_id)
        testing.expect(t,b_off)
    }
    added_found:=false
    for row in 0..<asset.scene_entity_count(loaded) {
        record:=asset.scene_entity(loaded,row)
        if record.name=="Added" {added_found=record.parent==a_id}
    }
    testing.expect(t,added_found)
}

// An undo in order that a step of another author leaves taken back, with no
// observation between them, is observed: what the undo took away is no longer
// an override.
@(test)
prefab_overrides_follow_an_undo_another_author_leaves_taken_back :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    if !testing.expect(t,prefab_fixture_init(f,"taken-back")) {return}
    defer prefab_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    root:=entity_create(s,{name="Root",named=true})
    a:=entity_create(s,{name="A",named=true,parent=root})
    core.world_settle(w)
    edits_reset(&f.edits,w)
    prefabs_follow(s,&f.prefabs)
    a_id:=api_entity_id(w,a)
    _,created:=prefab_create(s,root,"taken-back")
    if !testing.expect_value(t,created,Prefab_Error.None) {return}
    prefabs_follow(s,&f.prefabs)

    // An agent moves A; the user, later, adds an entity outside the instance.
    f.edits.author=EDIT_AUTHOR_API
    transform_set(s,prefab_fixture_find(f,a_id),core.to_math(core.Transform{{0,4,0},1,{1,1,1}}))
    prefab_fixture_step(f)
    testing.expect(t,len(prefab_fixture_kind(f,.Field))>0)
    testing.expect(t,undo(&f.edits,w,&f.selection))
    f.edits.author=EDIT_AUTHOR_USER
    entity_create(s,{name="Elsewhere",named=true})
    prefab_fixture_step(f)
    testing.expect_value(t,len(prefab_fixture_kind(f,.Field)),0)
}

// A variant is a prefab whose root is an instance of its base: it follows the
// base, keeps what it changes, takes what its instances apply and passes it
// on to the base when asked.
@(test)
prefab_variants_follow_their_base_and_apply_to_it :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    if !testing.expect(t,prefab_fixture_init(f,"variants")) {return}
    defer prefab_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    root:=entity_create(s,{name="Crate",named=true})
    lid:=entity_create(s,{name="Lid",named=true,parent=root})
    core.world_settle(w)
    edits_reset(&f.edits,w)
    prefabs_follow(s,&f.prefabs)
    root_id,lid_id:=api_entity_id(w,root),api_entity_id(w,lid)
    crate,created:=prefab_create(s,root,"crate")
    if !testing.expect_value(t,created,Prefab_Error.None) {return}
    prefabs_follow(s,&f.prefabs)
    transform:=base.name_hash("Transform")

    // Its root is an instance of the base; undo and redo take its file away and back.
    path:=prefab_variant_path(s,crate)
    testing.expect_value(t,path,"crate_variant")
    variant,made:=prefab_variant_create(s,crate,path)
    if !testing.expect_value(t,made,Prefab_Error.None) {return}
    prefabs_follow(s,&f.prefabs)
    file:=fmt.tprintf("%s/crate_variant.prefab",f.root)
    testing.expect(t,os.exists(file))
    testing.expect_value(t,prefab_variant_path(s,crate),"crate_variant_2")
    _,taken:=prefab_variant_create(s,crate,path)
    testing.expect_value(t,taken,Prefab_Error.Exists)
    chain:=prefab_variant_chain(s,variant)
    testing.expect(t,len(chain)==1 && chain[0]==crate)
    testing.expect_value(t,len(prefab_variant_chain(s,crate)),0)
    if loaded,found:=prefab_scene_load(s,variant);testing.expect(t,found) {
        based,base_id:=asset.prefab_variant_base(loaded)
        testing.expect(t,based!=0 && base_id==crate && len(loaded.overrides)==0)
        prefab_scene_free(loaded)
    }
    testing.expect(t,undo(&f.edits,w,&f.selection))
    prefabs_follow(s,&f.prefabs)
    testing.expect(t,!os.exists(file))
    testing.expect(t,redo(&f.edits,w,&f.selection))
    prefabs_follow(s,&f.prefabs)
    testing.expect(t,os.exists(file))

    // An instance of the variant applies to the variant, which keeps the change as an override of its base.
    placed,placed_error:=prefab_instantiate(s,variant,{position={5,0,0}})
    if !testing.expect_value(t,placed_error,Prefab_Error.None) {return}
    prefabs_follow(s,&f.prefabs)
    placed_lid:=core.NONE
    for child in entity_children(w,prefab_fixture_find(f,placed)) {if entity_name(w,child)=="Lid" {placed_lid=child}}
    if !testing.expect(t,placed_lid!=core.NONE) {return}
    placed_lid_id:=api_entity_id(w,placed_lid)
    link,linked:=prefab_link_of(s,placed)
    testing.expect(t,linked && link.root && link.asset==variant)
    testing.expect_value(t,prefab_variant_of(s,link,placed),crate)
    testing.expect_value(t,inspector_variant_name(s,w,prefab_fixture_find(f,placed)),"crate")
    lid_link,_:=prefab_link_of(s,placed_lid_id)
    selection_set(&f.selection,{prefab_fixture_find(f,placed)})
    testing.expect(t,prefab_action_disabled(s,.Prefab_Apply_Base))
    raised:=[3]f32{0,3,0}
    transform_set(s,placed_lid,core.to_math(core.Transform{raised,1,{1,1,1}}))
    prefab_fixture_step(f)
    testing.expect(t,!prefab_action_disabled(s,.Prefab_Apply_Base))
    _,applied:=prefab_apply(s,prefab_fixture_find(f,placed_lid_id),nil)
    testing.expect_value(t,applied,Prefab_Error.None)
    prefabs_follow(s,&f.prefabs)
    for override in f.document.previous.overrides {testing.expect(t,override.instance!=link.instance)}
    if loaded,found:=prefab_scene_load(s,variant);testing.expect(t,found) {
        moved,_:=asset.scene_get(loaded,lid_link.source,"Transform",core.Transform)
        testing.expect_value(t,moved.position,raised)
        kept:=false
        for override in loaded.overrides {kept||=override.entity==lid_link.source && override.component==transform}
        testing.expect(t,kept)
        prefab_scene_free(loaded)
    }
    if loaded,found:=prefab_scene_load(s,crate);testing.expect(t,found) {
        still,_:=asset.scene_get(loaded,lid_id,"Transform",core.Transform)
        testing.expect_value(t,still.position,([3]f32{0,0,0}))
        prefab_scene_free(loaded)
    }

    // The base changes on disk: the instance of the variant follows it and keeps the variant's change.
    crate_file:=fmt.tprintf("%s/crate.prefab",f.root)
    edited:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&edited,&f.assets.types,crate_file),asset.Error.None) {return}
    asset.scene_entity_rename(&edited,lid_id,"Lid v2")
    testing.expect_value(t,asset.scene_save(&edited,crate_file),asset.Error.None)
    asset.scene_destroy(&edited)
    _=asset.registry_scan(&f.assets.registry)
    _,refreshed:=prefab_refresh(s,{})
    testing.expect_value(t,refreshed,Prefab_Error.None)
    prefabs_follow(s,&f.prefabs)
    placed_lid=prefab_fixture_find(f,placed_lid_id)
    testing.expect_value(t,entity_name(w,placed_lid),"Lid v2")
    testing.expect_value(t,entity_local(w,placed_lid).position,raised)
    testing.expect_value(t,entity_name(w,prefab_fixture_find(f,lid_id)),"Lid v2")

    // Apply to base: the name goes through the variant into the base, and the variant keeps its own change.
    entity_rename(s,placed_lid,"Lid v3")
    prefab_fixture_step(f)
    count,to_base:=prefab_apply(s,prefab_fixture_find(f,placed),nil,true,.Base)
    testing.expect(t,to_base==.None && count==1)
    prefabs_follow(s,&f.prefabs)
    testing.expect_value(t,entity_name(w,prefab_fixture_find(f,lid_id)),"Lid v3")
    placed_lid=prefab_fixture_find(f,placed_lid_id)
    testing.expect_value(t,entity_name(w,placed_lid),"Lid v3")
    testing.expect_value(t,entity_local(w,placed_lid).position,raised)
    if loaded,found:=prefab_scene_load(s,crate);testing.expect(t,found) {
        row,_:=asset.scene_entity_find(loaded,lid_id)
        testing.expect_value(t,asset.scene_entity(loaded,row).name,"Lid v3")
        prefab_scene_free(loaded)
    }
    if loaded,found:=prefab_scene_load(s,variant);testing.expect(t,found) {
        kept,named:=false,false
        for override in loaded.overrides {
            kept||=override.entity==lid_link.source && override.component==transform
            named||=override.component==0
        }
        testing.expect(t,kept && !named)
        prefab_scene_free(loaded)
    }
    _,not_variant:=prefab_apply(s,prefab_fixture_find(f,root_id),nil,true,.Base)
    testing.expect_value(t,not_variant,Prefab_Error.Not_Variant)
    testing.expect(t,undo(&f.edits,w,&f.selection))
    prefabs_follow(s,&f.prefabs)
    if loaded,found:=prefab_scene_load(s,crate);testing.expect(t,found) {
        row,_:=asset.scene_entity_find(loaded,lid_id)
        testing.expect_value(t,asset.scene_entity(loaded,row).name,"Lid v2")
        prefab_scene_free(loaded)
    }
}

// A prefab file written before its component gained a field: the field is no override of an instance until
// the instance changes it, and applying it writes the component with every field, those the instance did not
// change with the value loading gave them.
@(test)
prefab_apply_writes_fields_the_file_of_the_prefab_did_not_have :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    if !testing.expect(t,prefab_fixture_init(f,"old-fields")) {return}
    defer prefab_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    lamps:=&f.tables[5]
    lamps.default=proc(dst:rawptr) {(^Prefab_Test_Lamp)(dst)^={intensity=1,range=10}}
    Lamp_Without_Range :: struct {intensity:f32}
    old:asset.Scene
    if !testing.expect_value(t,asset.scene_init(&old,&f.assets.types,asset.KIND_PREFAB,{1,2}),asset.Error.None) {return}
    lamp_id,bulb_id:=base.Entity_Id(0x11),base.Entity_Id(0x12)
    asset.scene_entity_add(&old,lamp_id,0,"Lamp")
    asset.scene_entity_add(&old,bulb_id,lamp_id,"Bulb")
    old.info.root=lamp_id
    for id in ([]base.Entity_Id{lamp_id,bulb_id}) {
        identity:=core.TRANSFORM_IDENTITY
        without:=Lamp_Without_Range{intensity=3}
        asset.scene_set(&old,id,"Transform",&identity)
        asset.scene_set(&old,id,"Prefab_Test_Lamp",&without)
    }
    file:=fmt.tprintf("%s/lamp.prefab",f.root)
    saved:=asset.scene_save(&old,file)
    asset.scene_destroy(&old)
    if !testing.expect_value(t,saved,asset.Error.None) {return}
    core.world_settle(w)
    edits_reset(&f.edits,w)
    prefabs_follow(s,&f.prefabs)
    id,problem:=asset_resolve(s,"lamp",".prefab")
    if !testing.expect_value(t,problem,"") {return}
    placed,placed_error:=prefab_instantiate(s,id,{})
    if !testing.expect_value(t,placed_error,Prefab_Error.None) {return}
    prefabs_follow(s,&f.prefabs)
    testing.expect_value(t,len(f.document.previous.overrides),0)

    reach:=f32(25)
    testing.expect(t,field_write(s,lamps,{prefab_fixture_find(f,placed)},int(offset_of(Prefab_Test_Lamp,range)),mem.ptr_to_bytes(&reach)))
    prefab_fixture_step(f)
    count,applied:=prefab_apply(s,prefab_fixture_find(f,placed),{"Prefab_Test_Lamp.range"})
    testing.expectf(t,applied==.None && count==1,"apply: %v, %d applied",applied,count)
    written:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&written,&f.assets.types,file),asset.Error.None) {return}
    defer asset.scene_destroy(&written)
    lamp,_:=asset.scene_get(&written,lamp_id,"Prefab_Test_Lamp",Prefab_Test_Lamp)
    bulb,_:=asset.scene_get(&written,bulb_id,"Prefab_Test_Lamp",Prefab_Test_Lamp)
    testing.expect_value(t,lamp,Prefab_Test_Lamp{intensity=3,range=25})
    testing.expect_value(t,bulb,Prefab_Test_Lamp{intensity=3,range=10})
}

// Whether the records of the document name only what the World has, and how many instances they hold.
@(private="file")
prefab_fixture_records_follow_the_world :: proc(t:^testing.T,f:^Prefab_Fixture,instances:int,loc:=#caller_location) -> bool {
    previous:=f.document.previous
    ok:=testing.expect_value(t,len(previous.instances),instances,loc)
    for instance in previous.instances {
        ok&=testing.expectf(t,prefab_fixture_find(f,instance.root)!=core.NONE,"the root of instance %d is in the World",instance.id,loc=loc)
    }
    for member in previous.members {
        ok&=testing.expect(t,asset.scene_instance_find(previous,member.instance)>=0 && prefab_fixture_find(f,member.entity)!=core.NONE,"a member is of an instance and in the World",loc=loc)
    }
    return ok
}

// Undo and redo of every step the history holds keep the records with the
// World, however many steps changed them, and a step the history no longer
// holds takes its version with it.
@(test)
prefab_records_follow_every_step_the_history_holds :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    if !testing.expect(t,prefab_fixture_init(f,"every-step")) {return}
    defer prefab_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    root:=entity_create(s,{name="Root",named=true})
    entity_create(s,{name="A",named=true,parent=root})
    core.world_settle(w)
    edits_reset(&f.edits,w)
    prefabs_follow(s,&f.prefabs)
    root_id:=api_entity_id(w,root)
    id,created:=prefab_create(s,root,"every-step")
    if !testing.expect_value(t,created,Prefab_Error.None) {return}
    prefabs_follow(s,&f.prefabs)
    PLACED :: 80
    for i in 0..<PLACED {
        _,placed:=prefab_instantiate(s,id,{position={f32(i),0,0}})
        if !testing.expect_value(t,placed,Prefab_Error.None) {return}
        prefabs_follow(s,&f.prefabs)
    }
    if !prefab_fixture_records_follow_the_world(t,f,PLACED+1) {return}
    testing.expect_value(t,len(f.prefabs.versions),PLACED+1)
    last:=f.document.previous.info.last_instance
    // One at a time, and three before the records follow.
    for undone:=0;undone<PLACED; {
        moves:=undone%2==0?1:min(3,PLACED-undone)
        for _ in 0..<moves {testing.expect(t,undo(&f.edits,w,&f.selection))}
        prefabs_follow(s,&f.prefabs)
        undone+=moves
        if !prefab_fixture_records_follow_the_world(t,f,PLACED+1-undone) {return}
    }
    testing.expect(t,undo(&f.edits,w,&f.selection))
    prefabs_follow(s,&f.prefabs)
    if !prefab_fixture_records_follow_the_world(t,f,0) {return}
    testing.expect(t,prefab_fixture_find(f,root_id)!=core.NONE && len(f.document.previous.members)==0)
    for redone:=0;redone<PLACED+1;redone+=1 {
        testing.expect(t,redo(&f.edits,w,&f.selection))
        prefabs_follow(s,&f.prefabs)
    }
    if !prefab_fixture_records_follow_the_world(t,f,PLACED+1) {return}
    testing.expect_value(t,f.document.previous.info.last_instance,last)
    _,linked:=prefab_link_of(s,root_id)
    testing.expect(t,linked)

    // A new step after two undos leaves them without redo: their versions go.
    for _ in 0..<2 {testing.expect(t,undo(&f.edits,w,&f.selection))}
    prefabs_follow(s,&f.prefabs)
    entity_create(s,{name="Elsewhere",named=true})
    prefab_fixture_step(f)
    testing.expect_value(t,len(f.prefabs.versions),PLACED-1)
    prefab_fixture_records_follow_the_world(t,f,PLACED-1)
    for &version in f.prefabs.versions {
        held:=false
        for step in f.edits.steps {held||=step.state==version.after_state}
        testing.expect(t,held)
    }
}

// What another editor of a session changes of a member is an override here
// too, although it is not a step of this history.
@(test)
prefab_edits_of_another_editor_mark_overrides :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    if !testing.expect(t,prefab_fixture_init(f,"remote")) {return}
    defer prefab_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    root:=entity_create(s,{name="Root",named=true})
    a:=entity_create(s,{name="A",named=true,parent=root})
    core.world_settle(w)
    edits_reset(&f.edits,w)
    prefabs_follow(s,&f.prefabs)
    a_id:=api_entity_id(w,a)
    _,created:=prefab_create(s,root,"remote")
    if !testing.expect_value(t,created,Prefab_Error.None) {return}
    prefabs_follow(s,&f.prefabs)
    testing.expect_value(t,len(f.document.previous.overrides),0)
    st:=new(Collab_State);defer free(st)
    collab_tables_build(s,st)
    defer collab_tables_free(st)
    st.role,st.phase=.Host,.Joined

    moved:=core.Transform{{0,5,0},1,{1,1,1}}
    message:serial.Writer
    serial.writer_init(&message,0,context.temp_allocator)
    serial.write_scalar(&message,u8(Collab_Message.Edit))
    serial.write_scalar(&message,u8(1))
    serial.write_scalar(&message,u16(1))
    serial.write_scalar(&message,u8(Collab_Op.Set))
    serial.write_scalar(&message,base.name_hash("Transform"))
    serial.write_scalar(&message,u64(a_id))
    serial.write_scalar(&message,u16(size_of(core.Transform)))
    serial.write_bytes(&message,mem.ptr_to_bytes(&moved))
    collab_edit_apply(s,st,serial.writer_bytes(&message))
    local,_:=core.get(core.read(&f.world.transforms),prefab_fixture_find(f,a_id))
    testing.expect_value(t,local.position,[3]f32{0,5,0})
    testing.expect_value(t,len(f.edits.steps),1)
    prefabs_follow(s,&f.prefabs)
    fields:=prefab_fixture_kind(f,.Field)
    testing.expect(t,len(fields)>0)
    for override in fields {testing.expect_value(t,override.entity,a_id)}
    testing.expect(t,len(f.prefabs.remote)==0 && !f.prefabs.remote_places)
}

// One resolver names an asset for every method: a path with or without its
// extension or an id, and a miss lists what is near.
@(test)
an_asset_is_named_by_its_path_with_or_without_its_extension_or_by_its_id :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    if !testing.expect(t,prefab_fixture_init(f,"asset-resolve")) {return}
    defer prefab_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    root:=entity_create(s,{name="Crate",named=true})
    core.world_settle(w)
    edits_reset(&f.edits,w)
    prefabs_follow(s,&f.prefabs)
    crate,created:=prefab_create(s,root,"crate")
    if !testing.expect_value(t,created,Prefab_Error.None) {return}
    _=asset.registry_scan(&f.assets.registry)
    b:=strings.builder_make(context.temp_allocator)
    fmt.sbprintf(&b,"%016x%016x",crate[0],crate[1])
    id:=strings.to_string(b)
    cases:=[?]struct{name,kinds,says:string}{
        {"crate.prefab",".prefab",""},
        {"crate",".prefab",""},
        {"crate","",""},
        {id,".prefab",""},
        {"crat",".prefab","crate.prefab"},
        {"prefabs/crat",".prefab","crate.prefab"},
        {"crate",".mesh","no .mesh"},
    }
    for c in cases {
        got,problem:=asset_resolve(s,c.name,c.kinds)
        testing.expectf(t,(c.says=="")==(problem=="") && strings.contains(problem,c.says),"%s: %s",c.name,problem)
        if c.says=="" {testing.expect_value(t,got,crate)}
    }
}
