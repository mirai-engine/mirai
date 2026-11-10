package ui

import "core:slice"
import "core:testing"
import "mirai:std/base"
import "mirai:std/serial"

Test_Slot :: struct {
    name:[16]u8 `mirai:"text"`,
    count:i32,
    equipped:bool,
}
Test_Bag :: struct {
    page:i32,
    slots:[6]Test_Slot,
    used:i32,
    screen:Test_Screen,
    screen_name:[16]u8 `mirai:"text"`,
}
Test_Screen :: enum i32 {Menu,Pause,Playing}

Test_Kinds :: struct {
    schema:serial.Schema,
    type:serial.Type_Index,
    host:Test_Host,
    tree:Widget_Tree,
    instance:Tree_Instance,
    values:Test_Bag,
    events:[8]Tree_Event,
    event_count:int,
}
test_kinds_build :: proc(ctx:^Context,user:rawptr) {
    s:=cast(^Test_Kinds)user
    s.event_count=test_tree_build(ctx,&s.tree,&s.instance,&s.host.host,{events=s.events[:]}).count
}

@(test)
a_grid_puts_its_children_in_rows_of_cells_of_one_width :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    build :: proc(ctx:^Context,user:rawptr) {
        if box(ctx,{id=id(ctx,"grid"),width=fixed(320),height=FIT,direction=.Grid,columns=3,gap=10,padding=padding_all(5),align_x=.Center,track=true}) {
            heights:=[5]f32{20,40,20,30,10}
            for height,i in heights {
                if box(ctx,{id=id(ctx,"cell",i+1),width=fixed(50),height=fixed(height),track=true}) {}
            }
            if box(ctx,{id=id(ctx,"wide"),width=GROW,height=fixed(10),track=true}) {}
        }
    }
    input:=test_input()
    test_frame(&ctx,&input,build)
    grid:=test_rect(t,&ctx,id(&ctx,"grid"))
    // Cells of (320-10-20)/3 units: the second row starts below the highest of the first.
    cell:=f32(320-10-20)/3
    testing.expect_value(t,grid.h,f32(5+40+10+30+5))
    first:=test_rect(t,&ctx,id(&ctx,"cell",1))
    testing.expect_value(t,first,Rect{5+(cell-50)*0.5,5,50,20})
    third:=test_rect(t,&ctx,id(&ctx,"cell",3))
    testing.expect_value(t,third.x,5+2*(cell+10)+(cell-50)*0.5)
    fourth:=test_rect(t,&ctx,id(&ctx,"cell",4))
    testing.expect_value(t,fourth.y,f32(5+40+10))
    wide:=test_rect(t,&ctx,id(&ctx,"wide"))
    testing.expect_value(t,wide.w,cell)
    testing.expect_value(t,wide.x,5+2*(cell+10))
}

@(test)
a_list_builds_its_node_for_each_element_and_a_switcher_one_child :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_FONT))
    defer context_destroy(&ctx)
    ctx.theme.activate_on_press=false
    s:Test_Kinds
    serial.schema_init(&s.schema)
    defer serial.schema_destroy(&s.schema)
    ok:bool
    s.type,ok=serial.schema_add(&s.schema,Test_Bag)
    testing.expect(t,ok)
    testing.expect(t,tree_init(&s.tree))
    defer tree_destroy(&s.tree)
    style,_:=tree_style(&s.tree,{text={size=12,color={255,255,255,255}},fill={40,40,40,255}})
    root:=tree_node(&s.tree,-1,{kind=.Box,name="bag",layout={width=fixed(400),height=fixed(300),direction=.Column}})
    pages:=tree_node(&s.tree,root,{kind=.Switcher,name="pages",bind_value="Test.page"})
    list:=tree_node(&s.tree,pages,{kind=.List,name="slots",bind_items="Test.slots",bind_value="Test.used",layout={direction=.Grid,columns=2,gap=4,width=GROW}})
    slot:=tree_node(&s.tree,list,{kind=.Box,name="slot",layout={width=GROW,height=fixed(30)},bind_selected="equipped"})
    tree_node(&s.tree,slot,{kind=.Button,name="use",style=style,bind_text="name",layout={width=fixed(60),height=fixed(24)}})
    tree_node(&s.tree,slot,{kind=.Text,name="count",style=style,bind_text="count"})
    tree_node(&s.tree,pages,{kind=.Text,name="empty",style=style,text="Nothing here"})
    testing.expect(t,tree_instance_init(&s.instance,&s.tree,test_host(&s.host,&s.schema,s.type,&s.values)))
    defer tree_instance_destroy(&s.instance)
    // The nodes of the list keep a slot per element.
    testing.expect_value(t,len(s.instance.states),1+1+1+6*3+1)
    names:=[3]string{"Sword","Shield","Potion"}
    for name,i in names {copy(s.values.slots[i].name[:],name);s.values.slots[i].count=i32(i+1)}
    s.values.used=3
    input:=test_input()
    test_frame(&ctx,&input,test_kinds_build,&s)
    test_frame(&ctx,&input,test_kinds_build,&s)
    testing.expect(t,test_paint(&ctx,"Sword")!=nil && test_paint(&ctx,"Potion")!=nil)
    testing.expect(t,test_paint(&ctx,"3")!=nil,"Each element shows its own fields")
    testing.expect(t,test_paint(&ctx,"Nothing here")==nil)
    // The second element sits in the second column of the grid, the third under the first.
    element :: proc(t:^testing.T,ctx:^Context,item:int) -> Rect {
        id_push(ctx,id(ctx,"item",item))
        defer id_pop(ctx)
        return test_rect(t,ctx,tree_element_id(ctx,"use"))
    }
    first,second,third:=element(t,&ctx,1),element(t,&ctx,2),element(t,&ctx,3)
    testing.expect(t,second.y==first.y && second.x>first.x && third.x==first.x && third.y>first.y)
    s.values.page=1
    test_frame(&ctx,&input,test_kinds_build,&s)
    testing.expect(t,test_paint(&ctx,"Sword")==nil && test_paint(&ctx,"Nothing here")!=nil)
}

