package ui_inspector_editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:cook/author"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:engine/gui"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// A project whose .ui only the memory of the registry holds, as an editor
// leaves them unsaved.
@(private="file")
Project :: struct {
    root:string,
    assets:host.Assets,
}

@(private="file")
project_init :: proc(t:^testing.T,p:^Project,name:string) -> bool {
    p.root=base.test_folder(t,fmt.tprintf("ui-inspector-%s",name))
    return p.root!="" && testing.expect(t,host.assets_init(&p.assets,{root=p.root,capacity=8}))
}

@(private="file")
project_destroy :: proc(p:^Project) {
    host.assets_destroy(&p.assets)
}

// Writes records to path as the .ui id; imports as host.ui_tree_imports reads them.
@(private="file")
project_put :: proc(t:^testing.T,p:^Project,path:string,id:base.Asset_Id,data:ui.Tree_Data,imports:[]ui.Tree_Data={},loc:=#caller_location) -> bool {
    bytes,error:=host.ui_tree_bytes(&p.assets.types,id,data,imports,context.temp_allocator)
    if !testing.expect_value(t,error,asset.Error.None,loc=loc) {return false}
    return testing.expect_value(t,asset.registry_memory_set(&p.assets.registry,path,bytes),asset.Error.None,loc=loc)
}

@(private="file")
project_records :: proc(t:^testing.T,p:^Project,id:base.Asset_Id,r:^author.Records,loc:=#caller_location) -> bool {
    return testing.expect(t,author.records_read(author.assets_of(&p.assets),id,r,context.temp_allocator),"the .ui reads",loc=loc)
}

// ---------------------------------------------------------------- texts

@(private="file") MENU_ID :: base.Asset_Id{0x3e,1}
@(private="file") GAME_LANGUAGES :: gui.Languages{.English,.Spanish,.French}

// A menu with two localized texts, one with no Spanish, and one that is not.
@(private="file")
menu_records :: proc(t:^testing.T,r:^author.Records,translated:bool) -> bool {
    texts:=make([dynamic]u8,context.temp_allocator)
    nodes:=[]ui.Tree_Node{
        ui.tree_node_record(&texts,-1,{kind=.Box,name="menu"}),
        ui.tree_node_record(&texts,0,{kind=.Text,name="play",text="Play, \"now\"\nor later",flags={.Localized},text_id=0xa1}),
        ui.tree_node_record(&texts,0,{kind=.Button,name="quit,all",text="Quit",flags={.Localized},text_id=0xb2}),
        ui.tree_node_record(&texts,0,{kind=.Text,name="hint",text="Not localized"}),
    }
    if !testing.expect(t,author.records_load(r,{text=texts[:],nodes=nodes,styles={{}}},context.temp_allocator)) {return false}
    if translated {
        node_text_set(r,&r.nodes[1],1,.Spanish,.English,"Jugar, \"ya\"\r\no luego")
        node_text_set(r,&r.nodes[1],1,.French,.English,"Jouer")
        node_text_set(r,&r.nodes[2],2,.French,.English,"Quitter")
    }
    return true
}

// The rows of the CSV of a menu, parsed as ui.text.import reads them.
@(private="file")
menu_csv :: proc(r:^author.Records) -> (text:string,rows:[][]string,count:int) {
    order:=texts_csv_order(GAME_LANGUAGES,.English)
    b:=strings.builder_make(context.temp_allocator)
    texts_csv_header(&b,order)
    count=texts_csv_file(&b,"ui/menu, main.ui",MENU_ID,r,order,.English)
    text=strings.to_string(b)
    return text,csv_rows(text),count
}

// The rows after the first, accepted against the registry; why of each rejected.
@(private="file")
csv_accept :: proc(p:^Project,rows:[][]string,rejected:^[dynamic]Texts_Rejected) -> []Texts_Row {
    accepted:=make([dynamic]Texts_Row,context.temp_allocator)
    for row,i in rows[1:] {
        if len(row)==1 && row[0]=="" {continue}
        parsed,why:=texts_csv_row(&p.assets.registry,row,i+2,len(rows[0]))
        if why!="" {append(rejected,Texts_Rejected{i+2,why});continue}
        append(&accepted,parsed)
    }
    return accepted[:]
}

