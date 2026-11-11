package editor


import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:cook/author"
import "mirai:core"
import "mirai:editor/history"
import erender "mirai:engine/render"
import scene "mirai:engine/scene"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

@(test_world,editor="Prefab_Fixture_Editor")
Prefab_Test_World :: struct {
    using world:Test_World,
    using scene_tables:Test_Scene,
    lamps:core.Table(Prefab_Test_Lamp),
    point_lights:core.Table(erender.Point_Light),
    instances:core.Table(scene.Prefab_Instance),
    members:core.Table(scene.Prefab_Member),
}

// A component a scene saves and the API writes.
Prefab_Test_Lamp :: struct {intensity,range:f32,target:core.Entity,uses:u32 `mirai:"hidden"`}

// The World_Info of Prefab_Test_World with what a session over it holds of the editor.
@(private)
prefab_test_info :: proc(t:^testing.T) -> (info:core.World_Info,ok:bool) {
    return test_info(t,Prefab_Test_World)
}

// A session over Prefab_Test_World with an assets folder of its own. It
// stays where prefab_fixture_init found it.
@(private)
Prefab_Fixture :: struct {
    world:Prefab_Test_World,
    info:core.World_Info,
    assets:host.Assets,
    app:host.App,
    using edited:Test_Session,
    inspector:Inspector,
    using editor:Prefab_Fixture_Editor,
    outliner:Outliner,
    ai:Ai,
    root:string,
}

@(private)
prefab_fixture_init :: proc(t:^testing.T,f:^Prefab_Fixture,name:string) -> bool {
    f.info=prefab_test_info(t) or_return
    if !testing.expect(t,core.world_init(&f.info,.World,&f.world,context.allocator)) {return false}
    f.root=base.test_folder(t,fmt.tprintf("prefabs-%s",name))
    if f.root=="" {return false}
    asset.types_init(&f.assets.types)
    asset.registry_init(&f.assets.registry,f.root)
    f.app=host.App{assets=&f.assets,info=&f.info,allocator=context.allocator}
    test_session_open(&f.edited,core.world_ref(&f.world,&f.info))
    f.s.editor_world,f.s.assets_root,f.s.app,f.s.inspector,f.s.outliner,f.s.ai=&f.editor,f.root,&f.app,&f.inspector,&f.outliner,&f.ai
    // The engine whose recipes it makes entities of: mirai test sets it.
    f.s.engine_root,_=os.lookup_env("MIRAI_ROOT",context.allocator)
    return true
}

@(private)
prefab_fixture_destroy :: proc(f:^Prefab_Fixture) {
    prefabs_free(&f.s)
    author.recipes_free(f.s.recipes)
    delete(f.s.engine_root)
    test_session_close(&f.edited)
    core.value_free(&f.inspector,type_info_of(Inspector))
    delete(f.app.worlds)
    asset.registry_destroy(&f.assets.registry)
    asset.types_destroy(&f.assets.types)
    if f.info.sizes[.World]>0 {core.world_destroy(&f.info,.World,&f.world)}
    test_info_destroy(&f.info)
}

@(private)
Prefab_Fixture_Editor :: struct {prefabs:Prefabs,collab:Collab,api:Api}

// Commits what was edited, as the end of a frame does.
@(private)
prefab_fixture_step :: proc(f:^Prefab_Fixture) {
    history.edits_commit(&f.edits,edited_world(&f.s),&f.selection)
}

@(private="file")
prefab_fixture_find :: proc(f:^Prefab_Fixture,id:base.Entity_Id) -> core.Entity {
    return api_entity(edited_world(&f.s),id)
}

// A crate with a lid and a lamp on it that looks at the lid.
@(private)
prefab_test_crate :: proc(f:^Prefab_Fixture,parent:=core.NONE) -> (crate,lid,lamp:core.Entity) {
    s:=&f.s
    crate=entity_create(s,{name="Crate",named=true,parent=parent})
    lid=entity_create(s,{name="Lid",named=true,parent=crate})
    lamp=entity_create(s,{name="Lamp",named=true,parent=lid})
    core.add(&f.world.lamps,lamp,Prefab_Test_Lamp{intensity=2,range=3,target=lid})
    core.world_settle(edited_world(s))
    return
}

// The member of an instance with a name; NONE without one.
@(private)
prefab_test_named :: proc(f:^Prefab_Fixture,root:core.Entity,name:string) -> core.Entity {
    w:=edited_world(&f.s)
    for member in prefab_members(w,root) {
        if entity_name(w,member.entity)==name {return member.entity}
    }
    return core.NONE
}

// Whether the instance of root holds an override of an entity: component "" is the entity itself.
@(private)
prefab_test_has :: proc(f:^Prefab_Fixture,root,e:core.Entity,component:string,kind:asset.Override_Kind,path:string) -> bool {
    overrides,_:=prefab_overrides_of(&f.s,root)
    id:=api_entity_id(edited_world(&f.s),e)
    hash:=component==""?0:base.name_hash(component)
    for &override in overrides {
        if override.entity==id && override.component==hash && override.kind==kind && prefab_override_text(&override)==path {return true}
    }
    return false
}

// An edit of the lamp of an entity, as one step.
@(private="file")
lamp_set :: proc(f:^Prefab_Fixture,e:core.Entity,intensity:f32) {
    value,_:=core.get(&f.world.lamps,e)
    value.intensity=intensity
    core.add(&f.world.lamps,e,value)
    core.world_settle(edited_world(&f.s))
    prefab_fixture_step(f)
}

@(private="file")
lamp_of :: proc(f:^Prefab_Fixture,e:core.Entity) -> Prefab_Test_Lamp {
    value,_:=core.get(&f.world.lamps,e)
    return value
}

// The lamp of a prefab file becomes another, as a change made outside the editor.
@(private="file")
lamp_file_set :: proc(t:^testing.T,f:^Prefab_Fixture,file:string,lamp:base.Entity_Id,intensity,range:f32) -> bool {
    edited:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&edited,&f.assets.types,file),asset.Error.None) {return false}
    defer asset.scene_destroy(&edited)
    value,_:=asset.scene_get(&edited,lamp,"Prefab_Test_Lamp",Prefab_Test_Lamp)
    value.intensity,value.range=intensity,range
    asset.scene_set(&edited,lamp,"Prefab_Test_Lamp",&value)
    if !testing.expect_value(t,asset.scene_save(&edited,file),asset.Error.None) {return false}
    _=asset.registry_scan(&f.assets.registry)
    return true
}

// The overrides the instances of the document hold, all together.
@(private="file")
overrides_held :: proc(s:^Session) -> (count:int) {
    for root in prefab_roots(edited_world(s),{}) {
        overrides,_:=prefab_overrides_of(s,root)
        count+=len(overrides)
    }
    return
}

// The only entity of a world without a parent: the root of a prefab. NONE with none or several.
@(private)
test_only_root :: proc(w:core.World_Ref) -> (root:core.Entity) {
    for e in core.world_table_of(w,core.Id).entities {
        if entity_parent(w,e)!=core.NONE {continue}
        if root!=core.NONE {return core.NONE}
        root=e
    }
    return
}

