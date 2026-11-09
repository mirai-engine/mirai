package ui

import "core:strings"
import "core:testing"
import "mirai:std/base"
import "mirai:std/serial"

@(private="file")
Sheet_Scene :: struct {
    tree:Widget_Tree,
    instance:Tree_Instance,
}
@(private="file")
sheet_build :: proc(ctx:^Context,user:rawptr) {
    s:=cast(^Sheet_Scene)user
    tree_build(ctx,&s.tree,&s.instance,{})
}
@(private="file")
sheet_tree :: proc(t:^testing.T,s:^Sheet_Scene,sheet:^Sheet,name:=#caller_expression(sheet)) -> bool {
    testing.expect_value(t,sheet_problem(sheet),"") or_return
    data,imports:=sheet_data(sheet)
    linked,ok:=tree_link(data,imports)
    testing.expect(t,ok,"the records of the sheet link") or_return
    testing.expect(t,tree_load(&s.tree,linked,{textures=make([]u32,len(linked.images),context.temp_allocator),fonts=make([]u8,len(linked.fonts),context.temp_allocator)}),"the records of the sheet load") or_return
    testing.expect(t,tree_instance_init(&s.instance,&s.tree,nil)) or_return
    return true
}

@(test)
a_sheet_compiles_names_tokens_and_states_into_the_tables_of_a_tree :: proc(t:^testing.T) {
    s:=sheet_make("shell")
    sheet_tokens(&s,{{"ink","#10203040"},{"gap",12},{"also_ink","ink"}})
    sheet_styles(&s,{
        {name="base",fill="also_ink",radius="gap",hover={fill="#ff0000"}},
        {name="big",extends={"base"},size=20,color="#ffffff",fill2="#00ff00",hover={stroke="#0000ff"},
            pressed={move_y=4,scale=0.9},transition=0.1,variants={{name="gold",fill="#ffd700"}}},
    })
    node:=sheet_node(&s,-1,"big",{kind=.Text,text="hello",name="label"})
    testing.expect_value(t,sheet_problem(&s),"")
    testing.expect_value(t,node,i32(0))
    testing.expect_value(t,s.rows[s.nodes[0].style].fill,Color{0x10,0x20,0x30,0x40})
    testing.expect_value(t,s.rows[s.nodes[0].style].radius,[4]f32{12,12,12,12})
    testing.expect_value(t,s.rows[s.nodes[0].style].text.size,f32(20))
    testing.expect_value(t,s.rows[s.nodes[0].style].transition,f32(0.1))
    // What a state changes is the patch, with no mask written by hand: hover of a child keeps the fill its parent's hover set.
    rule :: proc(s:^Sheet,style:u16,states:Style_States,variant:string) -> ^Tree_Style_Variant {
        for &v in s.variants {
            if v.style==style && v.states==states && serial.text_field(v.variant[:])==variant {return &v}
        }
        return nil
    }
    row:=s.nodes[0].style
    hover:=rule(&s,row,{.Hovered},"")
    if !testing.expect(t,hover!=nil,"the state becomes a rule") {return}
    testing.expect_value(t,hover.patch.fields,Style_Fields{.Fill,.Stroke})
    testing.expect_value(t,hover.patch.values.fill,Color{255,0,0,255})
    testing.expect_value(t,hover.patch.values.stroke,Color{0,0,255,255})
    pressed:=rule(&s,row,{.Pressed},"")
    if !testing.expect(t,pressed!=nil) {return}
    testing.expect_value(t,pressed.patch.values.move,[2]f32{0,4})
    testing.expect_value(t,pressed.patch.values.scale,f32(0.9))
    testing.expect(t,rule(&s,row,{},"gold")!=nil,"a named variant is a rule of its name")
    testing.expect_value(t,serial.text_field(s.infos[row].name[:]),"big")
}

