package ui

import "core:mem"
import "core:testing"
import "mirai:std/base"
import "mirai:std/serial"

Test_Hud :: struct {
    health:f32,
    score:i32,
    name:[16]u8 `mirai:"text"`,
    paused:bool,
    muted:bool,
    lives:u8,
}

Test_Hud_Tree :: struct {
    schema:serial.Schema,
    type:serial.Type_Index,
    host:Test_Host,
    tree:Widget_Tree,
    instance:Tree_Instance,
    values:Test_Hud,
    events:[8]Tree_Event,
    event_count:int,
    scope:int,   // builds the tree under an id scope when not zero
}

// A host of one source, Test, whose bytes are values: the tests bind "Test.field".
Test_Host :: struct {host:Bind_Host,type:serial.Type_Index,values:rawptr}
test_host :: proc(h:^Test_Host,schema:^serial.Schema,type:serial.Type_Index,values:rawptr) -> ^Bind_Host {
    h^={type=type,values=values}
    h.host={user=h,schema=schema,
        source=proc(user:rawptr,name:u64) -> (type:serial.Type_Index,storage,ok:bool) {
            h:=(^Test_Host)(user)
            if name!=base.name_hash("Test") {return}
            return h.type,false,true
        },
        fetch=proc(user:rawptr,name:u64,entity:base.Entity) -> (data:rawptr,stamp:u64) {
            h:=(^Test_Host)(user)
            return h.values if name==base.name_hash("Test") else nil,0
        },
    }
    return &h.host
}
// Builds a tree with the values its host gives now.
test_tree_build :: proc(ctx:^Context,tree:^Widget_Tree,instance:^Tree_Instance,host:^Bind_Host,desc:Tree_Build_Desc) -> Tree_Build_Result {
    changed,_:=tree_values_refresh(instance,host,0)
    desc:=desc
    desc.changed|=changed
    return tree_build(ctx,tree,instance,desc)
}

// A HUD: the name of the player, a health bar, the score and, while the game
// is paused, a menu with a button and a checkbox.
test_hud_fill :: proc(t:^testing.T,tree:^Widget_Tree,animated_menu:bool=false) {
    white:=Color{255,255,255,255}
    title,_:=tree_style(tree,{text={size=16,color=white}})
    bar,_:=tree_style(tree,{fill={200,40,40,255},track={30,30,30,255},radius=3})
    small,_:=tree_style(tree,{text={size=12,color={200,200,200,255}}})
    panel_style,_:=tree_style(tree,{fill={0,0,0,160},radius=4})
    button_style,_:=tree_style(tree,{text={size=14,color=white},fill={60,60,60,255},radius=4})
    tree_style_variant(tree,{style=button_style,states={.Hovered},patch={fields={.Fill},values={fill={90,90,90,255}}}})
    tree_style_variant(tree,{style=button_style,states={.Pressed},patch={fields={.Fill},values={fill={30,30,30,255}}}})
    menu_anims:u16
    if animated_menu {
        shown:=anim_tween(&tree.anims,.Opacity,{0,0,0,0},{1,0,0,0},0.5,.Linear)
        hidden:=anim_tween(&tree.anims,.Opacity,{1,0,0,0},{0,0,0,0},0.5,.Linear)
        menu_anims,_=tree_anim_set(tree,{shown=shown,hidden=hidden})
    }
    root:=tree_node(tree,-1,{kind=.Box,name="hud",layout={width=fixed(300),height=fixed(200),direction=.Column,padding=padding_all(10),gap=6},style=panel_style})
    testing.expect_value(t,root,i32(0))
    testing.expect_value(t,tree_node(tree,root,{kind=.Text,name="title",text="Player",style=title,bind_text="Test.name",layout={width=fixed(200),height=fixed(20)}}),i32(1))
    tree_node(tree,root,{kind=.Progress,name="health",style=bar,bind_value="Test.health",layout={width=fixed(200),height=fixed(12)}})
    tree_node(tree,root,{kind=.Text,name="score",style=small,bind_text="Test.score",layout={width=fixed(100),height=fixed(16)}})
    menu:=tree_node(tree,root,{kind=.Box,name="menu",layout={gap=8,align_y=.Center},bind_visible="Test.paused",anims=menu_anims})
    tree_node(tree,menu,{kind=.Button,name="resume",text="Resume",style=button_style,layout={width=fixed(90),height=fixed(30)}})
    tree_node(tree,menu,{kind=.Checkbox,name="mute",bind_value="Test.muted"})
    tree_node(tree,menu,{kind=.Text,text="Mute",style=small})
    testing.expect_value(t,tree_node(tree,root,{kind=.Spacer,layout={width=GROW,height=GROW}}),i32(8))
    testing.expect_value(t,tree.nodes[root].subtree,i32(8))
    testing.expect_value(t,tree.nodes[menu].subtree,i32(3))
}
test_hud_init :: proc(t:^testing.T,s:^Test_Hud_Tree,animated_menu:bool=false) {
    serial.schema_init(&s.schema)
    ok:bool
    s.type,ok=serial.schema_add(&s.schema,Test_Hud)
    testing.expect(t,ok)
    testing.expect(t,tree_init(&s.tree))
    test_hud_fill(t,&s.tree,animated_menu)
    testing.expect(t,tree_instance_init(&s.instance,&s.tree,test_host(&s.host,&s.schema,s.type,&s.values)))
    s.values={health=0.75,score=120,lives=3}
    copy(s.values.name[:],"Hero")
}
test_hud_destroy :: proc(s:^Test_Hud_Tree) {
    tree_instance_destroy(&s.instance);tree_destroy(&s.tree);serial.schema_destroy(&s.schema)
}
test_hud_build :: proc(ctx:^Context,user:rawptr) {
    s:=cast(^Test_Hud_Tree)user
    if s.scope!=0 {id_push(ctx,id(ctx,"scope",s.scope))}
    s.event_count=test_tree_build(ctx,&s.tree,&s.instance,&s.host.host,{events=s.events[:]}).count
    if s.scope!=0 {id_pop(ctx)}
}

