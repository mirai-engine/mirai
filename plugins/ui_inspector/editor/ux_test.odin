package ui_inspector_editor

import "core:testing"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// hud(0) > title(1), bar(2) > fuel(3); menu(4); list(5) > slot(6)
@(private="file")
ux_sample :: proc(t:^testing.T,r:^Records) -> bool {
    texts:=make([dynamic]u8,context.temp_allocator)
    nodes:=[]ui.Tree_Node{
        ui.tree_node_record(&texts,-1,{kind=.Box,name="hud"}),
        ui.tree_node_record(&texts,0,{kind=.Text,name="title",text="Trips"}),
        ui.tree_node_record(&texts,0,{kind=.Box,name="bar"}),
        ui.tree_node_record(&texts,2,{kind=.Progress,name="fuel"}),
        ui.tree_node_record(&texts,-1,{kind=.Button,name="menu",text="Menu"}),
        ui.tree_node_record(&texts,-1,{kind=.List,name="list"}),
        ui.tree_node_record(&texts,5,{kind=.Text,name="slot"}),
    }
    return testing.expect(t,records_load(r,{text=texts[:],nodes=nodes,styles={{}}},context.allocator))
}

@(private="file")
ux_loads :: proc(r:^Records) -> bool {
    tree:ui.Widget_Tree
    if !ui.tree_load(&tree,records_data(r),{textures=make([]u32,len(r.images),context.temp_allocator),fonts=make([]u8,len(r.fonts),context.temp_allocator)}) {return false}
    ui.tree_destroy(&tree)
    return true
}

@(private="file")
ux_names :: proc(nodes:[]ui.Tree_Node) -> []string {
    names:=make([]string,len(nodes),context.temp_allocator)
    for &n,i in nodes {names[i]=serial.text_field(n.name[:])}
    return names
}

@(test)
nodes_chosen_together_are_their_roots_once :: proc(t:^testing.T) {
    r:Records
    if !ux_sample(t,&r) {return}
    defer records_destroy(&r)
    roots:=selection_roots(r.nodes[:],{3,0,4,0,9})
    testing.expect_value(t,len(roots),2)
    testing.expect(t,roots[0]==0 && roots[1]==4)
}

@(test)
nodes_chosen_together_are_deleted_and_duplicated_together :: proc(t:^testing.T) {
    r:Records
    if !ux_sample(t,&r) {return}
    defer records_destroy(&r)
    copies:=records_duplicate_rows(&r,{2,4})
    testing.expect_value(t,len(copies),2)
    names:=ux_names(r.nodes[:])
    // bar and fuel are copied after fuel; menu after menu, two rows further.
    testing.expect_value(t,copies[0],4)
    testing.expect_value(t,names[4],"bar1")
    testing.expect_value(t,names[5],"fuel1")
    testing.expect_value(t,r.nodes[5].parent,i32(4))
    testing.expect_value(t,copies[1],7)
    testing.expect_value(t,names[7],"menu1")
    testing.expect(t,ux_loads(&r))
    records_delete_rows(&r,{copies[0],copies[1],5})
    testing.expect_value(t,len(r.nodes),7)
    testing.expect(t,ux_loads(&r))
}

@(test)
nodes_chosen_together_are_copied_pasted_and_moved_as_blocks :: proc(t:^testing.T) {
    r:Records
    if !ux_sample(t,&r) {return}
    defer records_destroy(&r)
    clip:Clip_Nodes
    records_copy_rows(&r,{2,1},&clip)
    defer clip_destroy(&clip)
    testing.expect_value(t,len(clip.records.nodes),3)
    blocks:=clip_blocks(&clip)
    testing.expect_value(t,len(blocks),2)
    testing.expect(t,blocks[0]==[2]int{0,1} && blocks[1]==[2]int{1,2})
    // Pasted into the menu's place: after it, at the root, one after the other.
    pasted:=records_paste_rows(&r,4,&clip)
    testing.expect_value(t,len(pasted),2)
    names:=ux_names(r.nodes[:])
    testing.expect_value(t,names[pasted[0]],"title1")
    testing.expect_value(t,names[pasted[1]],"bar1")
    testing.expect_value(t,r.nodes[pasted[1]+1].parent,i32(pasted[1]))
    testing.expect_value(t,r.nodes[pasted[0]].parent,i32(-1))
    testing.expect(t,ux_loads(&r))
    // The title and the menu go into the bar, after the fuel.
    placed:=records_place_rows(&r,{4,1},2,-1)
    testing.expect_value(t,len(placed),2)
    names=ux_names(r.nodes[:])
    testing.expect_value(t,names[placed[0]],"title")
    testing.expect_value(t,names[placed[1]],"menu")
    bar:=int(r.nodes[placed[0]].parent)
    testing.expect_value(t,names[bar],"bar")
    testing.expect_value(t,r.nodes[placed[1]].parent,i32(bar))
    testing.expect(t,ux_loads(&r))
    // Not into itself, and a List holds one node.
    testing.expect(t,records_place_rows(&r,{bar},bar+1,-1)==nil)
    list:=-1
    for name,i in ux_names(r.nodes[:]) {if name=="list" {list=i}}
    testing.expect(t,records_place_rows(&r,{0},list,-1)==nil)
}

