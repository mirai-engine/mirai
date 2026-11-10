package editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:editor/history"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

@(private="file") Panel_Test_Exposure :: struct {compensation:f32 `mirai:"unit=EV"`,auto:bool}
@(private="file") Panel_Test_Look :: struct {sky:[3]f32 `mirai:"color"`,tint:[3]f32 `mirai:"color"`,group:i32,exposure:Panel_Test_Exposure,secret:f32 `mirai:"hidden"`}
@(private="file") Panel_Test_Quality :: struct {level:i32 `mirai:"min=0,max=3"`,sharp:bool}
@(private="file") Panel_Test_World :: struct {entities:core.Entities,ids:core.Table(core.Id),looks:core.Table(Panel_Test_Look),quality:Panel_Test_Quality}
@(private="file") Panel_Test_Fixture :: struct {
    world:Panel_Test_World,
    tables:[2]core.Table_Info,
    storages:[1]core.Storage_Info,
    info:core.World_Info,
    edits:history.Edits,
    selection:history.Selection,
    session:Session,
    panels:Project_Panels,
    entities:[3]core.Entity, // ids 0x10, 0x20 and 0x30, of groups 1, 2 and 1
}

@(private="file")
panel_test_settle :: proc(data,shared,editor:rawptr) {
    w:=(^Panel_Test_World)(data)
    core.table_settle(&w.ids,&w.entities)
    core.table_settle(&w.looks,&w.entities)
    core.entities_settle(&w.entities)
}

@(private="file")
panel_test_init :: proc(f:^Panel_Test_Fixture) {
    core.entities_init(&f.world.entities)
    core.table_init(&f.world.ids,"Id")
    core.table_init(&f.world.looks,"Look")
    f.tables={
        {name="Id",type=core.Id,info=type_info_of(core.Id),offset=offset_of(Panel_Test_World,ids)},
        {name="Look",type=Panel_Test_Look,info=type_info_of(Panel_Test_Look),offset=offset_of(Panel_Test_World,looks)},
    }
    f.storages={
        {name="Quality",type=Panel_Test_Quality,info=type_info_of(Panel_Test_Quality),offset=offset_of(Panel_Test_World,quality),setting=.Project,default=proc(dst:rawptr) {(^Panel_Test_Quality)(dst)^={level=1}}},
    }
    f.info={entities=offset_of(Panel_Test_World,entities),tables=f.tables[:],storages=f.storages[:]}
    for &e,i in f.entities {
        e=core.create(&f.world.entities)
        core.add(&f.world.ids,e,{value=base.Entity_Id(0x10*(i+1))})
        core.add(&f.world.looks,e,{sky={1,1,1},group=i==1?2:1})
    }
    f.world.quality={level=1}
    panel_test_settle(&f.world,nil,nil)
    f.session=Session{info=&f.info,edit_world=&f.world,edits=&f.edits,selection=&f.selection,panels=&f.panels}
    history.edits_reset(&f.edits,edited_world(&f.session))
}

@(private="file")
panel_test_free :: proc(f:^Panel_Test_Fixture) {
    history.edits_free(&f.edits)
    panels_free(&f.panels)
    delete(f.selection.entities)
    core.table_destroy(&f.world.ids);core.table_destroy(&f.world.looks)
    core.entities_destroy(&f.world.entities)
}

@(private="file")
PANEL_TEST_TEXT :: `{"title": "Lighting lab",
  "buttons": [
    {"name": "Red", "sets": [{"component": "Look", "field": "tint", "where": {"group": 1}, "value": [1, 0, 0]}, {"setting": "Quality", "field": "level", "value": 3}]},
    {"name": "Dusk", "sets": [{"component": "Look", "field": "exposure.compensation", "entity": "0000000000000020", "value": 2}, {"component": "Look", "field": "sky", "where": {}, "value": [0.5, 0.25, 0.1]}]}
  ],
  "rows": [{"heading": "Sky"}, {"component": "Look", "field": "sky", "label": "Sky"}, {"setting": "Quality", "field": "level"}]}`

@(private="file")
// A panel is some 80 KB: on the temp allocator, so a test can hold several.
panel_test_parse :: proc(t:^testing.T,text:string) -> (p:^Project_Panel,message:string) {
    p=new(Project_Panel,context.temp_allocator)
    ok:bool
    message,ok=panel_parse(text,p,nil,nil)
    testing.expect(t,ok==(message==""))
    return
}