@(test)
a_tree_of_nodes_builds_the_widgets_it_describes :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:Test_Hud_Tree
    test_hud_init(t,&s)
    defer test_hud_destroy(&s)
    input:=test_input()
    frame:=test_frame(&ctx,&input,test_hud_build,&s)
    testing.expect_value(t,ctx.stats.layout_errors,u32(0))
    testing.expect(t,test_rect_near(test_rect(t,&ctx,tree_element_id(&ctx,"title")),{10,10,200,20}))
    testing.expect(t,test_rect_near(test_rect(t,&ctx,tree_element_id(&ctx,"health")),{10,36,200,12}))
    testing.expect(t,test_rect_near(test_rect(t,&ctx,tree_element_id(&ctx,"score")),{10,54,100,16}))
    // Bound fields are what the nodes show.
    testing.expect(t,test_paint(&ctx,"Hero")!=nil && test_paint(&ctx,"Player")==nil,"The bound text replaces the one of the node")
    score:=test_paint(&ctx,"120")
    testing.expect(t,score!=nil && test_paint_is_text(score^) && score.style.size==12)
    bar:^Paint
    for &p in ctx.paints[:ctx.paint_count] {if p.kind==.Progress {bar=&p}}
    testing.expect(t,bar!=nil && bar.value==0.75 && bar.fill==Color{200,40,40,255} && bar.fill2==Color{30,30,30,255})
    // The background of the root, the track and three quarters of the bar.
    testing.expect(t,test_rect_near(test_drawn(frame,frame.vertices),{0,0,300,200}))
    // The menu exists only while its field is true.
    testing.expect(t,test_paint(&ctx,"Resume")==nil)
    _,found:=widget_rect(&ctx,tree_element_id(&ctx,"resume"))
    testing.expect(t,!found)
    s.values.paused=true
    s.values.score=-7;s.values.health=0.1
    test_frame(&ctx,&input,test_hud_build,&s)
    testing.expect(t,test_paint(&ctx,"Resume")!=nil && test_paint(&ctx,"Mute")!=nil && test_paint(&ctx,"-7")!=nil)
    testing.expect(t,test_rect_near(test_rect(t,&ctx,tree_element_id(&ctx,"resume")),{10,76,90,30}))
    // A checkbox without a size is a line of its text square (16, of the first style), centered in the row.
    side:=16*TEXT_LINE
    testing.expect(t,test_rect_near(test_rect(t,&ctx,tree_element_id(&ctx,"mute")),{108,76+(30-side)*0.5,side,side}))
    testing.expect_value(t,s.event_count,0)
}

