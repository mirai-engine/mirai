package ui

import "core:testing"
import "mirai:std/base"
import "mirai:std/serial"

Test_Enemy :: struct {
    name:[16]u8 `mirai:"text"`,
    health:i32,
}
Test_Camp :: struct {
    tab:i32,
    open:bool,
    title:[16]u8 `mirai:"text"`,
    slots:[4]Test_Enemy,
}

// A world of one component Test_Camp (its source has a stamp) and a table
// Enemy of up to 8 rows.
Test_Containers :: struct {
    host:Bind_Host,
    schema:serial.Schema,
    camp_type,enemy_type:serial.Type_Index,
    camp:Test_Camp,
    camp_stamp:u64,
    enemies:[8]Test_Enemy,
    rows:int,
    rows_stamp:u64,
    tree:Widget_Tree,
    instance:Tree_Instance,
    events:[16]Tree_Event,
    log:[64]Tree_Event, // what every frame since the last test_containers_clear said
    logged:int,
    track:bool, // every container keeps its rectangle
    focus:int,  // the code gives the focus to the row of this element plus one before the build
}
test_containers_init :: proc(t:^testing.T,s:^Test_Containers) {
    serial.schema_init(&s.schema)
    s.camp_type,_=serial.schema_add(&s.schema,Test_Camp)
    s.enemy_type,_=serial.schema_add(&s.schema,Test_Enemy)
    testing.expect(t,tree_init(&s.tree,{max_nodes=64}))
    s.host={user=s,schema=&s.schema,
        source=proc(user:rawptr,name:u64) -> (type:serial.Type_Index,storage,ok:bool) {
            s:=(^Test_Containers)(user)
            switch name {
            case base.name_hash("Camp"):  return s.camp_type,false,true
            case base.name_hash("Enemy"): return s.enemy_type,false,true
            }
            return
        },
        fetch=proc(user:rawptr,name:u64,entity:base.Entity) -> (data:rawptr,stamp:u64) {
            s:=(^Test_Containers)(user)
            if name==base.name_hash("Camp") {return &s.camp,s.camp_stamp}
            return nil,0
        },
        rows=proc(user:rawptr,name:u64) -> (data:rawptr,count,stride:int,stamp:u64) {
            s:=(^Test_Containers)(user)
            if name!=base.name_hash("Enemy") || s.rows==0 {return}
            return &s.enemies[0],s.rows,size_of(Test_Enemy),s.rows_stamp
        },
    }
}
test_containers_destroy :: proc(s:^Test_Containers) {
    tree_instance_destroy(&s.instance);tree_destroy(&s.tree);serial.schema_destroy(&s.schema)
}
test_containers_build :: proc(ctx:^Context,user:rawptr) {
    s:=cast(^Test_Containers)user
    tree_values_refresh(&s.instance,&s.host,0)
    if s.focus>0 {focus_set(ctx,test_item_id(ctx,s.focus-1,"row"))}
    result:=tree_build(ctx,&s.tree,&s.instance,{events=s.events[:],track=s.track})
    for e in s.events[:result.count] {
        if s.logged<len(s.log) {s.log[s.logged]=e;s.logged+=1}
    }
}
test_containers_said :: proc(s:^Test_Containers,kind:Tree_Event_Kind,name:string) -> (found:Tree_Event,count:int) {
    for e in s.log[:s.logged] {
        if e.kind==kind && e.name==base.name_hash(name) {found=e;count+=1}
    }
    return
}
// The id of the node called name in element item of the List around it.
test_item_id :: proc(ctx:^Context,item:int,name:string) -> Id {
    id_push(ctx,id(ctx,"item",item+1))
    defer id_pop(ctx)
    return tree_element_id(ctx,name)
}