@(test)
a_grid_has_columns_of_its_own_until_they_are_the_same_again :: proc(t:^testing.T) {
    r:Records
    if !ux_sample(t,&r) {return}
    defer records_destroy(&r)
    r.nodes[0].layout.direction,r.nodes[0].layout.columns=.Grid,3
    at:=records_grid_tracks(&r,&r.nodes[0])
    testing.expect_value(t,at,0)
    testing.expect_value(t,r.nodes[0].layout.tracks,u16(1))
    testing.expect_value(t,r.grid_tracks[0].count,u8(3))
    testing.expect_value(t,r.grid_tracks[0].columns[2].kind,ui.Size_Kind.Grow)
    testing.expect_value(t,records_grid_tracks(&r,&r.nodes[0]),0) // its own: the same row
    testing.expect(t,ux_loads(&r))
    // A grid that shares the row gets a copy when it changes it.
    r.nodes[2].layout=r.nodes[0].layout
    copy:=records_grid_tracks(&r,&r.nodes[2])
    testing.expect_value(t,copy,1)
    testing.expect_value(t,r.nodes[2].layout.tracks,u16(2))
    records_grid_tracks_count(&r,copy,5)
    testing.expect_value(t,r.grid_tracks[copy].count,u8(5))
    testing.expect_value(t,r.grid_tracks[copy].columns[4].kind,ui.Size_Kind.Grow)
    records_grid_tracks_count(&r,copy,1)
    testing.expect(t,r.grid_tracks[copy].count==1 && r.grid_tracks[copy].columns[1]=={})
    // The first goes back to the same widths: its row goes and the other moves up.
    records_grid_tracks_drop(&r,&r.nodes[0])
    testing.expect_value(t,len(r.grid_tracks),1)
    testing.expect_value(t,r.nodes[0].layout.tracks,u16(0))
    testing.expect_value(t,r.nodes[2].layout.tracks,u16(1))
    testing.expect(t,ux_loads(&r))
}

@(test)
parts_and_animations_go_and_come_in_any_order_of_the_table :: proc(t:^testing.T) {
    r:Records
    if !ux_sample(t,&r) {return}
    defer records_destroy(&r)
    fade:=records_clip(&r,"fade",.Opacity,{0,0,0,0},{1,0,0,0},0.2)
    grow:=records_clip(&r,"grow",.Scale,{0.5,0.5,0,0},{1,1,0,0},0.2)
    append(&r.anims,ui.Tree_Anim{kind=.Sequence,first=u32(len(r.parts))})
    first:=len(r.anims)-1
    append(&r.anims,ui.Tree_Anim{kind=.Parallel,first=u32(len(r.parts))})
    second:=len(r.anims)-1
    testing.expect(t,records_part_add(&r,first,ui.Anim(fade+1)))
    testing.expect(t,records_part_add(&r,second,ui.Anim(grow+1)))
    // The first group's parts are not the last of the table any more.
    testing.expect(t,records_part_add(&r,first,ui.Anim(grow+1)))
    testing.expect_value(t,r.anims[first].count,u32(2))
    testing.expect_value(t,r.parts[r.anims[first].first+1],ui.Anim(grow+1))
    testing.expect_value(t,r.parts[r.anims[second].first],ui.Anim(grow+1))
    testing.expect(t,ux_loads(&r))
    set:=records_anim_set(&r,&r.nodes[0])
    r.anim_sets[set].shown,r.anim_sets[set].hovered,r.anim_sets[set].clicked=ui.Anim(fade+1),ui.Anim(grow+1),ui.Anim(second+1)
    // Fade goes: the groups lose it, the rows after it move up.
    records_anim_remove(&r,fade)
    testing.expect_value(t,len(r.anims),3)
    testing.expect_value(t,len(r.tracks),1)
    testing.expect_value(t,r.anims[0].first,u32(0))
    testing.expect_value(t,r.anims[first-1].count,u32(1))
    testing.expect_value(t,r.parts[r.anims[first-1].first],ui.Anim(1))
    testing.expect_value(t,r.anim_sets[set].shown,ui.Anim(0))
    testing.expect_value(t,r.anim_sets[set].hovered,ui.Anim(1))
    testing.expect_value(t,r.anim_sets[set].clicked,ui.Anim(second))
    testing.expect(t,ux_loads(&r))
    records_part_remove(&r,first-1,0)
    testing.expect_value(t,r.anims[first-1].count,u32(0))
    testing.expect(t,ux_loads(&r))
}