// The children are in another order than the members of the enum, and Playing has none.
@(test)
a_switcher_bound_to_an_enum_or_a_text_builds_the_child_of_that_name :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_FONT))
    defer context_destroy(&ctx)
    s:Test_Kinds
    serial.schema_init(&s.schema)
    defer serial.schema_destroy(&s.schema)
    ok:bool
    s.type,ok=serial.schema_add(&s.schema,Test_Bag)
    testing.expect(t,ok)
    testing.expect(t,tree_init(&s.tree))
    defer tree_destroy(&s.tree)
    style,_:=tree_style(&s.tree,{text={size=12,color={255,255,255,255}},fill={40,40,40,255}})
    root:=tree_node(&s.tree,-1,{kind=.Box,name="root",layout={width=fixed(400),height=fixed(300),direction=.Column}})
    by_enum:=tree_node(&s.tree,root,{kind=.Switcher,name="by_enum",bind_value="Test.screen"})
    tree_node(&s.tree,by_enum,{kind=.Text,name="Pause",style=style,text="the pause page"})
    tree_node(&s.tree,by_enum,{kind=.Text,name="Menu",style=style,text="the menu page"})
    by_text:=tree_node(&s.tree,root,{kind=.Switcher,name="by_text",bind_value="Test.screen_name"})
    tree_node(&s.tree,by_text,{kind=.Text,name="b",style=style,text="the b page"})
    tree_node(&s.tree,by_text,{kind=.Text,name="a",style=style,text="the a page"})
    testing.expect(t,tree_instance_init(&s.instance,&s.tree,test_host(&s.host,&s.schema,s.type,&s.values)))
    defer tree_instance_destroy(&s.instance)
    copy(s.values.screen_name[:],"a")
    input:=test_input()
    test_frame(&ctx,&input,test_kinds_build,&s)
    test_frame(&ctx,&input,test_kinds_build,&s)
    testing.expect(t,test_paint(&ctx,"the menu page")!=nil && test_paint(&ctx,"the pause page")==nil)
    testing.expect(t,test_paint(&ctx,"the a page")!=nil && test_paint(&ctx,"the b page")==nil)
    s.values.screen=.Pause
    test_frame(&ctx,&input,test_kinds_build,&s)
    testing.expect(t,test_paint(&ctx,"the pause page")!=nil && test_paint(&ctx,"the menu page")==nil)
    // The schema moves its choices when a later type makes it grow.
    moved:=slice.clone_to_dynamic(s.schema.choices[:],s.schema.allocator)
    for &choice in s.schema.choices {choice.name=""}
    delete(s.schema.choices)
    s.schema.choices=moved
    test_frame(&ctx,&input,test_kinds_build,&s)
    testing.expect(t,test_paint(&ctx,"the pause page")!=nil,"its page is found after the schema moved its choices")
    s.values.screen=.Playing
    test_frame(&ctx,&input,test_kinds_build,&s)
    testing.expect(t,test_paint(&ctx,"the pause page")==nil && test_paint(&ctx,"the menu page")==nil,"a member without a page shows none")
}