@(test)
a_list_that_clips_builds_only_what_is_in_sight_and_navigation_moves_it :: proc(t:^testing.T) {
    ctx:Context
    desc:=TEST_SMALL
    desc.navigation=true
    testing.expect(t,test_context_init(&ctx,desc))
    defer context_destroy(&ctx)
    s:Test_Containers
    test_containers_init(t,&s)
    defer test_containers_destroy(&s)
    list:=tree_node(&s.tree,-1,{kind=.List,name="rows",clip=true,count=1000,layout={width=fixed(120),height=fixed(100),direction=.Column}})
    tree_node(&s.tree,list,{kind=.Button,name="row",text="Row",layout={width=GROW,height=fixed(20)}})
    testing.expect(t,tree_instance_init(&s.instance,&s.tree,&s.host))
    input:=test_input()
    test_frame(&ctx,&input,test_containers_build,&s)
    slot:=int(s.instance.slots[list])
    testing.expect_value(t,s.instance.slot[slot].built,i32(TREE_LIST_PROBE))
    test_frame(&ctx,&input,test_containers_build,&s)
    // Five rows in sight and one more under them.
    testing.expect(t,s.instance.slot[slot].first==0 && s.instance.slot[slot].built==6)
    _,built:=widget_rect(&ctx,test_item_id(&ctx,6,"row"))
    testing.expect(t,!built)
    content:=test_rect(t,&ctx,scroll_content_id(&ctx,id(&ctx,"scroll",int(list)+1)))
    testing.expect(t,test_near(content.h,1000*20),"The room of every element is kept")
    s.instance.scrolls[slot].y=5000
    test_frame(&ctx,&input,test_containers_build,&s)
    testing.expect(t,s.instance.slot[slot].first==249 && s.instance.slot[slot].built==7)
    row:=test_rect(t,&ctx,test_item_id(&ctx,250,"row"))
    view:=test_rect(t,&ctx,id(&ctx,"scroll",int(list)+1))
    testing.expect(t,test_near(row.y,view.y),"An element is where it would be with all of them built")
    // Down from the last row in sight reaches the one under it, which comes into sight.
    focus_set(&ctx,test_item_id(&ctx,254,"row"))
    test_key(&input,.Down)
    test_frame(&ctx,&input,test_containers_build,&s)
    testing.expect_value(t,ctx.focus,test_item_id(&ctx,255,"row"))
    test_frame(&ctx,&input,test_containers_build,&s)
    test_frame(&ctx,&input,test_containers_build,&s)
    testing.expect(t,test_near(s.instance.scrolls[slot].y,5020))
    _,built=widget_rect(&ctx,test_item_id(&ctx,256,"row"))
    testing.expect(t,built,"The row under it is built for the next move")
    // An element out of sight the code gives the focus to comes into sight.
    s.focus=11
    test_frame(&ctx,&input,test_containers_build,&s)
    s.focus=0
    test_frame(&ctx,&input,test_containers_build,&s)
    testing.expect(t,test_near(s.instance.scrolls[slot].y,10*20))
    _,built=widget_rect(&ctx,test_item_id(&ctx,10,"row"))
    testing.expect(t,built && ctx.focus==test_item_id(&ctx,10,"row"))
}

@(test)
a_node_inside_an_element_out_of_sight_the_code_gives_the_focus_to_comes_into_sight :: proc(t:^testing.T) {
    ctx:Context
    desc:=TEST_SMALL
    desc.navigation=true
    testing.expect(t,test_context_init(&ctx,desc))
    defer context_destroy(&ctx)
    s:Test_Containers
    test_containers_init(t,&s)
    defer test_containers_destroy(&s)
    list:=tree_node(&s.tree,-1,{kind=.List,name="rows",clip=true,count=1000,layout={width=fixed(120),height=fixed(100),direction=.Column}})
    card:=tree_node(&s.tree,list,{kind=.Box,name="card",layout={width=GROW,height=fixed(20),direction=.Row}})
    tree_node(&s.tree,card,{kind=.Text,text="Row",layout={width=fixed(60),height=fixed(20)}})
    tree_node(&s.tree,card,{kind=.Button,name="row",text="Buy",layout={width=fixed(60),height=fixed(20)}})
    testing.expect(t,tree_instance_init(&s.instance,&s.tree,&s.host))
    input:=test_input()
    test_frame(&ctx,&input,test_containers_build,&s)
    test_frame(&ctx,&input,test_containers_build,&s)
    slot:=int(s.instance.slots[list])
    s.focus=501
    test_frame(&ctx,&input,test_containers_build,&s)
    s.focus=0
    test_frame(&ctx,&input,test_containers_build,&s)
    testing.expect(t,test_near(s.instance.scrolls[slot].y,500*20-100+20),"It scrolls just as far as the element shows")
    _,built:=widget_rect(&ctx,test_item_id(&ctx,500,"row"))
    testing.expect(t,built && ctx.focus==test_item_id(&ctx,500,"row"))
}