@(test)
prefab_selection_and_file_overrides_share_the_undo_history :: proc(t:^testing.T) {
    info,described:=prefab_test_info(t)
    if !described {return}
    defer test_info_destroy(&info)
    world:Prefab_Test_World
    if !testing.expect(t,core.world_init(&info,.World,&world,context.allocator)) {return}
    defer core.world_destroy(&info,.World,&world)
    root:=base.test_folder(t,"prefabs")
    if root=="" {return}
    assets:host.Assets
    asset.types_init(&assets.types)
    defer asset.types_destroy(&assets.types)
    asset.registry_init(&assets.registry,root)
    defer asset.registry_destroy(&assets.registry)
    app:=host.App{assets=&assets,info=&info,allocator=context.allocator}
    defer delete(app.worlds)
    viewport:Viewport
    selection:history.Selection
    inspector:Inspector
    edits:history.Edits
    document:Document
    editor:Prefab_Fixture_Editor
    ai:=new(Ai)
    defer free(ai)
    g:Editor_Ui
    outliner:Outliner
    // The session and the UI context are large: off the stack of the test.
    s:=new(Session)
    defer free(s)
    s.info,s.edit_world,s.editor_world,s.assets_root,s.app=&info,&world,&editor,root,&app
    s.gui,s.viewport,s.selection,s.inspector,s.edits,s.document,s.outliner,s.ai=&g,&viewport,&selection,&inspector,&edits,&document,&outliner,ai
    defer delete(selection.entities)
    defer core.value_free(&inspector,type_info_of(Inspector))
    defer history.edits_free(&edits)
    defer document_previous_free(&document)
    defer prefabs_free(s)
    w:=edited_world(s)
    first:=entity_create(s,{name="First",transform={position={2,0,0},rotation=1,scale={1,1,1}}})
    second:=entity_create(s,{name="Second",transform={position={6,0,0},rotation=1,scale={1,1,1}}})
    core.world_settle(w)
    first_id,second_id:=api_entity_id(w,first),api_entity_id(w,second)
    history.edits_reset(&edits,w)
    history.selection_set(&selection,{first,second})
    testing.expect(t,!prefab_entry_disabled(s,"prefab_create"))
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
    testing.expect_value(t,core.count(&world.instances),1)
    group:=history.selection_active(&selection)
    group_id:=api_entity_id(w,group)
    first,second=api_entity(w,first_id),api_entity(w,second_id)
    history.selection_clear(&selection)
    testing.expect_value(t,selection_click_target(s,w,first,false),group)
    testing.expect_value(t,selection_click_target(s,w,first,true),first)
    history.selection_set(&selection,{group})
    testing.expect_value(t,selection_click_target(s,w,first,false),first)
    history.selection_set(&selection,{first})
    testing.expect_value(t,selection_click_target(s,w,second,false),second)
    history.selection_set(&selection,{group})
    testing.expect_value(t,entity_parent(w,first),group)
    testing.expect_value(t,entity_parent(w,second),group)
    testing.expect_value(t,entity_world(w,first).position,([3]f32{2,0,0}))
    testing.expect_value(t,entity_world(w,second).position,([3]f32{6,0,0}))
    file:=fmt.tprintf("%s/pair.scene",root)
    testing.expect(t,file_exists(s,file) && !os.exists(file),"the prefab is an unsaved file of the step")
    testing.expect(t,history.undo(&edits,w,&selection))
    testing.expect(t,!file_exists(s,file) && core.count(&world.instances)==0)
    testing.expect_value(t,world.entities.alive,2)
    testing.expect_value(t,len(selection.entities),2)
    testing.expect(t,history.redo(&edits,w,&selection))
    testing.expect(t,file_exists(s,file) && core.count(&world.instances)==1)
    group=api_entity(w,group_id)
    group_placement:=core.to_math(core.Transform{{11,7,-3},quaternion(x=0,y=0.6,z=0,w=0.8),{2,3,4}})
    transform_set(s,group,group_placement)
    history.edits_commit(&edits,w,&selection)
    history.selection_set(&selection,{group})
    testing.expect(t,prefab_entry_disabled(s,"prefab_apply") && prefab_entry_disabled(s,"prefab_revert"))
    testing.expect_value(t,overrides_held(s),0)
    root_field:=inspect_component(s,w,core.Transform,{group})
    testing.expect_value(t,len(inspect_default(s,w,root_field.t,group)),0)
    testing.expect(t,!inspect_changed(&root_field,int(offset_of(core.Transform,position)),12))
    testing.expect(t,!inspect_changed(&root_field,int(offset_of(core.Transform,rotation)),16))
    testing.expect(t,!inspect_changed(&root_field,int(offset_of(core.Transform,scale)),12))
    placement_cursor:=edits.cursor
    inspect_reset(&root_field,0,size_of(core.Transform))
    history.edits_commit(&edits,w,&selection)
    testing.expect_value(t,entity_local(w,group),group_placement)
    testing.expect_value(t,edits.cursor,placement_cursor)
    first=api_entity(w,first_id)
    history.selection_set(&selection,{first})
    testing.expect(t,prefab_entry_disabled(s,"prefab_create"))
    inherited_position:=entity_local(w,first).position
    changed_transform:=entity_local(w,first)
    changed_transform.position.x+=4
    transform_set(s,first,changed_transform)
    history.edits_commit(&edits,w,&selection)
    inherited_field:=inspect_component(s,w,core.Transform,{first})
    position_offset:=int(offset_of(core.Transform,position))
    testing.expect(t,inspect_changed(&inherited_field,position_offset,12))
    mixed_field:=inspect_component(s,w,core.Transform,{group,first})
    testing.expect(t,inspect_changed(&mixed_field,position_offset,12))
    inspect_reset(&mixed_field,position_offset,12)
    history.edits_commit(&edits,w,&selection)
    testing.expect_value(t,entity_local(w,group),group_placement)
    testing.expect_value(t,entity_local(w,first).position,inherited_position)
    testing.expect(t,!inspect_changed(&inherited_field,position_offset,12))
    testing.expect_value(t,api_entity_id(w,first),first_id)
    testing.expect(t,entity_rename(s,first,"Changed"))
    testing.expect_value(t,entity_name(w,first),"Changed")
    history.edits_commit(&edits,w,&selection)
    testing.expect_value(t,overrides_held(s),1)
    testing.expect(t,!prefab_entry_disabled(s,"prefab_apply"))
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
    testing.expect(t,history.undo(&edits,w,&selection))
    testing.expect(t,!prefab_entry_disabled(s,"prefab_revert"))
    loaded,found=prefab_scene_load(s,id)
    testing.expect(t,found)
    if found {
        row,_:=asset.scene_entity_find(loaded,first_id)
        testing.expect_value(t,base.text_get(asset.scene_names(loaded)[row][:]),"First")
        prefab_scene_free(loaded)
    }
    testing.expect(t,history.redo(&edits,w,&selection))
    testing.expect(t,prefab_entry_disabled(s,"prefab_revert"))
    testing.expect(t,history.undo(&edits,w,&selection))
    first=history.selection_active(&selection)
    reverted,revert_error:=prefab_revert(s,first,nil)
    testing.expect(t,revert_error==.None && reverted==1)
    testing.expect_value(t,entity_name(w,api_entity(w,first_id)),"First")
    testing.expect_value(t,entity_local(w,api_entity(w,group_id)),group_placement)
    group=api_entity(w,group_id)
    first,second=api_entity(w,first_id),api_entity(w,second_id)
    entity_rename(s,first,"First changed")
    entity_rename(s,second,"Second changed")
    history.edits_commit(&edits,w,&selection)
    reverted,revert_error=prefab_revert(s,first,nil)
    testing.expect(t,revert_error==.None && reverted==1)
    first,second=api_entity(w,first_id),api_entity(w,second_id)
    testing.expect_value(t,entity_name(w,first),"First")
    testing.expect_value(t,entity_name(w,second),"Second changed")
    entity_rename(s,first,"First changed")
    history.edits_commit(&edits,w,&selection)
    group=api_entity(w,group_id)
    history.selection_set(&selection,{group})
    testing.expect(t,!prefab_entry_disabled(s,"prefab_apply") && !prefab_entry_disabled(s,"prefab_revert"))
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
    testing.expect(t,history.undo(&edits,w,&selection))
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
    testing.expect(t,history.undo(&edits,w,&selection))
    testing.expect(t,prefab_linked(s))
    ctx:=new(ui.Context)
    defer free(ctx)
    testing.expect(t,test_ui_init(ctx,{}))
    defer ui.context_destroy(ctx)
    g.ctx=ctx
    for size in ([2][2]f32{{1440,900},{800,420}}) {
        for _ in 0..<3 {
            ui.frame_begin(ctx,{size=size,pointer_absent=true})
            if ui.box(ctx,{width=ui.fixed(240),height=ui.FIT,gap=4,align_y=.Center}) {
                identity_row(s,w,history.selection_active(&selection))
            }
            frame:=ui.frame_end(ctx)
            testing.expect(t,!frame.overflow && ctx.stats.layout_errors==0)
        }
        _,visible:=ui.widget_rect(ctx,ui.id(ctx,"prefab_open"))
        _,saves:=ui.widget_rect(ctx,ui.id(ctx,"variant_save"))
        testing.expect(t,visible && saves,"the icon opens the prefab and Save variant shows beside Apply")
        action_row:=f32(-1)
        action_labels:=[3]string{"Apply changes","Revert all","Unlink"}
        for action,action_index in ([3]string{"prefab_apply","prefab_revert","prefab_unlink"}) {
            rect,shown:=ui.widget_rect(ctx,command_widget(&g,action,1))
            testing.expect(t,shown && rect.w==22 && rect.h==ui.metric(ctx,"control"))
            if action_row<0 {action_row=rect.y}
            testing.expect_value(t,rect.y,action_row)
            // The tip shows once the pointer rested on the button.
            for _ in 0..<int(ui.TOOLTIP_DELAY*60)+2 {
                ui.frame_begin(ctx,{size=size,pointer={rect.x+rect.w/2,rect.y+rect.h/2},dt=1.0/60})
                if ui.box(ctx,{width=ui.fixed(240),height=ui.FIT,gap=4,align_y=.Center}) {
                    identity_row(s,w,history.selection_active(&selection))
                }
                ui.frame_end(ctx)
            }
            testing.expect_value(t,ctx.tooltip,action_labels[action_index])
        }
        selected:=history.selection_active(&selection)
        first=api_entity(w,first_id)
        history.selection_set(&selection,{first})
        ui.frame_begin(ctx,{size=size,pointer_absent=true})
        if ui.box(ctx,{width=ui.fixed(240),height=ui.FIT,gap=4,align_y=.Center}) {identity_row(s,w,first)}
        ui.frame_end(ctx)
        // A member reverts only itself.
        _,revert:=ui.widget_rect(ctx,command_widget(&g,"prefab_revert",1))
        _,apply:=ui.widget_rect(ctx,command_widget(&g,"prefab_apply",1))
        _,unlink:=ui.widget_rect(ctx,command_widget(&g,"prefab_unlink",1))
        testing.expect(t,revert && !apply && !unlink)
        group=api_entity(w,group_id)
        history.selection_set(&selection,{group})
        ui.frame_begin(ctx,{size=size,pointer_absent=true})
        if ui.box(ctx,{width=ui.fixed(240),height=ui.FIT,direction=.Column}) {
            transform_rows(s,w)
        }
        ui.frame_end(ctx)
        for paint in ctx.paints[:ctx.paint_count] {testing.expect(t,paint.icon!=.Revert)}
        history.selection_set(&selection,{selected})
    }
    testing.expect(t,history.redo(&edits,w,&selection))
    group=api_entity(w,group_id)
    history.selection_set(&selection,{group})
    before=edits.cursor
    _,error=prefab_create(s,group,"single")
    testing.expect_value(t,error,Prefab_Error.None)
    testing.expect_value(t,edits.cursor,before+1)
    testing.expect(t,history.undo(&edits,w,&selection))
    testing.expect(t,!prefab_linked(s) && !file_exists(s,fmt.tprintf("%s/single.scene",root)))
    testing.expect(t,history.redo(&edits,w,&selection))
    testing.expect(t,prefab_linked(s))
    file_open_path(s,"single.scene")
    testing.expect_value(t,g.modal,Modal.None)
    testing.expect(t,.Open in s.requests)
    testing.expect_value(t,scene_open(s,"single.scene"),Document_Error.None)
    group=api_entity(w,group_id)
    entity_rename(s,group,"Saved prefab")
    history.edits_commit(&edits,w,&selection)
    testing.expect_value(t,scene_save(s),Document_Error.None)
    saved:asset.Scene
    testing.expect_value(t,asset.scene_load(&saved,&assets.types,fmt.tprintf("%s/single.scene",root)),asset.Error.None)
    defer asset.scene_destroy(&saved)
    saved_root,rooted:=asset.prefab_root(&saved)
    testing.expect(t,rooted && saved_root==group_id && .Prefab in saved.doc.flags,"what was saved is a prefab with the group as its one root")
    row,_:=asset.scene_entity_find(&saved,group_id)
    testing.expect_value(t,base.text_get(asset.scene_names(&saved)[row][:]),"Saved prefab")
    scene_new(s)
    // A prefab let go on the scene replaces the World between frames, after the render of the
    // frame it was let go in, which draws the World its fixed phase ran on.
    alive:=world.entities.alive
    s.requests={} // the Open above was run by hand
    placement_commit(s,w,Drag{kind=.Asset,asset_kind=asset.KIND_SCENE,asset_id=id},Pick{},true)
    testing.expect(t,world.entities.alive>alive)
    testing.expect_value(t,len(selection.entities),1)
    if len(selection.entities)==1 {
        link,linked:=prefab_link_of(w,selection.entities[0])
        testing.expect(t,linked && link.root && link.asset==id)
    }
    scene_new(s)
    placed,place_error:=prefab_instantiate(s,id,{position={9,5,1},rotation={0,0.6,0,0.8},scale_multiplier={2,3,4}})
    testing.expect_value(t,place_error,Prefab_Error.None)
    testing.expect_value(t,overrides_held(s),0)
    placed_entity:=api_entity(w,placed)
    placement:=entity_local(w,placed_entity)
    reverted,revert_error=prefab_revert(s,placed_entity,nil)
    testing.expect(t,revert_error==.None && reverted==0)
    testing.expect_value(t,entity_local(w,api_entity(w,placed)),placement)
    scene_new(s)
    plain:=entity_create(s,{name="Plain",transform={position={7,2,3},rotation=1,scale={2,3,4}}})
    core.world_settle(w)
    history.selection_set(&selection,{plain})
    history.edits_commit(&edits,w,&selection)
    c:=inspect_component(s,w,core.Transform,{plain})
    scale_offset:=int(offset_of(core.Transform,scale))
    testing.expect(t,inspect_changed(&c,scale_offset,12))
    inspect_reset(&c,scale_offset,12)
    history.edits_commit(&edits,w,&selection)
    testing.expect_value(t,entity_local(w,plain).position,[3]f32{7,2,3})
    testing.expect_value(t,entity_local(w,plain).scale,[3]f32{1,1,1})
    testing.expect(t,!inspect_changed(&c,scale_offset,12))
    testing.expect(t,history.undo(&edits,w,&selection))
    testing.expect_value(t,entity_local(w,plain).scale,[3]f32{2,3,4})
    viewport_init(&viewport)
    defer viewport_free(&viewport)
    viewport.size={1440,900}
    viewport.orbit.distance=37
    original_camera:=viewport.orbit
    original_cursor:=edits.cursor
    original_state:=history.edits_state(&edits)
    base.text_set(ai.prompt[:],"Scene draft")
    ai.prompt_length=len("Scene draft")
    ai.selected=7
    testing.expect_value(t,document_open_tab(s,"single.scene"),Document_Error.None)
    defer documents_free(s)
    testing.expect_value(t,len(s.documents),2)
    testing.expect_value(t,s.active_document,1)
    testing.expect(t,document_is_prefab(s) && viewport.preview_sun)
    testing.expect_value(t,string(ai.prompt[:ai.prompt_length]),"Scene draft")
    testing.expect_value(t,ai.selected,7)
    prefab_world:=edited_world(s)
    root_entity:=test_only_root(prefab_world)
    testing.expect(t,root_entity!=core.NONE)
    entity_rename(s,root_entity,"Changed in tab")
    history.edits_commit(&edits,prefab_world,&selection)
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
    testing.expect_value(t,history.edits_state(&edits),original_state)
    testing.expect_value(t,viewport.orbit,original_camera)
    testing.expect_value(t,history.selection_active(&selection),plain)
    testing.expect_value(t,string(ai.prompt[:ai.prompt_length]),"Scene draft")
    testing.expect_value(t,ai.selected,7)
    testing.expect_value(t,document_open_tab(s,"single.scene"),Document_Error.None)
    testing.expect_value(t,len(s.documents),2)
    testing.expect_value(t,edits.cursor,prefab_cursor)
    testing.expect_value(t,string(ai.prompt[:ai.prompt_length]),"Scene draft")
    testing.expect_value(t,viewport.orbit.distance,f32(9))
    testing.expect(t,!viewport.preview_sun)
    testing.expect_value(t,entity_name(prefab_world,root_entity),"Changed in tab")
    testing.expect(t,history.undo(&edits,prefab_world,&selection))
    testing.expect_value(t,entity_name(prefab_world,root_entity),"Saved prefab")
    testing.expect(t,history.redo(&edits,prefab_world,&selection))
    // The document of a prefab is a scene as any other: an entity made at its top is a second
    // root, and its tab stays as it was opened.
    another_root:=entity_create(s,{name="Second root"})
    history.edits_commit(&edits,prefab_world,&selection)
    testing.expect_value(t,entity_parent(prefab_world,another_root),core.NONE)
    testing.expect(t,test_only_root(prefab_world)==core.NONE && document_is_prefab(s))
    entities_delete(s,{another_root})
    core.world_settle(prefab_world)
    history.edits_commit(&edits,prefab_world,&selection)
    testing.expect_value(t,test_only_root(prefab_world),root_entity)
    saved_tabs,kept:=documents_save_restart(s,root)
    testing.expect(t,kept && os.exists(saved_tabs))
    document_close(s,1)
    testing.expect_value(t,g.modal,Modal.Confirm)
    confirm_resolve(s,.Cancel)
    testing.expect_value(t,len(s.documents),2)
    document_activate(s,0)
    testing.expect_value(t,document_open_tab(s,"missing.scene"),Document_Error.Not_Found)
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

@(test)
a_prefab_operation_is_one_step_of_the_rows_of_its_instance :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    if !testing.expect(t,prefab_fixture_init(t,f,"steps")) {return}
    defer prefab_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    other:=entity_create(s,{name="Other",named=true})
    crate,_,lamp:=prefab_test_crate(f)
    history.edits_reset(&f.edits,w)

    // Creating: the entities stay, linked, and the prefab is an unsaved file of the step.
    id,created:=prefab_create(s,crate,"crate")
    if !testing.expect_value(t,created,Prefab_Error.None) {return}
    file:=scene_file(s,"crate.scene")
    testing.expect(t,!os.exists(file) && file_exists(s,file),"the prefab waits for Save in memory")
    of_crate,_:=prefab_link_of(w,crate)
    of_lamp,linked:=prefab_link_of(w,lamp)
    testing.expect(t,of_crate.root && of_crate.asset==id && linked && !of_lamp.root && of_lamp.instance==crate && of_lamp.source==api_entity_id(w,lamp))
    testing.expect(t,len(f.edits.steps)==1 && len(f.edits.steps[0].files)==1)

    // Placing: new entities, and a step that holds their rows alone.
    placed,instantiated:=prefab_instantiate(s,id,{position={4,0,0}})
    root:=api_entity(w,placed)
    if !testing.expect(t,instantiated==.None && root!=core.NONE) {return}
    testing.expect(t,len(f.edits.steps)==2 && entity_alive(w,other) && entity_alive(w,crate) && entity_local(w,root).position==[3]f32{4,0,0})
    members:=prefab_members(w,root)
    testing.expect_value(t,len(members),3)
    inside:=make(map[core.Entity]bool,context.temp_allocator)
    for member in members {inside[member.entity]=true}
    for &rows in f.edits.steps[1].tables {
        for e in rows.entities {testing.expect(t,inside[e],"a row of the step is of the instance")}
    }
    testing.expect(t,lamp_of(f,prefab_test_named(f,root,"Lamp")).target==prefab_test_named(f,root,"Lid"),"the references of a member name the members")

    // The history carries the instance as it carries any row.
    testing.expect(t,history.undo(&f.edits,w,&f.selection))
    testing.expect(t,!entity_alive(w,root) && core.count(&f.world.instances)==1 && core.count(&f.world.members)==3)
    testing.expect(t,history.redo(&f.edits,w,&f.selection))
    again:=api_entity(w,placed)
    of_again,_:=prefab_link_of(w,again)
    testing.expect(t,again!=core.NONE && of_again.root && of_again.asset==id && len(prefab_members(w,again))==3)
    // Undoing the creation takes the link and the file with it.
    testing.expect(t,history.undo(&f.edits,w,&f.selection) && history.undo(&f.edits,w,&f.selection))
    files_settle(s)
    _,still:=prefab_link_of(w,crate)
    testing.expect(t,!still && entity_alive(w,crate) && !file_exists(s,file))
}

