package ui

import "core:math"
import "core:mem"
import "core:testing"
import std_anim "mirai:std/anim"

// The HUD of test_hud_fill with its animated menu, as records.
Test_Hud_Records :: struct {
    nodes:[9]Tree_Node,
    styles:[5]Node_Style,
    images:[1]Tree_Image,
    anims:[2]Tree_Anim,
    tracks:[2]Tree_Track,
    keys:[4]std_anim.Keyframe,
    anim_sets:[1]Anim_Set,
    variants:[2]Tree_Style_Variant,
    text:[dynamic]u8,
}
test_hud_records :: proc(r:^Test_Hud_Records) -> Tree_Data {
    r.text=make([dynamic]u8,context.temp_allocator)
    white:=Color{255,255,255,255}
    r.styles={
        {text={size=16,color=white}},
        {fill={200,40,40,255},track={30,30,30,255},radius=3},
        {text={size=12,color={200,200,200,255}}},
        {fill={0,0,0,160},radius=4},
        {text={size=14,color=white},fill={60,60,60,255},radius=4},
    }
    r.variants={{style=4,states={.Hovered},patch={fields={.Fill},values={fill={90,90,90,255}}}},{style=4,states={.Pressed},patch={fields={.Fill},values={fill={30,30,30,255}}}}}
    r.keys={{time=0,value={0,0,0,0}},{time=0.5,value={1,0,0,0},ease=.Linear},{time=0,value={1,0,0,0}},{time=0.5,value={0,0,0,0},ease=.Linear}}
    r.tracks={{.Opacity,0,2},{.Opacity,2,2}}
    r.anims={{kind=.Clip,first=0,count=1},{kind=.Clip,first=1,count=1}}
    r.anim_sets={{shown=1,hidden=2}}
    r.images={{texture={1,2},border={4,4,4,4},border_uv={0.25,0.25,0.25,0.25}}}
    r.nodes={
        tree_node_record(&r.text,-1,{kind=.Box,name="hud",layout={width=fixed(300),height=fixed(200),direction=.Column,padding=padding_all(10),gap=6},style=3}),
        tree_node_record(&r.text,0,{kind=.Text,name="title",text="Player",style=0,bind_text="Test.name",layout={width=fixed(200),height=fixed(20)}}),
        tree_node_record(&r.text,0,{kind=.Progress,name="health",style=1,bind_value="Test.health",layout={width=fixed(200),height=fixed(12)}}),
        tree_node_record(&r.text,0,{kind=.Text,name="score",style=2,bind_text="Test.score",layout={width=fixed(100),height=fixed(16)}}),
        tree_node_record(&r.text,0,{kind=.Box,name="menu",layout={gap=8,align_y=.Center},bind_visible="Test.paused",anims=1}),
        tree_node_record(&r.text,4,{kind=.Button,name="resume",text="Resume",style=4,layout={width=fixed(90),height=fixed(30)}}),
        tree_node_record(&r.text,4,{kind=.Checkbox,name="mute",bind_value="Test.muted"}),
        tree_node_record(&r.text,4,{kind=.Text,text="Mute",style=2}),
        tree_node_record(&r.text,0,{kind=.Spacer,layout={width=GROW,height=GROW}}),
    }
    return {nodes=r.nodes[:],styles=r.styles[:],variants=r.variants[:],images=r.images[:],anims=r.anims[:],tracks=r.tracks[:],keys=r.keys[:],anim_sets=r.anim_sets[:],text=r.text[:]}
}

