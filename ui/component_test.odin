package ui

import "core:testing"
import "mirai:std/base"
import "mirai:std/serial"

Test_Components :: struct {
    nodes:[3]Tree_Node,
    templates:[1]Tree_Component,
    component_nodes:[3]Tree_Node,
    overrides:[2]Tree_Override,
    styles:[2]Node_Style,
    variants:[3]Tree_Style_Variant,
}
test_components :: proc(r:^Test_Components) -> Tree_Data {
    texts:=make([dynamic]u8,context.temp_allocator)
    r.styles={{},{fill={20,25,34,230},fill2={37,30,60,230},stroke={90,90,120,255},radius=12,text={size=14,color={240,240,250,255}}}}
    r.templates={tree_component_record("card",0,3)}
    r.component_nodes={
        tree_node_record(&texts,-1,{kind=.Box,name="card",style=1,layout={width=fixed(180),height=fixed(80),direction=.Column,gap=6,padding=padding_all(8)}}),
        tree_node_record(&texts,0,{kind=.Text,name="title",style=1,text="Title"}),
        tree_node_record(&texts,0,{kind=.Button,name="action",style=1,text="Open",layout={width=fixed(90),height=fixed(28)}}),
    }
    r.nodes={
        tree_node_record(&texts,-1,{kind=.Box,name="container",layout={gap=12}}),
        tree_node_record(&texts,0,{kind=.Component,name="left",component=1,variant="accent"}),
        tree_node_record(&texts,0,{kind=.Component,name="right",component=1}),
    }
    r.overrides={
        tree_override_record(&texts,1,"title",{.Text},{text="Inventory"}),
        tree_override_record(&texts,2,"action",{.Text,.Visibility},{text="Locked",disabled=true}),
    }
    r.variants={
        tree_variant_record(1,"accent",{},{fields={.Fill},tokens={fill=.Accent}}),
        tree_variant_record(1,"",{.Hovered},{fields={.Fill},tokens={fill=.Field_Hover}}),
        tree_variant_record(1,"",{.Disabled},{fields={.Fill,.Text_Size,.Text_Color},tokens={fill=.Field,text=.Text_Faint},values={text={size=14}}}),
    }
    return {text=texts[:],nodes=r.nodes[:],styles=r.styles[:],components=r.templates[:],component_nodes=r.component_nodes[:],overrides=r.overrides[:],variants=r.variants[:]}
}

@(test)
components_expand_once_with_independent_names_overrides_and_variants :: proc(t:^testing.T) {
    r:Test_Components
    tree:Widget_Tree
    testing.expect(t,tree_load(&tree,test_components(&r),{}))
    defer tree_destroy(&tree)
    testing.expect_value(t,tree.node_count,7)
    testing.expect_value(t,tree.nodes[0].subtree,i32(6))
    testing.expect_value(t,tree.nodes[1].name,base.name_hash("left"))
    testing.expect_value(t,tree.nodes[2].name,base.name_hash("left/title"))
    testing.expect_value(t,tree.nodes[3].name,base.name_hash("left/action"))
    testing.expect_value(t,tree.nodes[6].name,base.name_hash("right/action"))
    testing.expect_value(t,string(tree.strings[tree.nodes[2].text_offset:][:tree.nodes[2].text_length]),"Inventory")
    testing.expect_value(t,string(tree.strings[tree.nodes[5].text_offset:][:tree.nodes[5].text_length]),"Title")
    testing.expect(t,tree.nodes[6].disabled && !tree.nodes[3].disabled)
    testing.expect_value(t,tree.nodes[2].variant,style_variant("accent"))
    instance:Tree_Instance
    testing.expect(t,tree_instance_init(&instance,&tree,nil))
    defer tree_instance_destroy(&instance)
    Scene :: struct {tree:^Widget_Tree,instance:^Tree_Instance}
    scene:=Scene{&tree,&instance}
    build :: proc(ctx:^Context,user:rawptr) {s:=cast(^Scene)user;tree_build(ctx,s.tree,s.instance,{})}
    owned,ambient,scratch:Test_Counter
    ctx:Context
    desc:=TEST_SMALL
    desc.allocator=test_counter(&owned,context.allocator)
    testing.expect(t,context_init(&ctx,desc))
    defer context_destroy(&ctx)
    input:=test_input()
    frame:=test_frame(&ctx,&input,build,&scene)
    testing.expect(t,!frame.overflow && ctx.stats.layout_errors==0)
    left:=test_rect(t,&ctx,tree_element_id(&ctx,"left/action"))
    right:=test_rect(t,&ctx,tree_element_id(&ctx,"right/action"))
    testing.expect(t,left.x<right.x)
    owned.requests=0
    {
        context.allocator=test_counter(&ambient,context.allocator)
        context.temp_allocator=test_counter(&scratch,context.temp_allocator)
        for _ in 0..<8 {frame=test_frame(&ctx,&input,build,&scene)}
    }
    testing.expect(t,owned.requests==0 && ambient.requests==0 && scratch.requests==0)
}

