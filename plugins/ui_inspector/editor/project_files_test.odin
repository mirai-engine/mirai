package ui_inspector_editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
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
    directory,_:=os.temp_directory(context.temp_allocator)
    p.root=fmt.aprintf("%s/mirai-ui-inspector-%d-%s",directory,os.get_pid(),name)
    os.remove_all(p.root)
    os.make_directory_all(p.root)
    return testing.expect(t,host.assets_init(&p.assets,{root=p.root,capacity=8}))
}

@(private="file")
project_destroy :: proc(p:^Project) {
    host.assets_destroy(&p.assets)
    os.remove_all(p.root)
    delete(p.root)
}

// Writes records to path as the .ui id; imports as host.ui_tree_imports reads them.
@(private="file")
project_put :: proc(t:^testing.T,p:^Project,path:string,id:base.Asset_Id,data:ui.Tree_Data,imports:[]ui.Tree_Data={},loc:=#caller_location) -> bool {
    bytes,error:=host.ui_tree_bytes(&p.assets.types,id,data,imports,context.temp_allocator)
    if !testing.expect_value(t,error,asset.Error.None,loc=loc) {return false}
    return testing.expect_value(t,asset.registry_memory_set(&p.assets.registry,path,bytes),asset.Error.None,loc=loc)
}

@(private="file")
project_records :: proc(t:^testing.T,p:^Project,id:base.Asset_Id,r:^Records,loc:=#caller_location) -> bool {
    return testing.expect(t,records_read(&p.assets,id,r,context.temp_allocator),"the .ui reads",loc=loc)
}

// ---------------------------------------------------------------- texts

@(private="file") MENU_ID :: base.Asset_Id{0x3e,1}
@(private="file") GAME_LANGUAGES :: gui.Languages{.English,.Spanish,.French}

// A menu with two localized texts, one with no Spanish, and one that is not.
@(private="file")
menu_records :: proc(t:^testing.T,r:^Records,translated:bool) -> bool {
    texts:=make([dynamic]u8,context.temp_allocator)
    nodes:=[]ui.Tree_Node{
        ui.tree_node_record(&texts,-1,{kind=.Box,name="menu"}),
        ui.tree_node_record(&texts,0,{kind=.Text,name="play",text="Play, \"now\"\nor later",flags={.Localized},text_id=0xa1}),
        ui.tree_node_record(&texts,0,{kind=.Button,name="quit,all",text="Quit",flags={.Localized},text_id=0xb2}),
        ui.tree_node_record(&texts,0,{kind=.Text,name="hint",text="Not localized"}),
    }
    if !testing.expect(t,records_load(r,{text=texts[:],nodes=nodes,styles={{}}},context.temp_allocator)) {return false}
    if translated {
        node_text_set(r,&r.nodes[1],1,.Spanish,.English,"Jugar, \"ya\"\r\no luego")
        node_text_set(r,&r.nodes[1],1,.French,.English,"Jouer")
        node_text_set(r,&r.nodes[2],2,.French,.English,"Quitter")
    }
    return true
}

