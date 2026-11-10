package editor

import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/history"
import "mirai:host"
import api "mirai:editor/api"

@(test)
tool_previews_confirm_once_or_restore_the_document_and_selection :: proc(t:^testing.T) {
    world:Simulation_Test_World
    if !core.test_world_init(t,&world) {return}
    defer core.test_world_destroy(&world)
    original:=core.create(&world.entities)
    core.add(&world.ids,original,core.Id{1})
    core.add(&world.transforms,original,core.Transform{{1,0,0},1,{1,1,1}})
    core.test_world_settle(&world)
    edits:history.Edits
    selection:history.Selection
    viewport:Viewport
    gui:Editor_Ui
    app:host.App
    s:=Session{info=core.test_world_info(&world),edit_world=&world,edits=&edits,selection=&selection,viewport=&viewport,gui=&gui,app=&app}
    w:=edited_world(&s)
    history.edits_reset(&edits,w)
    defer history.edits_free(&edits)
    defer delete(selection.entities)
    history.selection_set(&selection,{original})
    tool_set(&s,"test",true)
    testing.expect(t,tool_preview_begin(&s,"test","Place"))
    testing.expect(t,!tool_preview_begin(&s,"test","Other"))
    duplicate:=core.create(&world.entities)
    core.add(&world.ids,duplicate,core.Id{2})
    core.add(&world.transforms,duplicate,core.Transform{{2,0,0},1,{1,1,1}})
    core.world_settle(w)
    history.selection_set(&selection,{duplicate})
    core.edit(&world.transforms,original).position.x=5
    history.edits_end(&edits)
    history.edits_flush(&edits,w,&selection)
    testing.expect(t,!history.edits_commit(&edits,w,&selection))
    testing.expect(t,tool_preview_active(&s,"test"))
    testing.expect_value(t,edits.cursor,0)
    tools_release(&s)
    testing.expect(t,!tool_preview_active(&s,"test"))
    testing.expect(t,tool_on(&s,"test"))
    testing.expect_value(t,history.selection_active(&selection),original)
    testing.expect(t,!entity_alive(w,duplicate))
    testing.expect_value(t,entity_local(w,original).position.x,f32(1))
    testing.expect_value(t,edits.cursor,0)

    testing.expect(t,tool_preview_begin(&s,"test","Place"))
    duplicate=core.create(&world.entities)
    core.add(&world.ids,duplicate,core.Id{2})
    core.add(&world.transforms,duplicate,core.Transform{{3,0,0},1,{1,1,1}})
    core.world_settle(w)
    history.selection_set(&selection,{duplicate})
    testing.expect(t,tool_preview_end(&s,"test",true))
    testing.expect_value(t,edits.cursor,1)
    testing.expect_value(t,history.undo_label(&edits),"Place")
    testing.expect(t,history.undo(&edits,w,&selection))
    testing.expect(t,!entity_alive(w,duplicate))
    testing.expect_value(t,history.selection_active(&selection),original)
    testing.expect(t,history.redo(&edits,w,&selection))
    testing.expect(t,entity_alive(w,duplicate))
    testing.expect_value(t,history.selection_active(&selection),duplicate)

    testing.expect(t,tool_preview_begin(&s,"test","Move"))
    core.edit(&world.transforms,duplicate).position.x=8
    testing.expect(t,action_run(&s,.Undo))
    testing.expect_value(t,entity_local(w,duplicate).position.x,f32(3))
    testing.expect_value(t,edits.cursor,1)
    testing.expect(t,!tool_preview_active(&s,"test"))

    testing.expect(t,tool_preview_begin(&s,"test","Move"))
    core.edit(&world.transforms,duplicate).position.x=9
    tool_set(&s,"other",true)
    testing.expect(t,!tool_preview_active(&s,"test"))
    testing.expect_value(t,entity_local(w,duplicate).position.x,f32(3))
    testing.expect(t,tool_preview_begin(&s,"other","Move"))
    core.edit(&world.transforms,duplicate).position.x=10
    call:api.Call
    testing.expect(t,api_guard(&s,&call))
    testing.expect(t,!tool_preview_active(&s,"other"))
    testing.expect_value(t,entity_local(w,duplicate).position.x,f32(3))
    testing.expect_value(t,edits.cursor,1)

    testing.expect(t,tool_preview_begin(&s,"other","Move"))
    core.edit(&world.transforms,duplicate).position.x=11
    testing.expect_value(t,document_write(&s,"unused.scene",false),Document_Error.No_Assets)
    testing.expect(t,!tool_preview_active(&s,"other"))
    testing.expect_value(t,entity_local(w,duplicate).position.x,f32(3))
    testing.expect_value(t,edits.cursor,1)
    testing.expect(t,!tool_preview_end(&s,"other",true))

    history.selection_set(&selection,{original})
    testing.expect(t,tool_preview_begin(&s,"other","Place prefab"))
    copies:=entities_duplicate(&s,{original})
    testing.expect_value(t,len(copies),1)
    history.selection_set(&selection,copies)
    testing.expect(t,tool_preview_end(&s,"other",false))
    testing.expect_value(t,history.selection_active(&selection),original)
    testing.expect_value(t,edits.cursor,1)

    testing.expect(t,tool_preview_begin(&s,"other","Place prefab"))
    copies=entities_duplicate(&s,{original})
    history.selection_set(&selection,copies)
    testing.expect(t,tool_preview_end(&s,"other",true))
    testing.expect_value(t,edits.cursor,2)
    testing.expect(t,history.undo(&edits,w,&selection))
    testing.expect(t,history.redo(&edits,w,&selection))
}

// W, E and R take the scene a plugin tool lends, which stays on and takes it back.
@(test)
tool_lent_to_the_gizmo_stays_on :: proc(t:^testing.T) {
    world:Simulation_Test_World
    if !core.test_world_init(t,&world) {return}
    defer core.test_world_destroy(&world)
    edits:history.Edits
    selection:history.Selection
    viewport:Viewport
    gui:Editor_Ui
    app:host.App
    s:=Session{info=core.test_world_info(&world),edit_world=&world,edits=&edits,selection=&selection,viewport=&viewport,gui=&gui,app=&app}
    history.edits_reset(&edits,edited_world(&s))
    defer history.edits_free(&edits)
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