@(test)
component_cycles_missing_overrides_and_bad_ranges_load_nothing :: proc(t:^testing.T) {
    texts:=make([dynamic]u8,context.temp_allocator)
    r:Test_Components
    data:=test_components(&r)
    tree:Widget_Tree
    refused :: proc(t:^testing.T,tree:^Widget_Tree,data:Tree_Data) {
        testing.expect(t,!tree_load(tree,data,{}))
        testing.expect(t,tree.nodes==nil && tree.variants==nil)
    }
    r.templates[0].count=4
    refused(t,&tree,data)
    data=test_components(&r)
    r.component_nodes[2]=tree_node_record(&texts,0,{kind=.Component,name="self",component=1})
    refused(t,&tree,data)
    data=test_components(&r)
    tree_text_set(r.overrides[0].node[:],"absent")
    refused(t,&tree,data)
    data=test_components(&r)
    r.nodes[2].component=2
    refused(t,&tree,data)
    data=test_components(&r)
    r.component_nodes[2].parent=1
    refused(t,&tree,data)
    data=test_components(&r)
    r.variants[0].style=2
    refused(t,&tree,data)
    data=test_components(&r)
    r.variants[0].states=transmute(Style_States)u8(0x80)
    refused(t,&tree,data)
}

@(test)
nested_components_keep_local_override_paths_and_expanded_parents :: proc(t:^testing.T) {
    texts:=make([dynamic]u8,context.temp_allocator)
    components:=[2]Tree_Component{tree_component_record("outer",0,2),tree_component_record("inner",2,2)}
    component_nodes:=[4]Tree_Node{
        tree_node_record(&texts,-1,{kind=.Box,name="frame"}),tree_node_record(&texts,0,{kind=.Component,name="nested",component=2}),
        tree_node_record(&texts,-1,{kind=.Box,name="inner"}),tree_node_record(&texts,0,{kind=.Text,name="title",text="Before"}),
    }
    nodes:=[1]Tree_Node{tree_node_record(&texts,-1,{kind=.Component,name="menu",component=1})}
    overrides:=[1]Tree_Override{tree_override_record(&texts,0,"nested/title",{.Text},{text="After"})}
    tree:Widget_Tree
    testing.expect(t,tree_load(&tree,{text=texts[:],nodes=nodes[:],components=components[:],component_nodes=component_nodes[:],overrides=overrides[:]},{}))
    defer tree_destroy(&tree)
    testing.expect_value(t,tree.node_count,3)
    testing.expect_value(t,tree.nodes[1].name,base.name_hash("menu/nested"))
    testing.expect_value(t,tree.nodes[2].name,base.name_hash("menu/nested/title"))
    testing.expect_value(t,tree.nodes[2].parent,i32(1))
    testing.expect_value(t,string(tree.strings[:tree.string_length]),"After")
}

@(test)
style_rules_resolve_tokens_variant_and_state_precedence :: proc(t:^testing.T) {
    theme:=THEME_EDITOR
    base_style:=Node_Style{fill={1,2,3,255},radius=8,stroke_width=1,text={size=14,color={255,255,255,255}}}
    rules:=[]Style_Variant{
        {patch={fields={.Fill},values={fill={10,0,0,255}}}},
        {variant=style_variant("accent"),patch={fields={.Fill},tokens={fill=.Accent}}},
        {states={.Selected},patch={fields={.Fill},values={fill={20,0,0,255}}}},
        {states={.Hovered},patch={fields={.Fill},values={fill={30,0,0,255}}}},
        {states={.Pressed},patch={fields={.Fill},values={fill={40,0,0,255}}}},
        {states={.Disabled},patch={fields={.Fill,.Text_Size,.Text_Color},tokens={fill=.Field,text=.Text_Faint},values={text={size=14}}}},
        {states={.Hovered},variant=style_variant("accent"),patch={fields={.Fill},values={fill={50,0,0,255}}}},
    }
    normal:=style_resolve(&theme,base_style,rules)
    testing.expect_value(t,normal.fill,Color{10,0,0,255})
    testing.expect(t,normal.radius==8 && normal.stroke_width==1)
    accent:=style_resolve(&theme,base_style,rules,0,style_variant("accent"))
    testing.expect_value(t,accent.fill,theme.accent)
    theme.accent={120,10,240,255}
    testing.expect_value(t,style_resolve(&theme,base_style,rules,0,style_variant("accent")).fill,theme.accent)
    hovered:=style_resolve(&theme,base_style,rules,0,style_variant("accent"),{.Selected,.Hovered})
    testing.expect_value(t,hovered.fill,Color{50,0,0,255})
    pressed:=style_resolve(&theme,base_style,rules,0,style_variant("accent"),{.Selected,.Hovered,.Pressed})
    testing.expect_value(t,pressed.fill,Color{40,0,0,255})
    disabled:=style_resolve(&theme,base_style,rules,0,style_variant("accent"),{.Selected,.Hovered,.Pressed,.Disabled})
    testing.expect(t,disabled.fill==theme.field && disabled.text.color==theme.text_faint)
}