@(test)
a_sheet_says_what_is_wrong_and_how_to_fix_it :: proc(t:^testing.T) {
    Case :: struct {name:string,proc_:proc(s:^Sheet),says:string}
    cases:=[]Case{
        {"style unknown",proc(s:^Sheet){sheet_node(s,-1,"nope",{kind=.Box})},"style 'nope'"},
        {"token unknown",proc(s:^Sheet){sheet_styles(s,{{name="a",fill="nope"}})},"token 'nope'"},
        {"extends undeclared",proc(s:^Sheet){sheet_styles(s,{{name="a",extends={"nope"}}})},"extends 'nope'"},
        {"text without a color",proc(s:^Sheet){sheet_styles(s,{{name="a",size=12}});sheet_node(s,-1,"a",{kind=.Text})},"no color"},
        {"component unknown",proc(s:^Sheet){sheet_use(s,-1,"nope",{name="x"})},"component 'nope'"},
        {"bad hex",proc(s:^Sheet){sheet_styles(s,{{name="a",fill="#12"}})},"no color"},
        {"size token in a color",proc(s:^Sheet){sheet_tokens(s,{{"w",3}});sheet_styles(s,{{name="a",fill="w"}})},"is a size"},
    }
    for c in cases {
        s:=sheet_make("t")
        c.proc_(&s)
        testing.expect(t,strings.contains(sheet_problem(&s),c.says),c.name)
    }
}

@(test)
a_screen_shares_the_styles_tokens_and_components_of_another_file_through_the_link :: proc(t:^testing.T) {
    THEME_FILE :: base.Asset_Id{9,9}
    theme:=sheet_make("theme")
    sheet_tokens(&theme,{{"ink","#123456"}})
    sheet_styles(&theme,{{name="button",fill="ink",size=14,color="#ffffff",hover={fill="#ff00ff"}},{name="row",fill="#010203"}})
    if sheet_component(&theme,"button") {
        sheet_node(&theme,-1,"button",{kind=.Button,layout={width=fixed(90),height=fixed(30)}})
    }
    screen:=sheet_make("screen")
    sheet_take(&screen,THEME_FILE,&theme)
    // A token of the other file, used by a style of this one.
    sheet_styles(&screen,{{name="local",fill="ink",extends={"row"}}})
    panel:=sheet_node(&screen,-1,"local",{kind=.Box,name="root",layout={direction=.Column}})
    sheet_use(&screen,panel,"button",{name="menu_play",text="Play",flags={.Focus_First}})
    sheet_node(&screen,panel,"button",{kind=.Button,name="other",text="Other",layout={width=fixed(40),height=fixed(20)}})
    s:Sheet_Scene
    if !sheet_tree(t,&s,&screen) {return}
    defer tree_destroy(&s.tree)
    defer tree_instance_destroy(&s.instance)
    testing.expect_value(t,s.tree.node_count,3)
    testing.expect_value(t,s.tree.styles[s.tree.nodes[0].style].fill,Color{0x12,0x34,0x56,255})
    testing.expect_value(t,s.tree.nodes[1].name,base.name_hash("menu_play"))
    testing.expect_value(t,s.tree.nodes[1].kind,Node_Kind.Button)
    testing.expect_value(t,string(s.tree.strings[s.tree.nodes[1].text_offset:][:s.tree.nodes[1].text_length]),"Play")
    testing.expect(t,.Focus_First in s.tree.nodes[1].flags,"what the instance says reaches its root")
    testing.expect_value(t,s.tree.styles[s.tree.nodes[1].style].fill,Color{0x12,0x34,0x56,255})
    testing.expect_value(t,s.tree.nodes[2].name,base.name_hash("other"))
    other:=s.tree.nodes[2].style
    testing.expect_value(t,s.tree.styles[other].fill,Color{0x12,0x34,0x56,255})
    // The file's rules come with the style: both the node that names it and the component.
    found:=false
    for rule in s.tree.variants[:s.tree.variant_count] {found||=rule.style==other && rule.states=={.Hovered} && rule.patch.values.fill==Color{255,0,255,255}}
    testing.expect(t,found,"a style taken from a file keeps its states")
    // The file joins the tables once, however many components name it.
    styles:=0
    for style in s.tree.styles[:s.tree.style_count] {if style.fill==(Color{0x12,0x34,0x56,255}) {styles+=1}}
    testing.expect(t,styles<=3,"a file joins once")
}