@(test)
texts_go_to_a_csv_and_back_with_commas_quotes_and_lines :: proc(t:^testing.T) {
    p:Project
    if !project_init(t,&p,"texts") {return}
    defer project_destroy(&p)
    source:author.Records
    if !menu_records(t,&source,true) {return}
    if !project_put(t,&p,"ui/menu.ui",MENU_ID,author.records_data(&source)) {return}

    text,rows,count:=menu_csv(&source)
    testing.expect_value(t,count,2)
    if !testing.expect_value(t,len(rows),3) {return}
    testing.expect_value(t,strings.join(rows[0],"|",context.temp_allocator),"file|asset|node|id|en|es|fr")
    testing.expect_value(t,rows[1][0],"ui/menu, main.ui")
    testing.expect_value(t,rows[1][3],"00000000000000a1")
    testing.expect_value(t,rows[1][4],"Play, \"now\"\nor later")
    testing.expect_value(t,rows[1][5],"Jugar, \"ya\"\r\no luego")
    testing.expect_value(t,rows[2][2],"quit,all")
    testing.expect_value(t,rows[2][5],"")
    testing.expect_value(t,rows[2][6],"Quitter")
    testing.expect(t,strings.contains(text,`"Play, ""now""`),"A quote inside a field is doubled")

    // The same CSV into the menu without translations gives back every text.
    target:author.Records
    if !menu_records(t,&target,false) {return}
    columns,why:=texts_csv_columns(rows,GAME_LANGUAGES)
    if !testing.expect_value(t,why,"") {return}
    rejected:=make([dynamic]Texts_Rejected,context.temp_allocator)
    accepted:=csv_accept(&p,rows,&rejected)
    testing.expect_value(t,len(accepted),2)
    testing.expect(t,texts_csv_apply(&target,MENU_ID,accepted,columns,.English,&rejected))
    testing.expect_value(t,len(rejected),0)
    for row in 0..<len(source.nodes) {
        for language in GAME_LANGUAGES {
            testing.expectf(t,node_text_in(&target,&target.nodes[row],language,.English)==node_text_in(&source,&source.nodes[row],language,.English),"node %d in %v",row,language)
        }
    }
    again_text,_,_:=menu_csv(&target)
    testing.expect_value(t,again_text,text)

    // An empty cell changes nothing; another text replaces the one there.
    rows[1][5]=""
    rows[1][6]="Jouer, enfin"
    rows[2][4]=""
    accepted=csv_accept(&p,rows,&rejected)
    testing.expect(t,texts_csv_apply(&target,MENU_ID,accepted,columns,.English,&rejected))
    testing.expect_value(t,node_text_in(&target,&target.nodes[1],.Spanish,.English),"Jugar, \"ya\"\r\no luego")
    testing.expect_value(t,node_text_in(&target,&target.nodes[1],.French,.English),"Jouer, enfin")
    testing.expect_value(t,node_text_in(&target,&target.nodes[2],.English,.English),"Quit")
    testing.expect_value(t,node_text_in(&target,&target.nodes[2],.Spanish,.English),"")

    // Lines a spreadsheet ends with \r\n, and a last one without its end.
    crlf:=fmt.tprintf("file,asset,node,id,en,es\r\nui/menu.ui,%s,play,00000000000000a1,,\"Sí, \"\"ya\"\"\"",rows[1][1])
    parsed:=csv_rows(crlf)
    if testing.expect_value(t,len(parsed),2) && testing.expect_value(t,len(parsed[1]),6) {
        testing.expect_value(t,parsed[0][5],"es")
        testing.expect_value(t,parsed[1][5],"Sí, \"ya\"")
    }
}

@(test)
a_csv_of_texts_says_why_it_refuses_a_language_the_game_lacks_and_rows_of_no_text :: proc(t:^testing.T) {
    p:Project
    if !project_init(t,&p,"texts-refused") {return}
    defer project_destroy(&p)
    r:author.Records
    if !menu_records(t,&r,true) {return}
    if !project_put(t,&p,"ui/menu.ui",MENU_ID,author.records_data(&r)) {return}
    _,rows,_:=menu_csv(&r)

    // A column of a language the game is not in.
    _,why:=texts_csv_columns(rows,{.English,.Spanish})
    testing.expect(t,strings.contains(why,"column fr") && strings.contains(why,"Project Settings > UI"),why)
    _,why=texts_csv_columns(rows,{.English,.Spanish,.French,.German})
    testing.expect_value(t,why,"")
    _,why=texts_csv_columns({{"asset","file","node","id","en"}},GAME_LANGUAGES)
    testing.expect(t,strings.contains(why,"file,asset,node,id"),why)

    id:[32]u8
    menu:=base.asset_id_format(MENU_ID,id[:])
    other:[32]u8
    unknown:=base.asset_id_format({0x99,9},other[:])
    csv:=fmt.tprintf("file,asset,node,id,en,es,fr\nui/menu.ui,%s,play,00000000000000a1,,Jugar,\n" +
        "ui/menu.ui,not-an-id,play,00000000000000a1,,,\n" +
        "ui/gone.ui,%s,play,00000000000000a1,,,\n" +
        "ui/menu.ui,%s,play,00000000000000A1,,,\n" +
        "ui/menu.ui,%s,play,0000000000000000,,,\n" +
        "ui/menu.ui,%s,play\n" +
        "ui/menu.ui,%s,hint,00000000000000c3,,Pista,\n",menu,unknown,menu,menu,menu,menu)
    parsed:=csv_rows(csv)
    columns,columns_why:=texts_csv_columns(parsed,GAME_LANGUAGES)
    if !testing.expect_value(t,columns_why,"") {return}
    rejected:=make([dynamic]Texts_Rejected,context.temp_allocator)
    accepted:=csv_accept(&p,parsed,&rejected)
    testing.expect(t,texts_csv_apply(&r,MENU_ID,accepted,columns,.English,&rejected))
    testing.expect_value(t,node_text_in(&r,&r.nodes[1],.Spanish,.English),"Jugar")
    testing.expect_value(t,node_text_in(&r,&r.nodes[3],.Spanish,.English),"")
    if !testing.expect_value(t,len(rejected),6) {return}
    expected:=[6]struct{line:int,says:string}{
        {3,"is not an asset id"},{4,"is not a .ui of the project"},{5,"16 hexadecimal digits"},
        {6,"16 hexadecimal digits"},{7,"fewer columns"},{8,"no localized node with id 00000000000000c3"},
    }
    for e,i in expected {
        testing.expect_value(t,rejected[i].line,e.line)
        testing.expect(t,strings.contains(rejected[i].reason,e.says),rejected[i].reason)
    }
}

