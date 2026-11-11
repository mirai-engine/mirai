package ui

import "core:strings"
import "core:testing"
import "mirai:std/base"
import "mirai:std/serial"

Test_Weapon :: enum i32 {Sword,Bow,Staff}
Test_Inventory :: struct {
    names:[4][12]u8,
    weapons:[3]Test_Weapon,
    chosen,picked:i32,
    coins:i32,
    gold:f32,
    amount:f32,
    alive:bool,
    weapon:Test_Weapon,
    note:[32]u8 `mirai:"text"`,
}

// A tree built from code over a Test_Inventory.
Test_Shop :: struct {
    schema:serial.Schema,
    type:serial.Type_Index,
    host:Test_Host,
    tree:Widget_Tree,
    instance:Tree_Instance,
    values:Test_Inventory,
    events:[32]Tree_Event,
    result:Tree_Build_Result,
}
test_shop_init :: proc(t:^testing.T,s:^Test_Shop) {
    serial.schema_init(&s.schema)
    ok:bool
    s.type,ok=serial.schema_add(&s.schema,Test_Inventory)
    testing.expect(t,ok)
    testing.expect(t,tree_init(&s.tree))
}
test_shop_destroy :: proc(s:^Test_Shop) {
    tree_instance_destroy(&s.instance);tree_destroy(&s.tree);serial.schema_destroy(&s.schema)
}
test_shop_instance :: proc(s:^Test_Shop) -> bool {
    return tree_instance_init(&s.instance,&s.tree,test_host(&s.host,&s.schema,s.type,&s.values))
}
test_shop_build :: proc(ctx:^Context,user:rawptr) {
    s:=cast(^Test_Shop)user
    tree_values_refresh(&s.instance,&s.host.host,0)
    s.result=tree_build(ctx,&s.tree,&s.instance,{events=s.events[:],changed=true})
}
test_shop_events :: proc(s:^Test_Shop,kind:Tree_Event_Kind,name:string) -> (found:Tree_Event,count:int) {
    for event in s.events[:s.result.count] {
        if event.kind==kind && event.name==base.name_hash(name) {found=event;count+=1}
    }
    return
}
test_shop_context :: proc(t:^testing.T,ctx:^Context,font:=false) {
    desc:=TEST_FONT if font else TEST_SMALL
    desc.navigation=true
    testing.expect(t,test_context_init(ctx,desc))
    ctx.release_activates=true
}

@(test)
options_come_from_an_array_of_texts_or_of_enums :: proc(t:^testing.T) {
    s:Test_Shop
    test_shop_init(t,&s)
    defer test_shop_destroy(&s)
    style,_:=tree_style(&s.tree,{text={size=12,color={255,255,255,255}}})
    root:=tree_node(&s.tree,-1,{kind=.Box,name="shop",layout={direction=.Column,gap=4}})
    tree_node(&s.tree,root,{kind=.Selector,name="food",style=style,bind_items="Test.names",bind_value="Test.chosen"})
    tree_node(&s.tree,root,{kind=.Dropdown,name="weapon",style=style,text="Sword=Espada|Bow=Arco",bind_items="Test.weapons",bind_value="Test.picked"})
    testing.expect(t,test_shop_instance(&s))
    copy(s.values.names[0][:],"Bread");copy(s.values.names[1][:],"Milk")
    s.values.weapons={.Bow,.Sword,.Staff}
    ctx:Context
    test_shop_context(t,&ctx)
    defer context_destroy(&ctx)
    input:=test_input()
    test_frame(&ctx,&input,test_shop_build,&s)
    testing.expect(t,test_paint(&ctx,"Bread")!=nil,"A selector shows the text of the array its items bind")
    testing.expect(t,test_paint(&ctx,"Arco")!=nil,"An enum shows what the text of the node maps its name to")
    // The empty texts at the end of the array are no options: Right wraps after two.
    ctx.focus,ctx.focus_ring=tree_element_id(&ctx,"food"),true
    test_key(&input,.Right)
    test_frame(&ctx,&input,test_shop_build,&s)
    event,count:=test_shop_events(&s,.Changed,"food")
    testing.expect(t,count==1 && event.value==1)
    s.values.chosen=1
    test_key(&input,.Right)
    test_frame(&ctx,&input,test_shop_build,&s)
    event,count=test_shop_events(&s,.Changed,"food")
    testing.expect(t,count==1 && event.value==0)
    // A value the map does not name shows by its name.
    s.values.picked=2
    test_frame(&ctx,&input,test_shop_build,&s)
    testing.expect(t,test_paint(&ctx,"Staff")!=nil)
    // The keys open a Dropdown on the chosen option, move its current row and
    // choose it, and the focus stays on the node.
    weapon:=tree_element_id(&ctx,"weapon")
    ctx.focus,ctx.focus_ring=weapon,true
    test_key(&input,.Enter)
    test_frame(&ctx,&input,test_shop_build,&s)
    test_frame(&ctx,&input,test_shop_build,&s)
    test_key(&input,.Up)
    test_frame(&ctx,&input,test_shop_build,&s)
    test_key(&input,.Enter)
    test_frame(&ctx,&input,test_shop_build,&s)
    event,count=test_shop_events(&s,.Changed,"weapon")
    testing.expect(t,count==1 && event.value==1 && ctx.focus==weapon)
    // Options bound to what is not an array of texts or of enums make no instance.
    other:Tree_Instance
    tree_node(&s.tree,root,{kind=.Selector,name="bad",bind_items="Test.coins"})
    testing.expect(t,!tree_instance_init(&other,&s.tree,&s.host.host))
    testing.expect(t,other.failure.node==3 && other.failure.binding==.Items)
}

