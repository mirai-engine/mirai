package author

import "core:strings"
import "core:testing"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

@(private="file")
records_sample :: proc(t:^testing.T,r:^Records) -> bool {
    texts:=make([dynamic]u8,context.temp_allocator)
    nodes:=[]ui.Tree_Node{
        ui.tree_node_record(&texts,-1,{kind=.Box,name="hud",float={to=.Safe,anchor=.Top_Left,pivot=.Top_Left}}),
        ui.tree_node_record(&texts,0,{kind=.Text,name="title",text="Trips",bind_text="trips"}),
        ui.tree_node_record(&texts,0,{kind=.Box,name="bar"}),
        ui.tree_node_record(&texts,2,{kind=.Progress,name="fuel",bind_value="fuel"}),
        ui.tree_node_record(&texts,-1,{kind=.Button,name="menu",text="Menu"}),
    }
    styles:=[]ui.Node_Style{{}}
    return testing.expect(t,records_load(r,{text=texts[:],nodes=nodes,styles=styles},context.allocator))
}

records_load_as_tree :: proc(r:^Records) -> bool {
    tree:ui.Widget_Tree
    data:=records_data(r)
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
inserted_and_deleted_nodes_keep_the_records_in_pre_order :: proc(t:^testing.T) {
    r:Records
    if !records_sample(t,&r) {return}
    defer records_destroy(&r)
    testing.expect_value(t,records_subtree(r.nodes[:],0),3)
    testing.expect_value(t,records_subtree(r.nodes[:],2),1)
    testing.expect_value(t,records_depth(r.nodes[:],3),2)

    // Inside a box: after what it already holds, before the next root.
    row:=records_insert(&r,0,.Text)
    testing.expect_value(t,row,4)
    testing.expect_value(t,r.nodes[row].parent,i32(0))
    testing.expect_value(t,serial.text_field(r.nodes[row].name[:]),"text1")
    testing.expect_value(t,r.nodes[5].parent,i32(-1))
    testing.expect(t,records_load_as_tree(&r))
    testing.expect_value(t,records_insert(&r,1,.Text),-1) // a Text holds nothing

    root:=records_insert(&r,-1,.Box)
    testing.expect_value(t,root,len(r.nodes)-1)
    testing.expect_value(t,r.nodes[root].float.to,ui.Float_To.Safe)
    testing.expect(t,records_load_as_tree(&r))

    // The bar and its progress go; the rows after them point at their boxes again.
    records_delete(&r,2)
    testing.expect_value(t,len(r.nodes),5)
    testing.expect_value(t,serial.text_field(r.nodes[2].name[:]),"text1")
    testing.expect_value(t,r.nodes[2].parent,i32(0))
    testing.expect_value(t,serial.text_field(r.nodes[3].name[:]),"menu")
    testing.expect(t,records_load_as_tree(&r))
}

// What Create makes of a .ui: a root Box that grows to the surface, with style 0.
@(test)
an_empty_interface_is_a_root_box_that_grows_to_the_surface :: proc(t:^testing.T) {
    r:Records
    if !testing.expect(t,records_load(&r,ui_empty_data(),context.allocator)) {return}
    defer records_destroy(&r)
    testing.expect(t,len(r.nodes)==1 && r.nodes[0].kind==.Box && r.nodes[0].parent==-1 && len(r.styles)==1)
    testing.expect(t,r.nodes[0].layout.width.kind==.Grow && r.nodes[0].layout.height.kind==.Grow && r.nodes[0].float.to==.Surface)
    testing.expect(t,records_load_as_tree(&r))
}

@(test)
a_duplicate_has_its_own_names_image_animations_and_the_overrides_of_its_instances :: proc(t:^testing.T) {
    r:Records
    if !records_sample(t,&r) {return}
    defer records_destroy(&r)
    records_image(&r,&r.nodes[3])
    records_anim_set(&r,&r.nodes[3])
    card:=records_widget(&r,2,base.Asset_Id{7,7},"card","card")
    testing.expect_value(t,card,4)
    append(&r.overrides,ui.Tree_Override{instance=u32(card)})
    copy:=records_duplicate(&r,2)
    testing.expect_value(t,copy,5)
    names:=names_of(r.nodes[:])
    testing.expect(t,names[5]=="bar1" && names[6]=="fuel1" && names[7]=="card1")
    testing.expect_value(t,r.nodes[6].parent,i32(5))
    testing.expect(t,r.nodes[6].image!=r.nodes[3].image && r.nodes[6].anims!=r.nodes[3].anims,"The copy edits an image and animations of its own")
    testing.expect_value(t,len(r.overrides),2)
    testing.expect_value(t,r.overrides[1].instance,u32(7))
    // A row two nodes share is copied for the one that changes it.
    r.nodes[1].image=r.nodes[3].image
    testing.expect(t,records_image(&r,&r.nodes[1])!=int(r.nodes[3].image)-1)
}

@(test)
overrides_follow_the_rows_of_their_instances :: proc(t:^testing.T) {
    texts:=make([dynamic]u8,context.temp_allocator)
    nodes:=[]ui.Tree_Node{
        ui.tree_node_record(&texts,-1,{kind=.Box,name="first"}),
        ui.tree_node_record(&texts,-1,{kind=.Box,name="second"}),
    }
    r:Records
    if !testing.expect(t,records_load(&r,{text=texts[:],nodes=nodes,styles={{}},overrides={{instance=0},{instance=1}}},context.allocator)) {return}
    defer records_destroy(&r)
    testing.expect_value(t,records_insert(&r,0,.Spacer),1)
    testing.expect_value(t,r.overrides[0].instance,u32(0))
    testing.expect_value(t,r.overrides[1].instance,u32(2))
    records_delete(&r,0)
    testing.expect_value(t,len(r.overrides),1)
    testing.expect_value(t,r.overrides[0].instance,u32(0))
}

@(test)
a_widget_of_another_file_makes_its_component_once :: proc(t:^testing.T) {
    r:Records
    if !records_sample(t,&r) {return}
    defer records_destroy(&r)
    a:=records_widget(&r,0,base.Asset_Id{7,7},"button","button")
    b:=records_widget(&r,0,base.Asset_Id{7,7},"button","button")
    testing.expect(t,a>=0 && b>=0)
    testing.expect_value(t,len(r.components),1)
    testing.expect_value(t,r.components[0].widget,base.Asset_Id{7,7})
    testing.expect(t,serial.text_field(r.nodes[a].name[:])!=serial.text_field(r.nodes[b].name[:]))
    data:=records_data(&r)
    testing.expect_value(t,data.components[0].count,u32(0))
}

@(test)
tracks_and_keys_keep_their_ranges_and_their_order_in_time :: proc(t:^testing.T) {
    r:Records
    if !records_sample(t,&r) {return}
    defer records_destroy(&r)
    first:=records_clip(&r,"fade",.Opacity,{0,0,0,0},{1,0,0,0},0.2)
    second:=records_clip(&r,"grow",.Scale,{0.5,0.5,0,0},{1,1,0,0},0.2)
    testing.expect(t,records_track_add(&r,first,.Offset))
    testing.expect_value(t,r.anims[second].first,u32(2))
    testing.expect_value(t,r.tracks[r.anims[second].first].property,ui.Anim_Property.Scale)
    records_key_add(&r,int(r.anims[first].first))
    testing.expect_value(t,r.tracks[0].key_count,u32(3))
    testing.expect_value(t,r.keys[r.tracks[0].first_key+2].time,f32(1.2))
    records_track_remove(&r,first,0)
    testing.expect_value(t,r.anims[first].count,u32(1))
    testing.expect_value(t,r.tracks[r.anims[second].first].property,ui.Anim_Property.Scale)
    testing.expect(t,records_load_as_tree(&r))
    // A time edited past the next key goes after it when the records are written.
    track:=r.tracks[r.anims[second].first]
    r.keys[track.first_key].time=0.5
    if !testing.expect(t,!records_load_as_tree(&r),"The tree takes keys in order") {return}
    records_tidy(&r)
    testing.expect_value(t,r.keys[track.first_key].time,f32(0.2))
    testing.expect_value(t,r.keys[track.first_key+1].time,f32(0.5))
    testing.expect(t,records_load_as_tree(&r))
}

@(test)
a_copied_node_is_pasted_inside_a_container_or_after_another :: proc(t:^testing.T) {
    r:Records
    if !records_sample(t,&r) {return}
    defer records_destroy(&r)
    clip:Clip_Nodes
    defer clip_destroy(&clip)
    records_copy(&r,2,&clip)
    testing.expect_value(t,len(clip.records.nodes),2)
    // Into the hud, last, with names of its own.
    at:=records_paste(&r,0,&clip)
    testing.expect_value(t,at,4)
    testing.expect_value(t,r.nodes[4].parent,i32(0))
    testing.expect(t,serial.text_field(r.nodes[4].name[:])!="bar")
    // After a text, beside it.
    at=records_paste(&r,1,&clip)
    testing.expect_value(t,r.nodes[at].parent,i32(0))
    testing.expect_value(t,len(r.styles),1)
    testing.expect(t,records_load_as_tree(&r))
}

@(test)
an_override_saves_into_its_style_and_goes :: proc(t:^testing.T) {
    r:Records
    if !records_sample(t,&r) {return}
    defer records_destroy(&r)
    // A named style the title and the fuel share, with a variant.
    shared:=records_style_add(&r,{radius=4},{ui.tree_variant_record(0,"",{.Hovered},{})},{})
    ui.tree_text_set(r.style_infos[shared].name[:],"Label")
    r.nodes[1].style,r.nodes[3].style=u16(shared),u16(shared)
    testing.expect_value(t,records_style_users(&r,shared),2)
    testing.expect_value(t,records_style_name(&r,shared),"Label")
    // The title overrides it, with its variant.
    changed:=r.styles[shared]
    changed.radius=9
    info:ui.Tree_Style_Info
    ui.tree_text_set(info.extends[:],"Label")
    override:=records_style_add(&r,changed,records_style_variants(&r,shared),info)
    r.nodes[1].style=u16(override)
    testing.expect_value(t,records_style_base(&r,override),shared)
    // It says what differs, and follows the style in the rest.
    records_override_own(&r,override)
    testing.expect(t,r.style_infos[override].sets=={.Radius} && len(records_style_variants(&r,override))==0)
    r.styles[shared].stroke_width=2
    ui.tree_settle(r.styles[:],r.style_infos[:],&r.variants,r.tokens[:],r.token_uses[:])
    testing.expect(t,r.styles[override].stroke_width==2 && r.styles[override].radius==9)
    testing.expect_value(t,len(records_style_variants(&r,override)),1)
    if !testing.expect(t,records_load_as_tree(&r)) {return}
    // Saving writes it into the shared style, which both use again.
    saved:=records_style_save(&r,override)
    testing.expect_value(t,saved,shared)
    testing.expect_value(t,len(r.styles),2)
    testing.expect_value(t,len(r.style_infos),2)
    testing.expect_value(t,r.styles[shared].radius,9)
    testing.expect_value(t,records_style_users(&r,shared),2)
    testing.expect_value(t,len(records_style_variants(&r,shared)),1)
    testing.expect_value(t,len(r.variants),1)
    testing.expect(t,records_load_as_tree(&r))
    // A style still in use stays.
    testing.expect_value(t,records_style_remove(&r,shared,0),0)
    testing.expect_value(t,len(r.styles),2)
    testing.expect(t,!records_style_delete(&r,shared),"A named style a node uses stays")
}

@(test)
rows_nothing_uses_go_when_the_records_are_written :: proc(t:^testing.T) {
    r:Records
    if !records_sample(t,&r) {return}
    defer records_destroy(&r)
    lost:=records_style_add(&r,{radius={1,1,1,1}},{ui.tree_variant_record(0,"big",{},{})},{})
    named:=records_style_add(&r,{radius={2,2,2,2}},nil,{family=.Box})
    ui.tree_text_set(r.style_infos[named].name[:],"Kept")
    used:=records_style_add(&r,{radius={3,3,3,3}},{ui.tree_variant_record(0,"big",{},{})},{})
    r.nodes[2].style=u16(used)
    records_image(&r,&r.nodes[0]) // "No image" leaves it behind
    r.nodes[0].image=0
    records_image(&r,&r.nodes[3])
    r.images[r.nodes[3].image-1].texture={3,3}
    records_widget(&r,0,base.Asset_Id{7,7},"card","card")
    records_delete(&r,4)
    records_tidy(&r)
    testing.expect_value(t,len(r.styles),3)
    testing.expect(t,int(r.nodes[2].style)!=lost && r.styles[r.nodes[2].style].radius[0]==3,"The rows after the ones that went follow")
    testing.expect_value(t,len(r.variants),1)
    testing.expect_value(t,int(r.variants[0].style),int(r.nodes[2].style))
    testing.expect_value(t,records_style_name(&r,1),"Kept")
    testing.expect_value(t,len(r.images),1)
    testing.expect_value(t,r.images[r.nodes[3].image-1].texture,base.Asset_Id{3,3})
    testing.expect_value(t,len(r.components),1)
    testing.expect(t,records_use_remove(&r,0))
    testing.expect(t,records_load_as_tree(&r))
    // A named style no node uses goes when asked.
    testing.expect(t,records_style_delete(&r,1))
    testing.expect_value(t,len(r.styles),2)
    testing.expect_value(t,r.styles[r.nodes[2].style].radius[0],f32(3))
}

@(test)
an_undo_chooses_the_node_it_changed :: proc(t:^testing.T) {
    before,after:Records
    if !records_sample(t,&before) {return}
    defer records_destroy(&before)
    if !testing.expect(t,records_load(&after,records_data(&before),context.allocator)) {return}
    defer records_destroy(&after)
    testing.expect_value(t,records_changed_row(&before,&after,0),-1)
    ui.tree_text_set(after.nodes[3].name[:],"tank")
    testing.expect_value(t,records_changed_row(&before,&after,0),3)
    after.nodes[3]=before.nodes[3]
    // A style that changed chooses the node chosen when it takes it, the first that does otherwise.
    append(&before.styles,ui.Node_Style{})
    append(&after.styles,ui.Node_Style{radius=4})
    before.nodes[2].style,before.nodes[4].style=1,1
    after.nodes[2].style,after.nodes[4].style=1,1
    testing.expect_value(t,records_changed_row(&before,&after,4),4)
    testing.expect_value(t,records_changed_row(&before,&after,0),2)
    // A node taken away chooses the row it left.
    records_delete(&after,4)
    testing.expect_value(t,records_changed_row(&before,&after,0),3)
}

@(test)
a_renamed_node_keeps_a_name_of_its_own_and_what_named_it_follows :: proc(t:^testing.T) {
    r:Records
    if !records_sample(t,&r) {return}
    defer records_destroy(&r)
    ui.tree_text_set(r.nodes[4].nav[0][:],"title")
    ui.tree_text_set(r.nodes[0].ghost[:],"title")
    ui.tree_text_set(r.nodes[1].name[:],"menu")
    testing.expect_value(t,records_rename(&r,1,"title"),"menu1")
    testing.expect_value(t,serial.text_field(r.nodes[4].nav[0][:]),"menu1")
    testing.expect_value(t,serial.text_field(r.nodes[0].ghost[:]),"menu1")
    ui.tree_text_set(r.nodes[1].name[:],"heading")
    testing.expect_value(t,records_rename(&r,1,"menu1"),"heading")
    // What named a node that went names nothing.
    records_delete(&r,1)
    testing.expect_value(t,serial.text_field(r.nodes[3].nav[0][:]),"")
    testing.expect_value(t,serial.text_field(r.nodes[0].ghost[:]),"")
    field:[ui.TREE_NAME_CAPACITY]u8
    ui.tree_text_set(field[:],"slot/icon")
    testing.expect(t,path_part_rename(field[:],0,"slot","box") && serial.text_field(field[:])=="box/icon")
    testing.expect(t,path_part_rename(field[:],4,"icon","mark") && serial.text_field(field[:])=="box/mark")
    testing.expect(t,!path_part_rename(field[:],0,"bo","x"),"A part is a whole name")
}

@(test)
a_variant_renamed_changes_only_the_nodes_of_its_style :: proc(t:^testing.T) {
    r:Records
    if !records_sample(t,&r) {return}
    defer records_destroy(&r)
    a:=records_style_add(&r,{},{ui.tree_variant_record(0,"big",{},{})},{})
    b:=records_style_add(&r,{},{ui.tree_variant_record(0,"big",{},{})},{})
    r.nodes[1].style,r.nodes[3].style=u16(a),u16(b)
    ui.tree_text_set(r.nodes[1].variant[:],"big")
    ui.tree_text_set(r.nodes[3].variant[:],"big")
    records_variant_rename(&r,a,serial.text_field(r.nodes[1].variant[:]),"large")
    testing.expect_value(t,serial.text_field(r.nodes[1].variant[:]),"large")
    testing.expect_value(t,serial.text_field(r.nodes[3].variant[:]),"big")
    testing.expect_value(t,serial.text_field(records_style_variants(&r,a)[0].variant[:]),"large")
    testing.expect_value(t,serial.text_field(records_style_variants(&r,b)[0].variant[:]),"big")
}

@(test)
a_field_an_override_turns_on_takes_what_the_node_of_the_widget_has :: proc(t:^testing.T) {
    texts:=make([dynamic]u8,context.temp_allocator)
    nodes:=[]ui.Tree_Node{
        ui.tree_node_record(&texts,-1,{kind=.Box,name="card"}),
        ui.tree_node_record(&texts,0,{kind=.Text,name="label",text="Hi",style=1,selected=true}),
    }
    styles:=[]ui.Node_Style{{},{radius={5,5,5,5}}}
    infos:=[]ui.Tree_Style_Info{{},{family=.Text}}
    ui.tree_text_set(infos[1].name[:],"Big")
    widget:Records
    if !testing.expect(t,records_load(&widget,{text=texts[:],nodes=nodes,styles=styles,style_infos=infos},context.allocator)) {return}
    defer records_destroy(&widget)
    r:Records
    if !records_sample(t,&r) {return}
    defer records_destroy(&r)
    instance:=records_widget(&r,0,base.Asset_Id{7,7},"card","card")
    o:=records_override(&r,instance,"label",{})
    records_override_field(&r,o,.Style,true,&widget,widget.nodes[1])
    records_override_field(&r,o,.Text,true,&widget,widget.nodes[1])
    records_override_field(&r,o,.Visibility,true,&widget,widget.nodes[1])
    v:=&r.overrides[o].values
    testing.expect_value(t,records_style_name(&r,int(v.style)),"Big")
    testing.expect_value(t,r.styles[v.style].radius[0],f32(5))
    testing.expect_value(t,records_text(&r,v.text),"Hi")
    testing.expect(t,v.selected,"Selected comes from the widget")
    records_override_field(&r,o,.Text,false,&widget,widget.nodes[1])
    testing.expect(t,r.overrides[o].fields=={.Style,.Visibility})
}

@(test)
unbinding_the_visibility_shows_the_node :: proc(t:^testing.T) {
    r:Records
    if !records_sample(t,&r) {return}
    defer records_destroy(&r)
    n:=&r.nodes[1]
    ui.tree_text_set(n.bind_visible[:],"alive")
    n.flags+={.Invisible}
    node_unbind(n,n.bind_visible[:])
    testing.expect(t,n.bind_visible[0]==0 && .Invisible not_in n.flags && .Collapsed not_in n.flags)
}

@(test)
a_check_reports_each_path_the_game_lacks_and_why_records_do_not_load :: proc(t:^testing.T) {
    r:Records
    if !records_sample(t,&r) {return}
    defer records_destroy(&r)
    types:Bind_Types
    defer bind_types_free(&types)
    found:[BIND_PROBLEMS]Bind_Problem
    count:=bind_check(&types,context.allocator,{},nil,records_data(&r),nil,true,found[:])
    if !testing.expect_value(t,count,2) {return}
    testing.expect(t,found[0].row==1 && found[0].fault==.Path && serial.text_field(found[0].path[:])=="trips")
    testing.expect_value(t,serial.text_field(found[0].name[:]),serial.text_field(r.nodes[1].name[:]))
    testing.expect(t,found[1].row==3 && found[1].binding==.Value && serial.text_field(found[1].path[:])=="fuel")
    // An override of a node its template does not have.
    texts:=make([dynamic]u8,context.temp_allocator)
    nodes:=[]ui.Tree_Node{ui.tree_node_record(&texts,-1,{kind=.Box,name="root"}),ui.tree_node_record(&texts,0,{kind=.Component,name="slot",component=1})}
    template:=[]ui.Tree_Node{ui.tree_node_record(&texts,-1,{kind=.Box,name="card"}),ui.tree_node_record(&texts,0,{kind=.Text,name="label"})}
    overrides:=[]ui.Tree_Override{ui.tree_override_record(&texts,1,"icon",{.Clip},{})}
    data:=ui.Tree_Data{text=texts[:],nodes=nodes,styles={{}},component_nodes=template,components={ui.tree_component_record("card",0,2)},overrides=overrides}
    count=bind_check(&types,context.allocator,{},nil,data,nil,true,found[:])
    testing.expect(t,count==1 && found[0].fault==.Load)
    testing.expect(t,strings.contains(serial.text_field(found[0].path[:]),"'icon'"),serial.text_field(found[0].path[:]))
    overrides[0]=ui.tree_override_record(&texts,1,"label",{.Clip},{})
    testing.expect_value(t,bind_check(&types,context.allocator,{},nil,data,nil,true,found[:]),0)
}
