package ui_inspector_editor

import "core:mem"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:editor/api"
import "mirai:std/serial"
import "mirai:ui"

// A hud with a named style and its rule, a localized title with a look of its
// own, a bar that holds a progress and a localized label without a name, and
// a button that plays an animation.
@(private="file")
document_sample :: proc(t:^testing.T,r:^Records) -> bool {
    texts:=make([dynamic]u8,context.temp_allocator)
    nodes:=[]ui.Tree_Node{
        ui.tree_node_record(&texts,-1,{kind=.Box,name="hud",float={to=.Safe,anchor=.Top_Left,pivot=.Top_Left}}),
        ui.tree_node_record(&texts,0,{kind=.Text,name="title",text="Trips",bind_text="trips"}),
        ui.tree_node_record(&texts,0,{kind=.Box,name="bar"}),
        ui.tree_node_record(&texts,2,{kind=.Progress,name="fuel",bind_value="fuel"}),
        ui.tree_node_record(&texts,2,{kind=.Text,text="Fuel"}), // without a name, as generated files have them
        ui.tree_node_record(&texts,-1,{kind=.Button,name="menu",text="Menu"}),
    }
    styles:=[]ui.Node_Style{{},{fill={20,20,30,255},radius={8,8,8,8}},{text={size=18}}}
    infos:=make([]ui.Tree_Style_Info,3,context.temp_allocator)
    ui.tree_text_set(infos[1].name[:],"card")
    infos[2].family=.Text
    if !testing.expect(t,records_load(r,{text=texts[:],nodes=nodes,styles=styles,style_infos=infos},context.allocator)) {return false}
    r.nodes[0].style,r.nodes[1].style=1,2
    append(&r.variants,ui.Tree_Style_Variant{style=1,states={.Hovered},patch={fields={.Fill},values={fill={40,40,60,255}}}})
    for row in ([2][2]int{{1,77},{4,78}}) {
        r.nodes[row[0]].flags+={.Localized}
        r.nodes[row[0]].text_id=u64(row[1])
        translation:=ui.Tree_Translation{id=u64(row[1])}
        ui.tree_text_set(translation.language[:],"es")
        append(&r.translations,translation)
        records_text_set(r,&r.translations[len(r.translations)-1].text,"Traducido")
    }
    pop:=records_clip(r,"pop",.Opacity,{0,0,0,0},{1,0,0,0},0.2)
    set:=records_anim_set(r,&r.nodes[5])
    r.anim_sets[set].shown=ui.Anim(pop+1)
    return true
}

@(private="file")
document_text :: proc(types:^asset.Types,r:^Records,root:int) -> string {
    buffer:=make([]u8,1<<16,context.temp_allocator)
    w:serial.Writer
    serial.writer_init_fixed(&w,buffer)
    document_write(&w,types,r,root)
    return string(serial.writer_bytes(&w))
}

@(test)
a_document_written_back_leaves_the_file_as_it_was :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    r:Records
    if !document_sample(t,&r) {return}
    defer records_destroy(&r)
    for root in ([2]int{-1,0}) {
        before:=document_text(&types,&r,root)
        call:api.Call
        args:=call_args(&call,&types,"{}")
        made,removed,ok:=document_apply(&args,&r,root,before)
        if !testing.expectf(t,ok,"%s",call.error.message) {return}
        testing.expect(t,made==0 && removed==0)
        testing.expect_value(t,document_text(&types,&r,root),before)
    }
    title:=document_row_of(&r,"title")
    testing.expect(t,.Localized in r.nodes[title].flags && r.nodes[title].text_id==77 && len(r.translations)==2)
    testing.expect(t,r.nodes[4].name[0]==0 && r.nodes[4].text_id==78,"a node without a name is matched by place and keeps none")
    testing.expect(t,records_load_as_tree(&r))
}