// A panel reads its buttons and rows, writes what it read, and says where a
// file is wrong.
@(test)
panels_read_back_what_they_write :: proc(t:^testing.T) {
    p,message:=panel_test_parse(t,PANEL_TEST_TEXT)
    if !testing.expect_value(t,message,"") {return}
    testing.expect_value(t,p.button_count,2)
    testing.expect_value(t,p.row_count,3)
    testing.expect_value(t,p.rows[0].kind,Panel_Row_Kind.Heading)
    red:=&p.buttons[0]
    testing.expect_value(t,red.set_count,2)
    testing.expect_value(t,base.text_get(red.sets[0].match[:]),`{"group": 1}`)
    testing.expect_value(t,base.text_get(red.sets[0].value[:]),"[1, 0, 0]")
    testing.expect_value(t,red.sets[1].kind,Panel_Row_Kind.Setting)
    testing.expect_value(t,p.buttons[1].sets[0].entity,base.Entity_Id(0x20))
    testing.expect_value(t,base.text_get(p.buttons[1].sets[1].match[:]),"{}")
    w:serial.Writer
    serial.writer_init(&w,0,context.temp_allocator)
    panel_write(&w,p)
    again,again_message:=panel_test_parse(t,string(serial.writer_bytes(&w)))
    testing.expect_value(t,again_message,"")
    testing.expect(t,again^==p^,string(serial.writer_bytes(&w)))

    SET :: `{"setting": "Quality", "field": "level", "value": 1}`
    cases:=[?]struct{text,says:string}{
        {`{"rows": [{"heading": "A"}]}`,"title is missing"},
        {`{"title": "A"}`,"a panel has buttons, rows or both"},
        {`{"title": "A", "buttons": [{"sets": [` + SET + `]}]}`,"buttons[0]: name is missing"},
        {`{"title": "A", "buttons": [{"name": "B", "sets": []}]}`,"buttons[0]: sets is empty"},
        {`{"title": "A", "buttons": [{"name": "B", "sets": [{"setting": "Quality", "field": "level"}]}]}`,"buttons[0].sets[0]: value is missing"},
        {`{"title": "A", "buttons": [{"name": "B", "sets": [` + SET + `]}, {"name": "B", "sets": [` + SET + `]}]}`,`buttons[1]: "B" is the name of another button`},
        {`{"title": "A", "buttons": [{"name": "B", "sets": [{"component": "Look", "field": "tint", "entity": "0000000000000010", "where": {}, "value": 1}]}]}`,"entity and where name different entities"},
        {`{"title": "A", "buttons": [{"name": "B", "sets": [{"setting": "Quality", "field": "level", "where": {}, "value": 1}]}]}`,"a setting is of the project"},
        {`{"title": "A", "buttons": [{"name": "B", "sets": [{"component": "Look", "field": "tint", "where": 1, "value": 1}]}]}`,"where is an object"},
        {`{"title": "A", "rows": [{"component": "Look", "field": "tint", "value": 1}]}`,`rows[0]: unknown key "value"`},
        {`{"title": "A", "rows": [{"component": "Look"}]}`,"rows[0]: field is missing"},
        {`{"title": "A", "rows": [{"component": "Look", "setting": "Quality", "field": "x"}]}`,"one of heading, component or setting"},
        {`{"title": "A", "rows": [{"heading": "Sky", "field": "sky"}]}`,"a heading has only its text"},
        {`{"title": "A", "rows": [{"heading": "Sky"}], "colour": 1}`,`unknown key "colour"`},
        {`{"title": "A", "rows": [{"heading": "Sky"},]}`,"rows[1]: a panel is"},
    }
    for c in cases {
        _,says:=panel_test_parse(t,c.text)
        testing.expectf(t,strings.contains(says,c.says),"%s: %q",c.text,says)
    }
    _,with_id:=panel_test_parse(t,`{"id": "lab", "title": "A", "rows": [{"heading": "A"}]}`)
    testing.expect(t,strings.contains(with_id,`unknown key "id"`),"a file has no id: its name is it")
    testing.expect_value(t,panel_id_of("Lighting & Post FX!"),"lighting-post-fx")
    testing.expect(t,panel_id_check("Lab")!="" && panel_id_check("../lab")!="" && panel_id_check("lab-2_b")=="")
}