@(test)
a_tab_shows_its_option_or_the_text_the_name_or_the_number_of_its_node :: proc(t:^testing.T) {
    s:Test_Shop
    test_shop_init(t,&s)
    defer test_shop_destroy(&s)
    style,_:=tree_style(&s.tree,{text={size=12,color={255,255,255,255}}})
    root:=tree_node(&s.tree,-1,{kind=.Box,name="shop",layout={direction=.Column,gap=4}})
    bound:=tree_node(&s.tree,root,{kind=.Tabs,name="bound",style=style,bind_items="Test.names"})
    for name in ([4]string{"bag","purse","journal",""}) {tree_node(&s.tree,bound,{kind=.Box,name=name,text="Notes" if name=="purse" else ""})}
    joined:=tree_node(&s.tree,root,{kind=.Tabs,name="joined",style=style,text="Swords|Bows"})
    for name in ([2]string{"swords","bows"}) {tree_node(&s.tree,joined,{kind=.Box,name=name})}
    testing.expect(t,test_shop_instance(&s))
    copy(s.values.names[0][:],"Bread");copy(s.values.names[1][:],"Milk")
    ctx:Context
    test_shop_context(t,&ctx)
    defer context_destroy(&ctx)
    input:=test_input()
    test_frame(&ctx,&input,test_shop_build,&s)
    testing.expect(t,test_paint(&ctx,"Bread")!=nil && test_paint(&ctx,"Milk")!=nil,"A tab shows the text of the array its Tabs binds")
    testing.expect(t,test_paint(&ctx,"Notes")==nil,"An option comes before the text of the node")
    testing.expect(t,test_paint(&ctx,"journal")!=nil,"Past the options, a node without text shows its name")
    testing.expect(t,test_paint(&ctx,"4")!=nil,"and one without a name, its number")
    testing.expect(t,test_paint(&ctx,"Swords")!=nil && test_paint(&ctx,"Bows")!=nil,"The text of a Tabs separated by | names its tabs")
    testing.expect(t,test_paint(&ctx,"swords")==nil)
}

