package author

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"


// A project whose .ui only the memory of the registry holds, as an editor
// leaves them unsaved.
@(private="file")
Project :: struct {
    root:string,
    registry:asset.Registry,
    types:asset.Types,
    assets:Assets,
}

@(private="file")
project_init :: proc(t:^testing.T,p:^Project,name:string) -> bool {
    p.root=base.test_folder(t,fmt.tprintf("ui-inspector-%s",name))
    if p.root=="" {return false}
    asset.registry_init(&p.registry,p.root)
    asset.types_init(&p.types)
    p.assets={&p.registry,&p.types}
    return true
}

@(private="file")
project_destroy :: proc(p:^Project) {
    asset.registry_destroy(&p.registry)
    asset.types_destroy(&p.types)
}

// Writes records to path as the .ui id; imports as host.ui_tree_imports reads them.
@(private="file")
project_put :: proc(t:^testing.T,p:^Project,path:string,id:base.Asset_Id,data:ui.Tree_Data,imports:[]ui.Tree_Data={},loc:=#caller_location) -> bool {
    bytes,error:=host.ui_tree_bytes(&p.types,id,data,imports,context.temp_allocator)
    if !testing.expect_value(t,error,asset.Error.None,loc=loc) {return false}
    return testing.expect_value(t,asset.registry_memory_set(&p.registry,path,bytes),asset.Error.None,loc=loc)
}

@(private="file")
project_records :: proc(t:^testing.T,p:^Project,id:base.Asset_Id,r:^Records,loc:=#caller_location) -> bool {
    return testing.expect(t,records_read(p.assets,id,r,context.temp_allocator),"the .ui reads",loc=loc)
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
    reading:Reading
    args:=call_args(&reading,&p.types,"{}")
    args.assets=p.assets
    args.asset=id
    if _,_,applied:=document_apply(&args,&r,-1,text);!testing.expectf(t,applied,"%s",reading.problem,loc=loc) {return}
    imports,imported:=tree_imports(p.assets,records_data(&r))
    if !testing.expectf(t,imported,"%s does not read what it uses",path,loc=loc) {return}
    bytes,error:=records_commit(&p.types,id,&r,imports)
    if !testing.expect_value(t,error,asset.Error.None,loc=loc) {return}
    return r,testing.expect_value(t,asset.registry_memory_set(&p.registry,path,bytes),asset.Error.None,loc=loc)
}

