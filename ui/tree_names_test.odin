package ui

import "core:testing"

@(test)
what_a_style_extends_is_its_own_until_it_sets_it_itself :: proc(t:^testing.T) {
    styles:=[]Node_Style{{},{fill={1,2,3,255},radius={4,4,4,4}},{fill={9,9,9,255},stroke={7,7,7,255}}}
    infos:=make([]Tree_Style_Info,3,context.temp_allocator)
    tree_text_set(infos[1].name[:],"base")
    infos[1].layout.width,infos[1].layout.gap=GROW,6
    infos[1].sets={.Width,.Gap}
    tree_text_set(infos[2].name[:],"button")
    tree_text_set(infos[2].extends[:],"base")
    infos[2].layout.height=fixed(40)
    infos[2].sets={.Fill,.Stroke,.Height}
    variants:=make([dynamic]Tree_Style_Variant,context.temp_allocator)
    append(&variants,Tree_Style_Variant{style=1,states={.Hovered},own={.Fill,.Move_Y},patch={fields={.Fill,.Move},values={fill={200,0,0,255},move={0,-3}}}})
    append(&variants,Tree_Style_Variant{style=2,states={.Focused},extends={.Hovered},own={.Stroke},patch={fields={.Stroke},values={stroke={0,255,0,255}}}})
    append(&variants,Tree_Style_Variant{style=2,states={.Hovered},own={.Mark},patch={fields={.Mark},values={mark={1,1,1,255}}}})
    tree_settle(styles,infos,&variants,nil,nil)
    // What it extends reaches it where it does not say otherwise; what it sets stays.
    testing.expect_value(t,styles[2].radius,[4]f32{4,4,4,4})
    testing.expect_value(t,styles[2].fill,Color{9,9,9,255})
    testing.expect_value(t,infos[2].layout.width,GROW)
    testing.expect_value(t,infos[2].layout.gap,f32(6))
    testing.expect_value(t,infos[2].layout.height,fixed(40))
    testing.expect(t,.Width in infos[2].layout_keys && .Height in infos[2].layout_keys && .Gap in infos[2].layout_keys)
    rule :: proc(list:[dynamic]Tree_Style_Variant,style:u16,states:Style_States) -> ^Tree_Style_Variant {
        for &v in list {if v.style==style && v.states==states {return &v}}
        return nil
    }
    hover:=rule(variants,2,{.Hovered})
    testing.expect(t,hover!=nil && hover.patch.values.fill==Color{200,0,0,255} && hover.patch.values.mark==Color{1,1,1,255},"a rule of a style that extends takes what its parent's rule of that state sets, and what it sets stays")
    testing.expect_value(t,hover.patch.fields,Style_Fields{.Fill,.Mark,.Move})
    focus:=rule(variants,2,{.Focused})
    testing.expect(t,focus.patch.values.fill==Color{200,0,0,255} && focus.patch.values.stroke==Color{0,255,0,255} && focus.patch.values.move.y==-3,"a state that extends a state starts from it")
    // A change of the parent reaches what the child does not set, the next time it settles.
    styles[1].radius={9,9,9,9}
    tree_settle(styles,infos,&variants,nil,nil)
    testing.expect_value(t,styles[2].radius,[4]f32{9,9,9,9})
}

@(test)
tokens_give_their_values_to_styles_and_rules_that_name_them :: proc(t:^testing.T) {
    styles:=[]Node_Style{{},{fill={1,1,1,255},radius={0,0,0,0}}}
    infos:=make([]Tree_Style_Info,2,context.temp_allocator)
    tree_text_set(infos[1].name[:],"card")
    infos[1].sets={.Gap}
    variants:=make([dynamic]Tree_Style_Variant,context.temp_allocator)
    append(&variants,Tree_Style_Variant{style=1,states={.Hovered},own={.Fill},patch={fields={.Fill}}})
    tokens:=[]Tree_Token{{color={10,20,30,255}},{numeric=true,number=8}}
    tree_text_set(tokens[0].name[:],"ink")
    tree_text_set(tokens[1].name[:],"round")
    uses:=[]Tree_Token_Use{{style=1,key=.Fill},{style=1,key=.Radius},{style=1,key=.Gap},{style=1,states={.Hovered},key=.Fill}}
    for &use,i in uses {
        name:="ink" if use.key==.Fill else "round"
        tree_text_set(use.token[:],name)
        _=i
    }
    tree_settle(styles,infos,&variants,tokens,uses)
    testing.expect_value(t,styles[1].fill,Color{10,20,30,255})
    testing.expect_value(t,styles[1].radius,[4]f32{8,8,8,8})
    testing.expect_value(t,infos[1].layout.gap,f32(8))
    testing.expect_value(t,variants[0].patch.values.fill,Color{10,20,30,255})
    tokens[0].color={40,50,60,255}
    tree_settle(styles,infos,&variants,tokens,uses)
    testing.expect_value(t,styles[1].fill,Color{40,50,60,255})
}

@(test)
a_node_takes_what_its_style_gives_of_its_layout_but_what_it_has_as_its_own :: proc(t:^testing.T) {
    infos:=make([]Tree_Style_Info,2,context.temp_allocator)
    infos[1].layout={width=GROW,height=fixed(60),gap=10}
    infos[1].layout_keys={.Width,.Height,.Gap}
    infos[1].blur=4
    node:=Tree_Node{kind=.Box,style=1,layout={width=fixed(200),padding={1,2,3,4}},layout_own={.Width}}
    nodes:=[]Tree_Node{node}
    tree_nodes_take_styles(nodes,infos)
    testing.expect_value(t,nodes[0].layout.width,fixed(200))
    testing.expect_value(t,nodes[0].layout.height,fixed(60))
    testing.expect_value(t,nodes[0].layout.padding,[4]f32{1,2,3,4})
    testing.expect_value(t,nodes[0].layout.gap,f32(10))
    testing.expect(t,nodes[0].layer.enabled && nodes[0].layer.backdrop_blur==4,"a style with a blur gives its node the layer that draws it")
}

@(test)
the_first_control_of_each_page_takes_the_focus_unless_a_node_of_it_asks :: proc(t:^testing.T) {
    node :: proc(kind:Node_Kind,parent:i32,flags:Node_Flags={}) -> Node {return {kind=kind,parent=parent,flags=flags}}
    nodes:=[]Node{
        node(.Box,-1),                      // 0
        node(.Button,0),                    // 1: first of the tree
        node(.Switcher,0),                  // 2
        node(.Box,2),                       // 3: a page
        node(.Text,3),                      // 4
        node(.Selector,3),                  // 5: first of the page
        node(.Button,3),                    // 6
        node(.Box,2),                       // 7: a page that asks
        node(.Button,7),                    // 8
        node(.Button,7,{.Focus_First}),     // 9
        node(.Box,2),                       // 10: only something passed over
        node(.Button,10,{.Skip}),           // 11
    }
    tree_pages_focus(nodes)
    testing.expect(t,.Focus_First in nodes[1].flags,"the tree's own first control")
    testing.expect(t,.Focus_First in nodes[5].flags,"the first control of a page, past what is not one")
    testing.expect(t,.Focus_First not_in nodes[6].flags && .Focus_First not_in nodes[8].flags,"only one takes it, and not where a node asks")
    testing.expect(t,.Focus_First in nodes[9].flags,"the node that asks keeps it")
    testing.expect(t,.Focus_First not_in nodes[11].flags,"nothing passed over takes it")
}