@(test)
a_document_of_a_node_changes_that_node_alone :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    r:Records
    if !document_sample(t,&r) {return}
    defer records_destroy(&r)
    menu:=r.nodes[document_row_of(&r,"menu")]
    call:api.Call
    args:=call_args(&call,&types,"{}")
    made,removed,ok:=document_apply(&args,&r,document_row_of(&r,"hud"),`{"nodes":[{"name":"hud","kind":"Box","style":"card","children":[
        {"name":"fuel","kind":"Progress","bind_value":"fuel"},
        {"name":"note","kind":"Text","text":"Hi"}]}]}`)
    if !testing.expectf(t,ok,"%s",call.error.message) {return}
    testing.expect_value(t,made,1)
    testing.expect_value(t,removed,3)
    expected:=[?]string{"hud","fuel","note","menu"}
    if !testing.expect_value(t,len(r.nodes),len(expected)) {return}
    for name,i in expected {testing.expect_value(t,serial.text_field(r.nodes[i].name[:]),name)}
    testing.expect(t,r.nodes[1].parent==0 && r.nodes[2].parent==0)
    // What the node does not give is that of a new node of its kind.
    testing.expect_value(t,r.nodes[0].float,node_default(.Box).float)
    testing.expect_value(t,records_text(&r,r.nodes[2].text),"Hi")
    testing.expect(t,mem.compare_ptrs(&r.nodes[3],&menu,size_of(ui.Tree_Node))==0)
    testing.expect_value(t,len(r.translations),0)
    testing.expect(t,records_load_as_tree(&r))
}

@(test)
a_document_without_nodes_changes_only_the_styles_and_animations_it_names :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    r:Records
    if !document_sample(t,&r) {return}
    defer records_destroy(&r)
    nodes:=len(r.nodes)
    call:api.Call
    args:=call_args(&call,&types,"{}")
    _,_,ok:=document_apply(&args,&r,-1,`{"styles":{"card":{"family":"Box","radius":4},"panel":{"family":"Box","defaults":["Box"]}},"animations":{"pop":null}}`)
    if !testing.expectf(t,ok,"%s",call.error.message) {return}
    testing.expect_value(t,len(r.nodes),nodes)
    card:=tree_style_row(&r,"card")
    testing.expect(t,r.styles[card].radius==[4]f32{4,4,4,4} && r.styles[card].fill==ui.Color{})
    for &v in r.variants {testing.expect(t,int(v.style)!=card,"a style declared without rules has none")}
    testing.expect_value(t,records_kind_style(&r,.Box),tree_style_row(&r,"panel"))
    testing.expect_value(t,len(r.anims),0)
    testing.expect_value(t,r.anim_sets[r.nodes[5].anims-1].shown,ui.Anim(0))
}

@(test)
a_document_says_where_it_cannot_be_written :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    Case :: struct {node,document,message:string}
    cases:=[?]Case{
        {"hud",`{"nodes":[{"name":"hud","kind":"Button"}]}`,"nodes[0].kind: a node keeps its kind"},
        {"hud",`{"nodes":[{"name":"hud","kind":"Box","children":[{"name":"menu","kind":"Button"}]}]}`,"nodes[0].children[0].name: the node 'menu' is outside"},
        {"hud",`{"nodes":[{"name":"hud","kind":"Box"},{"name":"other","kind":"Box"}]}`,"nodes: with node, the document declares that node alone"},
        {"",`{"nodes":[{"name":"x","kind":"Box","colour":1}]}`,"nodes[0]: the node has no field 'colour'"},
        {"",`{"nodes":[{"name":"x","kind":"Box","style":"nope"}]}`,"nodes[0]: style: 'nope' is no style"},
        {"",`{"nodes":[{"name":"x","kind":"Text","children":[{"name":"y","kind":"Text"}]}]}`,"nodes[0].children[0]: parent: a Text holds no nodes"},
        {"",`{"nodes":[{"name":"x","kind":"Box"},{"name":"x","kind":"Text"}]}`,"nodes[1].name: 'x' is declared twice"},
        {"",`{"items":[]}`,"document has no 'items'"},
        {"",`{"styles":{"card":{"family":"Box","rules":[{"states":["Hovered"],"colour":1}]}}}`,"styles.card: rules[0]: a state has no 'colour'"},
        {"",`{"styles":{"card":null}}`,"styles.card: nodes still take it"},
    }
    for c in cases {
        r:Records
        if !document_sample(t,&r) {return}
        call:api.Call
        args:=call_args(&call,&types,"{}")
        root:=document_row_of(&r,c.node) if c.node!="" else -1
        _,_,ok:=document_apply(&args,&r,root,c.document)
        testing.expect(t,!ok)
        testing.expectf(t,strings.has_prefix(call.error.message,c.message),"%s gave '%s'",c.document,call.error.message)
        records_destroy(&r)
    }
}

