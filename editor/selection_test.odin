package editor

import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/history"
import "mirai:host"

@(test)
copy_and_paste_duplicate_the_copied_roots_as_one_step :: proc(t:^testing.T) {
    world:Simulation_Test_World
    if !test_world_init(t,&world) {return}
    defer test_world_destroy(&world)
    original:=core.create(&world.entities)
    core.add(&world.ids,original,core.Id{1})
    core.add(&world.transforms,original,core.Transform{{1,0,0},1,{1,1,1}})
    test_world_settle(&world)
    edits:history.Edits
    selection:history.Selection
    previous:asset.Scene
    document:=Document{previous=&previous}
    app:host.App
    viewport:Viewport
    gui:Editor_Ui
    s:=Session{info=test_world_info(&world),edit_world=&world,edits=&edits,selection=&selection,document=&document,app=&app,viewport=&viewport,gui=&gui}
    w:=edited_world(&s)
    history.edits_reset(&edits,w)
    defer history.edits_free(&edits)
    defer delete(selection.entities)
    defer delete(s.copied)
    commands:Api
    if !test_commands_open(t,&s,&commands) {return}
    defer test_commands_close(&s)

    testing.expect(t,command_state(&s,"copy").disabled)
    testing.expect(t,command_state(&s,"paste").disabled)
    history.selection_set(&selection,{original})
    testing.expect(t,test_command(&s,"copy"))
    testing.expect_value(t,len(s.copied),1)
    history.selection_clear(&selection)
    testing.expect(t,test_command(&s,"paste"))
    history.edits_flush(&edits,w,&selection)
    testing.expect_value(t,edits.cursor,1)
    testing.expect_value(t,history.undo_label(&edits),"Paste")
    pasted:=history.selection_active(&selection)
    testing.expect(t,pasted!=core.NONE && pasted!=original)
    testing.expect_value(t,entity_local(w,pasted).position.x,f32(1))
    testing.expect(t,api_entity_id(w,pasted)!=1)

    // Paste again makes another copy of the same source.
    testing.expect(t,test_command(&s,"paste"))
    history.edits_flush(&edits,w,&selection)
    testing.expect_value(t,edits.cursor,2)
    testing.expect(t,history.selection_active(&selection)!=pasted)
    testing.expect_value(t,core.world_entities(w).alive,3)
    testing.expect(t,history.undo(&edits,w,&selection))
    testing.expect(t,history.undo(&edits,w,&selection))
    testing.expect_value(t,core.world_entities(w).alive,1)

    // Once the source is gone there is nothing to paste: the entry is off, and there is no step.
    core.destroy(&world.entities,original)
    core.world_settle(w)
    testing.expect(t,command_state(&s,"paste").disabled && !test_command(&s,"paste"))
    testing.expect_value(t,edits.cursor,0)
    testing.expect_value(t,len(s.copied),1)
}