@(test)
templates_format_numbers_bools_enums_and_plurals_as_the_language_does :: proc(t:^testing.T) {
    s:Test_Shop
    test_shop_init(t,&s)
    defer test_shop_destroy(&s)
    root:=tree_node(&s.tree,-1,{kind=.Box,name="hud",layout={direction=.Column}})
    node :: proc(s:^Test_Shop,root:i32,name,text,field,path:string) {
        tree_node(&s.tree,root,{kind=.Text,name=name,text=text,fields={{field,path},{},{},{}}})
    }
    node(&s,root,"gold","{gold:#,##0.00}","gold","Test.gold")
    node(&s,root,"coins","{coins:#,##0}","coins","Test.coins")
    node(&s,root,"alive","{alive:Yes|No} {alive}","alive","Test.alive")
    node(&s,root,"weapon","{weapon:Sword=Espada|Bow=Arco} {weapon}","weapon","Test.weapon")
    node(&s,root,"plural","{coins:one=# coin|few=# coins (few)|many=# coins (many)|other=# coins}","coins","Test.coins")
    node(&s,root,"percent","{amount:0.0%}","amount","Test.amount")
    testing.expect(t,test_shop_instance(&s))
    s.values={gold=12345.25,coins=1234,alive=true,weapon=.Bow,amount=0.256}
    ctx:Context
    test_shop_context(t,&ctx)
    defer context_destroy(&ctx)
    input:=test_input()
    shows :: proc(t:^testing.T,ctx:^Context,input:^Input,s:^Test_Shop,language:string,texts:..string) {
        ctx.game.language=base.name_hash(language) if language!="" else 0
        test_frame(ctx,input,test_shop_build,s)
        for text in texts {testing.expectf(t,test_paint(ctx,text)!=nil,"%s shows %q",language,text)}
    }
    shows(t,&ctx,&input,&s,"","12,345.25","1,234","Yes On","Arco Bow","1,234 coins","25.6%")
    shows(t,&ctx,&input,&s,"de","12.345,25","1.234")
    shows(t,&ctx,&input,&s,"es","12.345,25","1234","1234 coins")
    shows(t,&ctx,&input,&s,"fr","12\u00a0345,25")
    s.values={coins=1,alive=false,weapon=.Staff}
    shows(t,&ctx,&input,&s,"en","1 coin","No Off","Staff Staff")
    shows(t,&ctx,&input,&s,"fr","1 coin")
    s.values.coins=0
    shows(t,&ctx,&input,&s,"en","0 coins")
    shows(t,&ctx,&input,&s,"fr","0 coin")
    Russian :: struct {coins:i32,text:string}
    for c in ([?]Russian{{21,"21 coin"},{3,"3 coins (few)"},{11,"11 coins (many)"},{25,"25 coins (many)"}}) {
        s.values.coins=c.coins
        shows(t,&ctx,&input,&s,"ru",c.text)
    }
    s.values.coins=1000000
    shows(t,&ctx,&input,&s,"es","1.000.000 coins (many)")
    // A name the enum lacks, or a category no language has, makes no instance.
    for spec in ([]string{"{weapon:Axe=Hacha}","{coins:lots=#}"}) {
        bad:Test_Shop
        test_shop_init(t,&bad)
        tree_node(&bad.tree,-1,{kind=.Text,name="bad",text=spec,fields={{"weapon","Test.weapon"},{"coins","Test.coins"},{},{}}})
        testing.expectf(t,!test_shop_instance(&bad) && bad.instance.failure.template,"%s fails",spec)
        test_shop_destroy(&bad)
    }
}

@(test)
a_drop_takes_only_what_it_accepts_and_a_named_ghost_follows_the_pointer :: proc(t:^testing.T) {
    s:Test_Shop
    test_shop_init(t,&s)
    defer test_shop_destroy(&s)
    red:=Color{255,0,0,255}
    plain,_:=tree_style(&s.tree,{fill={40,40,40,255},text={size=12,color={255,255,255,255}}})
    tree_style_variant(&s.tree,{style=plain,states={.Over},patch={fields={.Fill},values={fill=red}}})
    root:=tree_node(&s.tree,-1,{kind=.Box,name="slots",layout={gap=40}})
    tree_node(&s.tree,root,{kind=.Box,name="apple",style=plain,flags={.Draggable},tag="fruit",ghost="carried",layout={width=fixed(30),height=fixed(30)}})
    tree_node(&s.tree,root,{kind=.Box,name="basket",style=plain,flags={.Drop},accepts="fruit",layout={width=fixed(30),height=fixed(30)}})
    tree_node(&s.tree,root,{kind=.Box,name="wall",style=plain,flags={.Drop},accepts="stone",layout={width=fixed(30),height=fixed(30)}})
    ghost:=tree_node(&s.tree,root,{kind=.Box,name="carried",flags={.Collapsed}})
    tree_node(&s.tree,ghost,{kind=.Text,text="Apple",style=plain})
    testing.expect(t,test_shop_instance(&s))
    ctx:Context
    test_shop_context(t,&ctx)
    defer context_destroy(&ctx)
    input:=test_input()
    test_frame(&ctx,&input,test_shop_build,&s)
    testing.expect(t,test_paint(&ctx,"Apple")==nil,"The ghost is a node the tree hides")
    apple:=test_rect(t,&ctx,tree_element_id(&ctx,"apple"))
    basket:=test_rect(t,&ctx,tree_element_id(&ctx,"basket"))
    wall:=test_rect(t,&ctx,tree_element_id(&ctx,"wall"))
    test_point(&input,apple)
    test_frame(&ctx,&input,test_shop_build,&s)
    test_press(&input)
    test_frame(&ctx,&input,test_shop_build,&s)
    input.pointer.x+=20
    test_frame(&ctx,&input,test_shop_build,&s)
    _,dragged:=test_shop_events(&s,.Dragged,"apple")
    testing.expect_value(t,dragged,1)
    test_frame(&ctx,&input,test_shop_build,&s)
    testing.expect(t,test_paint(&ctx,"Apple")!=nil,"The node the ghost names follows the pointer")
    // Over the basket: it enters, and the basket draws its Over look.
    test_point(&input,basket)
    test_frame(&ctx,&input,test_shop_build,&s)
    _,entered:=test_shop_events(&s,.Drag_Entered,"basket")
    testing.expect_value(t,entered,1)
    test_frame(&ctx,&input,test_shop_build,&s)
    over:=false
    for &p in ctx.paints[:ctx.paint_count] {if p.fill==red {over=true}}
    testing.expect(t,over,"A Drop with something it accepts over it is Over")
    // The wall takes only stones: nothing enters it and nothing is dropped there.
    test_point(&input,wall)
    test_frame(&ctx,&input,test_shop_build,&s)
    _,left:=test_shop_events(&s,.Drag_Left,"basket")
    _,entered=test_shop_events(&s,.Drag_Entered,"wall")
    testing.expect(t,left==1 && entered==0)
    test_release(&input)
    test_frame(&ctx,&input,test_shop_build,&s)
    _,dropped:=test_shop_events(&s,.Dropped,"wall")
    testing.expect_value(t,dropped,0)
    // Let go over the basket, it is dropped there.
    test_point(&input,apple)
    test_frame(&ctx,&input,test_shop_build,&s)
    test_press(&input)
    test_frame(&ctx,&input,test_shop_build,&s)
    input.pointer.x+=20
    test_frame(&ctx,&input,test_shop_build,&s)
    test_point(&input,basket)
    test_frame(&ctx,&input,test_shop_build,&s)
    test_release(&input)
    test_frame(&ctx,&input,test_shop_build,&s)
    event,count:=test_shop_events(&s,.Dropped,"basket")
    testing.expect(t,count==1 && event.from==base.name_hash("apple"))
}