@(test)
a_tree_loaded_from_records_is_laid_out_and_drawn_like_the_one_built_in_code :: proc(t:^testing.T) {
    coded:Test_Hud_Tree
    test_hud_init(t,&coded,true)
    defer test_hud_destroy(&coded)

    records:Test_Hud_Records
    loaded:=Test_Hud_Tree{schema=coded.schema,type=coded.type,values=coded.values}
    testing.expect(t,tree_load(&loaded.tree,test_hud_records(&records),{textures={7}}))
    defer tree_destroy(&loaded.tree)
    testing.expect(t,tree_instance_init(&loaded.instance,&loaded.tree,test_host(&loaded.host,&loaded.schema,loaded.type,&loaded.values)))
    defer tree_instance_destroy(&loaded.instance)
    testing.expect_value(t,loaded.tree.node_count,coded.tree.node_count)
    testing.expect(t,mem.compare(mem.slice_to_bytes(loaded.tree.nodes[:9]),mem.slice_to_bytes(coded.tree.nodes[:9]))==0,"The nodes are the ones tree_node writes")
    testing.expect_value(t,string(loaded.tree.strings[:loaded.tree.string_length]),"PlayerTest.nameTest.healthTest.scoreTest.pausedResumeTest.mutedMute")
    testing.expect_value(t,loaded.tree.images[0].quad,Quad{.Image,7,{0,0,1,1}})
    tree_textures_set(&loaded.tree,{9})
    testing.expect_value(t,loaded.tree.images[0].quad.data,u32(9))

    a,b:Context
    testing.expect(t,context_init(&a,TEST_SMALL) && context_init(&b,TEST_SMALL))
    defer {context_destroy(&a);context_destroy(&b)}
    input:=test_input()
    // The menu appears and fades in: the animation of both runs alike.
    for frame in 0..<4 {
        coded.values.paused,loaded.values.paused=frame>0,frame>0
        fa:=test_frame(&a,&input,test_hud_build,&coded)
        fb:=test_frame(&b,&input,test_hud_build,&loaded)
        testing.expect(t,len(fa.vertices)>0 && len(fa.vertices)==len(fb.vertices))
        testing.expect(t,mem.compare(mem.slice_to_bytes(fa.vertices),mem.slice_to_bytes(fb.vertices))==0,"Both trees draw the same vertices")
        testing.expect(t,mem.compare(mem.slice_to_bytes(fa.commands),mem.slice_to_bytes(fb.commands))==0)
    }
    names:=[?]string{"title","health","score","menu","resume","mute"}
    for name in names {
        testing.expect(t,test_rect_near(test_rect(t,&a,tree_element_id(&a,name)),test_rect(t,&b,tree_element_id(&b,name))),name)
    }
    testing.expect(t,test_rect_near(test_rect(t,&b,tree_element_id(&b,"resume")),{10,76,90,30}))
    testing.expect(t,loaded.instance.states[4].time>0,"The menu of the loaded tree plays its animation")
}

@(test)
records_that_contradict_themselves_load_no_tree :: proc(t:^testing.T) {
    r:Test_Hud_Records
    tree:Widget_Tree
    refused :: proc(t:^testing.T,tree:^Widget_Tree,data:Tree_Data,what:string,textures:[]u32={7}) {
        testing.expect(t,!tree_load(tree,data,{textures=textures}),what)
        testing.expect(t,tree.nodes==nil && tree.anims.keys==nil,what)
    }
    data:=test_hud_records(&r)
    refused(t,&tree,data,"one texture per image",{})

    r.nodes[5].parent=3
    refused(t,&tree,data,"a parent that is not a box")
    r.nodes[5].parent=7
    refused(t,&tree,data,"a parent that comes later")
    data=test_hud_records(&r)
    r.nodes[2].style=5
    refused(t,&tree,data,"a style outside the table")
    data=test_hud_records(&r)
    r.nodes[2].image=2
    refused(t,&tree,data,"an image outside the table")
    data=test_hud_records(&r)
    r.nodes[4].anims=2
    refused(t,&tree,data,"an animation set outside the table")
    data=test_hud_records(&r)
    r.nodes[1].text.length=1<<20
    refused(t,&tree,data,"a text outside the texts")
    data=test_hud_records(&r)
    r.nodes[0].layout.gap=math.INF_F32
    refused(t,&tree,data,"a size that is not a number")
    data=test_hud_records(&r)
    r.tracks[1].key_count=3
    refused(t,&tree,data,"keys outside the table")
    data=test_hud_records(&r)
    r.keys[1].time=-1
    refused(t,&tree,data,"keys out of order")
    data=test_hud_records(&r)
    r.anims[0].count=3
    refused(t,&tree,data,"tracks outside the table")
    data=test_hud_records(&r)
    r.anim_sets[0].clicked=3
    refused(t,&tree,data,"an animation outside the table")
    // A group plays only animations of earlier rows: no cycles.
    data=test_hud_records(&r)
    parts:=[2]Anim{1,2}
    r.anims[1]={kind=.Sequence,first=0,count=2}
    data.parts=parts[:]
    refused(t,&tree,data,"a group that plays itself")
    parts={1,1}
    testing.expect(t,tree_load(&tree,data,{textures={7}}))
    testing.expect_value(t,anim_duration(&tree.anims,2),f32(1))
    tree_destroy(&tree)

    testing.expect(t,tree_load(&tree,{},{}),"No records: an empty tree")
    testing.expect_value(t,tree.node_count,0)
    tree_destroy(&tree)
}