// What a node showed in the last build, as a tool reads it: shown, hovered,
// disabled by its own binding, and the text it showed.
@(test)
the_state_of_a_node_is_what_its_last_build_showed :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:Test_Hud_Tree
    test_hud_init(t,&s)
    defer test_hud_destroy(&s)
    input:=test_input()
    test_frame(&ctx,&input,test_hud_build,&s)
    title,ok:=tree_node_state(&s.tree,&s.instance,1)
    testing.expect(t,ok && title.shown && !title.hovered && !title.disabled)
    testing.expect_value(t,title.text,"Hero")
    resume,_:=tree_node_state(&s.tree,&s.instance,5)
    testing.expect(t,!resume.shown,"the menu is not built while the game is not paused")
    s.values.paused=true
    input.pointer={50,90}
    for _ in 0..<3 {test_frame(&ctx,&input,test_hud_build,&s)}
    resume,_=tree_node_state(&s.tree,&s.instance,5)
    testing.expect(t,resume.shown && resume.hovered)
    testing.expect_value(t,resume.text,"Resume")
    mute,_:=tree_node_state(&s.tree,&s.instance,7)
    testing.expect_value(t,mute.text,"Mute")
    _,ok=tree_node_state(&s.tree,&s.instance,s.tree.node_count)
    testing.expect(t,!ok)

    gated:Widget_Tree
    testing.expect(t,tree_init(&gated))
    defer tree_destroy(&gated)
    root:=tree_node(&gated,-1,{kind=.Box,layout={width=fixed(100),height=fixed(100)}})
    tree_node(&gated,root,{kind=.Button,name="go",text="Go",bind_disabled="Test.muted",layout={width=fixed(50),height=fixed(20)}})
    tree_node(&gated,root,{kind=.Button,name="never",text="Never",disabled=true,layout={width=fixed(50),height=fixed(20)}})
    instance:Tree_Instance
    testing.expect(t,tree_instance_init(&instance,&gated,&s.host.host))
    defer tree_instance_destroy(&instance)
    Gated :: struct {tree:^Widget_Tree,instance:^Tree_Instance,host:^Bind_Host}
    g:=Gated{&gated,&instance,&s.host.host}
    build :: proc(ctx:^Context,user:rawptr) {
        g:=(^Gated)(user)
        test_tree_build(ctx,g.tree,g.instance,g.host,{})
    }
    s.values.muted=true
    test_frame(&ctx,&input,build,&g)
    go,_:=tree_node_state(&gated,&instance,1)
    never,_:=tree_node_state(&gated,&instance,2)
    testing.expect(t,go.shown && go.disabled && never.disabled)
    s.values.muted=false
    test_frame(&ctx,&input,build,&g)
    go,_=tree_node_state(&gated,&instance,1)
    testing.expect(t,!go.disabled)
}

// The events of a kind the last build of the HUD reported: the last one and how many.
test_hud_events :: proc(s:^Test_Hud_Tree,kind:Tree_Event_Kind) -> (found:Tree_Event,count:int) {
    for event in s.events[:s.event_count] {if event.kind==kind {found=event;count+=1}}
    return
}