@(test)
a_button_draws_the_gradient_border_shadow_and_disabled_variant_of_its_look :: proc(t:^testing.T) {
    Scene :: struct {disabled:bool,clicks:int}
    scene:Scene
    build :: proc(ctx:^Context,user:rawptr) {
        s:=cast(^Scene)user
        rules:=[1]Style_Variant{{states={.Disabled},patch={fields={.Fill,.Fill2,.Stroke},values={fill={40,40,40,255},fill2={40,40,40,255},stroke={90,90,90,255}}}}}
        if box(ctx,{width=fixed(96),height=fixed(64),padding=padding_all(8)}) {
            styled:=id(ctx,"styled")
            look:=style_resolve(&ctx.theme,{
                fill={255,0,0,255},fill2={0,0,255,255},stroke={0,255,0,255},radius=12,stroke_width=4,
                shadow=true,shadow_color={255,255,255,255},shadow_blur=3,
            },rules[:],states=widget_states(ctx,styled,false,s.disabled))
            it:=button(ctx,styled,{width=80,height=48,disabled=s.disabled,look=&look})
            if it.clicked {s.clicks+=1}
        }
    }
    ctx:Context
    testing.expect(t,context_init(&ctx,{no_font=true}))
    defer context_destroy(&ctx)
    input:=test_input(96,64)
    frame:=test_frame(&ctx,&input,build,&scene)
    image:=test_raster(&ctx,frame,96,64,1,{0,0,0,255})
    defer test_image_destroy(&image)
    top,bottom:=test_pixel(&image,48,16),test_pixel(&image,48,47)
    testing.expect(t,top.r>top.b && bottom.b>bottom.r)
    testing.expect(t,test_color_near(test_pixel(&image,9,32),{0,255,0,255}))
    testing.expect(t,test_pixel(&image,3,32).r>0,"the analytic shadow extends outside the button")
    rect:=test_rect(t,&ctx,id(&ctx,"styled"))
    test_point(&input,rect)
    test_frame(&ctx,&input,build,&scene)
    test_press(&input)
    test_frame(&ctx,&input,build,&scene)
    testing.expect_value(t,scene.clicks,1)
    test_release(&input)
    test_frame(&ctx,&input,build,&scene)
    scene.disabled=true
    frame=test_frame(&ctx,&input,build,&scene)
    disabled_image:=test_raster(&ctx,frame,96,64,1,{0,0,0,255})
    defer test_image_destroy(&disabled_image)
    testing.expect(t,test_color_near(test_pixel(&disabled_image,48,24),{40,40,40,255}))
    test_press(&input)
    test_frame(&ctx,&input,build,&scene)
    testing.expect(t,scene.clicks==1,"the disabled variant is visible and cannot activate")
    test_image_dump(&image,"component-button-appearance")
    test_image_dump(&disabled_image,"component-button-disabled")
}