@(test)
an_enum_without_a_name_loads_no_tree :: proc(t:^testing.T) {
    r:Test_Hud_Records
    tree:Widget_Tree
    data:=test_hud_records(&r)
    Case :: struct {field:^u8,what:string}
    node:=&r.nodes[0]
    cases:=[]Case{
        {cast(^u8)&node.kind,"kind"},{cast(^u8)&node.float.to,"float.to"},{cast(^u8)&node.float.anchor,"float.anchor"},{cast(^u8)&node.float.pivot,"float.pivot"},
        {cast(^u8)&node.layout.width.kind,"width.kind"},{cast(^u8)&node.layout.height.kind,"height.kind"},{cast(^u8)&node.layout.direction,"direction"},
        {cast(^u8)&node.layout.align_x,"align_x"},{cast(^u8)&node.layout.align_y,"align_y"},
        {cast(^u8)&r.styles[0].text.align_x,"text.align_x"},{cast(^u8)&r.styles[0].text.align_y,"text.align_y"},{cast(^u8)&r.styles[0].text.wrap,"text.wrap"},
        {cast(^u8)&r.anims[0].kind,"anim kind"},{cast(^u8)&r.anims[0].loop,"anim loop"},{cast(^u8)&r.tracks[0].property,"track property"},{cast(^u8)&r.keys[1].ease,"key ease"},{cast(^u8)&r.keys[1].interpolation,"key interpolation"},
    }
    for entry in cases {
        kept:=entry.field^
        entry.field^=200
        testing.expect(t,!tree_load(&tree,data,{textures={7}}),entry.what)
        testing.expect(t,tree.nodes==nil && tree.anims.keys==nil,entry.what)
        entry.field^=kept
    }
    testing.expect(t,tree_load(&tree,data,{textures={7}}),"The records load once every enum is one of its values")
    tree_destroy(&tree)
    // The last value of each enum is one of them.
    node.float={to=.Parent,anchor=.Bottom_Right,pivot=.Bottom_Right}
    r.keys[1].ease=.Bounce_In_Out;r.keys[1].interpolation=.Cubic_Spline
    testing.expect(t,tree_load(&tree,data,{textures={7}}))
    tree_destroy(&tree)
}

@(test)
the_layers_of_a_tree_count_from_the_layer_it_is_built_in :: proc(t:^testing.T) {
    texts:=make([dynamic]u8,context.temp_allocator)
    nodes:=[2]Tree_Node{
        tree_node_record(&texts,-1,{kind=.Box,name="plate",layout={width=fixed(100),height=fixed(100)},float={to=.Safe,layer=2}}),
        tree_node_record(&texts,-1,{kind=.Box,name="under",layout={width=fixed(50),height=fixed(50)},float={to=.Surface,layer=-3},style=1}),
    }
    styles:=[2]Node_Style{{fill={0,200,0,255}},{fill={0,0,200,255}}}
    Scene :: struct {tree:Widget_Tree,instance:Tree_Instance,layer:i16}
    scene:Scene
    testing.expect(t,tree_load(&scene.tree,{text=texts[:],nodes=nodes[:],styles=styles[:]},{}))
    defer tree_destroy(&scene.tree)
    low,high:=tree_layers(&scene.tree)
    testing.expect(t,low==-3 && high==2)
    testing.expect(t,tree_instance_init(&scene.instance,&scene.tree,nil))
    defer tree_instance_destroy(&scene.instance)

    // A red plate of layer 4 beside the tree, built inside a surface of the layer asked.
    build :: proc(ctx:^Context,user:rawptr) {
        s:=cast(^Scene)user
        if box(ctx,{id=id(ctx,"host"),width=fixed(200),height=fixed(200),float={to=.Surface,layer=s.layer}}) {
            tree_build(ctx,&s.tree,&s.instance,{})
        }
        if box(ctx,{id=id(ctx,"rival"),width=fixed(200),height=fixed(200),float={to=.Surface,layer=4},fill={200,0,0,255}}) {}
    }
    first :: proc(frame:Frame,channel:int) -> int {
        for vertex,i in frame.vertices {
            color:=test_color(frame,vertex)
            if color[channel]>0.5 && color[(channel+1)%3]<0.01 && color[(channel+2)%3]<0.01 {return i}
        }
        return -1
    }
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    input:=test_input()
    frame:=test_frame(&ctx,&input,build,&scene)
    red,green,blue:=first(frame,0),first(frame,1),first(frame,2)
    testing.expect(t,blue>=0 && blue<green && green<red,"Layers -3, 2 and 4")
    scene.layer=5
    frame=test_frame(&ctx,&input,build,&scene)
    red,green,blue=first(frame,0),first(frame,1),first(frame,2)
    testing.expect(t,blue>=0 && blue<red && red<green,"Layers 2, 4 and 7")
    testing.expect_value(t,ctx.stats.layout_errors,u32(0))
    // At the end of the range a layer stays inside it.
    scene.layer=max(i16)
    frame=test_frame(&ctx,&input,build,&scene)
    testing.expect(t,first(frame,0)<first(frame,1) && first(frame,2)>first(frame,0))
}