@(test)
the_buttons_of_a_list_report_their_element :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    ctx.theme.activate_on_press=false
    s:Test_Kinds
    serial.schema_init(&s.schema)
    defer serial.schema_destroy(&s.schema)
    s.type,_=serial.schema_add(&s.schema,Test_Bag)
    testing.expect(t,tree_init(&s.tree))
    defer tree_destroy(&s.tree)
    list:=tree_node(&s.tree,-1,{kind=.List,name="slots",bind_items="Test.slots",layout={direction=.Column,gap=2}})
    tree_node(&s.tree,list,{kind=.Button,name="use",text="Use",layout={width=fixed(60),height=fixed(20)}})
    testing.expect(t,tree_instance_init(&s.instance,&s.tree,test_host(&s.host,&s.schema,s.type,&s.values)))
    defer tree_instance_destroy(&s.instance)
    input:=test_input()
    test_frame(&ctx,&input,test_kinds_build,&s)
    // Without a value the list builds every element of its array: six buttons, one under the other.
    id_push(&ctx,id(&ctx,"item",3))
    third:=test_rect(t,&ctx,tree_element_id(&ctx,"use"))
    id_pop(&ctx)
    testing.expect_value(t,third.y,f32(2*22))
    test_point(&input,third)
    test_frame(&ctx,&input,test_kinds_build,&s)
    test_press(&input);test_release(&input)
    test_frame(&ctx,&input,test_kinds_build,&s)
    clicked:Tree_Event
    count:=0
    for event in s.events[:s.event_count] {if event.kind==.Clicked {clicked=event;count+=1}}
    testing.expect_value(t,count,1)
    testing.expect(t,clicked.rect.w>0,"it says where its button is")
    clicked.rect={}
    testing.expect_value(t,clicked,Tree_Event{name=base.name_hash("use"),node=1,kind=.Clicked,item=2})
}

@(test)
a_scroll_node_moves_what_does_not_fit_with_the_wheel :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:Test_Kinds
    testing.expect(t,tree_init(&s.tree))
    defer tree_destroy(&s.tree)
    area:=tree_node(&s.tree,-1,{kind=.Scroll,name="area",layout={width=fixed(100),height=fixed(50),direction=.Column,gap=0}})
    for i in 0..<5 {
        names:=[5]string{"a","b","c","d","e"}
        tree_node(&s.tree,area,{kind=.Spacer,name=names[i],layout={width=fixed(100),height=fixed(20)}})
    }
    tree_node(&s.tree,area,{kind=.Button,name="last",text="Last",flags={.Skip},layout={width=fixed(100),height=fixed(20)}})
    testing.expect(t,tree_instance_init(&s.instance,&s.tree,nil))
    defer tree_instance_destroy(&s.instance)
    input:=test_input()
    test_frame(&ctx,&input,test_kinds_build,&s)
    test_frame(&ctx,&input,test_kinds_build,&s)
    view:=test_rect(t,&ctx,id(&ctx,"scroll",1))
    last:=test_rect(t,&ctx,tree_element_id(&ctx,"last"))
    testing.expect_value(t,last.y,view.y+100)
    test_point(&input,view)
    input.wheel={0,-10}
    test_frame(&ctx,&input,test_kinds_build,&s)
    input.wheel={}
    test_frame(&ctx,&input,test_kinds_build,&s)
    last=test_rect(t,&ctx,tree_element_id(&ctx,"last"))
    testing.expect_value(t,last.y+last.h,view.y+view.h)
}