// ---------------------------------------------------------------- renames

@(private="file") CARD_ID :: base.Asset_Id{0xca,1}   // a widget: card > label
@(private="file") SLOT_ID :: base.Asset_Id{0x5107,1} // an instance of card, slot, that overrides label
@(private="file") SCREEN_ID :: base.Asset_Id{0x5c,1} // an instance of the slot one, outer, that overrides slot/label
@(private="file") PANEL_ID :: base.Asset_Id{0xba,1}  // another widget with a label
@(private="file") OTHER_ID :: base.Asset_Id{0x07,1}  // an instance of panel that overrides its label

@(private="file")
widget_data :: proc(root,child:string) -> ui.Tree_Data {
    texts:=make([dynamic]u8,context.temp_allocator)
    nodes:=make([]ui.Tree_Node,2,context.temp_allocator)
    nodes[0]=ui.tree_node_record(&texts,-1,{kind=.Box,name=root})
    nodes[1]=ui.tree_node_record(&texts,0,{kind=.Text,name=child,text="Label"})
    return {text=texts[:],nodes=nodes,styles=make([]ui.Node_Style,1,context.temp_allocator)}
}

// A root with an instance of widget that overrides the text of target.
@(private="file")
instance_data :: proc(instance:string,widget:base.Asset_Id,target:string) -> ui.Tree_Data {
    texts:=make([dynamic]u8,context.temp_allocator)
    nodes:=make([]ui.Tree_Node,2,context.temp_allocator)
    nodes[0]=ui.tree_node_record(&texts,-1,{kind=.Box,name="root"})
    nodes[1]=ui.tree_node_record(&texts,0,{kind=.Component,name=instance,component=1})
    components:=make([]ui.Tree_Component,1,context.temp_allocator)
    components[0]=ui.tree_component_record("widget",0,0)
    components[0].widget=widget
    overrides:=make([]ui.Tree_Override,1,context.temp_allocator)
    overrides[0]=ui.tree_override_record(&texts,1,target,{.Text},{text="Mine"})
    return {text=texts[:],nodes=nodes,styles=make([]ui.Node_Style,1,context.temp_allocator),components=components,overrides=overrides}
}

@(private="file")
override_of :: proc(r:^author.Records) -> string {return serial.text_field(r.overrides[0].node[:])}

// Whether records of a .ui load with the widgets the registry has for them.
@(private="file")
loads :: proc(p:^Project,id:base.Asset_Id,r:^author.Records) -> bool {
    data:=author.records_data(r)
    imports,ok:=host.ui_tree_imports(&p.assets,data)
    if !ok {return false}
    _,error:=host.ui_tree_bytes(&p.assets.types,id,data,imports,context.temp_allocator)
    return error==.None
}

@(test)
a_renamed_node_renames_the_overrides_of_the_interfaces_that_use_its_widget :: proc(t:^testing.T) {
    p:Project
    if !project_init(t,&p,"rename") {return}
    defer project_destroy(&p)
    card,panel:=widget_data("card","label"),widget_data("panel","label")
    slot:=instance_data("slot",CARD_ID,"label")
    linked_slot,linked:=ui.tree_link(slot,{card})
    if !testing.expect(t,linked) {return}
    ok:=project_put(t,&p,"card.ui",CARD_ID,card) && project_put(t,&p,"slot.ui",SLOT_ID,slot,{card}) &&
        project_put(t,&p,"screen.ui",SCREEN_ID,instance_data("outer",SLOT_ID,"slot/label"),{linked_slot}) &&
        project_put(t,&p,"panel.ui",PANEL_ID,panel) && project_put(t,&p,"other.ui",OTHER_ID,instance_data("other",PANEL_ID,"label"),{panel})
    if !ok {return}

    // label of card becomes caption: what names it through card follows, the label of panel does not.
    renamed:=[2]author.Records{}
    for id,i in ([2]base.Asset_Id{SLOT_ID,SCREEN_ID}) {
        if !project_records(t,&p,id,&renamed[i]) {return}
        testing.expect_value(t,records_rename_follow(&p.assets,&renamed[i],CARD_ID,"label","caption"),1)
    }
    testing.expect_value(t,override_of(&renamed[0]),"caption")
    testing.expect_value(t,override_of(&renamed[1]),"slot/caption")
    other:author.Records
    if !project_records(t,&p,OTHER_ID,&other) {return}
    testing.expect_value(t,records_rename_follow(&p.assets,&other,CARD_ID,"label","caption"),0)
    testing.expect_value(t,override_of(&other),"label")
    testing.expect_value(t,records_rename_follow(&p.assets,&renamed[0],CARD_ID,"capt","x"),0)

    // With card renamed, what followed loads and what did not follow does not.
    if !project_put(t,&p,"card.ui",CARD_ID,widget_data("card","caption")) {return}
    stale:author.Records
    if !project_records(t,&p,SLOT_ID,&stale) {return}
    testing.expect(t,!loads(&p,SLOT_ID,&stale),"An override of a node the widget no longer has does not load")
    testing.expect(t,loads(&p,SLOT_ID,&renamed[0]))
    if !project_put(t,&p,"slot.ui",SLOT_ID,author.records_data(&renamed[0]),{widget_data("card","caption")}) {return}
    testing.expect(t,loads(&p,SCREEN_ID,&renamed[1]))

    // The instance inside the widget renamed: the path follows in its first part.
    screen:author.Records
    if !project_records(t,&p,SCREEN_ID,&screen) {return}
    testing.expect_value(t,records_rename_follow(&p.assets,&screen,SLOT_ID,"slot","socket"),1)
    testing.expect_value(t,override_of(&screen),"socket/label")
    testing.expect_value(t,records_rename_follow(&p.assets,&screen,CARD_ID,"slot","socket"),0)
}