@(test)
nodes_report_events_and_write_their_bound_fields :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    ctx.theme.activate_on_press=false
    s:Test_Hud_Tree
    test_hud_init(t,&s)
    defer test_hud_destroy(&s)
    s.values.paused=true
    input:=test_input()
    test_frame(&ctx,&input,test_hud_build,&s)
    resume:=test_rect(t,&ctx,tree_element_id(&ctx,"resume"))
    test_point(&input,resume)
    test_frame(&ctx,&input,test_hud_build,&s)
    test_frame(&ctx,&input,test_hud_build,&s)
    testing.expect_value(t,test_paint(&ctx,"Resume").style.color,Color{255,255,255,255})
    hovered:^Paint
    for &p in ctx.paints[:ctx.paint_count] {if p.kind==.Box && p.fill==(Color{90,90,90,255}) {hovered=&p}}
    testing.expect(t,hovered!=nil && hovered.corners==4,"The button shows the fill of its state")
    test_press(&input)
    test_frame(&ctx,&input,test_hud_build,&s)
    pressed,presses:=test_hud_events(&s,.Pressed)
    _,clicks:=test_hud_events(&s,.Clicked)
    testing.expect(t,presses==1 && pressed.name==base.name_hash("resume") && clicks==0,"The press reports Pressed and clicks when it is let go")
    test_release(&input)
    test_frame(&ctx,&input,test_hud_build,&s)
    clicked,count:=test_hud_events(&s,.Clicked)
    testing.expect_value(t,count,1)
    clicked.rect={}
    testing.expect_value(t,clicked,Tree_Event{name=base.name_hash("resume"),node=5,kind=.Clicked,item=-1})
    _,count=test_hud_events(&s,.Released)
    testing.expect_value(t,count,1)
    // The checkbox edits the field it is bound to.
    mute:=test_rect(t,&ctx,tree_element_id(&ctx,"mute"))
    test_point(&input,mute)
    test_frame(&ctx,&input,test_hud_build,&s)
    test_press(&input);test_release(&input)
    test_frame(&ctx,&input,test_hud_build,&s)
    // It writes its copy, and the game what the event asks.
    muted :: proc(s:^Test_Hud_Tree) -> bool {return bound_number(raw_data(s.instance.values),s.instance.bounds[6].value)!=0}
    testing.expect(t,muted(&s))
    change,changes:=test_hud_events(&s,.Changed)
    testing.expect_value(t,changes,1)
    testing.expect_value(t,change.rect,mute)
    change.rect={}
    testing.expect_value(t,change,Tree_Event{name=base.name_hash("mute"),node=6,kind=.Changed,on=true,item=-1,value=1})
    s.values.muted=change.on
    test_press(&input);test_release(&input)
    test_frame(&ctx,&input,test_hud_build,&s)
    change,changes=test_hud_events(&s,.Changed)
    testing.expect(t,!muted(&s) && changes==1 && !change.on)
    s.values.muted=false
    // Events that do not fit are lost, not written past the end.
    test_press(&input);test_release(&input)
    frame_begin(&ctx,input)
    count=test_tree_build(&ctx,&s.tree,&s.instance,&s.host.host,{}).count
    frame_end(&ctx)
    testing.expect(t,count==0 && muted(&s))
}

@(test)
a_tree_refuses_nodes_out_of_order_and_beyond_its_capacity :: proc(t:^testing.T) {
    tree:Widget_Tree
    testing.expect(t,tree_init(&tree,{max_nodes=6,max_styles=1,max_images=1,max_anim_sets=1,max_strings=8}))
    defer tree_destroy(&tree)
    root:=tree_node(&tree,-1,{kind=.Box})
    first:=tree_node(&tree,root,{kind=.Box,text="abcd"})
    leaf:=tree_node(&tree,first,{kind=.Text,text="efgh"})
    testing.expect(t,root==0 && first==1 && leaf==2)
    testing.expect_value(t,tree_node(&tree,leaf,{kind=.Text}),i32(-1))
    testing.expect_value(t,tree_node(&tree,7,{kind=.Text}),i32(-1))
    testing.expect_value(t,tree_node(&tree,root,{kind=.Text,text="x"}),i32(-1))
    second:=tree_node(&tree,root,{kind=.Box})
    testing.expect_value(t,second,i32(3))
    // The first container is closed now: nothing more goes inside it.
    testing.expect_value(t,tree_node(&tree,first,{kind=.Text}),i32(-1))
    testing.expect_value(t,tree_node(&tree,second,{kind=.Text}),i32(4))
    testing.expect_value(t,tree_node(&tree,-1,{kind=.Box}),i32(5))
    testing.expect_value(t,tree_node(&tree,5,{kind=.Text}),i32(-1))
    testing.expect_value(t,tree.nodes[root].subtree,i32(4))
    testing.expect_value(t,tree.nodes[second].subtree,i32(1))
    testing.expect_value(t,tree.node_count,6)
    _,ok:=tree_style(&tree,{})
    testing.expect(t,ok)
    _,ok=tree_style(&tree,{})
    testing.expect(t,!ok)
    reference:u16
    reference,ok=tree_image(&tree,{quad={.Image,1,{0,0,1,1}}})
    testing.expect(t,ok && reference==1)
    _,ok=tree_image(&tree,{})
    testing.expect(t,!ok)
    _,ok=tree_anim_set(&tree,{})
    testing.expect(t,ok)
    _,ok=tree_anim_set(&tree,{})
    testing.expect(t,!ok)
}