@(test)
a_widget_of_another_file_joins_the_tree_with_its_styles_and_overrides :: proc(t:^testing.T) {
    texts:=make([dynamic]u8,context.temp_allocator)
    button_styles:=[2]Node_Style{{},{fill={10,20,30,255},text={size=12,font=FONT_TREE}}}
    button_nodes:=[2]Tree_Node{
        tree_node_record(&texts,-1,{kind=.Box,name="frame",style=1,layout={width=fixed(80),height=fixed(30)}}),
        tree_node_record(&texts,0,{kind=.Text,name="label",style=1,text="Button"}),
    }
    button_fonts:=[1]Tree_Font{{font=base.Asset_Id{7,0}}}
    widget:=Tree_Data{text=texts[:],nodes=button_nodes[:],styles=button_styles[:],fonts=button_fonts[:]}
    styles:=[1]Node_Style{{fill={1,2,3,255},text={font=FONT_TREE}}}
    fonts:=[1]Tree_Font{{font=base.Asset_Id{6,0}}}
    components:=[1]Tree_Component{tree_component_record("button",0,0)}
    components[0].widget=base.Asset_Id{1,2}
    nodes:=[3]Tree_Node{
        tree_node_record(&texts,-1,{kind=.Box,name="inventory",layout={gap=4}}),
        tree_node_record(&texts,0,{kind=.Component,name="equip",component=1}),
        tree_node_record(&texts,0,{kind=.Component,name="drop",component=1}),
    }
    overrides:=[1]Tree_Override{tree_override_record(&texts,2,"label",{.Text},{text="Drop"})}
    data:=Tree_Data{text=texts[:],nodes=nodes[:],styles=styles[:],fonts=fonts[:],components=components[:],overrides=overrides[:]}
    tree:Widget_Tree
    faces:=[2]u8{FONT_MEDIUM,FONT_SEMIBOLD}
    testing.expect(t,!tree_load(&tree,data,{fonts=faces[:1]}),"A widget not linked does not load")
    imports:=[1]Tree_Data{widget}
    linked,ok:=tree_link(data,imports[:])
    testing.expect(t,ok)
    // The fonts of the file follow those of the tree.
    testing.expect_value(t,len(linked.fonts),2)
    testing.expect_value(t,linked.fonts[1].font,base.Asset_Id{7,0})
    testing.expect(t,tree_load(&tree,linked,{fonts=faces[:]}))
    defer tree_destroy(&tree)
    testing.expect_value(t,tree.node_count,5)
    testing.expect_value(t,tree.nodes[3].name,base.name_hash("drop"))
    testing.expect_value(t,tree.nodes[4].name,base.name_hash("drop/label"))
    testing.expect_value(t,string(tree.strings[tree.nodes[4].text_offset:][:tree.nodes[4].text_length]),"Drop")
    testing.expect_value(t,string(tree.strings[tree.nodes[2].text_offset:][:tree.nodes[2].text_length]),"Button")
    testing.expect_value(t,tree.styles[tree.nodes[1].style].fill,Color{10,20,30,255})
    testing.expect_value(t,tree.styles[tree.nodes[0].style].fill,Color{1,2,3,255})
    testing.expect_value(t,tree.styles[tree.nodes[0].style].text.font,FONT_MEDIUM)
    testing.expect_value(t,tree.styles[tree.nodes[2].style].text.font,FONT_SEMIBOLD)
    missing:=[1]Tree_Data{}
    _,missing_ok:=tree_link(data,missing[:])
    testing.expect(t,!missing_ok,"A widget without its file does not link")
}

@(test)
what_floats_on_the_surface_of_a_tree_floats_on_its_area :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:Test_Kinds
    testing.expect(t,tree_init(&s.tree))
    defer tree_destroy(&s.tree)
    tree_node(&s.tree,-1,{kind=.Box,name="hud",layout={width=fixed(50),height=fixed(20)},float={to=.Safe,anchor=.Top_Left,pivot=.Top_Left,offset={10,10}}})
    tree_node(&s.tree,-1,{kind=.Box,name="menu",layout={width=fixed(40),height=fixed(40)},float={to=.Surface,anchor=.Center,pivot=.Center}})
    testing.expect(t,tree_instance_init(&s.instance,&s.tree,nil))
    defer tree_instance_destroy(&s.instance)
    // The right half of the window is the part of a player.
    build :: proc(ctx:^Context,user:rawptr) {
        s:=cast(^Test_Kinds)user
        part:=Rect{400,0,400,600}
        root:=Box{id=id(ctx,"part"),width=fixed(part.w),height=fixed(part.h),float={to=.Surface,offset={part.x,part.y}}}
        box_begin(ctx,root)
        tree_build(ctx,&s.tree,&s.instance,{track=true,area=root.id,area_rect=part})
        box_end(ctx,root)
    }
    input:=test_input()
    input.safe={0,20,0,0}
    test_frame(&ctx,&input,build,&s)
    test_frame(&ctx,&input,build,&s)
    testing.expect_value(t,test_rect(t,&ctx,tree_element_id(&ctx,"hud")),Rect{410,30,50,20})
    testing.expect_value(t,test_rect(t,&ctx,tree_element_id(&ctx,"menu")),Rect{580,280,40,40})
}

