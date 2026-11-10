package editor

import "core:testing"
import "mirai:core"
import erender "mirai:engine/render"

@(private="file")
Disable_Test_World :: struct {
    entities:core.Entities,
    ids:core.Table(core.Id),
    parents:core.Table(core.Parent),
    hierarchy:core.Hierarchy,
    disabled:core.Table(core.Disabled),
    points:core.Table(erender.Point_Light),
}

// Turning a component off and disabling an entity are steps of undo, and the
// values stay.
@(test)
turning_off_and_disabling_are_undone_and_keep_the_values :: proc(t:^testing.T) {
    w:Disable_Test_World
    core.entities_init(&w.entities);defer core.entities_destroy(&w.entities)
    defer core.value_free(&w.hierarchy,type_info_of(core.Hierarchy))
    core.table_init(&w.ids,"Id");core.table_init(&w.parents,"Parent");core.table_init(&w.disabled,"Disabled");core.table_init(&w.points,"Point_Light")
    w.ids.base,w.parents.base,w.disabled.base=true,true,true
    defer {core.table_destroy(&w.ids);core.table_destroy(&w.parents);core.table_destroy(&w.disabled);core.table_destroy(&w.points)}
    tables:=[4]core.Table_Info{
        {name="Id",type=core.Id,info=type_info_of(core.Id),offset=offset_of(Disable_Test_World,ids)},
        {name="Parent",type=core.Parent,info=type_info_of(core.Parent),offset=offset_of(Disable_Test_World,parents)},
        {name="Disabled",type=core.Disabled,info=type_info_of(core.Disabled),offset=offset_of(Disable_Test_World,disabled)},
        {name="Point_Light",type=erender.Point_Light,info=type_info_of(erender.Point_Light),offset=offset_of(Disable_Test_World,points)},
    }
    storages:=[1]core.Storage_Info{{name="Hierarchy",type=core.Hierarchy,info=type_info_of(core.Hierarchy),offset=offset_of(Disable_Test_World,hierarchy)}}
    info:=core.World_Info{entities=offset_of(Disable_Test_World,entities),tables=tables[:],storages=storages[:]}
    ref:=core.world_ref(&w,&info)
    lamp,bulb:=core.create(&w.entities),core.create(&w.entities)
    core.add(&w.ids,lamp,core.Id{1});core.add(&w.ids,bulb,core.Id{2})
    core.add(&w.parents,bulb,core.Parent{lamp,0})
    core.add(&w.points,lamp,erender.Point_Light{intensity=10});core.add(&w.points,bulb,erender.Point_Light{intensity=20})
    core.world_settle(ref)
    selection:Selection;defer delete(selection.entities)
    edits:Edits;defer edits_free(&edits)
    edits_reset(&edits,ref)

    core.disable(&w.points,bulb)
    core.world_settle(ref)
    testing.expect(t,edits_commit(&edits,ref,&selection))
    testing.expect(t,!core.has(&w.points,bulb) && core.has(&w.points,lamp))
    testing.expect(t,undo(&edits,ref,&selection))
    value,on:=core.get(core.read(&w.points),bulb)
    testing.expect(t,on && value.intensity==20)
    testing.expect(t,redo(&edits,ref,&selection))
    testing.expect(t,!core.has(&w.points,bulb))

    core.add(&w.disabled,lamp,core.Disabled{})
    core.world_settle(ref)
    testing.expect(t,edits_commit(&edits,ref,&selection))
    testing.expect_value(t,core.count(&w.points),0)
    testing.expect(t,undo(&edits,ref,&selection))
    testing.expect(t,core.has(&w.points,lamp) && !core.has(&w.points,bulb),"the bulb stays off by itself")
    testing.expect(t,redo(&edits,ref,&selection))
    testing.expect_value(t,core.count(&w.points),0)

    // Turning on a component of an entity off with the lamp is a step too.
    core.enable(&w.points,bulb)
    core.world_settle(ref)
    testing.expect(t,edits_commit(&edits,ref,&selection))
    _,turned_off,_:=core.raw_state(core.raw(&w.points),bulb)
    testing.expect(t,!turned_off)
    testing.expect(t,undo(&edits,ref,&selection))
    _,turned_off,_=core.raw_state(core.raw(&w.points),bulb)
    testing.expect(t,turned_off,"the bulb is off by itself again")
    core.remove(&w.disabled,lamp)
    core.world_settle(ref)
    lamp_value,lamp_on:=core.get(core.read(&w.points),lamp)
    testing.expect(t,lamp_on && lamp_value.intensity==10 && !core.has(&w.points,bulb))
}
