package editor

import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:host"

@(test)
copy_and_paste_duplicate_the_copied_roots_as_one_step :: proc(t:^testing.T) {
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
    previous:asset.Scene
    document:=Document{previous=&previous}
    app:host.App
    s:=Session{info=&info,edit_world=&world,edits=&edits,selection=&selection,document=&document,app=&app}
    w:=edited_world(&s)
    edits_reset(&edits,w)
    defer edits_free(&edits)
    defer delete(selection.entities)
    defer delete(s.copied)

    testing.expect(t,action_state(&s,.Copy).disabled)
    testing.expect(t,action_state(&s,.Paste).disabled)
    selection_set(&selection,{original})
    testing.expect(t,action_run(&s,.Copy))
    testing.expect_value(t,len(s.copied),1)
    selection_clear(&selection)
    testing.expect(t,action_run(&s,.Paste))
    edits_flush(&edits,w,&selection)
    testing.expect_value(t,edits.cursor,1)
    testing.expect_value(t,undo_label(&edits),"Paste")
    pasted:=selection_active(&selection)
    testing.expect(t,pasted!=core.NONE && pasted!=original)
    testing.expect_value(t,entity_local(w,pasted).position.x,f32(1))
    testing.expect(t,api_entity_id(w,pasted)!=1)

    // Paste again makes another copy of the same source.
    testing.expect(t,action_run(&s,.Paste))
    edits_flush(&edits,w,&selection)
    testing.expect_value(t,edits.cursor,2)
    testing.expect(t,selection_active(&selection)!=pasted)
    testing.expect_value(t,core.world_entities(w).alive,3)
    testing.expect(t,undo(&edits,w,&selection))
    testing.expect(t,undo(&edits,w,&selection))
    testing.expect_value(t,core.world_entities(w).alive,1)

    // Once the source is gone there is nothing to paste and no step.
    core.destroy(&world.entities,original)
    core.world_settle(w)
    testing.expect(t,action_run(&s,.Paste))
    testing.expect_value(t,edits.cursor,0)
    testing.expect(t,len(s.copied)==1 && s.toast_length>0)
}