@(test)
a_transition_carries_the_colors_of_a_node_between_its_states :: proc(t:^testing.T) {
    s:Test_Shop
    test_shop_init(t,&s)
    defer test_shop_destroy(&s)
    dark,light:=Color{0,0,0,255},Color{200,100,50,255}
    style,_:=tree_style(&s.tree,{fill=dark,transition=0.25})
    tree_style_variant(&s.tree,{style=style,states={.Hovered},patch={fields={.Fill},values={fill=light}}})
    tree_node(&s.tree,-1,{kind=.Button,name="go",style=style,text="Go",layout={width=fixed(40),height=fixed(20)}})
    testing.expect(t,test_shop_instance(&s))
    ctx:Context
    test_shop_context(t,&ctx)
    defer context_destroy(&ctx)
    input:=test_input()
    fill :: proc(ctx:^Context) -> Color {
        for &p in ctx.paints[:ctx.paint_count] {if p.kind==.Box {return p.fill}}
        return {}
    }
    test_frame(&ctx,&input,test_shop_build,&s)
    testing.expect_value(t,fill(&ctx),dark)
    test_point(&input,test_rect(t,&ctx,tree_element_id(&ctx,"go")))
    for _ in 0..<6 {test_frame(&ctx,&input,test_shop_build,&s)}
    between:=fill(&ctx)
    testing.expect(t,between[0]>0 && between[0]<200 && s.result.animating,"On its way the fill is between the two, and the frames keep coming")
    for _ in 0..<20 {test_frame(&ctx,&input,test_shop_build,&s)}
    testing.expect_value(t,fill(&ctx),light)
    testing.expect(t,!s.result.animating)
    // Leaving before it arrives, it goes back from where it was.
    input.pointer={-100,-100}
    test_frame(&ctx,&input,test_shop_build,&s)
    test_frame(&ctx,&input,test_shop_build,&s)
    back:=fill(&ctx)
    testing.expect(t,back[0]<200 && back[0]>150)
}