// A panel as the panel methods answer it has the shape their results declare,
// with buttons and rows or without either.
@(test)
panels_answer_with_the_shape_they_declare :: proc(t:^testing.T) {
    s:=Session{project_root="game"}
    for text in ([]string{PANEL_TEST_TEXT,`{"title": "Sky", "rows": [{"heading": "Sky"}]}`,`{"title": "Red", "buttons": [{"name": "Red", "sets": [{"setting": "Quality", "field": "level", "value": 3}]}]}`}) {
        p,message:=panel_test_parse(t,text)
        if !testing.expect_value(t,message,"") {continue}
        base.text_set(p.id[:],"lab")
        w:serial.Writer
        serial.writer_init(&w,0,context.temp_allocator)
        api_panel_write(&s,&w,p)
        api_result_shape_expect(t,string(serial.writer_bytes(&w)),Api_Panel)
    }
}

// The buttons and rows name what the project has, with the names there are
// when they do not; a button reads every value first, finds the entities its
// where matches when it is pressed, and sets the fields of the scene as one
// undo step and the settings in place.
@(test)
panel_buttons_set_their_fields_as_one_step :: proc(t:^testing.T) {
    f:Panel_Test_Fixture
    panel_test_init(&f);defer panel_test_free(&f)
    s:=&f.session
    w:=edited_world(s)
    rows:=[?]struct{row,says:string}{
        {`{"component": "Looks", "field": "sky"}`,`Looks is not a component of this project; component.list lists the components`},
        {`{"component": "Look", "field": "skies"}`,`Look has no field "skies"; its fields are sky, tint, group, exposure`},
        {`{"component": "Look", "field": "secret"}`,`Look has no field "secret"`},
        {`{"component": "Look", "field": "exposure.speed"}`,`Look.exposure has no field "speed"; its fields are compensation, auto`},
        {`{"component": "Look", "field": "sky.r"}`,`Look.sky has no fields`},
        {`{"component": "Look", "field": "sky", "entity": "00000000000000ff"}`,`00000000000000ff is not an entity of the scene`},
        {`{"setting": "Qualities", "field": "level"}`,`Qualities is not a setting of this project; settings.get lists them`},
    }
    for c in rows {
        p,message:=panel_test_parse(t,fmt.tprintf(`{{"title": "A", "rows": [%s]}}`,c.row))
        if !testing.expectf(t,message=="","%s: %s",c.row,message) {continue}
        says:=panel_check(s,p)
        testing.expectf(t,strings.contains(says,c.says),"%s: %q",c.row,says)
    }
    sets:=[?]struct{set,says:string}{
        {`{"component": "Looks", "field": "tint", "value": 1}`,`buttons[0].sets[0]: Looks is not a component`},
        {`{"component": "Look", "field": "tints", "value": 1}`,`buttons[0].sets[0]: Look has no field "tints"`},
        {`{"component": "Look", "field": "tint", "value": "red"}`,`buttons[0].sets[0].value: Look.tint`},
        {`{"component": "Look", "field": "tint", "where": {"grp": 1}, "value": [1, 0, 0]}`,`buttons[0].sets[0].where: Look has no field "grp"`},
        {`{"component": "Look", "field": "tint", "where": {"group": "one"}, "value": [1, 0, 0]}`,`buttons[0].sets[0].where.group`},
        {`{"component": "Look", "field": "tint", "entity": "00000000000000ff", "value": [1, 0, 0]}`,`00000000000000ff is not an entity of the scene`},
        {`{"setting": "Quality", "field": "level", "value": 9}`,`buttons[0].sets[0].value`},
    }
    for c in sets {
        p,message:=panel_test_parse(t,fmt.tprintf(`{{"title": "A", "buttons": [{{"name": "B", "sets": [%s]}}]}}`,c.set))
        if !testing.expectf(t,message=="","%s: %s",c.set,message) {continue}
        says:=panel_check(s,p)
        testing.expectf(t,strings.contains(says,c.says),"%s: %q",c.set,says)
    }

    {
        off:=`{"name": "Off", "sets": [{"component": "Look", "field": "tint", "where": {}, "value": [0, 0, 0]}, {"component": "Look", "field": "group", "where": {}, "value": 0}]}`
        red:=`{"name": "Red", "sets": [{"component": "Look", "field": "tint", "where": {}, "value": [1, 0, 0]}]}`
        p,_:=panel_test_parse(t,fmt.tprintf(`{{"title": "A", "buttons": [%s, %s]}}`,red,off))
        testing.expect_value(t,panel_check(s,p),"buttons[0] (Red) sets Look but not its group, which buttons[1] (Off) sets: buttons are variants pressed in any order, so give it the value of group it should have")
    }

    p,_:=panel_test_parse(t,PANEL_TEST_TEXT)
    testing.expect_value(t,panel_check(s,p),"")
    tint :: proc(f:^Panel_Test_Fixture,e:core.Entity) -> [3]f32 {return core.get(&f.world.looks,e).tint}
    changed,problem:=panel_press(s,p,0)
    testing.expect_value(t,problem,"")
    testing.expect_value(t,changed,3)
    history.edits_flush(&f.edits,w,&f.selection)
    testing.expect_value(t,tint(&f,f.entities[0]),[3]f32{1,0,0})
    testing.expect_value(t,tint(&f,f.entities[1]),[3]f32{0,0,0})
    testing.expect_value(t,tint(&f,f.entities[2]),[3]f32{1,0,0})
    testing.expect_value(t,f.world.quality.level,i32(3))
    testing.expect(t,history.undo(&f.edits,w,&f.selection))
    testing.expect_value(t,tint(&f,f.entities[0]),[3]f32{0,0,0})
    testing.expect_value(t,tint(&f,f.entities[2]),[3]f32{0,0,0})
    testing.expect(t,!history.undo(&f.edits,w,&f.selection),"a press is one step")

    changed,problem=panel_press(s,p,1)
    testing.expect_value(t,problem,"")
    testing.expect_value(t,changed,4)
    history.edits_flush(&f.edits,w,&f.selection)
    testing.expect_value(t,core.get(&f.world.looks,f.entities[1]).exposure.compensation,f32(2))
    testing.expect_value(t,core.get(&f.world.looks,f.entities[0]).exposure.compensation,f32(0))
    for e in f.entities {testing.expect_value(t,core.get(&f.world.looks,e).sky,[3]f32{0.5,0.25,0.1})}
    testing.expect(t,history.undo(&f.edits,w,&f.selection))
    testing.expect_value(t,core.get(&f.world.looks,f.entities[1]).exposure.compensation,f32(0))
    testing.expect(t,history.redo(&f.edits,w,&f.selection))
    testing.expect_value(t,core.get(&f.world.looks,f.entities[1]).exposure.compensation,f32(2))

    // A where finds the entities when the button is pressed.
    late:=core.create(&f.world.entities)
    core.add(&f.world.ids,late,{value=0x40})
    core.add(&f.world.looks,late,{group=1})
    panel_test_settle(&f.world,nil,nil)
    history.edits_flush(&f.edits,w,&f.selection)
    _,problem=panel_press(s,p,0)
    testing.expect_value(t,problem,"")
    history.edits_flush(&f.edits,w,&f.selection)
    testing.expect_value(t,tint(&f,late),[3]f32{1,0,0})

    // A where no entity matches changes nothing; a value that fails leaves
    // every field as it was.
    none,_:=panel_test_parse(t,`{"title": "A", "buttons": [{"name": "Blue", "sets": [{"component": "Look", "field": "tint", "where": {"group": 7}, "value": [0, 0, 1]}]}]}`)
    base.text_set(none.id[:],"none")
    changed,problem=panel_press(s,none,0)
    testing.expect(t,changed==0 && problem=="",problem)
    testing.expect_value(t,panel_kept_count(&f.panels,none),0)
    bad,_:=panel_test_parse(t,`{"title": "A", "buttons": [{"name": "Blue", "sets": [{"component": "Look", "field": "tint", "where": {}, "value": [0, 0, 1]}, {"setting": "Quality", "field": "level", "value": 7}]}]}`)
    _,problem=panel_press(s,bad,0)
    testing.expect(t,strings.contains(problem,"sets[1]"),problem)
    testing.expect_value(t,tint(&f,f.entities[1]),[3]f32{0,0,0})
}