@(test)
a_list_that_names_a_component_shows_the_rows_of_its_table :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:Test_Containers
    test_containers_init(t,&s)
    defer test_containers_destroy(&s)
    list:=tree_node(&s.tree,-1,{kind=.List,name="enemies",bind_items="Enemy",count=8,layout={direction=.Column}})
    tree_node(&s.tree,list,{kind=.Text,name="name",bind_text="name",layout={width=fixed(80),height=fixed(16)}})
    testing.expect(t,tree_instance_init(&s.instance,&s.tree,&s.host))
    testing.expect_value(t,len(s.instance.states),1+8)
    names:=[3]string{"Orc","Bat","Imp"}
    for name,i in names {copy(s.enemies[i].name[:],name)}
    s.rows,s.rows_stamp=2,1
    input:=test_input()
    test_frame(&ctx,&input,test_containers_build,&s)
    testing.expect(t,test_paint(&ctx,"Orc")!=nil && test_paint(&ctx,"Bat")!=nil && test_paint(&ctx,"Imp")==nil)
    // A row that came shows; one written while the stamp stays is not looked at.
    s.rows,s.rows_stamp=3,2
    test_frame(&ctx,&input,test_containers_build,&s)
    testing.expect(t,test_paint(&ctx,"Imp")!=nil)
    copy(s.enemies[0].name[:],"Elf")
    test_frame(&ctx,&input,test_containers_build,&s)
    testing.expect(t,test_paint(&ctx,"Orc")!=nil)
    s.rows_stamp=3
    test_frame(&ctx,&input,test_containers_build,&s)
    testing.expect(t,test_paint(&ctx,"Elf")!=nil && test_paint(&ctx,"Orc")==nil)
    s.rows=1
    s.rows_stamp=4
    test_frame(&ctx,&input,test_containers_build,&s)
    testing.expect(t,test_paint(&ctx,"Bat")==nil)
}

@(test)
an_array_whose_source_did_not_change_is_not_copied_and_only_changed_texts_are_made_again :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:Test_Containers
    test_containers_init(t,&s)
    defer test_containers_destroy(&s)
    root:=tree_node(&s.tree,-1,{kind=.Box,name="camp",layout={direction=.Column}})
    title:=tree_node(&s.tree,root,{kind=.Text,name="title",bind_text="Camp.title"})
    tab:=tree_node(&s.tree,root,{kind=.Text,name="tab",bind_text="Camp.tab"})
    list:=tree_node(&s.tree,root,{kind=.List,name="slots",bind_items="Camp.slots",layout={direction=.Column}})
    tree_node(&s.tree,list,{kind=.Text,name="slot",bind_text="name"})
    testing.expect(t,tree_instance_init(&s.instance,&s.tree,&s.host))
    copy(s.camp.title[:],"North")
    copy(s.camp.slots[0].name[:],"Axe")
    s.camp_stamp=1
    input:=test_input()
    test_frame(&ctx,&input,test_containers_build,&s)
    testing.expect(t,test_paint(&ctx,"North")!=nil && test_paint(&ctx,"Axe")!=nil && test_paint(&ctx,"0")!=nil)
    // The stamp did not move: neither the source nor the array in it is read.
    copy(s.camp.slots[0].name[:],"Bow")
    test_frame(&ctx,&input,test_containers_build,&s)
    testing.expect(t,test_paint(&ctx,"Axe")!=nil)
    // What reads a range that changed is made again; what kept its text keeps it.
    kept:=&s.instance.kept[s.instance.slots[title]]
    testing.expect(t,kept.valid)
    copy(s.instance.kept_bytes[kept.offset:],"Kept!")
    s.camp.tab=2
    s.camp_stamp=2
    test_frame(&ctx,&input,test_containers_build,&s)
    testing.expect(t,test_paint(&ctx,"2")!=nil && test_paint(&ctx,"Bow")!=nil)
    testing.expect(t,test_paint(&ctx,"Kept!")!=nil,"The title read nothing that changed")
    testing.expect(t,s.instance.kept[s.instance.slots[tab]].valid)
}