@(test)
a_tree_deeper_than_its_builder_opens_is_not_loaded :: proc(t:^testing.T) {
    texts:=make([dynamic]u8,context.temp_allocator)
    nodes:[TREE_DEPTH+1]Tree_Node
    for &node,i in nodes {node=tree_node_record(&texts,i32(i)-1,{kind=.Box,layout={width=fit(),height=fit()}})}
    styles:=[1]Node_Style{}
    tree:Widget_Tree
    testing.expect(t,!tree_load(&tree,{text=texts[:],nodes=nodes[:],styles=styles[:]},{}))
    testing.expect(t,tree.nodes==nil)
    testing.expect(t,tree_load(&tree,{text=texts[:],nodes=nodes[:TREE_DEPTH],styles=styles[:]},{}))
    tree_destroy(&tree)
}

// What a tree may nest is more than the stacks of a frame hold: it loads, and
// its frame is drawn without what did not fit.
@(test)
a_tree_that_nests_more_than_a_frame_holds_is_drawn_and_counted :: proc(t:^testing.T) {
    Case :: struct {name:string,node:Node_Desc,floating:bool,dropped:proc(s:^Stats) -> u32}
    nesting :: proc(s:^Stats) -> u32 {return s.dropped_nesting}
    clips :: proc(s:^Stats) -> u32 {return s.dropped_clips}
    cases:=[]Case{
        {"floats",{float={to=.Parent,offset={2,2}}},false,nesting},
        {"layers in a float",{layer={enabled=true,opacity=1}},true,nesting},
        {"clips",{clip=true},false,clips},
    }
    Scene :: struct {tree:Widget_Tree,instance:Tree_Instance,floating:bool}
    build :: proc(ctx:^Context,user:rawptr) {
        s:=cast(^Scene)user
        if s.floating {box_begin(ctx,{float={to=.Surface}})}
        tree_build(ctx,&s.tree,&s.instance,{})
        if s.floating {box_end(ctx,{float={to=.Surface}})}
    }
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    input:=test_input()
    for c in cases {
        texts:=make([dynamic]u8,context.temp_allocator)
        nodes:[TREE_DEPTH]Tree_Node
        for &node,i in nodes {
            desc:=c.node
            desc.kind=.Box
            desc.layout={width=fixed(f32(200-i)),height=fixed(f32(200-i))}
            node=tree_node_record(&texts,i32(i)-1,desc)
        }
        scene:=Scene{floating=c.floating}
        testing.expectf(t,tree_load(&scene.tree,{text=texts[:],nodes=nodes[:],styles={{fill={255,255,255,255}}}},{}),"%s: the tree loads",c.name)
        testing.expect(t,tree_instance_init(&scene.instance,&scene.tree,nil))
        dropped:=c.dropped(&ctx.stats)
        frame:=test_frame(&ctx,&input,build,&scene)
        testing.expectf(t,frame.overflow && c.dropped(&ctx.stats)>dropped,"%s: what did not fit is counted",c.name)
        testing.expectf(t,len(frame.vertices)>0,"%s: the frame is drawn",c.name)
        _,found:=layout_find(&ctx.layout,tree_node_id(&ctx,&scene.tree.nodes[TREE_DEPTH-1],TREE_DEPTH-1))
        testing.expectf(t,found,"%s: the deepest node is laid out",c.name)
        tree_instance_destroy(&scene.instance)
        tree_destroy(&scene.tree)
        frame=test_frame(&ctx,&input,proc(ctx:^Context,user:rawptr) {label(ctx,"fits")})
        testing.expectf(t,!frame.overflow,"%s: the next frame carries nothing of it",c.name)
    }
    testing.expect_value(t,ctx.stats.layout_errors,u32(0))
}