@(test)
the_overrides_of_an_instance_are_derived_reverted_and_applied_without_writing_files :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    if !testing.expect(t,prefab_fixture_init(t,f,"overrides")) {return}
    defer prefab_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    crate,_,lamp:=prefab_test_crate(f)
    history.edits_reset(&f.edits,w)
    id,created:=prefab_create(s,crate,"crate")
    if !testing.expect_value(t,created,Prefab_Error.None) {return}
    file:=scene_file(s,"crate.scene")
    placed,_:=prefab_instantiate(s,id,{})
    root:=api_entity(w,placed)
    copy,lid:=prefab_test_named(f,root,"Lamp"),prefab_test_named(f,root,"Lid")
    none,known:=prefab_overrides_of(s,root)
    testing.expect(t,known && len(none)==0)

    lamp_set(f,copy,9)
    testing.expect(t,prefab_test_has(f,root,copy,"Prefab_Test_Lamp",.Field,"intensity"))
    _,unknown:=prefab_revert(s,copy,{"Prefab_Test_Lamp.range"})
    testing.expect_value(t,unknown,Prefab_Error.Unknown_Path)
    reverted,revert_error:=prefab_revert(s,copy,nil)
    testing.expect(t,revert_error==.None && reverted==1 && lamp_of(f,copy).intensity==2)

    // A value and an entity added, applied: every instance follows and the file stays in memory.
    lamp_set(f,copy,7)
    sticker:=entity_create(s,{name="Sticker",named=true,parent=lid})
    core.world_settle(w)
    prefab_fixture_step(f)
    testing.expect(t,prefab_test_has(f,root,sticker,"",.Child,"") && prefab_test_has(f,root,copy,"Prefab_Test_Lamp",.Field,"intensity"))
    read,_:=file_read(s,file)
    before:=strings.clone(string(read),context.temp_allocator)
    applied,apply_error:=prefab_apply(s,root,nil,true)
    testing.expect(t,apply_error==.None && applied==2)
    testing.expect(t,lamp_of(f,lamp).intensity==7 && prefab_test_named(f,crate,"Sticker")!=core.NONE && !os.exists(file))
    of_sticker,member:=prefab_link_of(w,sticker)
    left,_:=prefab_overrides_of(s,root)
    testing.expect(t,member && of_sticker.instance==root && len(left)==0,"what was applied is the prefab's, and the entity added a member")
    registered,_,_:=prefab_file(s,id)
    first,_:=core.get(&f.world.instances,crate)
    second,_:=core.get(&f.world.instances,root)
    testing.expect(t,first.stamp==registered.content_hash && second.stamp==registered.content_hash)

    // Undone, the instances and the file are as before it; done again, as after.
    testing.expect(t,history.undo(&f.edits,w,&f.selection))
    files_settle(s)
    read,_=file_read(s,file)
    testing.expect(t,lamp_of(f,lamp).intensity==2 && prefab_test_named(f,crate,"Sticker")==core.NONE && string(read)==before)
    testing.expect(t,prefab_test_has(f,root,sticker,"",.Child,"") && lamp_of(f,copy).intensity==7)
    testing.expect(t,history.redo(&f.edits,w,&f.selection))
    files_settle(s)
    testing.expect(t,lamp_of(f,lamp).intensity==7 && prefab_test_named(f,crate,"Sticker")!=core.NONE)

    // Save writes it.
    _,saved:=assets_save_all(s)
    testing.expect(t,saved && os.exists(file))
}