// A panel is a file of panels/ in the project: it is read again from there
// and its delete takes the file with it.
@(test)
panels_are_kept_in_the_project_and_deleted_with_their_file :: proc(t:^testing.T) {
    f:Panel_Test_Fixture
    panel_test_init(&f);defer panel_test_free(&f)
    folder,_:=os.make_directory_temp("","mirai-editor-panels",context.temp_allocator)
    defer os.remove_all(folder)
    s:=&f.session
    s.project_root=project.path(folder,"game",allocator=context.temp_allocator)
    panels:Project_Panels;defer panels_free(&panels)
    panels_sync(s,&panels)
    testing.expect_value(t,len(panels.list),0)
    p,_:=panel_test_parse(t,PANEL_TEST_TEXT)
    base.text_set(p.id[:],"lab")
    p.open=true
    at,problem:=panel_store(s,&panels,p^)
    testing.expect_value(t,problem,"")
    testing.expect_value(t,at,0)
    testing.expect(t,os.is_file(panel_file(s,"lab")))
    testing.expect(t,os.write_entire_file(panel_file(s,"broken"),transmute([]u8)string(`{"title": 1}`))==nil)

    panels.root=0
    panels_sync(s,&panels)
    if !testing.expect_value(t,len(panels.list),1) {return}
    read:=panels.list[0]
    testing.expect_value(t,base.text_get(read.id[:]),"lab")
    testing.expect(t,!read.open,"a panel opens when it is asked for, not when it is read")
    read.open=true
    testing.expect(t,read==p^)

    testing.expect(t,panel_delete(s,&panels,0))
    testing.expect_value(t,len(panels.list),0)
    testing.expect(t,!os.exists(panel_file(s,"lab")))
}

