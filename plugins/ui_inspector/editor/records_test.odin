package ui_inspector_editor

import "core:strings"
import "core:testing"
import "mirai:cook/author"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

@(private="file")
records_sample :: proc(t:^testing.T,r:^author.Records) -> bool {
    texts:=make([dynamic]u8,context.temp_allocator)
    nodes:=[]ui.Tree_Node{
        ui.tree_node_record(&texts,-1,{kind=.Box,name="hud",float={to=.Safe,anchor=.Top_Left,pivot=.Top_Left}}),
        ui.tree_node_record(&texts,0,{kind=.Text,name="title",text="Trips",bind_text="trips"}),
        ui.tree_node_record(&texts,0,{kind=.Box,name="bar"}),
        ui.tree_node_record(&texts,2,{kind=.Progress,name="fuel",bind_value="fuel"}),
        ui.tree_node_record(&texts,-1,{kind=.Button,name="menu",text="Menu"}),
    }
    styles:=[]ui.Node_Style{{}}
    return testing.expect(t,author.records_load(r,{text=texts[:],nodes=nodes,styles=styles},context.allocator))
}

records_load_as_tree :: proc(r:^author.Records) -> bool {
    tree:ui.Widget_Tree
    data:=author.records_data(r)
    textures:=make([]u32,len(data.images),context.temp_allocator)
    fonts:=make([]u8,len(data.fonts),context.temp_allocator)
    if !ui.tree_load(&tree,data,{textures=textures,fonts=fonts}) {return false}
    ui.tree_destroy(&tree)
    return true
}

@(private="file")
names_of :: proc(nodes:[]ui.Tree_Node) -> [dynamic]string {
    names:=make([dynamic]string,context.temp_allocator)
    for &n in nodes {append(&names,serial.text_field(n.name[:]))}
    return names
}

@(test)
the_preview_shows_bound_names_and_floats_inside_the_stage :: proc(t:^testing.T) {
    texts:=make([dynamic]u8,context.temp_allocator)
    node:=ui.tree_node_record(&texts,-1,{kind=.Text,name="title",text="HP {health}",float={to=.Safe}})
    shown:=make([dynamic]u8,context.temp_allocator)
    preview_node(&node,texts[:],&shown,false)
    testing.expect_value(t,node.float.to,ui.Float_To.Safe) // the stage is the area it hangs from
    testing.expect_value(t,ui.tree_string(shown[:],node.text),"HP {{health}}")
    bound:=ui.tree_node_record(&texts,-1,{kind=.Text,name="trips",bind_text="trips"})
    preview_node(&bound,texts[:],&shown,false)
    testing.expect_value(t,ui.tree_string(shown[:],bound.text),"{{trips}}")
    testing.expect_value(t,serial.text_field(bound.bind_text[:]),"")
    list:=ui.tree_node_record(&texts,-1,{kind=.List,name="slots",bind_items="slots"})
    preview_node(&list,texts[:],&shown,false)
    testing.expect_value(t,list.count,u16(3))
    // A component counts as the nodes of its template.
    nodes:=[]ui.Tree_Node{ui.tree_node_record(&texts,-1,{kind=.Box,name="root"}),ui.tree_node_record(&texts,0,{kind=.Component,name="card",component=1})}
    template:=[]ui.Tree_Node{ui.tree_node_record(&texts,-1,{kind=.Box,name="card"}),ui.tree_node_record(&texts,0,{kind=.Text,name="title"})}
    components:=[]ui.Tree_Component{ui.tree_component_record("card",0,2)}
    data:=ui.Tree_Data{text=texts[:],nodes=nodes,component_nodes=template,components=components}
    testing.expect_value(t,author.tree_node_count(data,nodes[1],0),2)
}

@(test)
a_dragged_node_goes_inside_before_or_after_another_with_what_it_holds :: proc(t:^testing.T) {
    r:author.Records
    if !records_sample(t,&r) {return}
    defer author.records_destroy(&r)
    node_text_set(&r,&r.nodes[3],3,.Spanish,.English,"Combustible")
    // The bar and its fuel into the menu's place at the root, before it.
    at:=author.records_place(&r,2,-1,4)
    testing.expect_value(t,at,2)
    names:=names_of(r.nodes[:])
    testing.expect(t,names[0]=="hud" && names[1]=="title" && names[2]=="bar" && names[3]=="fuel" && names[4]=="menu")
    testing.expect_value(t,r.nodes[2].parent,i32(-1))
    testing.expect_value(t,r.nodes[3].parent,i32(2))
    testing.expect_value(t,node_text_in(&r,&r.nodes[3],.Spanish,.English),"Combustible")
    testing.expect(t,records_load_as_tree(&r))
    // The menu inside the bar, last.
    at=author.records_place(&r,4,2,-1)
    testing.expect_value(t,at,4)
    testing.expect_value(t,r.nodes[4].parent,i32(2))
    // Not into itself, nor into what holds nothing.
    testing.expect_value(t,author.records_place(&r,2,3,-1),-1)
    testing.expect_value(t,author.records_place(&r,2,1,-1),-1)
    testing.expect(t,records_load_as_tree(&r))
}

