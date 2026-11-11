package editor

import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/history"
import "mirai:host"

@(test)
copy_and_paste_duplicate_the_copied_roots_as_one_step :: proc(t:^testing.T) {
    world:Simulation_Test_World
    if !core.test_world_init(t,&world) {return}
    defer core.test_world_destroy(&world)
    original:=core.create(&world.entities)
    core.add(&world.ids,original,core.Id{1})
    core.add(&world.transforms,original,core.Transform{{1,0,0},1,{1,1,1}})
    core.test_world_settle(&world)
    edits:history.Edits
    selection:history.Selection
    previous:asset.Scene
    document:=Document{previous=&previous}
    app:host.App
    s:=Session{info=core.test_world_info(&world),edit_world=&world,edits=&edits,selection=&selection,document=&document,app=&app}
    w:=edited_world(&s)
    history.edits_reset(&edits,w)
    defer history.edits_free(&edits)
    defer delete(selection.entities)
    defer delete(s.copied)

    testing.expect(t,action_state(&s,.Copy).disabled)
    testing.expect(t,action_state(&s,.Paste).disabled)
    history.selection_set(&selection,{original})
    testing.expect(t,action_run(&s,.Copy))
    testing.expect_value(t,len(s.copied),1)
    history.selection_clear(&selection)
    testing.expect(t,action_run(&s,.Paste))
    history.edits_flush(&edits,w,&selection)
    testing.expect_value(t,edits.cursor,1)
    testing.expect_value(t,history.undo_label(&edits),"Paste")
    pasted:=history.selection_active(&selection)
    testing.expect(t,pasted!=core.NONE && pasted!=original)
    testing.expect_value(t,entity_local(w,pasted).position.x,f32(1))
    testing.expect(t,api_entity_id(w,pasted)!=1)

    // Paste again makes another copy of the same source.
    testing.expect(t,action_run(&s,.Paste))
    history.edits_flush(&edits,w,&selection)
    testing.expect_value(t,edits.cursor,2)
    testing.expect(t,history.selection_active(&selection)!=pasted)
    testing.expect_value(t,core.world_entities(w).alive,3)
    testing.expect(t,history.undo(&edits,w,&selection))
    testing.expect(t,history.undo(&edits,w,&selection))
    testing.expect_value(t,core.world_entities(w).alive,1)

    // Once the source is gone there is nothing to paste and no step.
    core.destroy(&world.entities,original)
    core.world_settle(w)
    testing.expect(t,action_run(&s,.Paste))
    testing.expect_value(t,edits.cursor,0)
    testing.expect(t,len(s.copied)==1 && s.toast_length>0)
}