@(test)
tree_state_bindings_select_the_style_and_disable_the_bound_button :: proc(t:^testing.T) {
    texts:=make([dynamic]u8,context.temp_allocator)
    s:Test_Hud_Tree
    serial.schema_init(&s.schema)
    s.type,_=serial.schema_add(&s.schema,Test_Hud)
    defer serial.schema_destroy(&s.schema)
    nodes:=[2]Tree_Node{tree_node_record(&texts,-1,{kind=.Box,name="panel"}),tree_node_record(&texts,0,{kind=.Button,name="action",style=1,bind_selected="Test.paused",bind_disabled="Test.muted",layout={width=fixed(80),height=fixed(40)}})}
    styles:=[2]Node_Style{{},{fill={200,0,0,255}}}
    rules:=[2]Tree_Style_Variant{
        tree_variant_record(1,"",{.Selected},{fields={.Fill},values={fill={0,200,0,255}}}),
        tree_variant_record(1,"",{.Disabled},{fields={.Fill},values={fill={40,40,40,255}}}),
    }
    testing.expect(t,tree_load(&s.tree,{text=texts[:],nodes=nodes[:],styles=styles[:],variants=rules[:]},{}))
    defer tree_destroy(&s.tree)
    testing.expect(t,tree_instance_init(&s.instance,&s.tree,test_host(&s.host,&s.schema,s.type,&s.values)))
    defer tree_instance_destroy(&s.instance)
    ctx:Context
    testing.expect(t,context_init(&ctx,{no_font=true}))
    defer context_destroy(&ctx)
    input:=test_input(96,64)
    s.values.paused,s.values.muted=true,true
    frame:=test_frame(&ctx,&input,test_hud_build,&s)
    disabled:=test_raster(&ctx,frame,96,64,1,{0,0,0,255})
    defer test_image_destroy(&disabled)
    testing.expect(t,test_color_near(test_pixel(&disabled,8,8),{40,40,40,255}))
    test_point(&input,test_rect(t,&ctx,tree_element_id(&ctx,"action")))
    test_press(&input)
    test_frame(&ctx,&input,test_hud_build,&s)
    for event in s.events[:s.event_count] {testing.expect(t,event.kind!=.Clicked,"a disabled button does not click")}
    test_release(&input)
    test_frame(&ctx,&input,test_hud_build,&s)
    s.values.muted=false
    frame=test_frame(&ctx,&input,test_hud_build,&s)
    selected:=test_raster(&ctx,frame,96,64,1,{0,0,0,255})
    defer test_image_destroy(&selected)
    testing.expect(t,test_color_near(test_pixel(&selected,8,8),{0,200,0,255}))
    test_frame(&ctx,&input,test_hud_build,&s)
    test_press(&input)
    test_frame(&ctx,&input,test_hud_build,&s)
    clicked:=0
    for event in s.events[:s.event_count] {if event.name==base.name_hash("action") && event.kind==.Clicked {clicked+=1}}
    testing.expect_value(t,clicked,1)
}

@(test)
unused_component_templates_obey_the_same_limits_as_their_instances :: proc(t:^testing.T) {
    texts:=make([dynamic]u8,context.temp_allocator)
    nodes:[TREE_DEPTH+1]Tree_Node
    for &node,i in nodes {node=tree_node_record(&texts,i32(i)-1,{kind=.Box})}
    templates:=[1]Tree_Component{tree_component_record("unused",0,TREE_DEPTH+1)}
    tree:Widget_Tree
    data:=Tree_Data{text=texts[:],components=templates[:],component_nodes=nodes[:]}
    testing.expect(t,!tree_load(&tree,data,{}),"a template is validated even when no node uses it")
    templates[0].count=TREE_DEPTH
    testing.expect(t,tree_load(&tree,data,{}))
    tree_destroy(&tree)
    nodes[0].style=1
    testing.expect(t,!tree_load(&tree,data,{}))
    nodes[0].style=0;nodes[0].image=1
    testing.expect(t,!tree_load(&tree,data,{}))
    nodes[0].image=0;nodes[0].anims=1
    testing.expect(t,!tree_load(&tree,data,{}))
}

@(test)
component_namespaces_preserve_unnamed_node_ids_and_long_root_names :: proc(t:^testing.T) {
    texts:=make([dynamic]u8,context.temp_allocator)
    r:Test_Components
    data:=test_components(&r)
    r.component_nodes[1].name={}
    data.overrides=nil
    scene:Test_Hud_Tree
    testing.expect(t,tree_load(&scene.tree,data,{}))
    defer tree_destroy(&scene.tree)
    testing.expect_value(t,scene.tree.nodes[2].name,u64(0))
    testing.expect_value(t,scene.tree.nodes[5].name,u64(0))
    testing.expect(t,tree_instance_init(&scene.instance,&scene.tree,nil))
    defer tree_instance_destroy(&scene.instance)
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    input:=test_input()
    test_frame(&ctx,&input,test_hud_build,&scene)
    testing.expect_value(t,ctx.stats.layout_errors,u32(0))
    tree:Widget_Tree
    component_nodes:=[1]Tree_Node{tree_node_record(&texts,-1,{kind=.Box,name="root"})}
    components:=[1]Tree_Component{tree_component_record("single",0,1)}
    nodes:=[1]Tree_Node{tree_node_record(&texts,-1,{kind=.Component,name="a_root_name_which_uses_all_sixty_three_characters_of_its_capacity",component=1})}
    testing.expect(t,tree_load(&tree,{text=texts[:],nodes=nodes[:],components=components[:],component_nodes=component_nodes[:]},{}))
    tree_destroy(&tree)
}