@(test)
what_an_instance_holds_goes_in_the_slot_of_its_template :: proc(t:^testing.T) {
    sheet:=sheet_make("s")
    sheet_styles(&sheet,{{name="card",fill="#ffffff"},{name="title",size=20,color="#000000"}})
    if sheet_component(&sheet,"panel") {
        root:=sheet_node(&sheet,-1,"card",{kind=.Box,flags={.Slot},layout={direction=.Column}})
        sheet_node(&sheet,root,"title",{kind=.Text,name="title"})
    }
    panel:=sheet_use(&sheet,-1,"panel",{name="pause"},{{"title",{text="Paused"},""}})
    sheet_node(&sheet,panel,"title",{kind=.Text,name="line",text="hi"})
    s:Sheet_Scene
    if !sheet_tree(t,&s,&sheet) {return}
    defer tree_destroy(&s.tree)
    defer tree_instance_destroy(&s.instance)
    testing.expect_value(t,s.tree.node_count,3)
    testing.expect_value(t,s.tree.nodes[0].subtree,i32(2))
    testing.expect_value(t,s.tree.nodes[1].name,base.name_hash("pause/title"))
    testing.expect_value(t,string(s.tree.strings[s.tree.nodes[1].text_offset:][:s.tree.nodes[1].text_length]),"Paused")
    testing.expect_value(t,s.tree.nodes[2].parent,i32(0))
    testing.expect_value(t,s.tree.nodes[2].name,base.name_hash("line"))
    // A template with a node after its Slot is refused with the reason.
    wrong:=sheet_make("w")
    sheet_styles(&wrong,{{name="c",fill="#ffffff"}})
    if sheet_component(&wrong,"bad") {
        root:=sheet_node(&wrong,-1,"c",{kind=.Box})
        sheet_node(&wrong,root,"c",{kind=.Box,flags={.Slot}})
        sheet_node(&wrong,root,"c",{kind=.Box,name="after"})
    }
    testing.expect(t,strings.contains(sheet_problem(&wrong),"Slot"),"a node after the Slot says so")
}

@(test)
a_style_moves_and_scales_by_state_without_moving_the_layout_or_the_pointer :: proc(t:^testing.T) {
    s:=sheet_make("s")
    sheet_styles(&s,{{name="face",fill="#ffffff",size=12,color="#000000",hover={fill="#00ff00",move_y=-10,scale=1.5}}})
    sheet_node(&s,-1,"face",{kind=.Button,name="button",layout={width=fixed(80),height=fixed(40)},float={to=.Surface,offset={8,20}}})
    scene:Sheet_Scene
    if !sheet_tree(t,&scene,&s) {return}
    defer tree_destroy(&scene.tree)
    defer tree_instance_destroy(&scene.instance)
    ctx:Context
    testing.expect(t,context_init(&ctx,{no_font=true}))
    defer context_destroy(&ctx)
    input:=test_input(128,96)
    frame:=test_frame(&ctx,&input,sheet_build,&scene)
    rest:=test_rect(t,&ctx,tree_element_id(&ctx,"button"))
    resting:=test_raster(&ctx,frame,128,96,1,{0,0,0,255})
    defer test_image_destroy(&resting)
    testing.expect(t,test_color_near(test_pixel(&resting,48,40),{255,255,255,255}),"the face where the layout put it")
    // At the lower edge the lift would leave the pointer behind were it not still.
    input.pointer={48,rest.y+rest.h-2}
    test_frame(&ctx,&input,sheet_build,&scene)
    frame=test_frame(&ctx,&input,sheet_build,&scene)
    testing.expect_value(t,ctx.hot,tree_element_id(&ctx,"button"))
    moved:=test_rect(t,&ctx,tree_element_id(&ctx,"button"))
    testing.expect_value(t,moved,rest)
    lifted:=test_raster(&ctx,frame,128,96,1,{0,0,0,255})
    defer test_image_destroy(&lifted)
    testing.expect(t,test_color_near(test_pixel(&lifted,48,18),{0,255,0,255}),"drawn scaled about its center and moved up")
    testing.expect(t,test_color_near(test_pixel(&lifted,48,62),{0,0,0,255}),"not drawn where it was")
}