@(test)
bindings_must_name_fields_the_value_has :: proc(t:^testing.T) {
    schema:serial.Schema
    serial.schema_init(&schema)
    defer serial.schema_destroy(&schema)
    type,_:=serial.schema_add(&schema,Test_Hud)
    values:Test_Hud
    host:Test_Host
    cases:=[?]Node_Desc{
        {kind=.Text,bind_text="Test.missing"},
        {kind=.Text,bind_text="Other.name"},
        {kind=.Text,bind_text="name"},
        {kind=.Box,bind_visible="Test.name"},
        {kind=.Progress,bind_value="Test.name"},
    }
    for desc in cases {
        tree:Widget_Tree
        testing.expect(t,tree_init(&tree,{max_nodes=4}))
        tree_node(&tree,-1,desc)
        instance:Tree_Instance
        testing.expect(t,!tree_instance_init(&instance,&tree,test_host(&host,&schema,type,&values)))
        testing.expect(t,instance.bounds==nil && instance.states==nil && instance.failure.node==0)
        tree_destroy(&tree)
    }
    // Numbers of every size are read; a tree without bindings needs no schema.
    tree:Widget_Tree
    testing.expect(t,tree_init(&tree,{max_nodes=4}))
    defer tree_destroy(&tree)
    tree_node(&tree,-1,{kind=.Text,name="lives",bind_text="Test.lives",bind_visible="Test.score"})
    instance:Tree_Instance
    testing.expect(t,tree_instance_init(&instance,&tree,test_host(&host,&schema,type,&values)))
    defer tree_instance_destroy(&instance)
    values=Test_Hud{lives=3,score=1}
    tree_values_refresh(&instance,&host.host,0)
    testing.expect_value(t,bound_number(raw_data(instance.values),instance.bounds[0].text),3.0)
    testing.expect_value(t,bound_number(raw_data(instance.values),instance.bounds[0].visible),1.0)
    // Only what the tree reads is copied: the lives and the score.
    testing.expect(t,len(instance.values)<size_of(Test_Hud))
    plain:Widget_Tree
    testing.expect(t,tree_init(&plain,{max_nodes=4}))
    defer tree_destroy(&plain)
    tree_node(&plain,-1,{kind=.Text,text="Static"})
    loose:Tree_Instance
    testing.expect(t,tree_instance_init(&loose,&plain,nil))
    tree_instance_destroy(&loose)
}