@(test)
the_programs_of_a_tree_follow_its_styles :: proc(t:^testing.T) {
    records:Test_Hud_Records
    data:=test_hud_records(&records)
    tree:Widget_Tree
    testing.expect(t,!tree_load(&tree,data,{textures={7},programs={1,2}}),"a program for each style or none")
    testing.expect(t,tree_load(&tree,data,{textures={7},programs={0,5,0,6,0}}))
    defer tree_destroy(&tree)
    got:[5]u32
    copy(got[:],tree.programs[:tree.style_count])
    testing.expect_value(t,got,[5]u32{0,5,0,6,0})
    tree_programs_set(&tree,{0,0,0,8,0,99})
    copy(got[:],tree.programs[:tree.style_count])
    testing.expect_value(t,got,[5]u32{0,0,0,8,0})
}

// A node that holds none floats too: a Button over the corner of its card,
// not in the flow under the card's text; it takes the pointer there, and its
// events say where it is.
@(test)
a_leaf_floats_from_its_parent_and_its_events_say_where :: proc(t:^testing.T) {
    texts:=make([dynamic]u8,context.temp_allocator)
    nodes:=[3]Tree_Node{
        tree_node_record(&texts,-1,{kind=.Box,name="card",layout={width=fixed(100),height=fixed(100),padding=padding_all(10),direction=.Column},float={to=.Surface,offset={50,50}}}),
        tree_node_record(&texts,0,{kind=.Text,name="label",text="Wood",layout={height=fixed(60)}}),
        tree_node_record(&texts,0,{kind=.Button,name="pick",layout={width=fixed(100),height=fixed(100)},float={to=.Parent,layer=1}}),
    }
    Scene :: struct {tree:Widget_Tree,instance:Tree_Instance,events:[8]Tree_Event,count:int,at:Rect}
    scene:Scene
    testing.expect(t,tree_load(&scene.tree,{text=texts[:],nodes=nodes[:],styles={{}}},{}))
    defer tree_destroy(&scene.tree)
    low,high:=tree_layers(&scene.tree)
    testing.expect(t,low==0 && high==1,"the layer of a floating leaf counts")
    testing.expect(t,tree_instance_init(&scene.instance,&scene.tree,nil))
    defer tree_instance_destroy(&scene.instance)
    build :: proc(ctx:^Context,user:rawptr) {
        s:=cast(^Scene)user
        result:=tree_build(ctx,&s.tree,&s.instance,{events=s.events[:]})
        for e in s.events[:result.count] {if e.kind==.Clicked {s.count+=1;s.at=e.rect}}
    }
    ctx:Context
    testing.expect(t,context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    input:=test_input()
    test_frame(&ctx,&input,build,&scene)
    pick:=test_rect(t,&ctx,tree_node_id(&ctx,&scene.tree.nodes[2],2))
    testing.expect(t,test_near(pick.x,50) && test_near(pick.y,50),"it hangs from the corner of the card, not under its text")
    input.pointer={60,60}
    test_frame(&ctx,&input,build,&scene)
    test_press(&input)
    test_frame(&ctx,&input,build,&scene)
    test_release(&input)
    test_frame(&ctx,&input,build,&scene)
    testing.expect_value(t,scene.count,1)
    testing.expect_value(t,scene.at,pick)
}