@(test)
unlinking_gives_back_what_a_prefab_placed_and_a_variant_applies_to_its_base :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    if !testing.expect(t,prefab_fixture_init(t,f,"nested")) {return}
    defer prefab_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    yard:=entity_create(s,{name="Yard",named=true})
    crate,_,lamp:=prefab_test_crate(f,yard)
    lamp_id:=api_entity_id(w,lamp)
    history.edits_reset(&f.edits,w)
    crate_id,_:=prefab_create(s,crate,"crate")
    yard_id,created:=prefab_create(s,yard,"yard")
    if !testing.expect_value(t,created,Prefab_Error.None) {return}
    // The crate is of the yard now: the scene holds one instance, and the yard's file the other,
    // which the chain of an entity reads from it.
    of_crate,_:=prefab_link_of(w,crate)
    testing.expect(t,core.count(&f.world.instances)==1 && of_crate.instance==yard && !of_crate.root && prefab_contains(s,yard_id,crate_id))
    links:=prefab_chain(s,w,lamp)
    if testing.expect_value(t,len(links),2) {
        testing.expect(t,links[0].asset==yard_id && links[0].instance==yard && !links[0].root)
        testing.expect(t,links[1].asset==crate_id && links[1].instance==crate && links[1].source==lamp_id && !links[1].root)
    }
    of_root:=prefab_chain(s,w,crate)
    testing.expect(t,len(of_root)==2 && of_root[1].root && of_root[1].instance==crate && len(prefab_chain(s,w,yard))==1)

    testing.expect_value(t,prefab_unlink(s,yard,false),Prefab_Error.None)
    of_crate,_=prefab_link_of(w,crate)
    of_lamp,_:=prefab_link_of(w,lamp)
    _,yard_linked:=prefab_link_of(w,yard)
    testing.expect(t,!yard_linked && of_crate.root && of_crate.asset==crate_id && of_lamp.instance==crate && of_lamp.source==lamp_id)
    testing.expect(t,core.count(&f.world.instances)==1 && core.count(&f.world.members)==3)
    testing.expect(t,history.undo(&f.edits,w,&f.selection))
    of_crate,_=prefab_link_of(w,crate)
    testing.expect(t,of_crate.instance==yard && core.count(&f.world.members)==4)
    testing.expect_value(t,prefab_unlink(s,crate,true),Prefab_Error.None)
    testing.expect(t,core.count(&f.world.instances)==0 && core.count(&f.world.members)==0)

    // A variant of the crate: what an instance of it changes goes through it into the crate.
    variant,made:=prefab_variant_create(s,crate_id,"crate_red")
    chain:=prefab_variant_chain(s,variant)
    testing.expect(t,made==.None && file_exists(s,scene_file(s,"crate_red.scene")) && len(chain)==1 && chain[0]==crate_id)
    placed,instantiated:=prefab_instantiate(s,variant,{})
    root:=api_entity(w,placed)
    if !testing.expect(t,instantiated==.None && root!=core.NONE) {return}
    link,_:=prefab_link_of(w,root)
    testing.expect_value(t,prefab_variant_of(s,w,link),crate_id)
    lamp_set(f,prefab_test_named(f,root,"Lamp"),5)
    _,plain:=prefab_apply(s,crate,nil,true,.Base)
    testing.expect_value(t,plain,Prefab_Error.Not_Instance)
    applied,apply_error:=prefab_apply(s,root,nil,true,.Base)
    testing.expect(t,apply_error==.None && applied==1)
    loaded,found:=prefab_scene_load(s,crate_id)
    if !testing.expect(t,found) {return}
    defer prefab_scene_free(loaded)
    in_base,_:=asset.scene_get(loaded,lamp_id,"Prefab_Test_Lamp",Prefab_Test_Lamp)
    testing.expect_value(t,in_base.intensity,f32(5))
    left,known:=prefab_overrides_of(s,root)
    testing.expect(t,known && len(left)==0)
}