@(private="file")
doc_text :: proc(p:^Project,r:^Records) -> string {
    buffer:=make([]u8,1<<16,context.temp_allocator)
    w:serial.Writer
    serial.writer_init_fixed(&w,buffer)
    reading:Reading
    args:=call_args(&reading,&p.types,"{}")
    args.assets=p.assets
    libs:=doc_libs(&args,r)
    document_write(&w,&p.types,r,-1,libs[:],p.assets)
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
a_file_has_one_row_and_stays_in_use_until_a_document_takes_it_away :: proc(t:^testing.T) {
    p:Project
    _,ok:=widgets_project(t,&p,"widget-use")
    if !ok {return}
    defer project_destroy(&p)
    // A file a use names and a style comes from is one row, called as the file.
    page:=base.Asset_Id{0xc4,1}
    r,made:=project_doc(t,&p,"ui/page.ui",page,`{"use":["ui/select_row.ui"],"nodes":[{"name":"root","kind":"Box","style":"row","children":[{"name":"use","kind":"select_row"}]}]}`)
    if !made {return}
    if !testing.expect_value(t,len(r.components),1) {return}
    testing.expect_value(t,serial.text_field(r.components[0].name[:]),"select_row")
    apply :: proc(t:^testing.T,p:^Project,r:^Records,id:base.Asset_Id,text:string) -> (ok:bool,message:string) {
        reading:Reading
        args:=call_args(&reading,&p.types,"{}")
        args.assets,args.asset=p.assets,id
        _,_,ok=document_apply(&args,r,-1,text)
        return ok,reading.problem
    }
    // Its last use goes and it stays, in the document too.
    applied,why:=apply(t,&p,&r,page,`{"nodes":[{"name":"root","kind":"Box"}]}`)
    if !testing.expectf(t,applied,"%s",why) {return}
    records_tidy(&r)
    testing.expect_value(t,len(r.components),1)
    testing.expect(t,strings.contains(doc_text(&p,&r),`"use":["ui/select_row.ui"]`),doc_text(&p,&r))
    imports,imported:=tree_imports(p.assets,records_data(&r))
    testing.expect(t,imported)
    linked,linked_ok:=ui.tree_link(records_data(&r),imports)
    testing.expect(t,linked_ok)
    _,expanded:=ui.tree_expand(linked,context.temp_allocator)
    testing.expect(t,expanded,"a use no node makes still links")
    // Taken away while a node still is a use of it, it says so.
    applied,_=apply(t,&p,&r,page,`{"nodes":[{"name":"root","kind":"Box","children":[{"name":"use","kind":"select_row"}]}]}`)
    if !testing.expect(t,applied) {return}
    applied,why=apply(t,&p,&r,page,`{"use":[]}`)
    testing.expect(t,!applied && strings.contains(why,"is not listed"),why)
    // Listed no more, with what it lent that nothing takes.
    applied,why=apply(t,&p,&r,page,`{"use":[],"nodes":[{"name":"root","kind":"Box"}]}`)
    if !testing.expectf(t,applied,"%s",why) {return}
    testing.expect_value(t,len(r.components),0)
    testing.expect(t,tree_style_row(&r,"row")<0,"the style it lent goes with it")
    testing.expect(t,records_load_as_tree(&r))
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
    imports,imported:=tree_imports(p.assets,data)
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
        reading:Reading
        args:=call_args(&reading,&p.types,"{}")
        args.assets=p.assets
        args.asset=c.id
        _,_,applied:=document_apply(&args,&r,-1,c.document)
        testing.expectf(t,!applied && strings.contains(reading.problem,c.message),"%s gave '%s'",c.document,reading.problem)
    }
    // What a file uses that goes missing, and a cycle, say so.
    r:Records
    project_records(t,&p,SCREEN_FILE_ID,&r)
    component:=&r.components[0]
    component.widget={0xdd,9}
    testing.expect(t,strings.contains(widget_why(p.assets,records_data(&r)),"whose file is missing"),widget_why(p.assets,records_data(&r)))
}

@(test)
a_commit_settles_what_a_style_gives_nodes_that_take_it :: proc(t:^testing.T) {
    p:Project
    if !project_init(t,&p,"commit") {return}
    defer project_destroy(&p)
    r,ok:=project_doc(t,&p,"ui/panel.ui",{0xc0,1},`{"styles":{"base":{"gap":6},"child":{"extends":"base","size":12}},"nodes":[{"name":"root","kind":"Box","style":"child"}]}`)
    if !ok {return}
    child:=tree_style_row(&r,"child")
    r.style_infos[tree_style_row(&r,"base")].layout.gap=30
    _,error:=records_commit(&p.types,{0xc0,1},&r,nil)
    if !testing.expect_value(t,error,asset.Error.None) {return}
    testing.expect_value(t,r.style_infos[child].layout.gap,f32(30))
    testing.expect_value(t,r.nodes[document_row_of(&r,"root")].layout.gap,f32(30))
}