// The layout transition of a style carries the rectangle of its node to a new layout: from where
// it was drawn, through rectangles between both, to exactly where the layout puts it; a layout
// that changes on the way starts again from where it is. A new size too, which the layout around
// it follows. A node shown again, a style whose transition is only of its colors and what code
// builds without a style, as the editor, go there at once. The context keeps as many rectangles
// as its description says.
@(test)
a_layout_transition_carries_the_rectangle_of_a_node_to_a_new_layout :: proc(t:^testing.T) {
    s:Test_Shop
    test_shop_init(t,&s)
    defer test_shop_destroy(&s)
    tree_style(&s.tree,{}) // what a node without a style takes
    style,_:=tree_style(&s.tree,{layout_transition=0.25})
    root:=tree_node(&s.tree,-1,{kind=.Box,name="row"})
    lead:=tree_node(&s.tree,root,{kind=.Box,name="lead",layout={width=fixed(20),height=fixed(10)}})
    mover:=tree_node(&s.tree,root,{kind=.Box,name="mover",style=style,layout={width=fixed(30),height=fixed(10)}})
    tree_node(&s.tree,root,{kind=.Box,name="after",layout={width=fixed(10),height=fixed(10)}})
    testing.expect(t,test_shop_instance(&s))
    ctx:Context
    test_shop_context(t,&ctx)
    defer context_destroy(&ctx)
    input:=test_input()
    rect :: proc(t:^testing.T,ctx:^Context,name:string) -> Rect {return test_rect(t,ctx,tree_element_id(ctx,name))}
    // Every container keeps its rectangle.
    tracked :: proc(ctx:^Context,user:rawptr) {
        s:=cast(^Test_Shop)user
        s.result=tree_build(ctx,&s.tree,&s.instance,{events=s.events[:],changed=true,track=true})
    }
    frame:=test_frame(&ctx,&input,tracked,&s)
    testing.expect(t,rect(t,&ctx,"mover")==Rect{20,0,30,10} && !frame.transitioning,"the first time it is where the layout puts it")
    s.tree.nodes[lead].layout.width=fixed(100)
    last:=f32(20)
    for _ in 0..<5 {
        frame=test_frame(&ctx,&input,tracked,&s)
        x:=rect(t,&ctx,"mover").x
        testing.expectf(t,x>last && x<100 && frame.transitioning,"on its way: %v after %v",x,last)
        last=x
    }
    s.tree.nodes[lead].layout.width=fixed(0)
    frame=test_frame(&ctx,&input,tracked,&s)
    turned:=rect(t,&ctx,"mover").x
    testing.expectf(t,turned<last && turned>0,"a new layout on the way starts from where it is: %v after %v",turned,last)
    for _ in 0..<20 {frame=test_frame(&ctx,&input,tracked,&s)}
    testing.expect(t,rect(t,&ctx,"mover")==Rect{0,0,30,10} && !frame.transitioning,"it ends exactly where the layout puts it")
    s.tree.nodes[mover].layout.width=fixed(60)
    test_frame(&ctx,&input,tracked,&s)
    grown,after:=rect(t,&ctx,"mover"),rect(t,&ctx,"after")
    testing.expectf(t,grown.w>30 && grown.w<60 && test_near(after.x,grown.w,PIXEL_EDGE),"its size on the way, which the layout around it follows: %v %v",grown,after)
    for _ in 0..<20 {test_frame(&ctx,&input,tracked,&s)}
    testing.expect(t,rect(t,&ctx,"mover").w==60 && rect(t,&ctx,"after").x==60)
    elsewhere :: proc(ctx:^Context,user:rawptr) {if box(ctx,{id=id(ctx,"elsewhere"),width=fixed(10),height=fixed(10)}) {}}
    test_frame(&ctx,&input,elsewhere,nil)
    s.tree.nodes[lead].layout.width=fixed(50)
    frame=test_frame(&ctx,&input,tracked,&s)
    testing.expect(t,rect(t,&ctx,"mover").x==50 && !frame.transitioning,"shown again elsewhere, it does not slide from where it was")
    s.tree.styles[style]={transition=0.25}
    s.tree.nodes[lead].layout.width=fixed(5)
    frame=test_frame(&ctx,&input,tracked,&s)
    testing.expect(t,rect(t,&ctx,"mover").x==5 && !frame.transitioning,"a transition of colors does not move the layout")
    s.tree.styles[style]={layout_transition=0.25}
    small:Context
    desc:=TEST_SMALL
    desc.max_transitions=1
    testing.expect(t,context_init(&small,desc))
    defer context_destroy(&small)
    s.tree.nodes[lead].style=style
    test_frame(&small,&input,tracked,&s)
    testing.expect_value(t,small.stats.dropped_transitions,u32(1))

    lead_width:=f32(20)
    built :: proc(ctx:^Context,user:rawptr) {
        if box(ctx,{id=id(ctx,"code_row")}) {
            spacer(ctx,(cast(^f32)user)^,10)
            if box(ctx,{id=id(ctx,"code_box"),width=fixed(30),height=fixed(10),track=true}) {}
        }
    }
    test_frame(&ctx,&input,built,&lead_width)
    lead_width=100
    frame=test_frame(&ctx,&input,built,&lead_width)
    testing.expect(t,test_rect(t,&ctx,id(&ctx,"code_box")).x==100 && !frame.transitioning,"a widget of code goes to its new place at once")
}