Test_Hero :: struct {
    name:[16]u8 `mirai:"text"`,
    target:base.Entity,
    party:[3]base.Entity,
    notes:[512]u8, // read by no node: never copied
}
Test_Health :: struct {health:i32,armor:i32}
Test_Clock :: struct {seconds:f32}

// A world of the tests: a player (entity 1) with Test_Hero, three
// entities with Test_Health (2, 3 and 4) and a storage Test_Clock.
Test_Bind_World :: struct {
    host:Bind_Host,
    schema:serial.Schema,
    player,stats,match:serial.Type_Index,
    players:Test_Hero,
    stats_of:[3]Test_Health,
    stamps:[3]u64,
    game:Test_Clock,
    fetched:int,
}
test_bind_world_init :: proc(w:^Test_Bind_World) -> ^Bind_Host {
    serial.schema_init(&w.schema)
    w.player,_=serial.schema_add(&w.schema,Test_Hero)
    w.stats,_=serial.schema_add(&w.schema,Test_Health)
    w.match,_=serial.schema_add(&w.schema,Test_Clock)
    w.host={user=w,schema=&w.schema,
        source=proc(user:rawptr,name:u64) -> (type:serial.Type_Index,storage,ok:bool) {
            w:=(^Test_Bind_World)(user)
            switch name {
            case base.name_hash("Test_Hero"): return w.player,false,true
            case base.name_hash("Test_Health"):  return w.stats,false,true
            case base.name_hash("Test_Clock"):  return w.match,true,true
            }
            return
        },
        fetch=proc(user:rawptr,name:u64,entity:base.Entity) -> (data:rawptr,stamp:u64) {
            w:=(^Test_Bind_World)(user)
            w.fetched+=1
            switch name {
            case base.name_hash("Test_Hero"): if entity==1 {return &w.players,0}
            case base.name_hash("Test_Health"):  if entity>=2 && entity<=4 {return &w.stats_of[entity-2],w.stamps[entity-2]}
            case base.name_hash("Test_Clock"):  return &w.game,0
            }
            return nil,0
        },
    }
    return &w.host
}

@(test)
paths_reach_components_through_entities_and_copy_only_what_is_read :: proc(t:^testing.T) {
    w:Test_Bind_World
    host:=test_bind_world_init(&w)
    defer serial.schema_destroy(&w.schema)
    tree:Widget_Tree
    testing.expect(t,tree_init(&tree))
    defer tree_destroy(&tree)
    root:=tree_node(&tree,-1,{kind=.Box,name="hud"})
    tree_node(&tree,root,{kind=.Text,name="name",bind_text="Test_Hero.name"})
    tree_node(&tree,root,{kind=.Progress,name="target",bind_value="Test_Hero.target.Test_Health.health"})
    tree_node(&tree,root,{kind=.Text,name="clock",text="{time:mm:ss}",fields={{"time","Test_Clock.seconds"},{},{},{}}})
    party:=tree_node(&tree,root,{kind=.List,name="party",bind_items="Test_Hero.party"})
    tree_node(&tree,party,{kind=.Text,name="member",text="{health}/{armor}",fields={{"health","Test_Health.health"},{"armor","Test_Health.armor"},{},{}}})
    // A number names an element of an array: an entity, through it a component, or a value.
    tree_node(&tree,root,{kind=.Progress,name="second",bind_value="Test_Hero.party.1.Test_Health.health"})
    tree_node(&tree,root,{kind=.Progress,name="note",bind_value="Test_Hero.notes.511"})
    instance:Tree_Instance
    testing.expect(t,tree_instance_init(&instance,&tree,host))
    defer tree_instance_destroy(&instance)
    // The notes are read by nothing: the copy is far smaller than the player.
    testing.expect(t,len(instance.values)<size_of(Test_Hero),"only what the tree reads is copied")
    w.players.target=3
    w.players.party={2,4,0}
    w.stats_of={{health=10,armor=1},{health=20,armor=2},{health=30,armor=3}}
    w.stamps={1,1,1}
    w.game.seconds=65
    copy(w.players.name[:],"Ana")
    changed,missing:=tree_values_refresh(&instance,host,1)
    testing.expect(t,changed && missing==0)
    values:=raw_data(instance.values)
    testing.expect_value(t,bound_number(values,instance.bounds[2].value),20.0)
    testing.expect_value(t,bound_bytes(values,instance.bounds[1].text),"Ana")
    // The elements of the party are its entities: each shows its own stats; the empty one, zeros.
    items:=instance.items[4]
    testing.expect_value(t,items.count,u32(3))
    member :: proc(instance:^Tree_Instance,values:[^]u8,items:Node_Items,element:int) -> f64 {
        part:=instance.parts[instance.templates[5].first]
        return bound_number(rawptr(&values[items.offset+u32(element)*items.stride]),part.bound)
    }
    testing.expect_value(t,member(&instance,values,items,0),10.0)
    testing.expect_value(t,member(&instance,values,items,1),30.0)
    testing.expect_value(t,member(&instance,values,items,2),0.0)
    testing.expect_value(t,bound_number(values,instance.bounds[6].value),30.0)
    testing.expect_value(t,bound_number(values,instance.bounds[7].value),0.0)
    // Nothing moved: nothing is copied. A note no node reads changes: nothing either.
    w.players.notes[0]=7
    changed,_=tree_values_refresh(&instance,host,1)
    testing.expect(t,!changed,"a field nothing reads changes nothing")
    w.players.notes[511]=9
    changed,_=tree_values_refresh(&instance,host,1)
    testing.expect(t,changed && bound_number(values,instance.bounds[7].value)==9,"the element a number names is read")
    // Another target: its health, though no stamp moved.
    w.players.target=2
    changed,_=tree_values_refresh(&instance,host,1)
    testing.expect(t,changed)
    testing.expect_value(t,bound_number(values,instance.bounds[2].value),10.0)
    // An element past the end of its array is not found.
    bad:Widget_Tree
    testing.expect(t,tree_init(&bad))
    defer tree_destroy(&bad)
    tree_node(&bad,-1,{kind=.Progress,name="past",bind_value="Test_Hero.party.3.Test_Health.health"})
    past:Tree_Instance
    tree_instance_init(&past,&bad,host)
    defer tree_instance_destroy(&past)
    testing.expect(t,past.failure.node==0,"an index past the array fails like a missing field")
    // A root without its source is not found.
    _,missing=tree_values_refresh(&instance,host,9)
    testing.expect_value(t,missing,base.name_hash("Test_Hero"))
}

