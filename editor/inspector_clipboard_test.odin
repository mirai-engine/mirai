package editor

import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:editor/history"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:ui"

Clipboard_Test_Lamp :: struct {
    color:[3]f32 `mirai:"color"`,
    intensity:f32 `mirai:"min=0"`,
    target:core.Entity,
    mesh:base.Asset_Id,
}

Clipboard_Test_World :: struct {
    using world:core.Test_World,
    ids:core.Table(core.Id),
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    lamps:core.Table(Clipboard_Test_Lamp),
}

Clipboard_Test_Board :: struct {text:[4096]u8,length:int}

@(private="file")
clipboard_test_get :: proc(user:rawptr,buffer:[]u8) -> int {
    b:=cast(^Clipboard_Test_Board)user
    return copy(buffer,b.text[:b.length])
}
@(private="file")
clipboard_test_set :: proc(user:rawptr,text:string) {
    b:=cast(^Clipboard_Test_Board)user
    b.length=copy(b.text[:],text)
}

@(test)
inspector_copies_and_pastes_values_as_the_json_of_the_api :: proc(t:^testing.T) {
    world:Clipboard_Test_World
    if !core.test_world_init(t,&world) {return}
    defer core.test_world_destroy(&world)
    LAMP :: 3
    info:=core.test_world_info(&world)
    a,b,c:=core.create(&world.entities),core.create(&world.entities),core.create(&world.entities)
    for e,i in ([3]core.Entity{a,b,c}) {
        core.add(&world.ids,e,core.Id{base.Entity_Id(i+1)})
        core.add(&world.transforms,e,core.Transform{{1,2,3},mm.quat_from_euler({0,mm.RAD_PER_DEG*90,0}),{2,2,2}} if e==a else core.TRANSFORM_IDENTITY)
    }
    core.add(&world.lamps,a,Clipboard_Test_Lamp{color={1,0.5,0.25},intensity=3,target=c,mesh={7,9}})
    core.add(&world.lamps,b,Clipboard_Test_Lamp{})
    core.test_world_settle(&world)

    board:Clipboard_Test_Board
    ctx:ui.Context
    testing.expect(t,ui.context_init(&ctx,{no_font=true,clipboard_get=clipboard_test_get,clipboard_set=clipboard_test_set,clipboard_user=&board}))
    defer ui.context_destroy(&ctx)
    gui:=Editor_Ui{ctx=&ctx}
    edits:history.Edits
    selection:history.Selection
    viewport:Viewport
    inspector:Inspector
    s:=Session{info=info,edit_world=&world,edits=&edits,selection=&selection,viewport=&viewport,gui=&gui,inspector=&inspector}
    w:=edited_world(&s)
    history.edits_reset(&edits,w)
    defer history.edits_free(&edits)
    defer delete(selection.entities)
    // A paste, and the end of its frame that records the step.
    paste :: proc(s:^Session,menu:Value_Menu) -> string {
        message:=value_paste(s,edited_world(s),menu)
        history.edits_flush(s.edits,edited_world(s),s.selection)
        return message
    }
    clipboard :: proc(b:^Clipboard_Test_Board) -> string {return string(b.text[:b.length])}
    put :: proc(b:^Clipboard_Test_Board,text:string) {b.length=copy(b.text[:],text)}
    lamp :: proc(w:^Clipboard_Test_World,e:core.Entity) -> Clipboard_Test_Lamp {value,_:=core.get(core.read(&w.lamps),e);return value}
    component:=Value_Menu{kind=.Component,table=LAMP}
    color:=Value_Menu{kind=.Field,table=LAMP,offset=int(offset_of(Clipboard_Test_Lamp,color)),info=type_info_of([3]f32)}
    intensity:=Value_Menu{kind=.Field,table=LAMP,offset=int(offset_of(Clipboard_Test_Lamp,intensity)),info=type_info_of(f32)}

    // A component goes under its name, as `components` of the API, with the
    // entity it names by its id.
    history.selection_set(&selection,{a})
    testing.expect_value(t,value_copy(&s,w,component),"Copied ")
    text:=clipboard(&board)
    testing.expectf(t,strings.has_prefix(text,`{"Clipboard_Test_Lamp":{`) && strings.contains(text,"intensity"),"component text: %s",text)
    history.selection_set(&selection,{b})
    testing.expect_value(t,paste(&s,component),"")
    testing.expect_value(t,lamp(&world,b),lamp(&world,a))
    testing.expect_value(t,edits.cursor,1)
    testing.expect(t,history.undo(&edits,w,&selection))
    testing.expect_value(t,lamp(&world,b),Clipboard_Test_Lamp{})

    // A field is its value, and goes to a field of the same type.
    history.selection_set(&selection,{a})
    value_copy(&s,w,color)
    testing.expect_value(t,clipboard(&board),"[1, 0.5, 0.25]")
    history.selection_set(&selection,{b})
    testing.expect_value(t,paste(&s,color),"")
    testing.expect_value(t,lamp(&world,b).color,[3]f32{1,0.5,0.25})
    testing.expect(t,paste(&s,intensity)!="","three numbers are not an intensity")
    // The ranges of the component hold, and nothing is written when they do not.
    cursor:=edits.cursor
    put(&board,"-1")
    testing.expect(t,paste(&s,intensity)!="")
    testing.expect_value(t,edits.cursor,cursor)
    put(&board,"4.5")
    testing.expect_value(t,paste(&s,intensity),"")
    testing.expect_value(t,lamp(&world,b).intensity,f32(4.5))
    // A component without its name takes the fields it names.
    put(&board,`{"intensity":2}`)
    testing.expect_value(t,paste(&s,component),"")
    testing.expect(t,lamp(&world,b).intensity==2 && lamp(&world,b).color==[3]f32{1,0.5,0.25})
    // A reference to an entity that is not in the scene is refused.
    put(&board,`{"Clipboard_Test_Lamp":{"target":"0x00000000000000ff"}}`)
    cursor=edits.cursor
    testing.expect(t,paste(&s,component)!="")
    testing.expect_value(t,edits.cursor,cursor)

    // The Transform reads as the API writes an entity, rotation in degrees.
    history.selection_set(&selection,{a})
    value_copy(&s,w,{kind=.Transform})
    text=clipboard(&board)
    testing.expectf(t,strings.has_prefix(text,`{"position":[1,2,3],"rotation_deg":[`) && strings.has_suffix(text,`"scale":[2,2,2]}`),"transform text: %s",text)
    history.selection_set(&selection,{b,c})
    cursor=edits.cursor
    testing.expect_value(t,paste(&s,{kind=.Transform}),"")
    testing.expect_value(t,edits.cursor,cursor+1)
    for e in ([2]core.Entity{b,c}) {
        local:=entity_local(w,e)
        testing.expect(t,local.position==[3]f32{1,2,3} && local.scale==[3]f32{2,2,2})
        testing.expect(t,abs(mm.quat_to_euler(local.rotation).y-mm.RAD_PER_DEG*90)<1e-3)
    }
    put(&board,"[0,0,45]")
    testing.expect_value(t,paste(&s,{kind=.Transform_Field,transform=.Rotation}),"")
    testing.expect(t,abs(inspector_angles(&inspector,c,entity_local(w,c).rotation).z-45)<1e-3,"the pasted angles are those shown")
    testing.expect_value(t,entity_local(w,c).position,[3]f32{1,2,3})

    // Add component adds what the text names to the entities without it.
    history.selection_set(&selection,{c})
    put(&board,`{"Clipboard_Test_Lamp":{"intensity":5}}`)
    testing.expect_value(t,paste(&s,{kind=.Components}),"")
    testing.expect(t,core.has(core.read(&world.lamps),c) && lamp(&world,c).intensity==5)
    put(&board,`{"Unknown":{}}`)
    testing.expect(t,paste(&s,{kind=.Components})!="")
}