@(test)
animations_value_frame_and_reveal_their_node :: proc(t:^testing.T) {
    s:Test_Shop
    test_shop_init(t,&s)
    defer test_shop_destroy(&s)
    lib:=&s.tree.anims
    constant :: proc(lib:^Anim_Library,property:Anim_Property,x:f32) -> Anim {
        return anim_clip(lib,{{property,{{time=0,value={x,0,0,0}}}}})
    }
    filled,_:=tree_anim_set(&s.tree,{shown=constant(lib,.Value,0.25)})
    framed,_:=tree_anim_set(&s.tree,{shown=constant(lib,.Frame,1)})
    typed,_:=tree_anim_set(&s.tree,{shown=constant(lib,.Reveal,0.5)})
    sheet,_:=tree_image(&s.tree,{quad={.Image,3,{0,0,1,1}},frames={2,1},size={64,32}})
    style,_:=tree_style(&s.tree,{fill={255,255,255,255},text={size=12,color={255,255,255,255}}})
    root:=tree_node(&s.tree,-1,{kind=.Box,name="row"})
    tree_node(&s.tree,root,{kind=.Progress,name="bar",style=style,anims=filled,bind_value="Test.amount",layout={width=fixed(40),height=fixed(6)}})
    tree_node(&s.tree,root,{kind=.Image,name="sprite",style=style,image=sheet,anims=framed,layout={width=fixed(16),height=fixed(16)}})
    tree_node(&s.tree,root,{kind=.Text,name="line",style=style,anims=typed,text="abcd"})
    testing.expect(t,test_shop_instance(&s))
    s.values.amount=0.9
    ctx:Context
    test_shop_context(t,&ctx)
    defer context_destroy(&ctx)
    input:=test_input()
    test_frame(&ctx,&input,test_shop_build,&s)
    test_frame(&ctx,&input,test_shop_build,&s)
    bar,sprite:^Paint
    for &p in ctx.paints[:ctx.paint_count] {
        if p.kind==.Progress {bar=&p}
        if p.kind==.Image {sprite=&p}
    }
    testing.expect(t,bar!=nil && bar.value==0.25,"Value is what the bar shows in place of its value")
    testing.expect(t,sprite!=nil && test_rect_near(sprite.quad.uv,{0.5,0,0.5,1}),"Frame chooses the frame of the sheet")
    line:=test_paint(&ctx,"abcd")
    testing.expect(t,line!=nil && line.revealed==3,"Reveal draws half the characters")
}

@(test)
a_click_plays_its_animation :: proc(t:^testing.T) {
    s:Test_Shop
    test_shop_init(t,&s)
    defer test_shop_destroy(&s)
    lib:=&s.tree.anims
    clicked:=anim_tween(lib,.Scale,{1,1,0,0},{1.1,1.1,0,0},0.1)
    set,_:=tree_anim_set(&s.tree,{clicked=clicked})
    tree_node(&s.tree,-1,{kind=.Button,name="go",text="Go",anims=set,layout={width=fixed(40),height=fixed(20)}})
    testing.expect(t,test_shop_instance(&s))
    ctx:Context
    test_shop_context(t,&ctx)
    defer context_destroy(&ctx)
    input:=test_input()
    test_frame(&ctx,&input,test_shop_build,&s)
    test_frame(&ctx,&input,test_shop_build,&s)
    testing.expect_value(t,s.instance.states[0].anim,Anim(0))
    test_point(&input,test_rect(t,&ctx,tree_element_id(&ctx,"go")))
    test_frame(&ctx,&input,test_shop_build,&s)
    test_press(&input);test_release(&input)
    test_frame(&ctx,&input,test_shop_build,&s)
    test_frame(&ctx,&input,test_shop_build,&s)
    testing.expect_value(t,s.instance.states[0].anim,clicked)
}