// ---------------------------------------------------------------- check

@(private="file") USES_ID :: base.Asset_Id{0x05e5,1}  // uses the widget and binds one path of its own
@(private="file") ALONE_ID :: base.Asset_Id{0xa1,1}   // binds a path, no widgets
@(private="file") QUIET_ID :: base.Asset_Id{0x9e,1}   // binds nothing

@(private="file")
bound_data :: proc(kind:ui.Node_Kind,name,path:string) -> ui.Tree_Data {
    texts:=make([dynamic]u8,context.temp_allocator)
    nodes:=make([]ui.Tree_Node,2,context.temp_allocator)
    nodes[0]=ui.tree_node_record(&texts,-1,{kind=.Box,name="root"})
    nodes[1]=ui.tree_node_record(&texts,0,{kind=kind,name=name,bind_text=path if kind==.Text else "",bind_value=path if kind!=.Text else ""})
    return {text=texts[:],nodes=nodes,styles=make([]ui.Node_Style,1,context.temp_allocator)}
}

@(private="file")
Problem_Key :: struct {asset:base.Asset_Id,row,node:int,binding:ui.Binding,fault:author.Bind_Fault,path:string}

// Whether two lists have the same problems, in any order.
@(private="file")
same_problems :: proc(a,b:[]author.Bind_Problem) -> bool {
    key :: proc(p:^author.Bind_Problem) -> Problem_Key {return {p.asset,p.row,p.node,p.binding,p.fault,serial.text_field(p.path[:])}}
    if len(a)!=len(b) {return false}
    taken:=make([]bool,len(b),context.temp_allocator)
    outer: for &x in a {
        for &y,i in b {
            if !taken[i] && key(&x)==key(&y) {taken[i]=true;continue outer}
        }
        return false
    }
    return true
}

@(private="file")
full_check :: proc(p:^Project) -> []author.Bind_Problem {
    types:author.Bind_Types
    defer author.bind_types_free(&types)
    problems:=make([dynamic]author.Bind_Problem,context.temp_allocator)
    author.bind_check_all(&problems,&types,context.allocator,author.assets_of(&p.assets),nil)
    return problems[:]
}

@(private="file") MARK :: -77

@(test)
the_check_of_interfaces_reads_again_only_what_changed_and_finds_what_the_full_check_finds :: proc(t:^testing.T) {
    p:Project
    if !project_init(t,&p,"check") {return}
    defer project_destroy(&p)
    widget:=bound_data(.Text,"label","Game.title")
    uses:=instance_data("slot",CARD_ID,"label")
    progress:=[3]ui.Tree_Node{uses.nodes[0],uses.nodes[1],{}}
    texts:=make([dynamic]u8,context.temp_allocator)
    append(&texts,..uses.text)
    progress[2]=ui.tree_node_record(&texts,0,{kind=.Progress,name="health",bind_value="Game.health"})
    uses.nodes,uses.text=progress[:],texts[:]
    ok:=project_put(t,&p,"card.ui",CARD_ID,widget) && project_put(t,&p,"uses.ui",USES_ID,uses,{widget}) &&
        project_put(t,&p,"alone.ui",ALONE_ID,bound_data(.Text,"clock","Game.time")) && project_put(t,&p,"quiet.ui",QUIET_ID,bound_data(.Spacer,"gap",""))
    if !ok {return}

    u:=new(Ui_Inspector,context.temp_allocator)
    defer {delete(u.problems);delete(u.checked);delete(u.checked_uses);author.bind_types_free(&u.bind_types)}
    testing.expect(t,bind_check_changed(u,context.allocator,&p.assets,nil,true))
    testing.expect(t,same_problems(u.problems[:],full_check(&p)),"The first check finds what the full one finds")
    testing.expect_value(t,bind_files(u.problems[:]),3)
    testing.expect_value(t,len(u.checked),4)

    // Nothing changed: nothing is read.
    loads:=p.assets.stats.loads
    testing.expect(t,!bind_check_changed(u,context.allocator,&p.assets,nil,false))
    testing.expect_value(t,p.assets.stats.loads,loads)

    // The widget changes: it and what uses it are checked again, the rest keeps what it found.
    for &problem in u.problems {problem.node=MARK}
    if !project_put(t,&p,"card.ui",CARD_ID,bound_data(.Text,"label","Game.name")) {return}
    testing.expect(t,bind_check_changed(u,context.allocator,&p.assets,nil,false))
    for &problem in u.problems {
        testing.expectf(t,(problem.node==MARK)==(problem.asset==ALONE_ID),"%v checked again: %v",problem.asset,problem.node!=MARK)
        if problem.asset==CARD_ID {testing.expect_value(t,serial.text_field(problem.path[:]),"Game.name")}
    }
    for &problem in u.problems {
        if problem.node!=MARK {continue}
        // What was not checked again holds what the first check found.
        for &first in full_check(&p) {if first.asset==problem.asset {problem.node=first.node}}
    }
    testing.expect(t,same_problems(u.problems[:],full_check(&p)),"After a change it finds what the full check finds")

    // A .ui that goes is checked no more; another build checks every one again.
    testing.expect_value(t,asset.registry_memory_remove(&p.assets.registry,"alone.ui"),asset.Error.None)
    testing.expect(t,bind_check_changed(u,context.allocator,&p.assets,nil,false))
    testing.expect_value(t,len(u.checked),3)
    testing.expect_value(t,bind_files(u.problems[:]),2)
    testing.expect(t,same_problems(u.problems[:],full_check(&p)))
    for &problem in u.problems {problem.node=MARK}
    testing.expect(t,bind_check_changed(u,context.allocator,&p.assets,nil,true))
    for &problem in u.problems {testing.expect(t,problem.node!=MARK,"Another build checks every .ui again")}
}