// Restore puts back every field a panel changed as it was before its first
// change, the entities a where found later included, as one undo step.
@(test)
panel_restore_puts_back_what_it_changed :: proc(t:^testing.T) {
    f:Panel_Test_Fixture
    panel_test_init(&f);defer panel_test_free(&f)
    s:=&f.session
    w:=edited_world(s)
    p,_:=panel_test_parse(t,PANEL_TEST_TEXT)
    base.text_set(p.id[:],"lab")
    _,problem:=panel_press(s,p,0)
    testing.expect_value(t,problem,"")
    history.edits_flush(&f.edits,w,&f.selection)
    late:=core.create(&f.world.entities)
    core.add(&f.world.ids,late,{value=0x40})
    core.add(&f.world.looks,late,{tint={0,1,0},group=1})
    panel_test_settle(&f.world,nil,nil)
    history.edits_flush(&f.edits,w,&f.selection)
    for button in 0..<2 {
        _,problem=panel_press(s,p,button)
        testing.expect_value(t,problem,"")
        history.edits_flush(&f.edits,w,&f.selection)
    }
    testing.expect_value(t,core.get(&f.world.looks,late).tint,[3]f32{1,0,0})
    testing.expect(t,panel_kept_count(&f.panels,p)>0)

    restored,message:=panel_restore(s,p)
    testing.expect_value(t,message,"")
    testing.expect_value(t,restored,panel_test_kept)
    history.edits_flush(&f.edits,w,&f.selection)
    for e in f.entities {
        look:=core.get(&f.world.looks,e)^
        testing.expect_value(t,look.tint,[3]f32{0,0,0})
        testing.expect_value(t,look.sky,[3]f32{1,1,1})
        testing.expect_value(t,look.exposure.compensation,f32(0))
    }
    testing.expect_value(t,core.get(&f.world.looks,late).tint,[3]f32{0,1,0})
    testing.expect_value(t,f.world.quality.level,i32(1))
    testing.expect_value(t,panel_kept_count(&f.panels,p),0)
    testing.expect(t,history.undo(&f.edits,w,&f.selection))
    testing.expect_value(t,core.get(&f.world.looks,late).tint,[3]f32{1,0,0})
    testing.expect_value(t,core.get(&f.world.looks,f.entities[1]).exposure.compensation,f32(2))
}

// Kept: the tint of 0x10, 0x30 and 0x40, the level, the compensation of 0x20
// and the sky of the four.
@(private="file") panel_test_kept :: 3+1+1+4