@(test)
a_tree_copied_byte_by_byte_builds_the_same_frame :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:Test_Hud_Tree
    test_hud_init(t,&s,true)
    defer test_hud_destroy(&s)
    s.values.paused=true
    input:=test_input()
    first:=test_frame(&ctx,&input,test_hud_build,&s)
    vertices:=make([]Vertex,len(first.vertices))
    defer delete(vertices)
    copy(vertices,first.vertices)
    // As an asset would bring it: the arrays of the tree in other memory.
    copied:Test_Hud_Tree
    copied.schema,copied.type=s.schema,s.type
    testing.expect(t,tree_init(&copied.tree))
    defer tree_destroy(&copied.tree)
    source,target:=&s.tree,&copied.tree
    mem.copy(raw_data(target.nodes),raw_data(source.nodes),source.node_count*size_of(Node));target.node_count=source.node_count
    mem.copy(raw_data(target.styles),raw_data(source.styles),source.style_count*size_of(Node_Style));target.style_count=source.style_count
    mem.copy(raw_data(target.anim_sets),raw_data(source.anim_sets),source.anim_set_count*size_of(Anim_Set));target.anim_set_count=source.anim_set_count
    mem.copy(raw_data(target.strings),raw_data(source.strings),source.string_length);target.string_length=source.string_length
    a,b:=&source.anims,&target.anims
    mem.copy(raw_data(b.keys),raw_data(a.keys),a.key_count*size_of(Keyframe));b.key_count=a.key_count
    mem.copy(raw_data(b.tracks),raw_data(a.tracks),a.track_count*size_of(Anim_Track));b.track_count=a.track_count
    mem.copy(raw_data(b.nodes),raw_data(a.nodes),a.node_count*size_of(Anim_Node));b.node_count=a.node_count
    copied.values=s.values
    testing.expect(t,tree_instance_init(&copied.instance,&copied.tree,test_host(&copied.host,&copied.schema,copied.type,&copied.values)))
    defer tree_instance_destroy(&copied.instance)
    other:Context
    testing.expect(t,context_init(&other,TEST_SMALL))
    defer context_destroy(&other)
    second:=test_frame(&other,&input,test_hud_build,&copied)
    testing.expect_value(t,len(second.vertices),len(vertices))
    same:=len(second.vertices)==len(vertices)
    if same {for v,i in second.vertices {if v!=vertices[i] {same=false}}}
    testing.expect(t,same)
}

@(test)
nodes_play_the_animations_of_their_set :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:Test_Hud_Tree
    test_hud_init(t,&s,true)
    defer test_hud_destroy(&s)
    input:=test_input()
    input.dt=0.25
    alpha :: proc(ctx:^Context,frame:Frame,s:^Test_Hud_Tree) -> f32 {
        // The fill of the button, the first dark shape inside the menu; its
        // quad reaches one pixel past it for antialiasing.
        resume,found:=widget_rect(ctx,tree_element_id(ctx,"resume"))
        if !found {return -1}
        for v in frame.vertices {
            color:=test_color(frame,v)
            if test_near(v.position.y,resume.y+resume.h*0.5,resume.h*0.5+1) && test_near(v.position.x,resume.x+resume.w*0.5,resume.w*0.5+1) && color.r<0.3 {return color.a}
        }
        return -1
    }
    frame:=test_frame(&ctx,&input,test_hud_build,&s)
    testing.expect_value(t,alpha(&ctx,frame,&s),f32(-1))
    s.values.paused=true
    frame=test_frame(&ctx,&input,test_hud_build,&s)
    testing.expect(t,test_near(alpha(&ctx,frame,&s),0.5),"The menu fades in")
    frame=test_frame(&ctx,&input,test_hud_build,&s)
    testing.expect_value(t,alpha(&ctx,frame,&s),f32(1))
    // Hidden, it is built until its animation ends.
    s.values.paused=false
    frame=test_frame(&ctx,&input,test_hud_build,&s)
    testing.expect(t,test_near(alpha(&ctx,frame,&s),0.5))
    frame=test_frame(&ctx,&input,test_hud_build,&s)
    testing.expect_value(t,alpha(&ctx,frame,&s),f32(-1))
    testing.expect(t,test_paint(&ctx,"Resume")==nil)
}

@(test)
the_same_tree_builds_twice_under_different_scopes :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    s:Test_Hud_Tree
    test_hud_init(t,&s)
    defer test_hud_destroy(&s)
    input:=test_input()
    test_frame(&ctx,&input,proc(ctx:^Context,user:rawptr) {
        s:=cast(^Test_Hud_Tree)user
        for scope in 1..=2 {
            id_push(ctx,id(ctx,"player",scope))
            test_tree_build(ctx,&s.tree,&s.instance,&s.host.host,{})
            id_pop(ctx)
        }
    },&s)
    testing.expect_value(t,ctx.stats.layout_errors,u32(0))
    id_push(&ctx,id(&ctx,"player",2))
    second:=test_rect(t,&ctx,tree_element_id(&ctx,"title"))
    id_pop(&ctx)
    testing.expect(t,test_rect_near(second,{310,10,200,20}))
}