@(test)
a_tabs_shows_the_page_of_the_tab_chosen :: proc(t:^testing.T) {
    ctx:Context
    desc:=TEST_SMALL
    desc.navigation=true
    testing.expect(t,test_context_init(&ctx,desc))
    defer context_destroy(&ctx)
    ctx.release_activates=true
    s:Test_Containers
    test_containers_init(t,&s)
    defer test_containers_destroy(&s)
    style,_:=tree_style(&s.tree,{text={size=12,color={255,255,255,255}},fill={40,40,40,255}})
    tabs:=tree_node(&s.tree,-1,{kind=.Tabs,name="tabs",style=style,index=1,layout={width=fixed(300),height=FIT,gap=4}})
    pages:=[3]string{"Gear","Map","Quests"}
    for page in pages {
        p:=tree_node(&s.tree,tabs,{kind=.Box,text=page})
        tree_node(&s.tree,p,{kind=.Text,text=page=="Map" ? "the map" : "a page",layout={width=fixed(50),height=fixed(10)}})
    }
    testing.expect(t,tree_instance_init(&s.instance,&s.tree,&s.host))
    input:=test_input()
    test_frame(&ctx,&input,test_containers_build,&s)
    testing.expect(t,test_paint(&ctx,"Gear")!=nil && test_paint(&ctx,"Quests")!=nil,"Each node held is a tab, by its text")
    testing.expect(t,test_paint(&ctx,"the map")!=nil,"Without a binding it starts at index")
    tabs_id:=tree_element_id(&ctx,"tabs")
    test_click(&ctx,&input,test_containers_build,&s,id_derive(&ctx,tabs_id,"tab",3))
    testing.expect(t,test_paint(&ctx,"the map")==nil && test_paint(&ctx,"a page")!=nil)
    changed,count:=test_containers_said(&s,.Changed,"tabs")
    testing.expect(t,count==1 && changed.value==2)
    // The keys choose the tab they move the focus to.
    test_key(&input,.Left)
    test_frame(&ctx,&input,test_containers_build,&s)
    test_frame(&ctx,&input,test_containers_build,&s)
    testing.expect(t,test_paint(&ctx,"the map")!=nil)
    // Bound, it shows the value of the game, which writes what it asks for.
    s.tree.nodes[tabs].binds[.Value]=Name_Ref{u32(s.tree.string_length),8}
    copy(s.tree.strings[s.tree.string_length:],"Camp.tab")
    s.tree.string_length+=8
    tree_instance_destroy(&s.instance)
    testing.expect(t,tree_instance_init(&s.instance,&s.tree,&s.host))
    s.camp.tab=2
    test_frame(&ctx,&input,test_containers_build,&s)
    testing.expect(t,test_paint(&ctx,"a page")!=nil && test_paint(&ctx,"the map")==nil)
}