@(test)
a_parameter_of_a_style_can_give_one_of_a_file_it_uses :: proc(t:^testing.T) {
    p:Project
    _,ok:=widgets_project(t,&p,"widget-style")
    if !ok {return}
    defer project_destroy(&p)
    tone:=base.Asset_Id{0xc1,1}
    if _,written:=project_doc(t,&p,"ui/tone.ui",tone,`{"use":["ui/theme.ui"],"params":{"accent":"label.style"},"nodes":[{"name":"tone","kind":"Box","children":[{"name":"label","kind":"Text","style":"label"}]}]}`);!written {return}
    r,made:=project_doc(t,&p,"ui/page.ui",{0xc2,1},`{"use":["ui/theme.ui","ui/tone.ui"],"nodes":[{"name":"page","kind":"Box","children":[{"name":"use","kind":"tone"}]}]}`)
    if !made {return}
    lib,read:=doc_lib_read(p.assets,tone,context.temp_allocator)
    if !testing.expect(t,read && len(lib.linked.params)==1) {return}
    param:=lib.linked.params[0]
    expanded,expanded_ok:=ui.tree_expand(lib.linked,context.temp_allocator)
    if !testing.expect(t,expanded_ok) {return}
    source:=new(Records,context.temp_allocator)
    if !testing.expect(t,records_load(source,lib.linked,context.temp_allocator)) {return}
    node:ui.Tree_Node
    for &e in expanded {if serial.text_field(e.name[:])=="label" {node=e}}
    row:=document_row_of(&r,"use")
    testing.expect(t,!records_param_give(p.assets,&r,row,&param,"nothing",source,node),"a name that resolves to nothing changes nothing")
    if !testing.expect(t,records_param_give(p.assets,&r,row,&param,"knob",source,node)) {return}
    at:=records_override(&r,row,"label",{})
    testing.expect_value(t,records_style_name(&r,int(r.overrides[at].values.style)),"knob")
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
    before:=widget_params(p.assets,ROW_ID)
    moved:=make([]ui.Tree_Param,len(before),context.temp_allocator)
    copy(moved,before)
    ui.tree_text_set(moved[0].node[:],"control")
    follow:=records_params_follow(p.assets,&screen,ROW_ID,params_changes(before,moved))
    testing.expect(t,follow.changed)
    found:=false
    for &o in screen.overrides {
        if int(o.instance)==second && serial.text_field(o.node[:])=="control" && .Text in o.fields {found=records_text(&screen,o.values.text)=="Volume"}
    }
    testing.expect(t,found,"the value went to the node the parameter goes to now")
    // A reach through its use follows too, in what it hands up.
    outer:Records
    project_records(t,&p,OUTER_ID,&outer)
    through:=records_params_follow(p.assets,&outer,ROW_ID,params_changes(before,moved))
    testing.expect(t,through.changed || len(through.through)==1)
    // Gone: what uses gave goes.
    fresh:Records
    project_records(t,&p,SCREEN_FILE_ID,&fresh)
    gone:=records_params_follow(p.assets,&fresh,ROW_ID,params_changes(before,before[1:]))
    testing.expect(t,gone.changed)
}

// The procedure a Draw names is one the game declares: one it lacks, or no
// procedure at all, is a problem that says what to write, before it runs.
@(test)
draws_the_game_lacks_are_problems_before_it_runs :: proc(t:^testing.T) {
    p:Project
    if !project_init(t,&p,"draw-names") {return}
    defer project_destroy(&p)
    screen,ok:=project_doc(t,&p,"screen.ui",SCREEN_FILE_ID,`{"nodes":[{"name":"menu","kind":"Box","children":[
        {"name":"map","kind":"Draw","draw":"minimap","width":40,"height":40},{"name":"blank","kind":"Draw"}]}]}`)
    if !ok {return}
    found:[4]Bind_Problem
    declared:=[1]core.Draw_Info{{name="minimap"}}
    info:=core.World_Info{draws=declared[:]}
    testing.expect_value(t,draw_names_check(nil,&screen,found[:]),0)
    if testing.expect_value(t,draw_names_check(&info,&screen,found[:]),1) {
        text:=bind_problem_text(p.assets,&found[0])
        testing.expectf(t,strings.contains(text,"Draw 'blank' has no draw"),"%s",text)
    }
    info.draws=nil
    if testing.expect_value(t,draw_names_check(&info,&screen,found[:]),2) {
        text:=bind_problem_text(p.assets,&found[0])
        testing.expectf(t,strings.contains(text,"Draw 'map' names 'minimap'") && strings.contains(text,`@(draw="minimap")`),"%s",text)
    }
    testing.expect_value(t,draw_names_check(&info,&screen,found[:1]),1)
}