@(test)
a_widget_reads_with_at_the_data_its_instance_gives_it :: proc(t:^testing.T) {
    texts:=make([dynamic]u8,context.temp_allocator)
    bar_nodes:=[2]Tree_Node{
        tree_node_record(&texts,-1,{kind=.Box,name="bar"}),
        tree_node_record(&texts,0,{kind=.Text,name="value",text="{health} of {armor:0}",fields={{"health","@health"},{"armor","@armor"},{},{}},bind_visible="@health"}),
    }
    widget:=Tree_Data{text=texts[:],nodes=bar_nodes[:]}
    components:=[1]Tree_Component{tree_component_record("bar",0,0)}
    components[0].widget=base.Asset_Id{1,2}
    nodes:=[3]Tree_Node{
        tree_node_record(&texts,-1,{kind=.Box,name="hud"}),
        tree_node_record(&texts,0,{kind=.Component,name="mine",component=1,data="Test_Hero.target.Test_Health"}),
        tree_node_record(&texts,0,{kind=.Component,name="loose",component=1}),
    }
    imports:=[1]Tree_Data{widget}
    linked,ok:=tree_link({text=texts[:],nodes=nodes[:],components=components[:]},imports[:])
    testing.expect(t,ok)
    tree:Widget_Tree
    testing.expect(t,tree_load(&tree,linked,{}))
    defer tree_destroy(&tree)
    text :: proc(tree:^Widget_Tree,node:int) -> string {return string(tree.strings[tree.nodes[node].text_offset:][:tree.nodes[node].text_length])}
    testing.expect_value(t,tree_field_path(&tree,&tree.nodes[2],"armor"),"Test_Hero.target.Test_Health.armor")
    testing.expect_value(t,tree_binding(&tree,&tree.nodes[2],.Visible),"Test_Hero.target.Test_Health.health")
    // Without data, @ names nothing the game has.
    testing.expect_value(t,tree_binding(&tree,&tree.nodes[4],.Visible),"@health")
    w:Test_Bind_World
    host:=test_bind_world_init(&w)
    defer serial.schema_destroy(&w.schema)
    instance:Tree_Instance
    testing.expect(t,!tree_instance_init(&instance,&tree,host))
    testing.expect(t,instance.failure.node==4 && instance.failure.binding==.Visible)
}