@(test)
a_popup_opens_from_its_parent_and_closes_outside_or_with_escape :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    ctx.release_activates=true
    s:Test_Containers
    test_containers_init(t,&s)
    defer test_containers_destroy(&s)
    holder:=tree_node(&s.tree,-1,{kind=.Box,name="holder",layout={width=fixed(100),height=fixed(30)},float={to=.Surface,offset={20,560}}})
    popup:=tree_node(&s.tree,holder,{kind=.Popup,name="menu",layout={width=fixed(120),height=fixed(60)}})
    tree_node(&s.tree,popup,{kind=.Button,name="pick",text="Pick",layout={width=fixed(80),height=fixed(20)}})
    testing.expect(t,tree_instance_init(&s.instance,&s.tree,&s.host))
    input:=test_input()
    test_frame(&ctx,&input,test_containers_build,&s)
    test_click(&ctx,&input,test_containers_build,&s,tree_element_id(&ctx,"holder"))
    _,opened:=test_containers_said(&s,.Opened,"menu")
    menu:=test_rect(t,&ctx,tree_element_id(&ctx,"menu"))
    testing.expect_value(t,opened,1)
    testing.expect_value(t,menu,Rect{20,560-4-60,120,60})
    // A press outside closes it, and opens nothing.
    input.pointer={600,100}
    test_press(&input)
    test_frame(&ctx,&input,test_containers_build,&s)
    test_release(&input)
    test_frame(&ctx,&input,test_containers_build,&s)
    _,closed:=test_containers_said(&s,.Closed,"menu")
    testing.expect_value(t,closed,1)
    _,shown:=widget_rect(&ctx,tree_element_id(&ctx,"menu"))
    testing.expect(t,!shown)
    test_click(&ctx,&input,test_containers_build,&s,tree_element_id(&ctx,"holder"))
    test_key(&input,.Escape)
    test_frame(&ctx,&input,test_containers_build,&s)
    test_frame(&ctx,&input,test_containers_build,&s)
    _,closed=test_containers_said(&s,.Closed,"menu")
    testing.expect_value(t,closed,2)
}

@(test)
a_bound_popup_opens_with_its_value_and_stays_shut_once_the_player_closed_it :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:Test_Containers
    test_containers_init(t,&s)
    defer test_containers_destroy(&s)
    holder:=tree_node(&s.tree,-1,{kind=.Box,name="holder",layout={width=fixed(100),height=fixed(30)}})
    tree_node(&s.tree,holder,{kind=.Popup,name="menu",bind_value="Camp.open",layout={width=fixed(120),height=fixed(60)}})
    testing.expect(t,tree_instance_init(&s.instance,&s.tree,&s.host))
    input:=test_input()
    s.camp.open=true
    test_frame(&ctx,&input,test_containers_build,&s)
    test_frame(&ctx,&input,test_containers_build,&s)
    menu:=test_rect(t,&ctx,tree_element_id(&ctx,"menu"))
    testing.expect_value(t,menu,Rect{0,34,120,60})
    test_key(&input,.Escape)
    test_frame(&ctx,&input,test_containers_build,&s)
    test_frame(&ctx,&input,test_containers_build,&s)
    _,shown:=widget_rect(&ctx,tree_element_id(&ctx,"menu"))
    testing.expect(t,!shown,"Shut while the game still shows it")
    s.camp.open=false
    test_frame(&ctx,&input,test_containers_build,&s)
    s.camp.open=true
    test_frame(&ctx,&input,test_containers_build,&s)
    test_frame(&ctx,&input,test_containers_build,&s)
    _,shown=widget_rect(&ctx,tree_element_id(&ctx,"menu"))
    testing.expect(t,shown)
}

@(test)
a_modal_blocks_what_is_under_it_and_escape_says_closed :: proc(t:^testing.T) {
    ctx:Context
    desc:=TEST_SMALL
    desc.navigation=true
    testing.expect(t,test_context_init(&ctx,desc))
    defer context_destroy(&ctx)
    s:Test_Containers
    test_containers_init(t,&s)
    defer test_containers_destroy(&s)
    root:=tree_node(&s.tree,-1,{kind=.Box,name="screen",layout={direction=.Column}})
    tree_node(&s.tree,root,{kind=.Button,name="under",text="Under",layout={width=fixed(80),height=fixed(20)}})
    modal:=tree_node(&s.tree,root,{kind=.Modal,name="dialog",layout={width=fixed(200),height=fixed(100)}})
    tree_node(&s.tree,modal,{kind=.Button,name="ok",text="OK",layout={width=fixed(80),height=fixed(20)}})
    testing.expect(t,tree_instance_init(&s.instance,&s.tree,&s.host))
    input:=test_input()
    test_frame(&ctx,&input,test_containers_build,&s)
    test_frame(&ctx,&input,test_containers_build,&s)
    _,opened:=test_containers_said(&s,.Opened,"dialog")
    testing.expect_value(t,opened,1)
    testing.expect_value(t,test_rect(t,&ctx,tree_element_id(&ctx,"dialog")),Rect{300,250,200,100})
    test_point(&input,test_rect(t,&ctx,tree_element_id(&ctx,"under")))
    test_frame(&ctx,&input,test_containers_build,&s)
    testing.expect(t,ctx.hot==id_derive(&ctx,tree_element_id(&ctx,"dialog"),"backdrop"),"The backdrop takes the pointer")
    test_key(&input,.Tab)
    test_frame(&ctx,&input,test_containers_build,&s)
    testing.expect_value(t,ctx.focus,tree_element_id(&ctx,"ok"))
    test_key(&input,.Tab)
    test_frame(&ctx,&input,test_containers_build,&s)
    testing.expect_value(t,ctx.focus,tree_element_id(&ctx,"ok"))
    test_key(&input,.Escape)
    test_frame(&ctx,&input,test_containers_build,&s)
    _,closed:=test_containers_said(&s,.Closed,"dialog")
    testing.expect_value(t,closed,1)
}