@(test)
pointer_buttons_report_presses_right_and_double_clicks :: proc(t:^testing.T) {
    s:Test_Shop
    test_shop_init(t,&s)
    defer test_shop_destroy(&s)
    tree_node(&s.tree,-1,{kind=.Box,name="card",block=true,layout={width=fixed(40),height=fixed(40)}})
    testing.expect(t,test_shop_instance(&s))
    ctx:Context
    test_shop_context(t,&ctx)
    defer context_destroy(&ctx)
    input:=test_input()
    test_frame(&ctx,&input,test_shop_build,&s)
    test_point(&input,test_rect(t,&ctx,tree_element_id(&ctx,"card")))
    test_frame(&ctx,&input,test_shop_build,&s)
    input_button(&input,.Right,true)
    test_frame(&ctx,&input,test_shop_build,&s)
    _,right:=test_shop_events(&s,.Right_Clicked,"card")
    testing.expect_value(t,right,1)
    input_button(&input,.Right,false)
    test_press(&input,2)
    test_frame(&ctx,&input,test_shop_build,&s)
    _,pressed:=test_shop_events(&s,.Pressed,"card")
    _,double:=test_shop_events(&s,.Double_Clicked,"card")
    testing.expect(t,pressed==1 && double==1)
    test_release(&input)
    test_frame(&ctx,&input,test_shop_build,&s)
    _,released:=test_shop_events(&s,.Released,"card")
    testing.expect_value(t,released,1)
}

@(test)
a_field_and_a_number_node_follow_their_flags_and_range :: proc(t:^testing.T) {
    s:Test_Shop
    test_shop_init(t,&s)
    defer test_shop_destroy(&s)
    style,_:=tree_style(&s.tree,{fill={30,30,30,255},mark={255,200,0,255},text={size=12,color={255,255,255,255}}})
    root:=tree_node(&s.tree,-1,{kind=.Box,name="form",layout={direction=.Column,gap=4}})
    tree_node(&s.tree,root,{kind=.Field,name="pin",style=style,text="Your pin",bind_text="Test.note",limit=3,flags={.Password}})
    tree_node(&s.tree,root,{kind=.Number,name="count",style=style,bind_value="Test.coins",range={0,10,1}})
    testing.expect(t,test_shop_instance(&s))
    ctx:Context
    test_shop_context(t,&ctx,font=true)
    defer context_destroy(&ctx)
    input:=test_input()
    test_frame(&ctx,&input,test_shop_build,&s)
    test_frame(&ctx,&input,test_shop_build,&s)
    placeholder:=false
    for &p in ctx.paints[:ctx.paint_count] {if p.kind==.Field && p.placeholder=="Your pin" {placeholder=true}}
    testing.expect(t,placeholder,"The text of a field is its placeholder while it is empty")
    test_click(&ctx,&input,test_shop_build,&s,tree_element_id(&ctx,"pin"))
    test_type(&input,"12345")
    test_frame(&ctx,&input,test_shop_build,&s)
    test_key(&input,.Enter)
    test_frame(&ctx,&input,test_shop_build,&s)
    event,count:=test_shop_events(&s,.Submitted,"pin")
    testing.expect(t,count==1 && strings.string_from_null_terminated_ptr(&event.text[0],len(event.text))=="123","A field takes as many bytes as its limit")
    testing.expect(t,test_paint(&ctx,"***")!=nil,"A password shows a mark for each character")
    count_id:=tree_element_id(&ctx,"count")
    test_click(&ctx,&input,test_shop_build,&s,id_derive(&ctx,count_id,"next"))
    changed,changes:=test_shop_events(&s,.Changed,"count")
    testing.expect(t,changes==1 && changed.value==1)
}