@(test)
a_widget_that_holds_the_document_is_not_offered :: proc(t:^testing.T) {
    Graph :: struct {edges:[][2]base.Asset_Id}
    a,b,c,d:=base.Asset_Id{1,0},base.Asset_Id{2,0},base.Asset_Id{3,0},base.Asset_Id{4,0}
    edges:=[][2]base.Asset_Id{{a,b},{b,c},{c,b},{d,a}}
    graph:=Graph{edges}
    children :: proc(user:rawptr,id:base.Asset_Id) -> (used:[]ui.Tree_Component,read:bool) {
        g:=(^Graph)(user)
        held:=make([dynamic]ui.Tree_Component,context.temp_allocator)
        for e in g.edges {if e[0]==id {append(&held,ui.Tree_Component{widget=e[1]})}}
        return held[:],true
    }
    testing.expect(t,widget_reaches(a,c,children,&graph))  // a holds b, which holds c
    testing.expect(t,widget_reaches(d,c,children,&graph))
    testing.expect(t,!widget_reaches(c,a,children,&graph)) // c and b hold each other, not a
    testing.expect(t,widget_reaches(a,a,children,&graph))
}

@(test)
handles_resize_and_snap_to_the_edges_near_them :: proc(t:^testing.T) {
    start:=ui.Rect{100,50,200,40}
    testing.expect_value(t,gesture_rect(start,.Move,{10,-5},1),ui.Rect{110,45,200,40})
    testing.expect_value(t,gesture_rect(start,.Right,{30,99},1),ui.Rect{100,50,230,40})
    testing.expect_value(t,gesture_rect(start,.Top_Left,{-20,10},1),ui.Rect{80,60,220,30})
    // No side under the least.
    testing.expect_value(t,gesture_rect(start,.Left,{500,0},4),ui.Rect{296,50,4,40})
    // The edge nearest a target within reach takes it.
    values:[3]f32
    moved:=snap_values(ui.Rect{103,0,200,0},.Move,0,&values)
    testing.expect_value(t,len(moved),3)
    delta,line,ok:=snap_axis(moved,{0,100,400},6)
    testing.expect(t,ok && delta==-3 && line==100)
    _,_,ok=snap_axis(moved,{0,120,500},6)
    testing.expect(t,!ok)
    // A center: 103+100=203 near 205.
    delta,line,ok=snap_axis(moved,{205},6)
    testing.expect(t,ok && delta==2 && line==205)
    resized:=snap_values(ui.Rect{100,0,200,0},.Right,0,&values)
    testing.expect(t,len(resized)==1 && resized[0]==300)
    testing.expect_value(t,len(snap_values(ui.Rect{100,0,200,0},.Right,1,&values)),0)
    // A node hung by its center grows on the right: its offset moves half the growth.
    testing.expect_value(t,pivot_shift(start,gesture_rect(start,.Right,{20,0},1),.Center),[2]f32{10,0})
    testing.expect_value(t,pivot_shift(start,gesture_rect(start,.Left,{-20,0},1),.Top_Left),[2]f32{-20,0})
    testing.expect_value(t,pivot_shift(start,gesture_rect(start,.Left,{-20,0},1),.Top_Right),[2]f32{0,0})
}

@(test)
samples_fill_numbers_texts_and_arrays :: proc(t:^testing.T) {
    Item :: struct {count:i32,name:[16]u8}
    Stats :: struct {health:f32,alive:bool,items:[dynamic]Item,icon:base.Asset_Id,title:string}
    s:Preview_Samples
    s.allocator=context.allocator
    s.blocks=make([dynamic][]u8,context.allocator)
    defer {
        for block in s.blocks {delete(block)}
        delete(s.blocks)
    }
    stats:Stats
    sample_fill(&s,&stats,type_info_of(Stats),"",0)
    testing.expect_value(t,stats.health,f32(0.5))
    testing.expect(t,stats.alive)
    testing.expect_value(t,len(stats.items),SAMPLE_ELEMENTS)
    testing.expect_value(t,stats.items[2].count,i32(3))
    testing.expect_value(t,serial.text_field(stats.items[1].name[:]),"name")
    testing.expect_value(t,stats.icon,SAMPLE_ASSET)
    testing.expect_value(t,stats.title,"title")
}