@(test)
a_context_menu_opens_at_the_pointer_and_a_button_chosen_closes_it :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    ctx.release_activates=true
    s:Test_Containers
    test_containers_init(t,&s)
    defer test_containers_destroy(&s)
    holder:=tree_node(&s.tree,-1,{kind=.Box,name="holder",layout={width=fixed(300),height=fixed(200)}})
    menu:=tree_node(&s.tree,holder,{kind=.Context_Menu,name="menu",layout={width=fixed(100),height=fixed(50)}})
    tree_node(&s.tree,menu,{kind=.Button,name="copy",text="Copy",layout={width=fixed(80),height=fixed(20)}})
    testing.expect(t,tree_instance_init(&s.instance,&s.tree,&s.host))
    input:=test_input()
    test_frame(&ctx,&input,test_containers_build,&s)
    input.pointer={40,50}
    test_frame(&ctx,&input,test_containers_build,&s)
    input_button(&input,.Right,true)
    test_frame(&ctx,&input,test_containers_build,&s)
    input_button(&input,.Right,false)
    test_frame(&ctx,&input,test_containers_build,&s)
    testing.expect_value(t,test_rect(t,&ctx,tree_element_id(&ctx,"menu")),Rect{40,50,100,50})
    test_click(&ctx,&input,test_containers_build,&s,tree_element_id(&ctx,"copy"))
    test_frame(&ctx,&input,test_containers_build,&s)
    _,clicked:=test_containers_said(&s,.Clicked,"copy")
    _,closed:=test_containers_said(&s,.Closed,"menu")
    testing.expect(t,clicked==1 && closed==1)
}

@(test)
a_radial_focuses_the_child_in_the_direction_of_the_stick :: proc(t:^testing.T) {
    ctx:Context
    desc:=TEST_SMALL
    desc.navigation=true
    testing.expect(t,test_context_init(&ctx,desc))
    defer context_destroy(&ctx)
    ctx.release_activates=true
    s:Test_Containers
    test_containers_init(t,&s)
    defer test_containers_destroy(&s)
    radial:=tree_node(&s.tree,-1,{kind=.Radial,name="wheel",layout={width=fixed(200),height=fixed(200)}})
    names:=[4]string{"north","east","south","west"}
    for name in names {tree_node(&s.tree,radial,{kind=.Button,name=name,text=name,layout={width=fixed(40),height=fixed(40)}})}
    testing.expect(t,tree_instance_init(&s.instance,&s.tree,&s.host))
    input:=test_input()
    test_frame(&ctx,&input,test_containers_build,&s)
    test_frame(&ctx,&input,test_containers_build,&s)
    east:=test_rect(t,&ctx,tree_element_id(&ctx,"east"))
    testing.expect_value(t,east,Rect{200-40,80,40,40})
    testing.expect_value(t,test_rect(t,&ctx,tree_element_id(&ctx,"north")),Rect{80,0,40,40})
    input.aim={0.9,0.2}
    test_frame(&ctx,&input,test_containers_build,&s)
    testing.expect_value(t,ctx.focus,tree_element_id(&ctx,"east"))
    input.aim={}
    test_key(&input,.Down)
    test_frame(&ctx,&input,test_containers_build,&s)
    testing.expect_value(t,ctx.focus,tree_element_id(&ctx,"south"))
    test_key(&input,.Enter)
    test_frame(&ctx,&input,test_containers_build,&s)
    _,clicked:=test_containers_said(&s,.Clicked,"south")
    testing.expect_value(t,clicked,1)
}