@(test)
a_node_pasted_into_another_interface_takes_the_rows_it_uses :: proc(t:^testing.T) {
    src,dst:author.Records
    if !records_sample(t,&src) {return}
    // In the source the bar has a named style, and the fuel a look of its own
    // with a font of the file, an image, a fade and a translation.
    panel:=author.records_style_add(&src,{radius={4,4,4,4}},nil,{family=.Box})
    ui.tree_text_set(src.style_infos[panel].name[:],"Panel")
    append(&src.fonts,ui.Tree_Font{font={9,9}})
    own:=author.records_style_add(&src,{text={font=ui.FONT_TREE}},nil,{})
    src.nodes[2].style,src.nodes[3].style=u16(panel),u16(own)
    image:=author.records_image(&src,&src.nodes[3])
    src.images[image].texture={5,5}
    fade:=author.records_clip(&src,"fade",.Opacity,{0,0,0,0},{1,0,0,0},0.2)
    set:=author.records_anim_set(&src,&src.nodes[3])
    src.anim_sets[set].shown=ui.Anim(fade+1)
    node_text_set(&src,&src.nodes[3],3,.Spanish,.English,"Combustible")
    source_id:=src.nodes[3].text_id
    clip:author.Clip_Nodes
    defer author.clip_destroy(&clip)
    author.records_copy(&src,2,&clip)
    author.records_destroy(&src)
    // The other has a style of that name and family, and an animation of that name.
    if !records_sample(t,&dst) {return}
    defer author.records_destroy(&dst)
    other:=author.records_style_add(&dst,{radius={9,9,9,9}},nil,{family=.Box})
    ui.tree_text_set(dst.style_infos[other].name[:],"Panel")
    author.records_clip(&dst,"fade",.Scale,{},{1,1,0,0},0.5)
    at:=author.records_paste(&dst,0,&clip)
    if !testing.expect(t,at>=0) {return}
    bar,fuel:=&dst.nodes[at],&dst.nodes[at+1]
    testing.expect_value(t,int(bar.style),other)
    testing.expect_value(t,dst.styles[fuel.style].text.font,u8(ui.FONT_TREE))
    testing.expect_value(t,dst.fonts[0].font,base.Asset_Id{9,9})
    testing.expect_value(t,dst.images[fuel.image-1].texture,base.Asset_Id{5,5})
    testing.expect_value(t,len(dst.anims),1)
    testing.expect_value(t,dst.anim_sets[fuel.anims-1].shown,ui.Anim(1))
    testing.expect(t,fuel.text_id!=0 && fuel.text_id!=source_id,"A pasted text is another text")
    testing.expect_value(t,node_text_in(&dst,fuel,.Spanish,.English),"Combustible")
    testing.expect(t,records_load_as_tree(&dst))
}

@(test)
a_box_becomes_a_widget_with_only_the_rows_it_uses :: proc(t:^testing.T) {
    r:author.Records
    if !records_sample(t,&r) {return}
    defer author.records_destroy(&r)
    unused:=author.records_style_add(&r,{radius={2,2,2,2}},nil,{family=.Box})
    ui.tree_text_set(r.style_infos[unused].name[:],"Unused")
    own:=author.records_style_add(&r,{radius={6,6,6,6}},nil,{})
    r.nodes[3].style=u16(own)
    node_text_set(&r,&r.nodes[3],3,.Spanish,.English,"Combustible")
    widget:author.Records
    if !testing.expect(t,author.records_widget_data(&r,2,&widget,context.allocator)) {return}
    defer author.records_destroy(&widget)
    testing.expect(t,len(widget.nodes)==2 && widget.nodes[0].parent==-1 && widget.nodes[0].float.to==.None)
    testing.expect_value(t,len(widget.styles),2)
    testing.expect_value(t,widget.styles[widget.nodes[1].style].radius[0],f32(6))
    testing.expect(t,widget.nodes[1].text_id!=r.nodes[3].text_id && len(widget.translations)==1,"Its texts have ids of their own")
    testing.expect(t,records_load_as_tree(&widget))
    other:author.Records
    testing.expect(t,!author.records_widget_data(&r,1,&other,context.allocator),"only a Box")
}

@(test)
a_copy_of_a_localized_node_is_another_text_and_a_deleted_one_takes_its_translations :: proc(t:^testing.T) {
    r:author.Records
    if !records_sample(t,&r) {return}
    defer author.records_destroy(&r)
    menu:=&r.nodes[4]
    node_text_set(&r,menu,4,.Spanish,.English,"Menú")
    testing.expect(t,.Localized in menu.flags && menu.text_id!=0,"A translation makes the node localized, with an id")
    copy:=author.records_duplicate(&r,4)
    testing.expect_value(t,copy,5)
    testing.expect(t,r.nodes[5].text_id!=0 && r.nodes[5].text_id!=r.nodes[4].text_id,"The copy has an id of its own")
    testing.expect_value(t,node_text_in(&r,&r.nodes[5],.Spanish,.English),"Menú")
    node_text_set(&r,&r.nodes[5],5,.Spanish,.English,"Opciones")
    testing.expect_value(t,node_text_in(&r,&r.nodes[4],.Spanish,.English),"Menú")
    testing.expect(t,records_load_as_tree(&r))
    author.records_delete(&r,5)
    testing.expect_value(t,len(r.translations),1)
}