@(test)
rich_text_takes_italics_rules_links_and_images :: proc(t:^testing.T) {
    spans:[RICH_SPANS]Rich_Span
    style:=Text_Style{size=12,color={255,255,255,255}}
    count,lost:=rich_parse("<i>a</i><u>b</u><s>c</s><link=shop>d</link><img=coin>",style,spans[:])
    testing.expect(t,count==5 && !lost)
    testing.expect(t,spans[0].decoration=={.Italic} && spans[1].decoration=={.Underline} && spans[2].decoration=={.Strike})
    testing.expect(t,spans[3].link==base.name_hash("shop") && spans[4].image==base.name_hash("coin"))
    heavy:=style
    heavy.font=FONT_SEMIBOLD
    count,_=rich_parse("<b>x</b>",heavy,spans[:])
    testing.expect(t,spans[0].decoration=={.Bold} && spans[0].style.font==FONT_SEMIBOLD,"A font without a heavier face of its own draws a synthetic bold")
    Test_Rich :: struct {clicked:u64,text:string}
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_FONT))
    defer context_destroy(&ctx)
    ctx.release_activates=true
    input:=test_input()
    build :: proc(ctx:^Context,user:rawptr) {
        r:=cast(^Test_Rich)user
        images:=[1]Node_Image{{name=base.name_hash("coin"),quad={.Image,3,{0,0,1,1}},size={32,16}}}
        if link:=rich_text(ctx,id(ctx,"rich"),r.text,{size=12,color={255,255,255,255}},{width=fixed(300)},images[:],{255,0,0,255});link!=0 {r.clicked=link}
    }
    r:=Test_Rich{text="Buy <link=shop>more <i>gold</i></link> <img=coin>"}
    test_frame(&ctx,&input,build,&r)
    gold:=test_paint(&ctx,"gold")
    testing.expect(t,gold!=nil && gold.style.color==Color{255,0,0,255} && gold.decoration=={.Italic},"A link takes its color and keeps its decorations")
    coin:^Paint
    for &p in ctx.paints[:ctx.paint_count] {if p.kind==.Image {coin=&p}}
    testing.expect(t,coin!=nil && coin.quad.data==3,"An image of the tree goes in the line")
    // The pointer over a piece of a link underlines all of it, and a click reports its name.
    first:=id_derive(&ctx,id(&ctx,"rich"),"link",int(u32(base.name_hash("shop")))+1)
    test_point(&input,test_rect(t,&ctx,first))
    test_frame(&ctx,&input,build,&r)
    gold=test_paint(&ctx,"gold")
    testing.expect(t,gold!=nil && .Underline in gold.decoration)
    test_press(&input);test_release(&input)
    test_frame(&ctx,&input,build,&r)
    testing.expect_value(t,r.clicked,base.name_hash("shop"))
    // Italics lean the glyphs: their tops are to the right of their bottoms.
    r.text="<i>Italic</i>"
    frame:=test_frame(&ctx,&input,build,&r)
    leaning:=0
    v:=frame.vertices
    for i:=0;i+6<=len(v);i+=6 {
        if quad_kind(v[i].quad)==.Glyph && v[i].position.x>v[i+5].position.x+0.5 {leaning+=1}
    }
    testing.expect(t,leaning>0)
    // Spans past the capacity are left out and counted.
    builder:=strings.builder_make(context.temp_allocator)
    for _ in 0..<RICH_SPANS+4 {strings.write_string(&builder,"<b>x</b>")}
    r.text=strings.to_string(builder)
    before:=ctx.stats.dropped_tree
    test_frame(&ctx,&input,build,&r)
    testing.expect(t,ctx.stats.dropped_tree>before)
}

@(test)
an_action_bar_counts_the_buttons_and_letters_it_cannot_hold :: proc(t:^testing.T) {
    s:Test_Shop
    test_shop_init(t,&s)
    defer test_shop_destroy(&s)
    root:=tree_node(&s.tree,-1,{kind=.Box,name="bar"})
    long:=strings.repeat("x",TREE_TEXT_KEPT+10,context.temp_allocator)
    for i in 0..<TREE_BAR+2 {tree_node(&s.tree,root,{kind=.Button,text=long if i==0 else "Go",action="use",layout={width=fixed(4),height=fixed(4)}})}
    tree_node(&s.tree,root,{kind=.Action_Bar,name="actions"})
    testing.expect(t,test_shop_instance(&s))
    ctx:Context
    test_shop_context(t,&ctx)
    defer context_destroy(&ctx)
    input:=test_input()
    test_frame(&ctx,&input,test_shop_build,&s)
    testing.expect_value(t,s.instance.bar_count,TREE_BAR)
    testing.expect_value(t,int(s.instance.bar[0].length),TREE_TEXT_KEPT)
    testing.expect_value(t,ctx.stats.dropped_tree,u32(3)) // two buttons and the letters of one
}

@(test)
a_new_animation_starts_from_where_the_last_one_left :: proc(t:^testing.T) {
    lib:Anim_Library
    testing.expect(t,anim_library_init(&lib))
    defer anim_library_destroy(&lib)
    out:=anim_tween(&lib,.Offset,{0,0,0,0},{100,0,0,0},1,.Linear)
    back:=anim_tween(&lib,.Offset,{0,0,0,0},{10,0,0,0},1,.Linear)
    player:Anim_Player
    anim_play(&player,back)
    anim_update(&lib,&player,0)
    testing.expect_value(t,player.value.offset.x,f32(0)) // the first one starts at its keys
    anim_play(&player,out)
    anim_update(&lib,&player,0.5)
    testing.expect(t,test_near(player.value.offset.x,50,0.01))
    // Interrupted at 50, the next one goes from there to its second key.
    anim_play(&player,back)
    anim_update(&lib,&player,0)
    testing.expect(t,test_near(player.value.offset.x,50,0.01),"It does not jump to its first key")
    anim_update(&lib,&player,0.5)
    testing.expect(t,test_near(player.value.offset.x,30,0.01))
    anim_update(&lib,&player,0.5)
    testing.expect(t,test_near(player.value.offset.x,10,0.01))
}