@(test)
a_scene_opened_after_its_prefab_changed_follows_it_and_keeps_what_its_instances_set :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    if !testing.expect(t,prefab_fixture_init(t,f,"reopen")) {return}
    defer prefab_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    crate,_,lamp:=prefab_test_crate(f)
    history.edits_reset(&f.edits,w)
    id,created:=prefab_create(s,crate,"crate")
    if !testing.expect_value(t,created,Prefab_Error.None) {return}
    placed,_:=prefab_instantiate(s,id,{})
    copy:=prefab_test_named(f,api_entity(w,placed),"Lamp")
    lamp_set(f,copy,9)
    lamp_id,copy_id:=api_entity_id(w,lamp),api_entity_id(w,copy)
    testing.expect_value(t,scene_save(s,"level.scene"),Document_Error.None)
    _,saved:=assets_save_all(s)
    testing.expect(t,saved)

    if !lamp_file_set(t,f,scene_file(s,"crate.scene"),lamp_id,5,8) {return}
    stale:=0
    for state in prefab_instances(s) {stale+=int(state.stale)}
    testing.expect_value(t,stale,2)

    testing.expect_value(t,scene_open(s,"level.scene"),Document_Error.None)
    testing.expect(t,len(f.edits.steps)==0 && !document_dirty(s),"the instances were brought up to date before the World took them")
    first,second:=lamp_of(f,api_entity(w,lamp_id)),lamp_of(f,api_entity(w,copy_id))
    testing.expect(t,first.intensity==5 && first.range==8 && second.intensity==9 && second.range==8,"what the instance set stays over the new file")
    for state in prefab_instances(s) {testing.expect(t,!state.stale)}
    root:=api_entity(w,placed)
    overrides,known:=prefab_overrides_of(s,root)
    testing.expect(t,known && len(overrides)==1 && prefab_test_has(f,root,api_entity(w,copy_id),"Prefab_Test_Lamp",.Field,"intensity"))
}

// A prefab changed outside under a prefab that places it: one refresh brings every instance up to
// date, the ones of the placer to what it resolves to, and nothing is stale after it although the
// file of the placer stays as it was.
@(test)
a_refresh_after_a_placed_prefab_changed_leaves_nothing_stale :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    if !testing.expect(t,prefab_fixture_init(t,f,"converge")) {return}
    defer prefab_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    crate,_,lamp:=prefab_test_crate(f)
    shelf:=entity_create(s,{name="Shelf",named=true})
    core.world_settle(w)
    history.edits_reset(&f.edits,w)
    crate_id,created:=prefab_create(s,crate,"crate")
    if !testing.expect_value(t,created,Prefab_Error.None) {return}
    on_shelf,placed:=prefab_instantiate(s,crate_id,{parent=shelf})
    _,shelved:=prefab_create(s,shelf,"shelf")
    if !testing.expect(t,placed==.None && shelved==.None) {return}
    testing.expect_value(t,scene_save(s,"level.scene"),Document_Error.None)
    _,saved:=assets_save_all(s)
    testing.expect(t,saved)
    shelf_lamp:=prefab_test_named(f,shelf,"Lamp")
    testing.expect(t,shelf_lamp!=core.NONE && api_entity(w,on_shelf)!=core.NONE)
    of_shelf,_:=scene.prefab_instance(w,shelf)
    testing.expect(t,!prefab_stale(s,of_shelf))

    if !lamp_file_set(t,f,scene_file(s,"crate.scene"),api_entity_id(w,lamp),5,8) {return}
    of_crate,_:=scene.prefab_instance(w,crate)
    testing.expect(t,prefab_stale(s,of_crate) && prefab_stale(s,of_shelf),"an instance is stale once the registry has the file that changed outside")
    steps:=len(f.edits.steps)
    report,refreshed:=prefab_refresh(s,{})
    testing.expect(t,refreshed==.None && report.prefabs==2 && report.instances==2 && len(f.edits.steps)==steps+1)
    testing.expect(t,lamp_of(f,lamp).range==8 && lamp_of(f,shelf_lamp).range==8)
    of_crate,_=scene.prefab_instance(w,crate)
    of_shelf,_=scene.prefab_instance(w,shelf)
    testing.expect(t,!prefab_stale(s,of_crate) && !prefab_stale(s,of_shelf))
    for state in prefab_instances(s) {testing.expect(t,!state.stale)}

    again,_:=prefab_refresh(s,{})
    testing.expect(t,again.instances==0 && len(f.edits.steps)==steps+1 && len(assets_unsaved_paths(s))==0,"nothing is brought up to date twice, and no file was made unsaved")
    // Saved and opened again: still nothing to do, and no step.
    testing.expect_value(t,scene_save(s),Document_Error.None)
    testing.expect_value(t,scene_open(s,"level.scene"),Document_Error.None)
    for state in prefab_instances(s) {testing.expect(t,!state.stale)}
    again,_=prefab_refresh(s,{})
    testing.expect(t,again.instances==0 && len(f.edits.steps)==0 && !document_dirty(s) && len(assets_unsaved_paths(s))==0)
}