@(test)
the_focus_leaves_a_button_a_style_moves :: proc(t:^testing.T) {
    s:=sheet_make("s")
    sheet_styles(&s,{{name="face",fill="#ffffff",size=12,color="#000000",focus={move_y=-3,scale=1.1}}})
    column:=sheet_node(&s,-1,"",{kind=.Box,float={to=.Surface,offset={8,8}},layout={direction=.Column,gap=8}})
    sheet_node(&s,column,"face",{kind=.Button,name="first",flags={.Focus_First},layout={width=fixed(60),height=fixed(24)}})
    sheet_node(&s,column,"face",{kind=.Button,name="second",layout={width=fixed(60),height=fixed(24)}})
    scene:Sheet_Scene
    if !sheet_tree(t,&scene,&s) {return}
    defer tree_destroy(&scene.tree)
    defer tree_instance_destroy(&scene.instance)
    ctx:Context
    testing.expect(t,context_init(&ctx,{no_font=true,navigation=true}))
    defer context_destroy(&ctx)
    input:=test_input(128,96)
    test_frame(&ctx,&input,sheet_build,&scene)
    test_frame(&ctx,&input,sheet_build,&scene)
    testing.expect_value(t,ctx.focus,tree_element_id(&ctx,"first"))
    input.keys_repeated+={.Down}
    test_frame(&ctx,&input,sheet_build,&scene)
    input.keys_repeated-={.Down}
    testing.expect_value(t,ctx.focus,tree_element_id(&ctx,"second"))
}

@(test)
transitions_carry_what_a_style_moves_as_they_carry_its_colors :: proc(t:^testing.T) {
    look:Style_Transition
    a:=Node_Style{fill={0,0,0,255}}
    style_transition(&look,&a,0.1,0.016)
    b:=Node_Style{fill={0,0,0,255},move={0,-8},scale=1.2}
    testing.expect(t,style_transition(&look,&b,0.1,0.05),"it is on its way")
    c:=Node_Style{fill={0,0,0,255},move={0,-8},scale=1.2}
    testing.expect(t,style_transition(&look,&c,0.1,0.05))
    testing.expect(t,test_near(c.move.y,-4,0.01),"half way")
    testing.expect(t,test_near(c.scale,1.1,0.01),"half way")
}

@(test)
a_rounded_box_draws_its_gradient_border_and_hard_shadow_through_the_records :: proc(t:^testing.T) {
    s:=sheet_make("s")
    sheet_styles(&s,{{name="face",fill="#ff0000",fill2="#0000ff",stroke="#00ff00",border=4,radius=10,shadow={color="#ffffff",x=0,y=6}}})
    sheet_node(&s,-1,"face",{kind=.Box,name="box",float={to=.Surface,offset={20,16}},layout={width=fixed(60),height=fixed(40)}})
    // Without corners its stroke still goes around it.
    sheet_styles(&s,{{name="square",fill="#ff0000",fill2="#0000ff",stroke="#00ff00",border=4}})
    sheet_node(&s,-1,"square",{kind=.Box,float={to=.Surface,offset={90,16}},layout={width=fixed(30),height=fixed(40)}})
    scene:Sheet_Scene
    if !sheet_tree(t,&scene,&s) {return}
    defer tree_destroy(&scene.tree)
    defer tree_instance_destroy(&scene.instance)
    ctx:Context
    testing.expect(t,context_init(&ctx,{no_font=true}))
    defer context_destroy(&ctx)
    input:=test_input(128,96)
    frame:=test_frame(&ctx,&input,sheet_build,&scene)
    image:=test_raster(&ctx,frame,128,96,1,{0,0,0,255})
    defer test_image_destroy(&image)
    top:=test_pixel(&image,50,22)
    bottom:=test_pixel(&image,50,50)
    testing.expect(t,top.r>200 && top.b<100,"the fill starts red at the top")
    testing.expect(t,bottom.b>150 && bottom.r<120,"and goes down into blue")
    border:=test_pixel(&image,22,36)
    testing.expect(t,test_color_near(border,{0,255,0,255}),"the border goes all around")
    corner:=test_pixel(&image,21,17)
    testing.expect(t,test_color_near(corner,{0,0,0,255}),"the corners are round")
    edge:=test_pixel(&image,50,58)
    testing.expect(t,test_color_near(edge,{255,255,255,255}),"a hard shadow is a solid edge under it")
    testing.expect(t,test_color_near(test_pixel(&image,92,36),{0,255,0,255}),"a square box with a gradient keeps its stroke")
}
