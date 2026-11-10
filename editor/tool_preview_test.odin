package editor

import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import api "mirai:editor/api"

@(test)
tool_previews_confirm_once_or_restore_the_document_and_selection :: proc(t:^testing.T) {
    world:Simulation_Test_World
    core.entities_init(&world.entities)
    core.table_init(&world.ids,"Id")
    core.table_init(&world.transforms,"Transform")
    core.table_init(&world.parents,"Parent")
    defer core.entities_destroy(&world.entities)
    defer core.table_destroy(&world.ids)
    defer core.table_destroy(&world.transforms)
    defer core.table_destroy(&world.parents)
    tables:=[2]core.Table_Info{
        {name="Id",type=core.Id,info=type_info_of(core.Id),offset=offset_of(Simulation_Test_World,ids)},
        {name="Transform",type=core.Transform,info=type_info_of(core.Transform),offset=offset_of(Simulation_Test_World,transforms)},
    }
    info:=core.World_Info{entities=offset_of(Simulation_Test_World,entities),tables=tables[:]}
    original:=core.create(&world.entities)
    core.add(&world.ids,original,core.Id{1})
    core.add(&world.transforms,original,core.Transform{{1,0,0},1,{1,1,1}})
    simulation_test_settle(&world,nil,nil)
    edits:Edits
    selection:Selection
    viewport:Viewport
    gui:Editor_Ui
    app:host.App
    s:=Session{info=&info,edit_world=&world,edits=&edits,selection=&selection,viewport=&viewport,gui=&gui,app=&app}
    w:=edited_world(&s)
    edits_reset(&edits,w)
    defer edits_free(&edits)
    defer delete(selection.entities)
    selection_set(&selection,{original})
    tool_set(&s,"test",true)
    testing.expect(t,tool_preview_begin(&s,"test","Place"))
    testing.expect(t,!tool_preview_begin(&s,"test","Other"))
    duplicate:=core.create(&world.entities)
    core.add(&world.ids,duplicate,core.Id{2})
    core.add(&world.transforms,duplicate,core.Transform{{2,0,0},1,{1,1,1}})
    core.world_settle(w)
    selection_set(&selection,{duplicate})
    core.get(&world.transforms,original).position.x=5
    edits_end(&edits)
    edits_flush(&edits,w,&selection)
    testing.expect(t,!edits_commit(&edits,w,&selection))
    testing.expect(t,tool_preview_active(&s,"test"))
    testing.expect_value(t,edits.cursor,0)
    tools_release(&s)
    testing.expect(t,!tool_preview_active(&s,"test"))
    testing.expect(t,tool_on(&s,"test"))
    testing.expect_value(t,selection_active(&selection),original)
    testing.expect(t,!entity_alive(w,duplicate))
    testing.expect_value(t,entity_local(w,original).position.x,f32(1))
    testing.expect_value(t,edits.cursor,0)

    testing.expect(t,tool_preview_begin(&s,"test","Place"))
    duplicate=core.create(&world.entities)
    core.add(&world.ids,duplicate,core.Id{2})
    core.add(&world.transforms,duplicate,core.Transform{{3,0,0},1,{1,1,1}})
    core.world_settle(w)
    selection_set(&selection,{duplicate})
    testing.expect(t,tool_preview_end(&s,"test",true))
    testing.expect_value(t,edits.cursor,1)
    testing.expect_value(t,undo_label(&edits),"Place")
    testing.expect(t,undo(&edits,w,&selection))
    testing.expect(t,!entity_alive(w,duplicate))
    testing.expect_value(t,selection_active(&selection),original)
    testing.expect(t,redo(&edits,w,&selection))
    testing.expect(t,entity_alive(w,duplicate))
    testing.expect_value(t,selection_active(&selection),duplicate)

    testing.expect(t,tool_preview_begin(&s,"test","Move"))
    core.get(&world.transforms,duplicate).position.x=8
    testing.expect(t,action_run(&s,.Undo))
    testing.expect_value(t,entity_local(w,duplicate).position.x,f32(3))
    testing.expect_value(t,edits.cursor,1)
    testing.expect(t,!tool_preview_active(&s,"test"))

    testing.expect(t,tool_preview_begin(&s,"test","Move"))
    core.get(&world.transforms,duplicate).position.x=9
    tool_set(&s,"other",true)
    testing.expect(t,!tool_preview_active(&s,"test"))
    testing.expect_value(t,entity_local(w,duplicate).position.x,f32(3))
    testing.expect(t,tool_preview_begin(&s,"other","Move"))
    core.get(&world.transforms,duplicate).position.x=10
    call:api.Call
    testing.expect(t,api_guard(&s,&call))
    testing.expect(t,!tool_preview_active(&s,"other"))
    testing.expect_value(t,entity_local(w,duplicate).position.x,f32(3))
    testing.expect_value(t,edits.cursor,1)

    testing.expect(t,tool_preview_begin(&s,"other","Move"))
    core.get(&world.transforms,duplicate).position.x=11
    testing.expect_value(t,document_write(&s,"unused.scene",false),Document_Error.No_Assets)
    testing.expect(t,!tool_preview_active(&s,"other"))
    testing.expect_value(t,entity_local(w,duplicate).position.x,f32(3))
    testing.expect_value(t,edits.cursor,1)
    testing.expect(t,!tool_preview_end(&s,"other",true))

    prefabs:=Prefabs{epoch=edits.epoch,last_state=edits_state(&edits)}
    previous:asset.Scene
    document:=Document{previous=&previous}
    storage:=[1]core.Storage_Info{{name="Prefabs",type=Prefabs,info=type_info_of(Prefabs),place=.Editor}}
    info.storages=storage[:]
    s.editor_world,s.document=&prefabs,&document
    defer prefabs_free(&s)
    defer delete(previous.instances)
    defer delete(previous.members)
    defer delete(previous.overrides)
    previous.info.last_instance=1
    append(&previous.instances,asset.Instance{id=1,prefab={4,5},root=1})
    append(&previous.members,asset.Member{instance=1,source=11,entity=1})
    selection_set(&selection,{original})
    testing.expect(t,tool_preview_begin(&s,"other","Place prefab"))
    copies:=entities_duplicate(&s,{original})
    testing.expect_value(t,len(copies),1)
    testing.expect_value(t,len(previous.instances),2)
    testing.expect_value(t,len(previous.members),2)
    testing.expect(t,prefabs.has_pending)
    selection_set(&selection,copies)
    testing.expect(t,tool_preview_end(&s,"other",false))
    testing.expect_value(t,len(previous.instances),1)
    testing.expect_value(t,len(previous.members),1)
    testing.expect_value(t,previous.info.last_instance,u32(1))
    testing.expect(t,!prefabs.has_pending)
    testing.expect_value(t,selection_active(&selection),original)
    testing.expect_value(t,edits.cursor,1)

    testing.expect(t,tool_preview_begin(&s,"other","Place prefab"))
    copies=entities_duplicate(&s,{original})
    selection_set(&selection,copies)
    testing.expect(t,tool_preview_end(&s,"other",true))
    testing.expect_value(t,len(previous.instances),2)
    testing.expect(t,!prefabs.has_pending)
    testing.expect_value(t,len(prefabs.versions),1)
    testing.expect_value(t,edits.cursor,2)
    testing.expect(t,undo(&edits,w,&selection))
    prefabs_sync(&s,&prefabs)
    testing.expect_value(t,len(previous.instances),1)
    testing.expect_value(t,len(previous.members),1)
    testing.expect(t,redo(&edits,w,&selection))
    prefabs_sync(&s,&prefabs)
    testing.expect_value(t,len(previous.instances),2)
    testing.expect_value(t,len(previous.members),2)
}

