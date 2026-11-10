package author

import "core:mem"
import "core:slice"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:std/serial"
import "mirai:ui"

// The texts the sample shows: what its keys say.
@(private="file")
sample_texts :: proc() -> Texts {
    texts:=texts_read({},"en")
    texts_set(&texts,"hud.trips","en","Trips")
    texts_set(&texts,"hud.trips","es","Viajes")
    texts_set(&texts,"fuel","en","Fuel")
    for &file in texts.files {file.changed=false}
    return texts
}

// A hud with a named style and its rule, a localized title with a look of its
// own, a bar that holds a progress and a localized label without a name, and
// a button that plays an animation.
@(private="file")
document_sample :: proc(t:^testing.T,r:^Records) -> bool {
    texts:=make([dynamic]u8,context.temp_allocator)
    nodes:=[]ui.Tree_Node{
        ui.tree_node_record(&texts,-1,{kind=.Box,name="hud",float={to=.Safe,anchor=.Top_Left,pivot=.Top_Left}}),
        ui.tree_node_record(&texts,0,{kind=.Text,name="title",text="hud.trips",bind_text="trips",flags={.Localized}}),
        ui.tree_node_record(&texts,0,{kind=.Box,name="bar"}),
        ui.tree_node_record(&texts,2,{kind=.Progress,name="fuel",bind_value="fuel"}),
        ui.tree_node_record(&texts,2,{kind=.Text,text="fuel",flags={.Localized}}), // without a name, as generated files have them
        ui.tree_node_record(&texts,-1,{kind=.Button,name="menu",text="Menu"}),
    }
    styles:=[]ui.Node_Style{{},{fill={20,20,30,255},radius={8,8,8,8}},{text={size=18}}}
    infos:=make([]ui.Tree_Style_Info,3,context.temp_allocator)
    ui.tree_text_set(infos[1].name[:],"card")
    infos[2].family=.Text
    if !testing.expect(t,records_load(r,{text=texts[:],nodes=nodes,styles=styles,style_infos=infos},context.allocator)) {return false}
    r.nodes[0].style,r.nodes[1].style=1,2
    append(&r.variants,ui.Tree_Style_Variant{style=1,states={.Hovered},patch={fields={.Fill},values={fill={40,40,60,255}}}})
    pop:=records_clip(r,"pop",.Opacity,{0,0,0,0},{1,0,0,0},0.2)
    set:=records_anim_set(r,&r.nodes[5])
    r.anim_sets[set].shown=ui.Anim(pop+1)
    return true
}

@(private="file")
document_text :: proc(types:^asset.Types,r:^Records,root:int,texts:^Texts=nil) -> string {
    buffer:=make([]u8,1<<16,context.temp_allocator)
    w:serial.Writer
    serial.writer_init_fixed(&w,buffer)
    document_write(&w,types,r,root,texts=texts)
    return string(serial.writer_bytes(&w))
}

@(test)
a_document_written_back_leaves_the_file_as_it_was :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    r:Records
    if !document_sample(t,&r) {return}
    defer records_destroy(&r)
    texts:=sample_texts()
    for root in ([2]int{-1,0}) {
        before:=document_text(&types,&r,root,&texts)
        reading:Reading
        args:=call_args(&reading,&types,"{}")
        args.texts=&texts
        made,removed,ok:=document_apply(&args,&r,root,before)
        if !testing.expectf(t,ok,"%s",reading.problem) {return}
        testing.expect(t,made==0 && removed==0)
        testing.expect_value(t,document_text(&types,&r,root,&texts),before)
        testing.expect(t,!texts.files[0].changed && len(texts.rows)==2,"the texts stay as they were")
    }
    title:=document_row_of(&r,"title")
    testing.expect(t,.Localized in r.nodes[title].flags && records_text(&r,r.nodes[title].text)=="hud.trips")
    testing.expect(t,r.nodes[4].name[0]==0 && records_text(&r,r.nodes[4].text)=="fuel","a node without a name is matched by place and keeps none")
    testing.expect(t,records_load_as_tree(&r))
}