@(test)
a_tooltip_waits_its_delay_and_stays_inside_the_surface :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:Test_Containers
    test_containers_init(t,&s)
    s.track=true
    defer test_containers_destroy(&s)
    holder:=tree_node(&s.tree,-1,{kind=.Box,name="holder",layout={width=fixed(60),height=fixed(30)},float={to=.Surface,offset={760,570}}})
    tip:=tree_node(&s.tree,holder,{kind=.Tooltip,name="tip",delay=1,layout={width=fixed(100),height=fixed(20)}})
    tree_node(&s.tree,tip,{kind=.Text,text="Says what it is",layout={width=fixed(90),height=fixed(16)}})
    testing.expect(t,tree_instance_init(&s.instance,&s.tree,&s.host))
    input:=test_input()
    input.dt=0.25
    test_frame(&ctx,&input,test_containers_build,&s)
    input.pointer={780,580}
    for _ in 0..<3 {test_frame(&ctx,&input,test_containers_build,&s)}
    _,shown:=widget_rect(&ctx,tree_element_id(&ctx,"tip"))
    testing.expect(t,!shown,"It waits its own delay")
    for _ in 0..<3 {test_frame(&ctx,&input,test_containers_build,&s)}
    // No room under its node nor right of it: over the node, inside the surface.
    testing.expect_value(t,test_rect(t,&ctx,tree_element_id(&ctx,"tip")),Rect{700,570-6-20,100,20})
    // With a float of its own it hangs where that says: left of its node, a label beside an icon.
    s.tree.nodes[tip].float={to=.Parent,anchor=.Center_Left,pivot=.Center_Right,offset={-8,0}}
    s.tree.nodes[holder].float.offset={300,300}
    for _ in 0..<2 {test_frame(&ctx,&input,test_containers_build,&s)}
    input.pointer={320,310}
    for _ in 0..<6 {test_frame(&ctx,&input,test_containers_build,&s)}
    testing.expect_value(t,test_rect(t,&ctx,tree_element_id(&ctx,"tip")),Rect{300-8-100,315-10,100,20})
}

@(test)
a_tree_gives_its_grids_the_tracks_it_holds :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:Test_Containers
    test_containers_init(t,&s)
    defer test_containers_destroy(&s)
    s.tree.grid_tracks[0]={count=2,columns={0=fixed(30),1=GROW}}
    s.tree.grid_track_count=1
    grid:=tree_node(&s.tree,-1,{kind=.Box,name="grid",layout={width=fixed(200),height=FIT,direction=.Grid,tracks=1,gap=10}})
    tree_node(&s.tree,grid,{kind=.Box,name="label",layout={width=GROW,height=fixed(10)}})
    tree_node(&s.tree,grid,{kind=.Box,name="value",layout={width=GROW,height=fixed(10)}})
    testing.expect(t,tree_instance_init(&s.instance,&s.tree,&s.host))
    input:=test_input()
    build :: proc(ctx:^Context,user:rawptr) {
        // Tracks of the frame before the tree's: its rows still name its own.
        grid_tracks_add(ctx,{count=1,columns={0=fixed(5)}})
        s:=cast(^Test_Containers)user
        tree_build(ctx,&s.tree,&s.instance,{track=true})
    }
    test_frame(&ctx,&input,build,&s)
    testing.expect_value(t,test_rect(t,&ctx,tree_element_id(&ctx,"label")).w,f32(30))
    value:=test_rect(t,&ctx,tree_element_id(&ctx,"value"))
    testing.expect(t,test_near(value.x,40) && test_near(value.w,160))
}