// ---------------------------------------------------------------- widgets

@(private="file") THEME_FILE_ID :: base.Asset_Id{0xfe,1}
@(private="file") ROW_ID :: base.Asset_Id{0xa0,1}
@(private="file") OUTER_ID :: base.Asset_Id{0xa1,1}
@(private="file") SCREEN_FILE_ID :: base.Asset_Id{0xa2,1}

// The params of a reading read against the types of the assets, with no file.
@(private="file")
call_args :: proc(reading:^author.Reading,types:^asset.Types,params:string) -> author.Tree_Args {
    reading^={raw=params,allocator=context.temp_allocator}
    args:=author.Tree_Args{reading=reading,types=types}
    args.keys,args.values,_=author.tree_object(reading,params,"params")
    return args
}

// Writes a document as the file path, id, through the same route as ui.write.
@(private="file")
project_doc :: proc(t:^testing.T,p:^Project,path:string,id:base.Asset_Id,text:string,loc:=#caller_location) -> (r:author.Records,ok:bool) {
    empty:=[1]ui.Node_Style{{}}
    if !testing.expect(t,author.records_load(&r,{styles=empty[:]},context.temp_allocator),loc=loc) {return}
    reading:author.Reading
    args:=call_args(&reading,&p.assets.types,"{}")
    args.assets=author.assets_of(&p.assets)
    args.asset=id
    if _,_,applied:=author.document_apply(&args,&r,-1,text);!testing.expectf(t,applied,"%s",reading.problem,loc=loc) {return}
    imports,imported:=host.ui_tree_imports(&p.assets,author.records_data(&r))
    if !testing.expectf(t,imported,"%s does not read what it uses",path,loc=loc) {return}
    bytes,error:=author.records_commit(&p.assets.types,id,&r,imports)
    if !testing.expect_value(t,error,asset.Error.None,loc=loc) {return}
    return r,testing.expect_value(t,asset.registry_memory_set(&p.assets.registry,path,bytes),asset.Error.None,loc=loc)
}

@(private="file")
doc_text :: proc(p:^Project,r:^author.Records) -> string {
    buffer:=make([]u8,1<<16,context.temp_allocator)
    w:serial.Writer
    serial.writer_init_fixed(&w,buffer)
    reading:author.Reading
    args:=call_args(&reading,&p.assets.types,"{}")
    args.assets=author.assets_of(&p.assets)
    libs:=author.doc_libs(&args,r)
    author.document_write(&w,&p.assets.types,r,-1,libs[:],author.assets_of(&p.assets))
    return string(serial.writer_bytes(&w))
}

@(private="file") WIDGET_THEME :: `{"tokens":{"ink":"#102030"},"styles":{"row":{"width":"grow","gap":22},"label":{"size":12,"color":"ink"},"knob":{"size":14,"color":"ink"}}}`
@(private="file") WIDGET_ROW :: `{"use":["ui/theme.ui"],"params":{"label":"label.text","options":"control.text","bind":"data"},"nodes":[{"name":"row","kind":"Box","style":"row","children":[{"name":"label","kind":"Text","style":"label"},{"name":"control","kind":"Selector","style":"knob","bind_value":"@"}]}]}`
@(private="file") WIDGET_OUTER :: `{"use":["ui/select_row.ui"],"params":{"heading":"inner.label","dim":"bind_visible"},"nodes":[{"name":"outer","kind":"Box","slot":true,"children":[{"name":"inner","kind":"select_row","options":"A|B","bind":"Game.a"}]}]}`
@(private="file") WIDGET_SCREEN :: `{"use":["ui/outer.ui","ui/select_row.ui"],"nodes":[{"name":"root","kind":"Box","children":[{"name":"first","kind":"outer","heading":"Hello","children":[{"name":"held","kind":"Button","text":"Ok"}]},{"name":"second","kind":"select_row","label":"Volume","options":"Low|High","bind":"Game.volume"}]}]}`