@(test)
a_document_of_a_node_changes_that_node_alone :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    r:Records
    if !document_sample(t,&r) {return}
    defer records_destroy(&r)
    menu:=r.nodes[document_row_of(&r,"menu")]
    reading:Reading
    args:=call_args(&reading,&types,"{}")
    made,removed,ok:=document_apply(&args,&r,document_row_of(&r,"hud"),`{"nodes":[{"name":"hud","kind":"Box","style":"card","children":[
        {"name":"fuel","kind":"Progress","bind_value":"fuel"},
        {"name":"note","kind":"Text","text":"Hi"}]}]}`)
    if !testing.expectf(t,ok,"%s",reading.problem) {return}
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
    testing.expect(t,records_load_as_tree(&r))
}

@(test)
a_document_without_nodes_changes_only_the_styles_and_animations_it_names :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    r:Records
    if !document_sample(t,&r) {return}
    defer records_destroy(&r)
    nodes:=len(r.nodes)
    reading:Reading
    args:=call_args(&reading,&types,"{}")
    _,_,ok:=document_apply(&args,&r,-1,`{"styles":{"card":{"family":"Box","radius":4},"panel":{"family":"Box","defaults":["Box"]}},"animations":{"pop":null}}`)
    if !testing.expectf(t,ok,"%s",reading.problem) {return}
    testing.expect_value(t,len(r.nodes),nodes)
    card:=tree_style_row(&r,"card")
    testing.expect(t,r.styles[card].radius==[4]f32{4,4,4,4} && r.styles[card].fill==ui.Color{})
    for &v in r.variants {testing.expect(t,int(v.style)!=card,"a style declared without rules has none")}
    testing.expect_value(t,records_kind_style(&r,.Box),tree_style_row(&r,"panel"))
    testing.expect_value(t,len(r.anims),0)
    testing.expect_value(t,r.anim_sets[r.nodes[5].anims-1].shown,ui.Anim(0))
}