@(private="file")
THEME_DOCUMENT :: `{"tokens":{"ink":"#102030","round":8},
"styles":{
"base":{"fill":"ink","radius":"round","width":"grow","gap":6,"padding":4,"size":14,"color":"#ffffff","text_x":"center"},
"button":{"extends":"base","height":40,"transition":0.1,"hover":{"fill":"#ff0000","move_y":-2,"shadow":{"color":"ink","y":4}},
    "focus":{"extends":"hover","stroke":"#00ff00","border":3},"pressed":{"scale":0.9},"variants":{"gold":{"fill":"#ffd700"}}},
"row":{"width":"grow","gap":22,"align_y":"center"},
"label":{"size":12,"color":"#000000"}},
"components":{"select_row":{"params":{"label":"label.text","options":"control.text","bind":"control.bind_value","dim":"bind_visible"},"kind":"Box","style":"row","children":[
    {"name":"label","kind":"Text","style":"label"},{"name":"control","kind":"Selector","style":"button","width":310}]}},
"animations":{"pulse":{"scale":[1,1.2],"seconds":0.6,"ease":"In_Out_Quad","loop":"Ping_Pong"}},
"nodes":[{"name":"panel","kind":"Box","style":"base","float":{"to":"Surface"},"children":[
    {"name":"play","kind":"Button","style":"button","text":"Play","height":64,"events":{"shown":"pulse"}},
    {"name":"quality","kind":"select_row","label":"Quality","options":"Low|High","bind":"Graphics_Settings.quality","dim":"Shell.settings_on"},
    {"name":"vsync","kind":"select_row","label":"VSync","options":"Off|On","bind":"Graphics_Settings.vsync"}]}]}`

@(private="file")
document_of :: proc(t:^testing.T,types:^asset.Types,r:^Records,text:string) -> bool {
    empty:=[1]ui.Node_Style{{}}
    if !testing.expect(t,records_load(r,{styles=empty[:]},context.temp_allocator)) {return false}
    call:api.Call
    args:=call_args(&call,types,"{}")
    _,_,ok:=document_apply(&args,r,-1,text)
    if !testing.expectf(t,ok,"%s",call.error.message) {return false}
    ui.tree_settle(r.styles[:],r.style_infos[:],&r.variants,r.tokens[:],r.token_uses[:])
    return true
}

@(test)
a_document_with_names_comes_back_the_same_and_changes_nothing_when_written :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    r:Records
    if !document_of(t,&types,&r,THEME_DOCUMENT) {return}
    first:=document_text(&types,&r,-1)
    for expected in ([]string{`"extends":"base"`,`"fill":"ink"`,`"focus":{"extends":"hover"`,`"pressed":{"scale":0.9`,`"width":"grow"`,`"radius":"round"`,`"pulse":{"scale":[1,1.2]`,`"label":"Quality"`,`"bind":"Graphics_Settings.vsync"`,`"params":{"label":"label.text"`,`"height":64`,`"kind":"select_row"`}) {
        testing.expectf(t,strings.contains(first,expected),"the document names %s: %s",expected,first)
    }
    testing.expect(t,!strings.contains(first,"#ff0000\",\"fields"),"no field masks")
    call:api.Call
    args:=call_args(&call,&types,"{}")
    made,removed,ok:=document_apply(&args,&r,-1,first)
    if !testing.expectf(t,ok,"%s",call.error.message) {return}
    testing.expect(t,made==0 && removed==0,"writing what it gave makes and takes nothing")
    ui.tree_settle(r.styles[:],r.style_infos[:],&r.variants,r.tokens[:],r.token_uses[:])
    testing.expect_value(t,document_text(&types,&r,-1),first)
    testing.expect(t,records_load_as_tree(&r))
}