// The rows of the CSV of a menu, parsed as ui.text.import reads them.
@(private="file")
menu_csv :: proc(r:^Records) -> (text:string,rows:[][]string,count:int) {
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
    source:Records
    if !menu_records(t,&source,true) {return}
    if !project_put(t,&p,"ui/menu.ui",MENU_ID,records_data(&source)) {return}

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
    target:Records
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
    r:Records
    if !menu_records(t,&r,true) {return}
    if !project_put(t,&p,"ui/menu.ui",MENU_ID,records_data(&r)) {return}
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
override_of :: proc(r:^Records) -> string {return serial.text_field(r.overrides[0].node[:])}

// Whether records of a .ui load with the widgets the registry has for them.
@(private="file")
loads :: proc(p:^Project,id:base.Asset_Id,r:^Records) -> bool {
    data:=records_data(r)
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
    renamed:=[2]Records{}
    for id,i in ([2]base.Asset_Id{SLOT_ID,SCREEN_ID}) {
        if !project_records(t,&p,id,&renamed[i]) {return}
        testing.expect_value(t,records_rename_follow(&p.assets,&renamed[i],CARD_ID,"label","caption"),1)
    }
    testing.expect_value(t,override_of(&renamed[0]),"caption")
    testing.expect_value(t,override_of(&renamed[1]),"slot/caption")
    other:Records
    if !project_records(t,&p,OTHER_ID,&other) {return}
    testing.expect_value(t,records_rename_follow(&p.assets,&other,CARD_ID,"label","caption"),0)
    testing.expect_value(t,override_of(&other),"label")
    testing.expect_value(t,records_rename_follow(&p.assets,&renamed[0],CARD_ID,"capt","x"),0)

    // With card renamed, what followed loads and what did not follow does not.
    if !project_put(t,&p,"card.ui",CARD_ID,widget_data("card","caption")) {return}
    stale:Records
    if !project_records(t,&p,SLOT_ID,&stale) {return}
    testing.expect(t,!loads(&p,SLOT_ID,&stale),"An override of a node the widget no longer has does not load")
    testing.expect(t,loads(&p,SLOT_ID,&renamed[0]))
    if !project_put(t,&p,"slot.ui",SLOT_ID,records_data(&renamed[0]),{widget_data("card","caption")}) {return}
    testing.expect(t,loads(&p,SCREEN_ID,&renamed[1]))

    // The instance inside the widget renamed: the path follows in its first part.
    screen:Records
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
Problem_Key :: struct {asset:base.Asset_Id,row,node:int,binding:ui.Binding,fault:Bind_Fault,path:string}

// Whether two lists have the same problems, in any order.
@(private="file")
same_problems :: proc(a,b:[]Bind_Problem) -> bool {
    key :: proc(p:^Bind_Problem) -> Problem_Key {return {p.asset,p.row,p.node,p.binding,p.fault,serial.text_field(p.path[:])}}
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
full_check :: proc(p:^Project) -> []Bind_Problem {
    types:Bind_Types
    defer bind_types_free(&types)
    problems:=make([dynamic]Bind_Problem,context.temp_allocator)
    bind_check_all(&problems,&types,context.allocator,&p.assets,nil)
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
    defer {delete(u.problems);delete(u.checked);delete(u.checked_uses);bind_types_free(&u.bind_types)}
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

// Writes a document as the file path, id, through the same route as ui.write.
@(private="file")
project_doc :: proc(t:^testing.T,p:^Project,path:string,id:base.Asset_Id,text:string,loc:=#caller_location) -> (r:Records,ok:bool) {
    empty:=[1]ui.Node_Style{{}}
    if !testing.expect(t,records_load(&r,{styles=empty[:]},context.temp_allocator),loc=loc) {return}
    call:api.Call
    args:=call_args(&call,&p.assets.types,"{}")
    args.assets=&p.assets
    args.asset=id
    if _,_,applied:=document_apply(&args,&r,-1,text);!testing.expectf(t,applied,"%s",call.error.message,loc=loc) {return}
    imports,settled:=records_settle(&r,&p.assets)
    if !testing.expectf(t,settled,"%s does not settle",path,loc=loc) {return}
    return r,project_put(t,p,path,id,records_data(&r),imports,loc)
}

@(private="file")
doc_text :: proc(p:^Project,r:^Records) -> string {
    buffer:=make([]u8,1<<16,context.temp_allocator)
    w:serial.Writer
    serial.writer_init_fixed(&w,buffer)
    call:api.Call
    args:=call_args(&call,&p.assets.types,"{}")
    args.assets=&p.assets
    libs:=doc_libs(&args,r)
    document_write(&w,&p.assets.types,r,-1,libs[:],&p.assets)
    return string(serial.writer_bytes(&w))
}

@(private="file") WIDGET_THEME :: `{"tokens":{"ink":"#102030"},"styles":{"row":{"width":"grow","gap":22},"label":{"size":12,"color":"ink"},"knob":{"size":14,"color":"ink"}}}`
@(private="file") WIDGET_ROW :: `{"use":["ui/theme.ui"],"params":{"label":"label.text","options":"control.text","bind":"data"},"nodes":[{"name":"row","kind":"Box","style":"row","children":[{"name":"label","kind":"Text","style":"label"},{"name":"control","kind":"Selector","style":"knob","bind_value":"@"}]}]}`
@(private="file") WIDGET_OUTER :: `{"use":["ui/select_row.ui"],"params":{"heading":"inner.label","dim":"bind_visible"},"nodes":[{"name":"outer","kind":"Box","slot":true,"children":[{"name":"inner","kind":"select_row","options":"A|B","bind":"Game.a"}]}]}`
@(private="file") WIDGET_SCREEN :: `{"use":["ui/outer.ui","ui/select_row.ui"],"nodes":[{"name":"root","kind":"Box","children":[{"name":"first","kind":"outer","heading":"Hello","children":[{"name":"held","kind":"Button","text":"Ok"}]},{"name":"second","kind":"select_row","label":"Volume","options":"Low|High","bind":"Game.volume"}]}]}`

@(private="file")
widgets_project :: proc(t:^testing.T,p:^Project,name:string) -> (screen:Records,ok:bool) {
    if !project_init(t,p,name) {return}
    project_doc(t,p,"ui/theme.ui",THEME_FILE_ID,WIDGET_THEME) or_return
    project_doc(t,p,"ui/select_row.ui",ROW_ID,WIDGET_ROW) or_return
    project_doc(t,p,"ui/outer.ui",OUTER_ID,WIDGET_OUTER) or_return
    return project_doc(t,p,"ui/screen.ui",SCREEN_FILE_ID,WIDGET_SCREEN)
}

@(test)
a_widget_is_a_file_and_its_document_comes_back_the_same :: proc(t:^testing.T) {
    p:Project
    screen,ok:=widgets_project(t,&p,"widget-doc")
    if !ok {return}
    defer project_destroy(&p)
    files:=[?]struct{path:string,id:base.Asset_Id}{{"ui/select_row.ui",ROW_ID},{"ui/outer.ui",OUTER_ID},{"ui/screen.ui",SCREEN_FILE_ID}}
    for f in files {
        path,id:=f.path,f.id
        r:Records
        if !project_records(t,&p,id,&r) {return}
        first:=doc_text(&p,&r)
        again,written:=project_doc(t,&p,path,id,first)
        if !written {return}
        testing.expectf(t,doc_text(&p,&again)==first,"%s changed when written back:\n%s\n%s",path,first,doc_text(&p,&again))
    }
    text:=doc_text(&p,&screen)
    for expected in ([]string{`"use":["ui/outer.ui","ui/select_row.ui"]`,`"kind":"select_row"`,`"kind":"outer"`,`"heading":"Hello"`,`"label":"Volume"`,`"bind":"Game.volume"`}) {
        testing.expectf(t,strings.contains(text,expected),"the document says %s: %s",expected,text)
    }
    testing.expect(t,!strings.contains(text,`"widget":`),"a use names no file but through use")
    row:Records
    project_records(t,&p,ROW_ID,&row)
    testing.expect(t,strings.contains(doc_text(&p,&row),`"params":{"label":"label.text","options":"control.text","bind":"data"}`))
    data:=records_data(&screen)
    imports,imported:=host.ui_tree_imports(&p.assets,data)
    linked,linked_ok:=ui.tree_link(data,imports)
    if !testing.expect(t,imported && linked_ok) {return}
    expanded,expanded_ok:=ui.tree_expand(linked,context.temp_allocator)
    if !testing.expect(t,expanded_ok) {return}
    // A parameter that reaches through a use, and a slot of a use.
    found:=false
    for &n in expanded {found||=serial.text_field(n.name[:])=="first/inner/label" && ui.tree_string(linked.text,n.text)=="Hello"}
    testing.expect(t,found,"a parameter of the widget a use holds reaches through it")
    held:=-1
    for &n,i in expanded {if serial.text_field(n.name[:])=="held" {held=i}}
    testing.expect(t,held>0 && serial.text_field(expanded[expanded[held].parent].name[:])=="first","what a use holds goes in its slot")
}

@(test)
a_document_says_what_is_wrong_with_what_it_uses :: proc(t:^testing.T) {
    p:Project
    _,ok:=widgets_project(t,&p,"widget-errors")
    if !ok {return}
    defer project_destroy(&p)
    cases:=[?]struct{id:base.Asset_Id,document,message:string}{
        {{0xb0,1},`{"use":["ui/none.ui"],"nodes":[]}`,"use[0]"},
        {OUTER_ID,`{"use":["ui/screen.ui"],"nodes":[{"name":"outer","kind":"Box","children":[{"name":"s","kind":"screen"}]}]}`,"uses this file back"},
        {{0xb0,1},`{"components":{}}`,"document has no 'components'"},
        {{0xb0,1},`{"use":["ui/select_row.ui"],"nodes":[{"name":"s","kind":"select_row","colour":"x"}]}`,"has no parameter 'colour'"},
        {{0xb0,1},`{"nodes":[{"name":"s","kind":"select_row"}]}`,"nodes[0]: kind 'select_row' is no Node_Kind and no widget"},
        {{0xb0,1},`{"params":{"x":"nope.text"},"nodes":[{"name":"s","kind":"Box"}]}`,"params.x: this file has no node 'nope'"},
        {{0xb0,1},`{"params":{"text":"s.text"},"nodes":[{"name":"s","kind":"Box"}]}`,"A node has a key of that name"},
        {{0xb0,1},`{"params":{"x":"s.text"},"nodes":[{"name":"s","kind":"Box"},{"name":"t","kind":"Box"}]}`,"it has one root"},
        {{0xb0,1},`{"use":["ui/select_row.ui"],"params":{"x":"s.volume"},"nodes":[{"name":"s","kind":"select_row"}]}`,"no parameter of 's'"},
    }
    for c in cases {
        r:Records
        testing.expect(t,records_load(&r,{styles=make([]ui.Node_Style,1,context.temp_allocator)},context.temp_allocator))
        call:api.Call
        args:=call_args(&call,&p.assets.types,"{}")
        args.assets=&p.assets
        args.asset=c.id
        _,_,applied:=document_apply(&args,&r,-1,c.document)
        testing.expectf(t,!applied && strings.contains(call.error.message,c.message),"%s gave '%s'",c.document,call.error.message)
    }
    // What a file uses that goes missing, and a cycle, say so.
    r:Records
    project_records(t,&p,SCREEN_FILE_ID,&r)
    component:=&r.components[0]
    component.widget={0xdd,9}
    testing.expect(t,strings.contains(widget_why(&p.assets,records_data(&r)),"whose file is missing"),widget_why(&p.assets,records_data(&r)))
}

@(test)
a_parameter_moved_in_a_widget_moves_what_its_uses_give :: proc(t:^testing.T) {
    p:Project
    screen,ok:=widgets_project(t,&p,"widget-follow")
    if !ok {return}
    defer project_destroy(&p)
    // select_row's label goes to the options now: what uses gave of label moves with it.
    second:=-1
    for &n,i in screen.nodes {if serial.text_field(n.name[:])=="second" {second=i}}
    before:=widget_params(&p.assets,ROW_ID)
    moved:=make([]ui.Tree_Param,len(before),context.temp_allocator)
    copy(moved,before)
    ui.tree_text_set(moved[0].node[:],"control")
    follow:=records_params_follow(&p.assets,&screen,ROW_ID,params_changes(before,moved))
    testing.expect(t,follow.changed)
    found:=false
    for &o in screen.overrides {
        if int(o.instance)==second && serial.text_field(o.node[:])=="control" && .Text in o.fields {found=records_text(&screen,o.values.text)=="Volume"}
    }
    testing.expect(t,found,"the value went to the node the parameter goes to now")
    // A reach through its use follows too, in what it hands up.
    outer:Records
    project_records(t,&p,OUTER_ID,&outer)
    through:=records_params_follow(&p.assets,&outer,ROW_ID,params_changes(before,moved))
    testing.expect(t,through.changed || len(through.through)==1)
    // Gone: what uses gave goes.
    fresh:Records
    project_records(t,&p,SCREEN_FILE_ID,&fresh)
    gone:=records_params_follow(&p.assets,&fresh,ROW_ID,params_changes(before,before[1:]))
    testing.expect(t,gone.changed)
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
    r,widget:Records
    testing.expect(t,records_load(&r,{text=texts[:],nodes=nodes,styles={{}}},context.temp_allocator))
    testing.expect(t,records_widget_data(&r,1,&widget,context.temp_allocator))
    if !testing.expect_value(t,len(widget.params),2) {return}
    testing.expect_value(t,serial.text_field(widget.params[0].name[:]),"title")
    testing.expect_value(t,widget.params[0].field,ui.Tree_Param_Field.Text)
    testing.expect_value(t,serial.text_field(widget.params[1].node[:]),"fuel")
    testing.expect_value(t,widget.params[1].field,ui.Tree_Param_Field.Bind_Value)
    at:=records_param_add(&widget)
    testing.expect_value(t,serial.text_field(widget.params[at].name[:]),"param1")
    ui.tree_text_set(widget.params[at].name[:],"text")
    testing.expect(t,records_param_valid_name(&widget,at)!="","a key of a node is no parameter")
    ui.tree_text_set(widget.params[at].name[:],"note")
    records_param_target(&widget,at,"title",.Bind_Text,"")
    testing.expect_value(t,serial.text_field(widget.params[at].node[:]),"title")
    testing.expect_value(t,records_slot_set(&widget,3,true),"")
    testing.expect(t,.Slot in widget.nodes[3].flags)
    testing.expect(t,records_slot_set(&widget,1,true)!="","a node before the last is no slot")
    testing.expect_value(t,records_slot_set(&widget,0,true),"")
    testing.expect(t,.Slot not_in widget.nodes[3].flags && .Slot in widget.nodes[0].flags,"one slot")
    ordered_remove(&widget.params,at)
    testing.expect_value(t,len(widget.params),2)
    // A renamed node takes the parameters that go to it along.
    ui.tree_text_set(widget.nodes[1].name[:],"caption")
    records_rename(&widget,1,"title")
    testing.expect_value(t,serial.text_field(widget.params[0].node[:]),"caption")
}