// A node with a key shows what the key says: the document gives that text
// beside it, and writing it sets the key in the language texts are written
// in. An empty key is made from the text: equal texts share one, and a name
// another text took gets a number.
@(test)
a_node_with_a_key_reads_and_writes_its_text_in_the_texts_of_the_game :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    r:Records
    if !document_sample(t,&r) {return}
    defer records_destroy(&r)
    texts:=sample_texts()
    write :: proc(t:^testing.T,types:^asset.Types,r:^Records,texts:^Texts,node,document:string) -> bool {
        reading:Reading
        args:=call_args(&reading,types,"{}")
        args.texts=texts
        _,_,ok:=document_apply(&args,r,document_row_of(r,node) if node!="" else -1,document)
        return testing.expectf(t,ok,"%s",reading.problem)
    }
    key_of :: proc(r:^Records,node:string) -> string {return records_text(r,r.nodes[document_row_of(r,node)].text)}
    first:=document_text(&types,&r,-1,&texts)
    testing.expectf(t,strings.contains(first,`"text":"Trips","key":"hud.trips"`),"a localized node says its text and its key: %s",first)
    if !write(t,&types,&r,&texts,"title",`{"nodes":[{"name":"title","kind":"Text","text":"Hi","key":"hud.trips"}]}`) {return}
    testing.expect(t,.Localized in r.nodes[document_row_of(&r,"title")].flags && key_of(&r,"title")=="hud.trips")
    testing.expect_value(t,texts_text(&texts,"hud.trips","en"),"Hi")
    testing.expect_value(t,texts_text(&texts,"hud.trips","es"),"Viajes")
    testing.expect(t,texts.files[0].changed)
    // A key alone shows what it already says.
    if !write(t,&types,&r,&texts,"menu",`{"nodes":[{"name":"menu","kind":"Button","key":"hud.trips"}]}`) {return}
    testing.expect(t,strings.contains(document_text(&types,&r,document_row_of(&r,"menu"),&texts),`"text":"Hi","key":"hud.trips"`))
    // Without a key it is not localized, and the key keeps its texts.
    if !write(t,&types,&r,&texts,"title",`{"nodes":[{"name":"title","kind":"Text","text":"Hi"}]}`) {return}
    testing.expect(t,.Localized not_in r.nodes[document_row_of(&r,"title")].flags && key_of(&r,"title")=="Hi" && texts_text(&texts,"hud.trips","es")=="Viajes")
    // A key made from the text: shared by the nodes that say it, numbered where another text has the name.
    if !write(t,&types,&r,&texts,"title",`{"nodes":[{"name":"title","kind":"Text","text":"Start","key":""}]}`) {return}
    if !write(t,&types,&r,&texts,"menu",`{"nodes":[{"name":"menu","kind":"Button","text":"Start","key":""}]}`) {return}
    if !write(t,&types,&r,&texts,"fuel",`{"nodes":[{"name":"fuel","kind":"Progress","text":"Start!","key":""}]}`) {return}
    testing.expect(t,key_of(&r,"title")=="start" && key_of(&r,"menu")=="start" && key_of(&r,"fuel")=="start_2")
    testing.expect(t,texts_text(&texts,"start","en")=="Start" && texts_text(&texts,"start_2","en")=="Start!")
    made:=[]struct{text,key:string}{
        {"Score: {coins}","score_coins"},
        {"...","text"},
        {"Start","start"},
        {"The quick brown fox jumps over the lazy dog again","the_quick_brown_fox_jumps_over_the_lazy"},
    }
    for c in made {testing.expect_value(t,texts_key(&texts,c.text),c.key)}
    again:=document_text(&types,&r,-1,&texts)
    if !write(t,&types,&r,&texts,"",again) {return}
    testing.expect_value(t,document_text(&types,&r,-1,&texts),again)
    testing.expect(t,records_load_as_tree(&r))
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
        {"",`{"nodes":[{"name":"x","kind":"Text","style":"card","look":{"radius":1}}]}`,"nodes[0]: look: a node has a style or a look"},
        {"",`{"nodes":[{"name":"x","kind":"Text","key":""}]}`,"nodes[0]: key: \"\" makes the key from the text of the node, and it has none"},
        {"",`{"nodes":[{"name":"x","kind":"Text","text":"Hi","key":7}]}`,"nodes[0]: key must be a string"},
        {"",`{"nodes":[{"name":"x","kind":"Text","text":"Hi","key":"a_key_that_goes_on_and_on_past_the_sixty_three_bytes_a_key_can_have"}]}`,"nodes[0]: key: a key is a name shorter than 64 bytes"},
        {"",`{"nodes":[{"name":"x","kind":"Text","text":"Hi","translations":{"es":"Hola"}}]}`,"nodes[0]: the node has no field 'translations'"},
        {"",`{"nodes":[{"name":"x","kind":"Text","flags":["Localized"]}]}`,"nodes[0]: flags: a node is Localized by its key"},
    }
    for c in cases {
        r:Records
        if !document_sample(t,&r) {return}
        reading:Reading
        args:=call_args(&reading,&types,"{}")
        texts:=sample_texts()
        args.texts=&texts
        root:=document_row_of(&r,c.node) if c.node!="" else -1
        _,_,ok:=document_apply(&args,&r,root,c.document)
        testing.expect(t,!ok)
        testing.expectf(t,strings.has_prefix(reading.problem,c.message),"%s gave '%s'",c.document,reading.problem)
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
"animations":{"pulse":{"scale":[1,1.2],"seconds":0.6,"ease":"Quad_In_Out","loop":"Ping_Pong"}},
"nodes":[{"name":"panel","kind":"Box","style":"base","float":{"to":"Surface"},"children":[
    {"name":"play","kind":"Button","style":"button","text":"Play","height":64,"events":{"shown":"pulse"}}]}]}`

@(private="file")
document_of :: proc(t:^testing.T,types:^asset.Types,r:^Records,text:string) -> bool {
    empty:=[1]ui.Node_Style{{}}
    if !testing.expect(t,records_load(r,{styles=empty[:]},context.temp_allocator)) {return false}
    reading:Reading
    args:=call_args(&reading,types,"{}")
    _,_,ok:=document_apply(&args,r,-1,text)
    if !testing.expectf(t,ok,"%s",reading.problem) {return false}
    ui.tree_settle(r.styles[:],r.style_infos[:],&r.variants,r.tokens[:],r.token_uses[:])
    return true
}

@(test)
a_document_with_names_comes_back_the_same_and_changes_nothing_when_written :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    r:Records
    if !document_of(t,&types,&r,THEME_DOCUMENT) {return}
    first:=document_text(&types,&r,-1)
    for expected in ([]string{`"extends":"base"`,`"fill":"ink"`,`"focus":{"extends":"hover"`,`"pressed":{"scale":0.9`,`"width":"grow"`,`"radius":"round"`,`"pulse":{"scale":[1,1.2]`,`"height":64`}) {
        testing.expectf(t,strings.contains(first,expected),"the document names %s: %s",expected,first)
    }
    testing.expect(t,!strings.contains(first,"#ff0000\",\"fields"),"no field masks")
    reading:Reading
    args:=call_args(&reading,&types,"{}")
    made,removed,ok:=document_apply(&args,&r,-1,first)
    if !testing.expectf(t,ok,"%s",reading.problem) {return}
    testing.expect(t,made==0 && removed==0,"writing what it gave makes and takes nothing")
    ui.tree_settle(r.styles[:],r.style_infos[:],&r.variants,r.tokens[:],r.token_uses[:])
    testing.expect_value(t,document_text(&types,&r,-1),first)
    testing.expect(t,records_load_as_tree(&r))
}

@(test)
a_look_that_extends_a_style_follows_it_and_comes_back_the_same :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    r:Records
    if !document_of(t,&types,&r,`{"styles":{"label":{"size":12,"color":"#112233","hover":{"color":"#ffffff"}}},"nodes":[
        {"name":"a","kind":"Text","style":"label"},
        {"name":"b","kind":"Text","look":{"extends":"label","radius":9,"hover":{"scale":1.1}}}]}`) {return}
    b:=int(r.nodes[document_row_of(&r,"b")].style)
    testing.expect_value(t,records_style_base(&r,b),tree_style_row(&r,"label"))
    testing.expect_value(t,r.styles[b].text.color,ui.Color{0x11,0x22,0x33,255})
    testing.expect_value(t,r.styles[b].radius,[4]f32{9,9,9,9})
    first:=document_text(&types,&r,-1)
    for expected in ([]string{`"look":{"extends":"label","radius":9`,`"hover":{"scale":1.1`}) {
        testing.expectf(t,strings.contains(first,expected),"the document says %s: %s",expected,first)
    }
    testing.expect(t,!strings.contains(first,`"radius":9,"hover":{"color"`),"it does not copy the style's own")
    reading:Reading
    args:=call_args(&reading,&types,"{}")
    _,_,ok:=document_apply(&args,&r,-1,first)
    if !testing.expectf(t,ok,"%s",reading.problem) {return}
    ui.tree_settle(r.styles[:],r.style_infos[:],&r.variants,r.tokens[:],r.token_uses[:])
    testing.expect_value(t,document_text(&types,&r,-1),first)
    // A later change of the style reaches the look.
    args=call_args(&reading,&types,"{}")
    _,_,ok=document_apply(&args,&r,-1,`{"styles":{"label":{"size":20,"color":"#445566","hover":{"color":"#000000"}}}}`)
    if !testing.expectf(t,ok,"%s",reading.problem) {return}
    ui.tree_settle(r.styles[:],r.style_infos[:],&r.variants,r.tokens[:],r.token_uses[:])
    b=int(r.nodes[document_row_of(&r,"b")].style)
    testing.expect_value(t,r.styles[b].text.size,f32(20))
    testing.expect_value(t,r.styles[b].text.color,ui.Color{0x44,0x55,0x66,255})
    testing.expect_value(t,r.styles[b].radius,[4]f32{9,9,9,9})
    hover:^ui.Tree_Style_Variant
    for &v in r.variants {if int(v.style)==b && v.states=={.Hovered} {hover=&v}}
    testing.expect(t,hover!=nil && hover.patch.values.text.color==ui.Color{0,0,0,255} && hover.patch.values.scale==1.1)
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
    reading:Reading
    args:=call_args(&reading,&types,"{}")
    _,_,ok:=document_apply(&args,&r,-1,`{"tokens":{"ink":"#aabbcc"},"styles":{"base":{"fill":"ink","radius":"round","width":"grow","gap":6,"padding":4,"size":14,"color":"#ffffff","text_x":"center"}}}`)
    if !testing.expectf(t,ok,"%s",reading.problem) {return}
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