// W, E and R take the scene a plugin tool lends, which stays on and takes it back.
@(test)
tool_lent_to_the_gizmo_stays_on :: proc(t:^testing.T) {
    world:Simulation_Test_World
    core.entities_init(&world.entities)
    core.table_init(&world.ids,"Id")
    core.table_init(&world.transforms,"Transform")
    core.table_init(&world.parents,"Parent")
    defer core.entities_destroy(&world.entities)
    defer core.table_destroy(&world.ids)
    defer core.table_destroy(&world.transforms)
    defer core.table_destroy(&world.parents)
    tables:=[2]core.Table_Info{
        {name="Id",type=core.Id,info=type_info_of(core.Id),offset=offset_of(Simulation_Test_World,ids)},
        {name="Transform",type=core.Transform,info=type_info_of(core.Transform),offset=offset_of(Simulation_Test_World,transforms)},
    }
    info:=core.World_Info{entities=offset_of(Simulation_Test_World,entities),tables=tables[:]}
    edits:Edits
    selection:Selection
    viewport:Viewport
    gui:Editor_Ui
    app:host.App
    s:=Session{info=&info,edit_world=&world,edits=&edits,selection=&selection,viewport=&viewport,gui=&gui,app=&app}
    edits_reset(&edits,edited_world(&s))
    defer edits_free(&edits)
    defer delete(selection.entities)
    tool_set(&s,"test",true)
    testing.expect(t,action_state(&s,.Tool_Move).checked)
    tool_lend(&s,"test")
    testing.expect(t,!action_state(&s,.Tool_Move).checked)
    testing.expect(t,action_run(&s,.Tool_Rotate))
    testing.expect(t,tool_on(&s,"test") && tool_aside(&s,"test"))
    testing.expect(t,action_state(&s,.Tool_Rotate).checked)
    tool_take(&s,"test")
    testing.expect(t,!tool_aside(&s,"test") && tool_on(&s,"test"))
    testing.expect(t,!action_state(&s,.Tool_Rotate).checked)
    // Another tool lends nothing until it says so.
    tool_set(&s,"other",true)
    testing.expect(t,action_state(&s,.Tool_Rotate).checked)
    testing.expect(t,action_run(&s,.Tool_Move))
    testing.expect(t,!tool_aside(&s,"other"))
}