@(test)
what_a_style_extends_reaches_its_values_rules_and_nodes_when_they_change :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    r:Records
    if !document_of(t,&types,&r,THEME_DOCUMENT) {return}
    button:=tree_style_row(&r,"button")
    testing.expect_value(t,r.styles[button].fill,ui.Color{0x10,0x20,0x30,255})
    testing.expect_value(t,r.styles[button].text.color,ui.Color{255,255,255,255})
    rule :: proc(r:^Records,style:int,states:ui.Style_States) -> ^ui.Tree_Style_Variant {
        for &v in r.variants {if int(v.style)==style && v.states==states && v.variant[0]==0 {return &v}}
        return nil
    }
    focus:=rule(&r,button,{.Focused})
    testing.expect(t,focus!=nil && focus.patch.values.fill==ui.Color{255,0,0,255} && focus.patch.values.move.y==-2,"focus starts from hover")
    testing.expect_value(t,focus.patch.values.stroke,ui.Color{0,255,0,255})
    testing.expect(t,.Shadow in focus.patch.fields && focus.patch.values.shadow_offset.y==4 && focus.patch.values.shadow_color==ui.Color{0x10,0x20,0x30,255},"its shadow took what hover says and its color from the token")
    // A token changed: every style that names it, however far.
    call:api.Call
    args:=call_args(&call,&types,"{}")
    _,_,ok:=document_apply(&args,&r,-1,`{"tokens":{"ink":"#aabbcc"},"styles":{"base":{"fill":"ink","radius":"round","width":"grow","gap":6,"padding":4,"size":14,"color":"#ffffff","text_x":"center"}}}`)
    if !testing.expectf(t,ok,"%s",call.error.message) {return}
    ui.tree_settle(r.styles[:],r.style_infos[:],&r.variants,r.tokens[:],r.token_uses[:])
    testing.expect_value(t,r.styles[button].fill,ui.Color{0xaa,0xbb,0xcc,255})
    focus=rule(&r,button,{.Focused})
    testing.expect(t,focus.patch.values.shadow_color==ui.Color{0xaa,0xbb,0xcc,255},"the token reaches a state too")
    // A node takes the layout of its style where it does not say otherwise: 40 high from its style, 64 of its own.
    ui.tree_nodes_take_styles(r.nodes[:],r.style_infos[:])
    play:=document_row_of(&r,"play")
    testing.expect_value(t,r.nodes[play].layout.height,ui.fixed(64))
    testing.expect_value(t,r.nodes[play].layout.width,ui.GROW)
    panel:=document_row_of(&r,"panel")
    testing.expect_value(t,r.nodes[panel].layout.padding,[4]f32{4,4,4,4})
    testing.expect(t,records_load_as_tree(&r))
}

@(test)
a_use_of_a_component_by_name_writes_its_parameters_and_they_are_read_back :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    r:Records
    if !document_of(t,&types,&r,THEME_DOCUMENT) {return}
    quality:=document_row_of(&r,"quality")
    label:=-1
    for &o,i in r.overrides {if int(o.instance)==quality && serial.text_field(o.node[:])=="label" {label=i}}
    if !testing.expect(t,label>=0,"a parameter that goes to a node is an override of it") {return}
    testing.expect_value(t,records_text(&r,r.overrides[label].values.text),"Quality")
    testing.expect_value(t,serial.text_field(r.nodes[quality].bind_visible[:]),"Shell.settings_on")
    testing.expect(t,.Bindings in r.nodes[quality].component_fields,"a parameter that goes to the root is the instance's")
    // A use with fewer takes back what it does not say.
    call:api.Call
    args:=call_args(&call,&types,"{}")
    _,_,ok:=document_apply(&args,&r,quality,`{"nodes":[{"name":"quality","kind":"select_row","label":"Render scale"}]}`)
    if !testing.expectf(t,ok,"%s",call.error.message) {return}
    quality=document_row_of(&r,"quality")
    testing.expect_value(t,serial.text_field(r.nodes[quality].bind_visible[:]),"")
    rows:=0
    for &o in r.overrides {if int(o.instance)==quality {rows+=1}}
    testing.expect_value(t,rows,1)
    // An unknown parameter says what it has.
    wrong:api.Call
    wrong_args:=call_args(&wrong,&types,"{}")
    _,_,failed:=document_apply(&wrong_args,&r,quality,`{"nodes":[{"name":"quality","kind":"select_row","colour":"x"}]}`)
    testing.expect(t,!failed)
    testing.expectf(t,strings.contains(wrong.error.message,"has no parameter 'colour'"),"%s",wrong.error.message)
}

@(test)
a_parameter_changed_in_the_editor_writes_where_its_component_says_and_reads_back :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    r:Records
    if !document_of(t,&types,&r,THEME_DOCUMENT) {return}
    row:=document_row_of(&r,"quality")
    params:=doc_params_of(&r,nil,"select_row")
    if !testing.expect_value(t,len(params),4) {return}
    testing.expect(t,records_param_set(&r,row,&params[0],"Quality level",nil,"select_row"))
    testing.expect(t,records_param_set(&r,row,&params[3],"Shell.other",nil,"select_row"))
    text:=document_text(&types,&r,-1)
    testing.expect(t,strings.contains(text,`"label":"Quality level"`),"a parameter that goes to a node reads back by name")
    testing.expect(t,strings.contains(text,`"dim":"Shell.other"`),"one that goes to the root too")
    testing.expect(t,records_load_as_tree(&r))
}