@(private="file")
widgets_project :: proc(t:^testing.T,p:^Project,name:string) -> (screen:author.Records,ok:bool) {
    if !project_init(t,p,name) {return}
    project_doc(t,p,"ui/theme.ui",THEME_FILE_ID,WIDGET_THEME) or_return
    project_doc(t,p,"ui/select_row.ui",ROW_ID,WIDGET_ROW) or_return
    project_doc(t,p,"ui/outer.ui",OUTER_ID,WIDGET_OUTER) or_return
    return project_doc(t,p,"ui/screen.ui",SCREEN_FILE_ID,WIDGET_SCREEN)
}

@(test)
what_make_widget_declares_and_what_a_person_changes :: proc(t:^testing.T) {
    texts:=make([dynamic]u8,context.temp_allocator)
    nodes:=[]ui.Tree_Node{
        ui.tree_node_record(&texts,-1,{kind=.Box,name="hud"}),
        ui.tree_node_record(&texts,0,{kind=.Box,name="card"}),
        ui.tree_node_record(&texts,1,{kind=.Text,name="title",text="Hi"}),
        ui.tree_node_record(&texts,1,{kind=.Progress,name="fuel",bind_value="Game.fuel"}),
        ui.tree_node_record(&texts,1,{kind=.Box,name="content"}),
    }
    r,widget:author.Records
    testing.expect(t,author.records_load(&r,{text=texts[:],nodes=nodes,styles={{}}},context.temp_allocator))
    testing.expect(t,author.records_widget_data(&r,1,&widget,context.temp_allocator))
    if !testing.expect_value(t,len(widget.params),2) {return}
    testing.expect_value(t,serial.text_field(widget.params[0].name[:]),"title")
    testing.expect_value(t,widget.params[0].field,ui.Tree_Param_Field.Text)
    testing.expect_value(t,serial.text_field(widget.params[1].node[:]),"fuel")
    testing.expect_value(t,widget.params[1].field,ui.Tree_Param_Field.Bind_Value)
    at:=author.records_param_add(&widget)
    testing.expect_value(t,serial.text_field(widget.params[at].name[:]),"param1")
    ui.tree_text_set(widget.params[at].name[:],"text")
    testing.expect(t,author.records_param_valid_name(&widget,at)!="","a key of a node is no parameter")
    ui.tree_text_set(widget.params[at].name[:],"note")
    author.records_param_target(&widget,at,"title",.Bind_Text,"")
    testing.expect_value(t,serial.text_field(widget.params[at].node[:]),"title")
    testing.expect_value(t,author.records_slot_set(&widget,3,true),"")
    testing.expect(t,.Slot in widget.nodes[3].flags)
    testing.expect(t,author.records_slot_set(&widget,1,true)!="","a node before the last is no slot")
    testing.expect_value(t,author.records_slot_set(&widget,0,true),"")
    testing.expect(t,.Slot not_in widget.nodes[3].flags && .Slot in widget.nodes[0].flags,"one slot")
    ordered_remove(&widget.params,at)
    testing.expect_value(t,len(widget.params),2)
    // A renamed node takes the parameters that go to it along.
    ui.tree_text_set(widget.nodes[1].name[:],"caption")
    author.records_rename(&widget,1,"title")
    testing.expect_value(t,serial.text_field(widget.params[0].node[:]),"caption")
}

// ---------------------------------------------------------------- the paths a write binds

@(private="file") Game_Slot :: struct {label:[16]u8,count:i32}
@(private="file") Game_Status :: struct {health:f32,hits:i32,message:[32]u8,slots:[3]Game_Slot}
@(private="file") Game_Hotbar :: struct {slots:[3]Game_Slot,chosen:i32}
@(private="file") Game_Enemy :: struct {label:[16]u8,health:f32}
@(private="file")
Game_World :: struct {
    using world:core.Test_World,
    status:core.Table(Game_Status) `mirai:"game,name=Status"`,
    enemies:core.Table(Game_Enemy) `mirai:"game,name=Enemy"`,
    hotbar:Game_Hotbar `mirai:"game,name=Hotbar"`,
}

@(private="file") STAT_ID :: base.Asset_Id{0x57a7,1}
@(private="file") HUD_ID :: base.Asset_Id{0x4d,1}
@(private="file") STALE_ID :: base.Asset_Id{0x57a1e,1}