@(test)
an_instance_whose_base_is_not_held_keeps_what_it_has_when_it_is_refreshed :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    if !testing.expect(t,prefab_fixture_init(t,f,"unknown")) {return}
    defer prefab_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    crate,_,lamp:=prefab_test_crate(f)
    history.edits_reset(&f.edits,w)
    id,created:=prefab_create(s,crate,"crate")
    if !testing.expect_value(t,created,Prefab_Error.None) {return}
    _,saved:=assets_save_all(s)
    testing.expect(t,saved)
    placed,_:=prefab_instantiate(s,id,{})
    root:=api_entity(w,placed)
    copy:=prefab_test_named(f,root,"Lamp")
    lamp_set(f,copy,9)

    // The file is another, and this editor never held the one the instances were made with.
    if !lamp_file_set(t,f,scene_file(s,"crate.scene"),api_entity_id(w,lamp),5,8) {return}
    prefabs_state_free(&f.prefabs)
    _,known:=prefab_overrides_of(s,root)
    testing.expect(t,!known,"nothing says what the instance set")
    report,refreshed:=prefab_refresh(s,{})
    testing.expect(t,refreshed==.None && report.prefabs==1 && report.instances==2 && report.failed==0)
    testing.expect(t,lamp_of(f,copy).intensity==9 && lamp_of(f,copy).range==3 && lamp_of(f,lamp).intensity==2,"what differs from the file stays")
    registered,_,_:=prefab_file(s,id)
    instance,_:=core.get(&f.world.instances,root)
    testing.expect_value(t,instance.stamp,registered.content_hash)
    _,known=prefab_overrides_of(s,root)
    testing.expect(t,known && prefab_test_has(f,root,copy,"Prefab_Test_Lamp",.Field,"range") && prefab_test_has(f,root,copy,"Prefab_Test_Lamp",.Field,"intensity"))
    again,_:=prefab_refresh(s,{})
    testing.expect_value(t,again.instances,0)
}

@(test)
a_copy_of_an_instance_is_another_and_a_member_keeps_its_place :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    if !testing.expect(t,prefab_fixture_init(t,f,"copies")) {return}
    defer prefab_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    crate,lid,lamp:=prefab_test_crate(f)
    history.edits_reset(&f.edits,w)
    id,created:=prefab_create(s,crate,"crate")
    if !testing.expect_value(t,created,Prefab_Error.None) {return}

    whole:=entities_duplicate(s,{crate})
    core.world_settle(w)
    if !testing.expect_value(t,len(whole),1) {return}
    link,linked:=prefab_link_of(w,whole[0])
    testing.expect(t,linked && link.root && link.asset==id && len(prefab_members(w,whole[0]))==3 && core.count(&f.world.instances)==2)
    testing.expect(t,lamp_of(f,prefab_test_named(f,whole[0],"Lamp")).target==prefab_test_named(f,whole[0],"Lid"))

    one:=entities_duplicate(s,{lamp})
    core.world_settle(w)
    prefab_fixture_step(f)
    if !testing.expect_value(t,len(one),1) {return}
    _,member:=prefab_link_of(w,one[0])
    testing.expect(t,!member && entity_parent(w,one[0])==lid && prefab_test_has(f,crate,one[0],"",.Child,""),"the copy of a member is an entity its instance added")

    testing.expect(t,prefab_member_locked(s,w,lamp) && !prefab_member_locked(s,w,crate) && !prefab_member_locked(s,w,one[0]))
    testing.expect(t,!entity_reparent(s,lamp,core.NONE) && entity_parent(w,lamp)==lid)
    _,locked:=prefab_create(s,lamp,"lamp")
    testing.expect_value(t,locked,Prefab_Error.Member_Locked)
}

// The overrides of a kind, of the instances of the document.
@(private="file")
prefab_fixture_kind :: proc(f:^Prefab_Fixture,kind:asset.Override_Kind) -> (found:[dynamic]asset.Override) {
    found=make([dynamic]asset.Override,context.temp_allocator)
    for override in prefab_test_all(f) {
        if override.kind==kind {append(&found,override)}
    }
    return
}

// The overrides the instances of the document hold, all together.
@(private)
prefab_test_all :: proc(f:^Prefab_Fixture) -> []asset.Override {
    all:=make([dynamic]asset.Override,context.temp_allocator)
    for root in prefab_roots(edited_world(&f.s),{}) {
        overrides,_:=prefab_overrides_of(&f.s,root)
        append(&all,..overrides)
    }
    return all[:]
}

