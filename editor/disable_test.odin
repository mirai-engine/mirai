package editor

import "core:testing"
import "mirai:core"
import "mirai:editor/history"
import erender "mirai:engine/render"

@(private="file")
Disable_Test_World :: struct {
    using world:core.Test_World,
    using scene_tables:Test_Scene,
    points:core.Table(erender.Point_Light),
}

// Turning a component off and disabling an entity are steps of undo, and the
// values stay.
@(test)
turning_off_and_disabling_are_undone_and_keep_the_values :: proc(t:^testing.T) {
    w:Disable_Test_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    ref:=core.test_world_ref(&w)
    lamp,bulb:=core.create(&w.entities),core.create(&w.entities)
    core.add(&w.ids,lamp,core.Id{1});core.add(&w.ids,bulb,core.Id{2})
    core.add(&w.parents,bulb,core.Parent{lamp,0})
    core.add(&w.points,lamp,erender.Point_Light{intensity=10});core.add(&w.points,bulb,erender.Point_Light{intensity=20})
    core.world_settle(ref)
    selection:history.Selection;defer delete(selection.entities)
    edits:history.Edits;defer history.edits_free(&edits)
    history.edits_reset(&edits,ref)

    core.disable(&w.points,bulb)
    core.world_settle(ref)
    testing.expect(t,history.edits_commit(&edits,ref,&selection))
    testing.expect(t,!core.has(&w.points,bulb) && core.has(&w.points,lamp))
    testing.expect(t,history.undo(&edits,ref,&selection))
    value,on:=core.get(&w.points,bulb)
    testing.expect(t,on && value.intensity==20)
    testing.expect(t,history.redo(&edits,ref,&selection))
    testing.expect(t,!core.has(&w.points,bulb))

    core.add(&w.disabled,lamp,core.Disabled{})
    core.world_settle(ref)
    testing.expect(t,history.edits_commit(&edits,ref,&selection))
    testing.expect_value(t,core.count(&w.points),0)
    testing.expect(t,history.undo(&edits,ref,&selection))
    testing.expect(t,core.has(&w.points,lamp) && !core.has(&w.points,bulb),"the bulb stays off by itself")
    testing.expect(t,history.redo(&edits,ref,&selection))
    testing.expect_value(t,core.count(&w.points),0)

    // Turning on a component of an entity off with the lamp is a step too.
    core.enable(&w.points,bulb)
    core.world_settle(ref)
    testing.expect(t,history.edits_commit(&edits,ref,&selection))
    _,turned_off,_:=core.raw_state(core.raw(&w.points),bulb)
    testing.expect(t,!turned_off)
    testing.expect(t,history.undo(&edits,ref,&selection))
    _,turned_off,_=core.raw_state(core.raw(&w.points),bulb)
    testing.expect(t,turned_off,"the bulb is off by itself again")
    core.remove(&w.disabled,lamp)
    core.world_settle(ref)
    lamp_value,lamp_on:=core.get(&w.points,lamp)
    testing.expect(t,lamp_on && lamp_value.intensity==10 && !core.has(&w.points,bulb))
}