// A widget whose paths only its uses know: with @, inside a List of one and in the braces of a text.
@(private="file") PATHS_STAT :: `{"params":{"label":"name.text","value":"amount.bind_text","of":"data"},"nodes":[{"name":"stat","kind":"Box","children":[{"name":"name","kind":"Text"},{"name":"amount","kind":"Text"},{"name":"now","kind":"Text","text":"{now} now","fields":[{"name":"now","path":"@hits"}]},{"name":"bar","kind":"Progress","bind_value":"@health"},{"name":"rows","kind":"List","bind_items":"@slots","children":[{"name":"row","kind":"Text","bind_text":"label"}]}]}]}`
@(private="file") PATHS_HUD :: `{"use":["hud/stat.ui"],"nodes":[{"name":"root","kind":"Box","children":[` +
    `{"name":"health","kind":"Progress","bind_value":"Status.health"},` +
    `{"name":"second","kind":"Text","bind_text":"Hotbar.slots.1.count"},` +
    `{"name":"count","kind":"Text","text":"{hits} hits","fields":[{"name":"hits","path":"Status.hits"}]},` +
    `{"name":"slots","kind":"List","bind_items":"Hotbar.slots","children":[{"name":"slot","kind":"Text","bind_text":"label"}]},` +
    `{"name":"enemies","kind":"List","bind_items":"Enemy","children":[{"name":"enemy","kind":"Progress","bind_value":"health"}]},` +
    `{"name":"hits","kind":"stat","label":"Hits","value":"Status.hits","of":"Status"}]}]}`
// Written before the game lost a field: one path of it resolves no more.
@(private="file") PATHS_STALE :: `{"styles":{"plain":{"size":12}},"nodes":[{"name":"root","kind":"Box","children":[{"name":"old","kind":"Progress","bind_value":"Status.fuel"},{"name":"fresh","kind":"Text","style":"plain"}]}]}`

@(private="file")
paths_hud :: proc(node:string) -> string {
    return strings.concatenate({`{"use":["hud/stat.ui"],"nodes":[{"name":"root","kind":"Box","children":[`,node,`]}]}`},context.temp_allocator)
}