@(test)
prefab_instances_add_entities_and_turn_members_off_through_updates_apply_and_revert :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    if !testing.expect(t,prefab_fixture_init(t,f,"places")) {return}
    defer prefab_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    // Root with A (holding C) and B.
    root:=entity_create(s,{name="Root",named=true})
    a:=entity_create(s,{name="A",named=true,parent=root})
    b:=entity_create(s,{name="B",named=true,parent=root})
    c:=entity_create(s,{name="C",named=true,parent=a})
    core.world_settle(w)
    history.edits_reset(&f.edits,w)
    root_id,a_id,b_id,c_id:=api_entity_id(w,root),api_entity_id(w,a),api_entity_id(w,b),api_entity_id(w,c)
    id,created:=prefab_create(s,root,"places")
    if !testing.expect_value(t,created,Prefab_Error.None) {return}
    file:=fmt.tprintf("%s/places.scene",f.root)
    testing.expect_value(t,len(prefab_test_all(f)),0)
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
    testing.expect_value(t,len(prefab_test_all(f)),2)

    // A step that changes one value looks again at that member alone.
    transform_set(s,prefab_fixture_find(f,c_id),core.to_math(core.Transform{{0,4,0},1,{1,1,1}}))
    history.edits_commit(&f.edits,w,&f.selection)
    total:=len(prefab_test_all(f))
    testing.expect(t,total>2 && len(prefab_fixture_kind(f,.Field))==total-2)
    for override in prefab_fixture_kind(f,.Field) {testing.expect_value(t,override.entity,c_id)}
    // Undoing the steps forgets what they marked; redoing them marks it again.
    for _ in 0..<3 {
        testing.expect(t,history.undo(&f.edits,w,&f.selection))
    }
    testing.expect_value(t,len(prefab_test_all(f)),0)
    for _ in 0..<3 {
        testing.expect(t,history.redo(&f.edits,w,&f.selection))
    }
    testing.expect_value(t,len(prefab_test_all(f)),total)

    // The prefab is saved and changes on disk: what the instance holds survives the refresh.
    _,stored:=assets_save_all(s)
    testing.expect(t,stored)
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
    testing.expect_value(t,len(prefab_test_all(f)),total-2) // C keeps its position
    for _ in 0..<2 {
        testing.expect(t,history.undo(&f.edits,w,&f.selection))
    }
    testing.expect_value(t,len(prefab_test_all(f)),total)

    // Apply all: the prefab takes the entity added and B off, and the instance holds nothing of its own.
    applied_count,applied:=prefab_apply(s,prefab_fixture_find(f,root_id),nil,true)
    testing.expectf(t,applied==.None && applied_count==total,"apply: %v %d of %d",applied,applied_count,total)
    testing.expect_value(t,len(prefab_test_all(f)),0)
    testing.expect(t,prefab_fixture_find(f,added_id)!=core.NONE)
    _,still_added:=prefab_link_of(w,api_entity(w,added_id))
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
    if !testing.expect(t,prefab_fixture_init(t,f,"taken-back")) {return}
    defer prefab_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    root:=entity_create(s,{name="Root",named=true})
    a:=entity_create(s,{name="A",named=true,parent=root})
    core.world_settle(w)
    history.edits_reset(&f.edits,w)
    a_id:=api_entity_id(w,a)
    _,created:=prefab_create(s,root,"taken-back")
    if !testing.expect_value(t,created,Prefab_Error.None) {return}

    // An agent moves A; the user, later, adds an entity outside the instance.
    f.edits.author=history.EDIT_AUTHOR_API
    transform_set(s,prefab_fixture_find(f,a_id),core.to_math(core.Transform{{0,4,0},1,{1,1,1}}))
    prefab_fixture_step(f)
    testing.expect(t,len(prefab_fixture_kind(f,.Field))>0)
    testing.expect(t,history.undo(&f.edits,w,&f.selection))
    f.edits.author=history.EDIT_AUTHOR_USER
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
    if !testing.expect(t,prefab_fixture_init(t,f,"variants")) {return}
    defer prefab_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    root:=entity_create(s,{name="Crate",named=true})
    lid:=entity_create(s,{name="Lid",named=true,parent=root})
    core.world_settle(w)
    history.edits_reset(&f.edits,w)
    root_id,lid_id:=api_entity_id(w,root),api_entity_id(w,lid)
    crate,created:=prefab_create(s,root,"crate")
    if !testing.expect_value(t,created,Prefab_Error.None) {return}
    transform:=base.name_hash("Transform")

    // Its root is an instance of the base; undo and redo take its file away and back.
    path:=prefab_variant_path(s,crate)
    testing.expect_value(t,path,"crate_variant")
    variant,made:=prefab_variant_create(s,crate,path)
    if !testing.expect_value(t,made,Prefab_Error.None) {return}
    file:=fmt.tprintf("%s/crate_variant.scene",f.root)
    testing.expect(t,file_exists(s,file) && !os.exists(file))
    testing.expect_value(t,prefab_variant_path(s,crate),"crate_variant_2")
    _,taken:=prefab_variant_create(s,crate,path)
    testing.expect_value(t,taken,Prefab_Error.Exists)
    chain:=prefab_variant_chain(s,variant)
    testing.expect(t,len(chain)==1 && chain[0]==crate)
    testing.expect_value(t,len(prefab_variant_chain(s,crate)),0)
    if loaded,found:=prefab_scene_load(s,variant);testing.expect(t,found) {
        base_id,based:=asset.prefab_variant_base(loaded)
        testing.expect(t,based && base_id==crate && len(loaded.overrides)==0)
        prefab_scene_free(loaded)
    }
    testing.expect(t,history.undo(&f.edits,w,&f.selection))
    testing.expect(t,!file_exists(s,file))
    testing.expect(t,history.redo(&f.edits,w,&f.selection))
    testing.expect(t,file_exists(s,file))

    // An instance of the variant applies to the variant, which keeps the change as an override of its base.
    placed,placed_error:=prefab_instantiate(s,variant,{position={5,0,0}})
    if !testing.expect_value(t,placed_error,Prefab_Error.None) {return}
    placed_lid:=core.NONE
    for child in entity_children(w,prefab_fixture_find(f,placed)) {if entity_name(w,child)=="Lid" {placed_lid=child}}
    if !testing.expect(t,placed_lid!=core.NONE) {return}
    placed_lid_id:=api_entity_id(w,placed_lid)
    link,linked:=prefab_link_of(w,api_entity(w,placed))
    testing.expect(t,linked && link.root && link.asset==variant)
    testing.expect_value(t,prefab_variant_of(s,w,link),crate)
    testing.expect_value(t,inspector_variant_name(s,w,prefab_fixture_find(f,placed)),"crate")
    lid_link,_:=prefab_link_of(w,api_entity(w,placed_lid_id))
    history.selection_set(&f.selection,{prefab_fixture_find(f,placed)})
    testing.expect(t,prefab_entry_disabled(s,"prefab_apply_base"))
    raised:=[3]f32{0,3,0}
    transform_set(s,placed_lid,core.to_math(core.Transform{raised,1,{1,1,1}}))
    prefab_fixture_step(f)
    testing.expect(t,!prefab_entry_disabled(s,"prefab_apply_base"))
    _,applied:=prefab_apply(s,prefab_fixture_find(f,placed_lid_id),nil)
    testing.expect_value(t,applied,Prefab_Error.None)
    
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

    // The base is saved and changes on disk: the instance of the variant follows it and keeps the variant's change.
    _,stored:=assets_save_all(s)
    testing.expect(t,stored)
    crate_file:=fmt.tprintf("%s/crate.scene",f.root)
    edited:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&edited,&f.assets.types,crate_file),asset.Error.None) {return}
    asset.scene_entity_rename(&edited,lid_id,"Lid v2")
    testing.expect_value(t,asset.scene_save(&edited,crate_file),asset.Error.None)
    asset.scene_destroy(&edited)
    _=asset.registry_scan(&f.assets.registry)
    _,refreshed:=prefab_refresh(s,{})
    testing.expect_value(t,refreshed,Prefab_Error.None)
    placed_lid=prefab_fixture_find(f,placed_lid_id)
    testing.expect_value(t,entity_name(w,placed_lid),"Lid v2")
    testing.expect_value(t,entity_local(w,placed_lid).position,raised)
    testing.expect_value(t,entity_name(w,prefab_fixture_find(f,lid_id)),"Lid v2")

    // Apply to base: the name goes through the variant into the base, and the variant keeps its own change.
    entity_rename(s,placed_lid,"Lid v3")
    prefab_fixture_step(f)
    count,to_base:=prefab_apply(s,prefab_fixture_find(f,placed),nil,true,.Base)
    testing.expect(t,to_base==.None && count==1)
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
    testing.expect(t,history.undo(&f.edits,w,&f.selection))
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
    if !testing.expect(t,prefab_fixture_init(t,f,"old-fields")) {return}
    defer prefab_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    _,lamps:=core.world_table(edited_world(s),Prefab_Test_Lamp)
    lamps.default=proc(dst:rawptr) {(^Prefab_Test_Lamp)(dst)^={intensity=1,range=10}}
    Lamp_Without_Range :: struct {intensity:f32}
    old:asset.Scene
    if !testing.expect_value(t,asset.scene_init(&old,&f.assets.types,{1,2}),asset.Error.None) {return}
    old.doc.flags+={.Prefab}
    lamp_id,bulb_id:=base.Entity_Id(0x11),base.Entity_Id(0x12)
    asset.scene_entity_add(&old,lamp_id,0,"Lamp")
    asset.scene_entity_add(&old,bulb_id,lamp_id,"Bulb")
    for id in ([]base.Entity_Id{lamp_id,bulb_id}) {
        identity:=core.TRANSFORM_IDENTITY
        without:=Lamp_Without_Range{intensity=3}
        asset.scene_set(&old,id,"Transform",&identity)
        asset.scene_set(&old,id,"Prefab_Test_Lamp",&without)
    }
    file:=fmt.tprintf("%s/lamp.scene",f.root)
    saved:=asset.scene_save(&old,file)
    asset.scene_destroy(&old)
    if !testing.expect_value(t,saved,asset.Error.None) {return}
    core.world_settle(w)
    history.edits_reset(&f.edits,w)
    id,problem:=asset_resolve(s,"lamp",".scene")
    if !testing.expect_value(t,problem,"") {return}
    placed,placed_error:=prefab_instantiate(s,id,{})
    if !testing.expect_value(t,placed_error,Prefab_Error.None) {return}
    none,known:=prefab_overrides_of(s,prefab_fixture_find(f,placed))
    testing.expect(t,known && len(none)==0)

    reach:=f32(25)
    testing.expect(t,field_write(s,lamps,{prefab_fixture_find(f,placed)},int(offset_of(Prefab_Test_Lamp,range)),mem.ptr_to_bytes(&reach)))
    prefab_fixture_step(f)
    count,applied:=prefab_apply(s,prefab_fixture_find(f,placed),{"Prefab_Test_Lamp.range"})
    testing.expectf(t,applied==.None && count==1,"apply: %v, %d applied",applied,count)
    unsaved,_:=file_read(s,file)
    written:asset.Scene
    if !testing.expect_value(t,asset.scene_read(&written,&f.assets.types,unsaved),asset.Error.None) {return}
    defer asset.scene_destroy(&written)
    lamp,_:=asset.scene_get(&written,lamp_id,"Prefab_Test_Lamp",Prefab_Test_Lamp)
    bulb,_:=asset.scene_get(&written,bulb_id,"Prefab_Test_Lamp",Prefab_Test_Lamp)
    testing.expect_value(t,lamp,Prefab_Test_Lamp{intensity=3,range=25})
    testing.expect_value(t,bulb,Prefab_Test_Lamp{intensity=3,range=10})
}

// The editors of a shared session, each over its own copy of the assets.
@(private="file")
prefab_collab_join :: proc(f:^Prefab_Fixture,role:Collab_Role) {
    w:=edited_world(&f.s)
    core.world_settle(w)
    history.edits_reset(&f.edits,w)
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
        delete(peer.out);delete(peer.incoming)
    }
    for path in st.files_out {delete(path)}
    delete(st.files_out)
    collab_tables_free(st)
    history.journal_reading(&f.edits,false)
    free(st)
    f.collab.state=nil
}

// An update of the session at one end, and what it queued for its peer
// arriving at the other in order.
@(private="file")
prefab_collab_send :: proc(f,to:^Prefab_Fixture) {
    st:=f.collab.state
    collab_edits_send(&f.s,st)
    collab_files_send(&f.s,st)
    peer:=&st.peers[st.role==.Host?1:0]
    for message in peer.out {
        collab_receive(&to.s,to.collab.state,st.role==.Host?-1:1,message,0)
        delete(message)
    }
    clear(&peer.out)
}

// The instances of one editor reach the others as the rows of their entities,
// and the prefab an operation wrote as an unsaved file: nothing else travels.
@(test)
prefab_instances_travel_a_session_as_rows_and_their_prefab_as_an_unsaved_file :: proc(t:^testing.T) {
    host:=new(Prefab_Fixture);defer free(host)
    if !testing.expect(t,prefab_fixture_init(t,host,"collab-host")) {return}
    defer prefab_fixture_destroy(host)
    guest:=new(Prefab_Fixture);defer free(guest)
    if !testing.expect(t,prefab_fixture_init(t,guest,"collab-guest")) {return}
    defer prefab_fixture_destroy(guest)
    prefab_collab_join(host,.Host)
    defer prefab_collab_leave(host)
    prefab_collab_join(guest,.Guest)
    defer prefab_collab_leave(guest)
    hw,gw:=edited_world(&host.s),edited_world(&guest.s)

    crate,_,_:=prefab_test_crate(host)
    prefab_fixture_step(host)
    crate_id:=api_entity_id(hw,crate)
    prefab_collab_send(host,guest)
    testing.expect(t,prefab_fixture_find(guest,crate_id)!=core.NONE)

    id,created:=prefab_create(&host.s,crate,"group")
    if !testing.expect_value(t,created,Prefab_Error.None) {return}
    prefab_collab_send(host,guest)
    there:=prefab_fixture_find(guest,crate_id)
    link,linked:=prefab_link_of(gw,there)
    file:=scene_file(&guest.s,"group.scene")
    testing.expect(t,linked && link.root && link.asset==id && core.count(&guest.world.members)==3)
    testing.expect(t,file_exists(&guest.s,file) && !os.exists(file),"the prefab came as an unsaved file")
    _,known:=prefab_overrides_of(&guest.s,there)
    testing.expect(t,known,"the guest compares its instance with the prefab it received")

    // An instance placed there: its entities and the rows that name its root arrive in one update.
    placed,instantiated:=prefab_instantiate(&host.s,id,{position={2,0,0}})
    if !testing.expect_value(t,instantiated,Prefab_Error.None) {return}
    prefab_collab_send(host,guest)
    root:=prefab_fixture_find(guest,placed)
    testing.expect(t,root!=core.NONE && len(prefab_members(gw,root))==3 && core.count(&guest.world.instances)==2,"each member names the root made with it")

    // The host applies what a guest did and sends it back to it; an undo there goes the same way.
    testing.expect_value(t,prefab_unlink(&guest.s,there,false),Prefab_Error.None)
    prefab_collab_send(guest,host)
    testing.expect(t,core.count(&host.world.instances)==1 && core.count(&host.world.members)==3)
    prefab_collab_send(host,guest)
    move:=history_undo(&guest.s)
    testing.expect(t,move.done && move.error=="",move.error)
    prefab_fixture_step(guest)
    prefab_collab_send(guest,host)
    prefab_collab_send(host,guest)
    testing.expect(t,core.count(&host.world.instances)==2 && core.count(&host.world.members)==6 && core.count(&guest.world.instances)==2)
}

@(test)
an_asset_is_named_by_its_path_with_or_without_its_extension_or_by_its_id :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    if !testing.expect(t,prefab_fixture_init(t,f,"asset-resolve")) {return}
    defer prefab_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    root:=entity_create(s,{name="Crate",named=true})
    core.world_settle(w)
    history.edits_reset(&f.edits,w)
    crate,created:=prefab_create(s,root,"crate")
    if !testing.expect_value(t,created,Prefab_Error.None) {return}
    _=asset.registry_scan(&f.assets.registry)
    b:=strings.builder_make(context.temp_allocator)
    fmt.sbprintf(&b,"%016x%016x",crate[0],crate[1])
    id:=strings.to_string(b)
    cases:=[?]struct{name,kinds,says:string}{
        {"crate.scene",".scene",""},
        {"crate",".scene",""},
        {"crate","",""},
        {id,".scene",""},
        {"crat",".scene","crate.scene"},
        {"prefabs/crat",".scene","crate.scene"},
        {"crate",".mesh","no .mesh"},
    }
    for c in cases {
        got,problem:=asset_resolve(s,c.name,c.kinds)
        testing.expectf(t,(c.says=="")==(problem=="") && strings.contains(problem,c.says),"%s: %s",c.name,problem)
        if c.says=="" {testing.expect_value(t,got,crate)}
    }
}

// One kind of file, told apart by what its header says: a prefab to the
// browser and to what places it, whatever its roots. Made a scene, nothing
// places it as an instance or makes a variant of it, and the instance it
// placed before stays linked.
@(test)
the_editor_tells_a_prefab_from_a_scene_by_its_kind :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    if !testing.expect(t,prefab_fixture_init(t,f,"kind")) {return}
    defer prefab_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    crate,_,_:=prefab_test_crate(f)
    core.world_settle(w)
    history.edits_reset(&f.edits,w)
    id,created:=prefab_create(s,crate,"crate")
    if !testing.expect_value(t,created,Prefab_Error.None) {return}
    registry:=&f.assets.registry
    shown :: proc(t:^testing.T,s:^Session,registry:^asset.Registry,id:base.Asset_Id,prefab:bool) {
        file,found:=asset.registry_find(registry,id)
        if !testing.expect(t,found) {return}
        testing.expect_value(t,file.kind,asset.KIND_SCENE)
        testing.expect_value(t,content_file_category(file),prefab?Content_Category.Prefab:Content_Category.Scene)
        testing.expect_value(t,path_is_prefab(s,file.path),prefab)
        testing.expect(t,asset_kind_takes({0=asset.KIND_SCENE},file.kind),"a field of scenes takes a prefab, which is one")
        testing.expect(t,(asset_file_color(s,file)==PREFAB_ASSET_COLOR)==prefab && PREFAB_ASSET_COLOR!=asset_color(asset.KIND_SCENE))
    }
    shown(t,s,registry,id,true)
    edit :: proc(t:^testing.T,f:^Prefab_Fixture,change:proc(scene:^asset.Scene)) {
        registry:=&f.assets.registry
        data,read:=asset.registry_read(registry,"crate.scene",context.temp_allocator)
        edited:asset.Scene
        if !testing.expect(t,read==.None && asset.scene_read(&edited,&f.assets.types,data)==.None) {return}
        defer asset.scene_destroy(&edited)
        change(&edited)
        bytes,encoded:=asset.scene_bytes(&edited,context.temp_allocator)
        testing.expect(t,encoded==.None)
        testing.expect_value(t,asset.registry_memory_set(registry,"crate.scene",bytes),asset.Error.None)
    }
    edit(t,f,proc(scene:^asset.Scene) {asset.scene_entity_add(scene,asset.scene_new_id(scene),0,"Second root")})
    shown(t,s,registry,id,true)
    edit(t,f,proc(scene:^asset.Scene) {scene.doc.flags-={.Prefab}})
    shown(t,s,registry,id,false)
    _,placed:=prefab_instantiate(s,id,{})
    testing.expect_value(t,placed,Prefab_Error.Not_Found)
    _,varied:=prefab_variant_create(s,id,"crate_variant")
    testing.expect_value(t,varied,Prefab_Error.Not_Found)
    link,linked:=prefab_link_of(w,crate)
    testing.expect(t,linked && link.root && link.asset==id)
}