@(test)
a_write_refuses_the_paths_the_game_lacks_and_changes_nothing :: proc(t:^testing.T) {
    p:Project
    if !project_init(t,&p,"paths") {return}
    defer project_destroy(&p)
    info,described:=core.test_info(t,Game_World)
    if !described {return}
    defer core.test_info_destroy(&info)
    app:=host.App{allocator=context.allocator,assets=&p.assets,info=&info}
    s:=editor.Session{app=&app,assets_root=p.root,headless=true}
    write :: proc(s:^editor.Session,file,node,document:string) -> (message:string,ok:bool) {
        named:=fmt.tprintf(`"node":%q,`,node) if node!="" else ""
        params:=strings.concatenate({`{"asset":"`,file,`",`,named,`"document":`,document,"}"},context.temp_allocator)
        answer:Tree_Write_Answer
        method:=api.Method{result_id=Tree_Write_Answer}
        call:=api.Call{method=&method,raw=params,result=&answer,allocator=context.temp_allocator}
        api_tree_write(s,&call)
        return call.error.message,!call.failed && answer.ok
    }
    // What the files hold before: saved, with nothing waiting for Save.
    files:=[?]struct{path:string,id:base.Asset_Id,document:string}{{"hud/stat.ui",STAT_ID,PATHS_STAT},{"hud/hud.ui",HUD_ID,PATHS_HUD},{"hud/stale.ui",STALE_ID,PATHS_STALE}}
    for f in files {
        if _,made:=project_doc(t,&p,f.path,f.id,f.document);!made {return}
        if !testing.expect_value(t,asset.registry_memory_write(&p.assets.registry,f.path),asset.Error.None) {return}
    }
    host.assets_scan(&p.assets)
    saved :: proc(p:^Project,path:string) -> string {
        bytes,_:=os.read_entire_file(fmt.tprintf("%s/%s",p.root,path),context.temp_allocator)
        return string(bytes)
    }
    hud_before:=saved(&p,"hud/hud.ui")
    if !testing.expect(t,hud_before!="") {return}

    refused:=[?]struct{asset,node,document:string,says:[]string}{
        {"hud/hud.ui","",paths_hud(`{"name":"health","kind":"Progress","bind_value":"Statuz.health"}`),
            {"nodes[0].children[0] 'health'","bind_value 'Statuz.health'","no component or storage 'Statuz'","Status","Nothing changed","ui.paths"}},
        {"hud/hud.ui","",paths_hud(`{"name":"health","kind":"Progress","bind_value":"Status.helth"}`),
            {"nodes[0].children[0] 'health'","bind_value 'Status.helth'","no field 'helth'","health, hits, message"}},
        {"hud/hud.ui","",paths_hud(`{"name":"health","kind":"Progress","bind_value":"Status.message"}`),
            {"'health'","bind_value 'Status.message'","takes a number"}},
        {"hud/hud.ui","",paths_hud(`{"name":"second","kind":"Text","bind_text":"Hotbar.slots.3.count"}`),
            {"'second'","bind_text 'Hotbar.slots.3.count'","3 elements"}},
        {"hud/hud.ui","",paths_hud(`{"name":"slots","kind":"List","bind_items":"Hotbar.slots","children":[{"name":"slot","kind":"Text","bind_text":"nmae"}]}`),
            {"nodes[0].children[0].children[0] 'slot'","bind_text 'nmae'","no field 'nmae'","label, count"}},
        {"hud/hud.ui","",paths_hud(`{"name":"enemies","kind":"List","bind_items":"Enemy","children":[{"name":"enemy","kind":"Progress","bind_value":"helth"}]}`),
            {"'enemy'","bind_value 'helth'","no field 'helth'","label, health"}},
        {"hud/hud.ui","",paths_hud(`{"name":"count","kind":"Text","text":"{hits} of {most}","fields":[{"name":"hits","path":"Status.hitz"}]}`),
            {"'count'","{hits} 'Status.hitz'","no field 'hitz'","{most} has no path"}},
        {"hud/hud.ui","",paths_hud(`{"name":"hits","kind":"stat","label":"Hits","value":"Status.hitz"}`),
            {"nodes[0].children[0] 'hits'","value gives","'amount'","'Status.hitz'","no field 'hitz'"}},
        {"hud/hud.ui","",paths_hud(`{"name":"hits","kind":"stat","of":"Statuz"}`),
            {"'hits'","of gives","'Statuz.","no component or storage 'Statuz'"}},
        {"hud/hud.ui","health",`{"nodes":[{"name":"health","kind":"Progress","bind_value":"Status.helth"}]}`,
            {"nodes[0] 'health'","bind_value 'Status.helth'"}},
        {"hud/new.ui","",paths_hud(`{"name":"health","kind":"Progress","bind_value":"Status.helth"}`),
            {"'health'","bind_value 'Status.helth'"}},
        // A document that reads and a tree that does not load: a use holds a node and its widget has no slot.
        {"hud/held.ui","",paths_hud(`{"name":"hits","kind":"stat","children":[{"name":"inside","kind":"Text"}]}`),
            {"would not load","Nothing changed"}},
        {"hud/hud.ui","",paths_hud(`{"name":"slots","kind":"List","bind_items":"Hotbar.slots","children":[{"name":"slot","kind":"Text","bind_text":"label"},{"name":"count","kind":"Text","bind_text":"count"}]}`),
            {"nodes[0].children[0].children[","a List holds one node","put a Box there"}},
    }
    for c in refused {
        message,written:=write(&s,c.asset,c.node,c.document)
        if !testing.expectf(t,!written,"%s was written",c.document) {continue}
        for part in c.says {testing.expectf(t,strings.contains(message,part),"%s\nlacks: %s\nsays:  %s",c.document,part,message)}
        _,unsaved:=asset.registry_memory_find(&p.assets.registry,c.asset)
        testing.expectf(t,!unsaved,"%s waits for Save after a refused write",c.asset)
    }
    testing.expect(t,saved(&p,"hud/hud.ui")==hud_before,"the file is as it was")
    host.assets_scan(&p.assets)
    for path in ([]string{"hud/new.ui","hud/held.ui"}) {
        _,made:=asset.registry_find_path(&p.assets.registry,path)
        testing.expectf(t,!made && !os.exists(fmt.tprintf("%s/%s",p.root,path)),"%s was made by a refused write",path)
    }

    // What the game has, what only a use knows, and what the document does not declare.
    taken:=[?]struct{asset,node,document:string}{
        {"hud/hud.ui","",PATHS_HUD},
        {"hud/stat.ui","",PATHS_STAT},
        {"hud/stale.ui","fresh",`{"nodes":[{"name":"fresh","kind":"Text","bind_text":"Status.message"}]}`},
        {"hud/stale.ui","",`{"styles":{"plain":{"size":14}}}`},
        // The node a List holds becomes another, which may hold the one it held.
        {"hud/hud.ui","slots",`{"nodes":[{"name":"slots","kind":"List","bind_items":"Hotbar.slots","children":[{"name":"cell","kind":"Box","children":[{"name":"slot","kind":"Text","bind_text":"label"}]}]}]}`},
        {"hud/hud.ui","enemies",`{"nodes":[{"name":"enemies","kind":"List","bind_items":"Enemy","children":[{"name":"foe","kind":"Text","bind_text":"label"}]}]}`},
    }
    for c in taken {
        message,written:=write(&s,c.asset,c.node,c.document)
        testing.expectf(t,written,"%s %s: %s",c.asset,c.node,message)
    }
    hud:author.Records
    if !project_records(t,&p,HUD_ID,&hud) {return}
    holds :: proc(r:^author.Records,holder,held:string) -> bool {
        at:=author.document_row_of(r,held)
        return at>=0 && r.nodes[at].parent>=0 && serial.text_field(r.nodes[r.nodes[at].parent].name[:])==holder
    }
    testing.expect(t,holds(&hud,"slots","cell") && holds(&hud,"cell","slot") && holds(&hud,"enemies","foe"),doc_text(&p,&hud))
    testing.expect(t,author.document_row_of(&hud,"enemy")<0 && author.records_subtree(hud.nodes[:],author.document_row_of(&hud,"enemies"))==1,"what the List held went")
    _,unsaved:=asset.registry_memory_find(&p.assets.registry,"hud/stale.ui")
    testing.expect(t,unsaved,"a write the game takes waits for Save")
    // Written whole, the file answers for every path it holds.
    stale:author.Records
    if !project_records(t,&p,STALE_ID,&stale) {return}
    message,written:=write(&s,"hud/stale.ui","",doc_text(&p,&stale))
    testing.expectf(t,!written && strings.contains(message,"'old'") && strings.contains(message,"no field 'fuel'"),"%s",message)
}
