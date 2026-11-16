package ui

import "core:strings"
import "core:testing"
import "mirai:std/base"
import "mirai:std/serial"

Test_Stats :: struct {
    health,most:f32,
    seconds:f32,
}
Test_Player :: struct {
    name:[16]u8 `mirai:"text"`,
    stats:Test_Stats,
    ratio:f32,
    volume:f32,
    level:i32,
    team:i32,
    nick:[16]u8 `mirai:"text"`,
    portrait:base.Asset_Id,
    tint:[4]f32,
    mood:[16]u8 `mirai:"text"`,
}

// A tree built from code over a Test_Player, with a context that navigates.
Test_Game :: struct {
    shown:i32,
    shown_states:Style_States,
    schema:serial.Schema,
    type:serial.Type_Index,
    host:Test_Host,
    tree:Widget_Tree,
    instance:Tree_Instance,
    values:Test_Player,
    events:[16]Tree_Event,
    result:Tree_Build_Result,
    passive:bool,
    changed:bool,
    sounds:int,
    held:bool,      // the action "use" is down
    pressed:bool,
    texts:base.Texts, // what test_game_text made the keys say
    text_slots:[8]base.Text_Slot,
    text_bytes:[128]u8,
    text_length:int,
}
// Makes a key say a text in the language of the tests.
test_game_text :: proc(s:^Test_Game,key,text:string) {
    hash:=base.name_hash(key)
    at:=base.text_slot(base.name_hash(TEST_LANGUAGE),hash)&u64(len(s.text_slots)-1)
    for s.text_slots[at].key!=0 {at=(at+1)&u64(len(s.text_slots)-1)}
    s.text_slots[at]={base.name_hash(TEST_LANGUAGE),hash,u32(s.text_length),u32(len(text))}
    s.text_length+=copy(s.text_bytes[s.text_length:],text)
    s.texts={slots=s.text_slots[:],text=s.text_bytes[:]}
}
test_game_init :: proc(t:^testing.T,s:^Test_Game) {
    serial.schema_init(&s.schema)
    ok:bool
    s.type,ok=serial.schema_add(&s.schema,Test_Player)
    testing.expect(t,ok)
    testing.expect(t,tree_init(&s.tree))
}
test_game_destroy :: proc(s:^Test_Game) {
    tree_instance_destroy(&s.instance);tree_destroy(&s.tree);serial.schema_destroy(&s.schema)
}
test_game_build :: proc(ctx:^Context,user:rawptr) {
    s:=cast(^Test_Game)user
    // What changed is what the test says: it checks the texts kept while nothing does.
    tree_values_refresh(&s.instance,&s.host.host,0)
    s.result=tree_build(ctx,&s.tree,&s.instance,{events=s.events[:],passive=s.passive,changed=s.changed,shown=s.shown,shown_states=s.shown_states})
}
// The instance of the tree over the values, in the language of the tests.
test_game_instance :: proc(s:^Test_Game) -> bool {
    return tree_instance_init(&s.instance,&s.tree,test_host(&s.host,&s.schema,s.type,&s.values),&s.texts,TEST_LANGUAGE)
}
TEST_LANGUAGE :: "xx" // a language other than the one the texts are written in
// A number a node writes in the copy of its instance.
test_game_number :: proc(s:^Test_Game,node:int) -> f64 {return bound_number(raw_data(s.instance.values),s.instance.bounds[node].value)}
test_game_context :: proc(t:^testing.T,ctx:^Context,s:^Test_Game,font:=false) {
    desc:=TEST_FONT if font else TEST_SMALL
    desc.navigation=true
    testing.expect(t,test_context_init(ctx,desc))
    ctx.release_activates=true
    ctx.game={
        user=s,
        texts=&s.texts,language=TEST_LANGUAGE,
        action=proc(user:rawptr,action:u64) -> (down,pressed:bool) {
            s:=cast(^Test_Game)user
            if action!=base.name_hash("use") {return}
            return s.held,s.pressed
        },
        sound=proc(user:rawptr,id:base.Asset_Id) {(cast(^Test_Game)user).sounds+=1},
        texture=proc(user:rawptr,id:base.Asset_Id) -> Quad {return {.Image,u32(id[0]),{0,0,1,1}}},
    }
}
test_game_events :: proc(s:^Test_Game,kind:Tree_Event_Kind,name:string) -> (found:Tree_Event,count:int) {
    for event in s.events[:s.result.count] {
        if event.kind==kind && event.name==base.name_hash(name) {found=event;count+=1}
    }
    return
}

@(test)
templates_format_nested_fields_and_keep_the_text_while_values_do_not_change :: proc(t:^testing.T) {
    s:Test_Game
    test_game_init(t,&s)
    defer test_game_destroy(&s)
    style,_:=tree_style(&s.tree,{text={size=12,color={255,255,255,255}}})
    root:=tree_node(&s.tree,-1,{kind=.Box,name="hud",layout={direction=.Column}})
    tree_node(&s.tree,root,{kind=.Text,name="health",style=style,text="HP {health:0}/{most} {{ok}}",fields={{"health","Test.stats.health"},{"most","Test.stats.most"},{},{}}})
    tree_node(&s.tree,root,{kind=.Text,name="ratio",style=style,text="{ratio:%1} {time:mm:ss} {level:+}",fields={{"ratio","Test.ratio"},{"time","Test.stats.seconds"},{"level","Test.level"},{}}})
    tree_node(&s.tree,root,{kind=.Text,name="label",style=style,text="hud.health",fields={{"health","Test.stats.health"},{},{},{}},flags={.Localized}})
    test_game_text(&s,"hud.health","Vida {health:0}")
    tree_node(&s.tree,root,{kind=.Text,name="name",style=style,bind_text="Test.name"})
    testing.expect(t,test_game_instance(&s))
    s.values.stats={health=72.6,most=100,seconds=125}
    s.values.ratio,s.values.level=0.4567,3
    copy(s.values.name[:],"Ana")
    ctx:Context
    test_game_context(t,&ctx,&s)
    defer context_destroy(&ctx)
    input:=test_input()
    s.changed=true
    test_frame(&ctx,&input,test_game_build,&s)
    testing.expect(t,test_paint(&ctx,"HP 73/100 {ok}")!=nil)
    testing.expect(t,test_paint(&ctx,"45.7% 02:05 +3")!=nil)
    testing.expect(t,test_paint(&ctx,"Vida 73")!=nil,"What the key of a localized node says is a template in the language of the game")
    testing.expect(t,test_paint(&ctx,"Ana")!=nil)
    // What the refresh copied anew is shown, though the build is not told.
    s.changed=false
    s.values.stats.health=10
    test_frame(&ctx,&input,test_game_build,&s)
    testing.expect(t,test_paint(&ctx,"HP 10/100 {ok}")!=nil)
    // A field the type does not have makes no instance, and neither does a name without its field.
    other:Tree_Instance
    tree_node(&s.tree,root,{kind=.Text,name="bad",text="{mana}",fields={{"mana","Test.stats.mana"},{},{},{}}})
    testing.expect(t,!tree_instance_init(&other,&s.tree,&s.host.host))
    testing.expect(t,other.failure.node==5 && other.failure.template)
}

@(test)
bindings_choose_the_image_the_tint_and_the_variant :: proc(t:^testing.T) {
    s:Test_Game
    test_game_init(t,&s)
    defer test_game_destroy(&s)
    plain,_:=tree_style(&s.tree,{fill={255,255,255,255}})
    tree_style_variant(&s.tree,{style=plain,variant=style_variant("angry"),patch={fields={.Fill},values={fill={200,0,0,255}}}})
    root:=tree_node(&s.tree,-1,{kind=.Box,name="card",style=plain,bind_variant="Test.mood",layout={width=fixed(40),height=fixed(40)}})
    tree_node(&s.tree,root,{kind=.Image,name="face",style=plain,bind_image="Test.portrait",bind_tint="Test.tint",layout={width=fixed(20),height=fixed(20)}})
    testing.expect(t,test_game_instance(&s))
    s.values.portrait={9,0}
    s.values.tint={1,0.5,0,1}
    copy(s.values.mood[:],"angry")
    ctx:Context
    test_game_context(t,&ctx,&s)
    defer context_destroy(&ctx)
    input:=test_input()
    test_frame(&ctx,&input,test_game_build,&s)
    image,card:^Paint
    for &p in ctx.paints[:ctx.paint_count] {
        if p.kind==.Image {image=&p}
        if p.kind==.Rect || p.kind==.Panel {if card==nil {card=&p}}
    }
    testing.expect(t,image!=nil && image.quad.data==9,"The image shows the texture of the field")
    testing.expect(t,image!=nil && image.fill==Color{255,188,0,255},"The tint is the color of the field, linear to display")
    testing.expect(t,card!=nil && card.fill==Color{200,0,0,255},"The variant is the name the field holds")
}

// An Image, and a Box that shows one, take the shadow, the corners, the stroke and the program of
// their style as a plain Box does: the program gets the image as the color of the node.
@(test)
an_image_takes_the_shadow_the_corners_and_the_program_of_its_style :: proc(t:^testing.T) {
    s:Test_Game
    test_game_init(t,&s)
    defer test_game_destroy(&s)
    round,_:=tree_style(&s.tree,{fill={255,255,255,255},radius={8,8,8,8},shadow=true,shadow_color={0,0,0,255},shadow_offset={0,4}})
    cut,_:=tree_style(&s.tree,{fill={255,255,255,255},program_values={6,0,0,0}})
    sheet,_:=tree_image(&s.tree,{quad={.Image,4,{0,0,0.5,0.5}}})
    root:=tree_node(&s.tree,-1,{kind=.Box,name="root",layout={direction=.Column,gap=8}})
    tree_node(&s.tree,root,{kind=.Image,name="face",style=round,bind_image="Test.portrait",layout={width=fixed(20),height=fixed(20)}})
    tree_node(&s.tree,root,{kind=.Box,name="card",style=cut,image=sheet,layout={width=fixed(30),height=fixed(30)}})
    tree_programs_set(&s.tree,{0,11})
    testing.expect(t,test_game_instance(&s))
    s.values.portrait={9,0}
    ctx:Context
    test_game_context(t,&ctx,&s)
    defer context_destroy(&ctx)
    input:=test_input()
    test_frame(&ctx,&input,test_game_build,&s)
    frame:=test_frame(&ctx,&input,test_game_build,&s)
    face:=test_rect(t,&ctx,tree_element_id(&ctx,"face"))
    rounded,shaded,programmed:=false,false,false
    for shape in frame.shapes {
        texture:=transmute(u32)shape.stroke[1]
        if texture==10 && transmute(u32)shape.stroke[0]==0 && shape.radii[0]==8 {rounded=true}
        if shape.bounds=={face.x,face.y+4,face.w,face.h} && shape.fill[3]==1 {shaded=true}
        if texture==5 && transmute(u32)shape.stroke[0]==11 && shape.params[0]==6 && shape.fill2=={0,0,0.5,0.5} && shape.bounds[2]==30 {programmed=true}
    }
    testing.expect(t,rounded,"the image is cut to the corners of its style")
    testing.expect(t,shaded,"and casts its shadow")
    testing.expect(t,programmed,"the program of the style colors the image of a Box, with its part of the texture")
}

@(test)
a_text_draws_what_its_style_fills_behind_it_with_its_padding :: proc(t:^testing.T) {
    s:Test_Game
    test_game_init(t,&s)
    defer test_game_destroy(&s)
    pill,_:=tree_style(&s.tree,{fill={10,20,30,200},radius={6,6,6,6},text={size=12,color={255,255,255,255}}})
    plain,_:=tree_style(&s.tree,{text={size=12,color={255,255,255,255}}})
    root:=tree_node(&s.tree,-1,{kind=.Box,name="root",layout={direction=.Column,width=fixed(300),height=fixed(200)}})
    tree_node(&s.tree,root,{kind=.Text,name="pill",style=pill,text="Coconut 1 of 10",layout={padding=padding_xy(10,4)}})
    tree_node(&s.tree,root,{kind=.Text,name="bare",style=plain,text="Plain text"})
    testing.expect(t,test_game_instance(&s))
    ctx:Context
    test_game_context(t,&ctx,&s)
    defer context_destroy(&ctx)
    input:=test_input()
    test_frame(&ctx,&input,test_game_build,&s)
    test_frame(&ctx,&input,test_game_build,&s)
    fills:=0
    for &p in ctx.paints[:ctx.paint_count] {
        if (p.kind==.Rect || p.kind==.Panel) && (p.fill==Color{10,20,30,200}) {
            fills+=1
            testing.expect_value(t,p.corners,[4]f32{6,6,6,6})
        }
    }
    testing.expect(t,fills>0,"the fill of the style is behind the text")
    words:=test_paint(&ctx,"Coconut 1 of 10")
    if !testing.expect(t,words!=nil && test_paint(&ctx,"Plain text")!=nil) {return}
    area:=test_rect(t,&ctx,tree_element_id(&ctx,"pill"))
    testing.expect(t,area.w>=text_width(&ctx.font,"Coconut 1 of 10",12,int(FONT_TREE)) && area.h>=12*TEXT_LINE+8,"the box holds the text and its padding")
}

@(test)
links_wraps_and_orders_decide_where_the_focus_goes :: proc(t:^testing.T) {
    s:Test_Game
    test_game_init(t,&s)
    defer test_game_destroy(&s)
    // Three buttons in a row that wraps, and a fourth below that the first links down to.
    row:=tree_node(&s.tree,-1,{kind=.Box,name="row",flags={.Wrap_X},layout={gap=10}})
    tree_node(&s.tree,row,{kind=.Button,name="a",text="A",flags={.Focus_First},nav={2="d"},order=2,layout={width=fixed(40),height=fixed(20)}})
    tree_node(&s.tree,row,{kind=.Button,name="b",text="B",order=1,layout={width=fixed(40),height=fixed(20)}})
    tree_node(&s.tree,row,{kind=.Button,name="c",text="C",layout={width=fixed(40),height=fixed(20)}})
    tree_node(&s.tree,-1,{kind=.Button,name="d",text="D",flags={.Skip},layout={width=fixed(40),height=fixed(20),},float={to=.Surface,offset={300,300}}})
    testing.expect(t,test_game_instance(&s))
    ctx:Context
    test_game_context(t,&ctx,&s)
    defer context_destroy(&ctx)
    input:=test_input()
    input.pointer_absent=true
    test_frame(&ctx,&input,test_game_build,&s)
    test_frame(&ctx,&input,test_game_build,&s)
    testing.expect_value(t,ctx.focus,tree_element_id(&ctx,"a"))
    _,focused:=test_game_events(&s,.Focused,"a")
    testing.expect_value(t,focused,1)
    // Right from the last of the row wraps to the first.
    ctx.focus=tree_element_id(&ctx,"c")
    test_key(&input,.Right)
    test_frame(&ctx,&input,test_game_build,&s)
    testing.expect_value(t,ctx.focus,tree_element_id(&ctx,"a"))
    // A link goes where it says, even to a node navigation skips otherwise.
    test_key(&input,.Down)
    test_frame(&ctx,&input,test_game_build,&s)
    testing.expect(t,ctx.focus!=tree_element_id(&ctx,"d"),"a node that skips navigation is not focusable")
    // Tab follows the order: b (1), a (2), then c.
    ctx.focus=0
    test_key(&input,.Tab)
    test_frame(&ctx,&input,test_game_build,&s)
    testing.expect_value(t,ctx.focus,tree_element_id(&ctx,"b"))
    test_key(&input,.Tab)
    test_frame(&ctx,&input,test_game_build,&s)
    testing.expect_value(t,ctx.focus,tree_element_id(&ctx,"a"))
    _,focused=test_game_events(&s,.Focused,"a")
    testing.expect_value(t,focused,1)
    test_key(&input,.Tab)
    test_frame(&ctx,&input,test_game_build,&s)
    testing.expect_value(t,ctx.focus,tree_element_id(&ctx,"c"))
    // A passive tree takes no focus.
    ctx.focus=0
    s.passive=true
    test_frame(&ctx,&input,test_game_build,&s)
    test_key(&input,.Tab)
    test_frame(&ctx,&input,test_game_build,&s)
    testing.expect_value(t,ctx.focus,Id(0))
    // In a Modal, under a pointer that never moved, the keys work from its first frame; a page of
    // a Switcher that replaces the one with the focus takes it in the frame it comes back.
    m:Test_Game
    test_game_init(t,&m)
    defer test_game_destroy(&m)
    button:=Layout{width=fixed(40),height=fixed(20)}
    modal:=tree_node(&m.tree,-1,{kind=.Modal,name="pause",layout={width=fixed(200),height=fixed(200)}})
    pages:=tree_node(&m.tree,modal,{kind=.Switcher,name="pages",bind_value="Test.level"})
    first_page:=tree_node(&m.tree,pages,{kind=.Box,name="main",layout={direction=.Column,gap=4}})
    tree_node(&m.tree,first_page,{kind=.Button,name="play",text="Play",flags={.Focus_First},layout=button})
    tree_node(&m.tree,first_page,{kind=.Button,name="options",text="Options",layout=button})
    second_page:=tree_node(&m.tree,pages,{kind=.Box,name="paused"})
    tree_node(&m.tree,second_page,{kind=.Button,name="quit",text="Quit",flags={.Focus_First},layout=button})
    testing.expect(t,test_game_instance(&m))
    menu:Context
    test_game_context(t,&menu,&m)
    defer context_destroy(&menu)
    keys:=test_input()
    test_frame(&menu,&keys,test_game_build,&m)
    testing.expect_value(t,menu.focus,tree_element_id(&menu,"play"))
    test_key(&keys,.Down)
    test_frame(&menu,&keys,test_game_build,&m)
    testing.expect_value(t,menu.focus,tree_element_id(&menu,"options"))
    test_key(&keys,.Up)
    test_frame(&menu,&keys,test_game_build,&m)
    test_key(&keys,.Enter)
    test_frame(&menu,&keys,test_game_build,&m)
    _,clicked:=test_game_events(&m,.Clicked,"play")
    testing.expect_value(t,clicked,1)
    m.values.level=1
    test_frame(&menu,&keys,test_game_build,&m)
    testing.expect_value(t,menu.focus,tree_element_id(&menu,"quit"))
    m.values.level=0
    test_frame(&menu,&keys,test_game_build,&m)
    testing.expect(t,menu.focus==tree_element_id(&menu,"play") && menu.focus_ring,"the page that came back has the focus at once")
    test_key(&keys,.Enter)
    test_frame(&menu,&keys,test_game_build,&m)
    _,clicked=test_game_events(&m,.Clicked,"play")
    testing.expect_value(t,clicked,1)
}

@(test)
controls_write_their_bound_values_and_report_them :: proc(t:^testing.T) {
    s:Test_Game
    test_game_init(t,&s)
    defer test_game_destroy(&s)
    style,_:=tree_style(&s.tree,{fill={30,30,30,255},track={60,60,60,255},stroke={255,255,255,255},text={size=12,color={255,255,255,255}}})
    root:=tree_node(&s.tree,-1,{kind=.Box,name="menu",layout={direction=.Column,gap=4}})
    tree_node(&s.tree,root,{kind=.Slider,name="volume",style=style,bind_value="Test.volume",range={0,1,0.25},layout={width=fixed(112),height=fixed(20)}})
    tree_node(&s.tree,root,{kind=.Selector,name="quality",style=style,bind_value="Test.level",text="menu.quality",flags={.Localized},layout={width=fixed(160),height=fixed(24)}})
    test_game_text(&s,"menu.quality","Baja|Media|Alta")
    tree_node(&s.tree,root,{kind=.Radio,name="red",style=style,bind_value="Test.team",choice=1})
    tree_node(&s.tree,root,{kind=.Radio,name="blue",style=style,bind_value="Test.team",choice=2})
    testing.expect(t,test_game_instance(&s))
    ctx:Context
    test_game_context(t,&ctx,&s,font=true)
    defer context_destroy(&ctx)
    input:=test_input()
    test_frame(&ctx,&input,test_game_build,&s)
    testing.expect(t,test_paint(&ctx,"Baja")!=nil,"The options of a localized node are what its key says")
    // The slider follows the pointer in its steps.
    volume:=test_rect(t,&ctx,tree_element_id(&ctx,"volume"))
    input.pointer={volume.x+6+(volume.w-12)*0.6,volume.y+volume.h*0.5}
    test_frame(&ctx,&input,test_game_build,&s)
    test_press(&input)
    test_frame(&ctx,&input,test_game_build,&s)
    testing.expect_value(t,test_game_number(&s,1),0.5)
    event,count:=test_game_events(&s,.Changed,"volume")
    testing.expect(t,count==1 && event.value==0.5)
    test_release(&input)
    test_frame(&ctx,&input,test_game_build,&s)
    // Left and right step the selector while it has the focus, and wrap.
    ctx.focus,ctx.focus_ring=tree_element_id(&ctx,"quality"),true
    test_key(&input,.Left)
    test_frame(&ctx,&input,test_game_build,&s)
    testing.expect_value(t,test_game_number(&s,2),2.0)
    testing.expect_value(t,ctx.focus,tree_element_id(&ctx,"quality"))
    // Choosing a radio writes its value.
    blue:=test_rect(t,&ctx,tree_element_id(&ctx,"blue"))
    test_point(&input,blue)
    test_frame(&ctx,&input,test_game_build,&s)
    test_press(&input);test_release(&input)
    test_frame(&ctx,&input,test_game_build,&s)
    testing.expect_value(t,test_game_number(&s,4),2.0)
    event,count=test_game_events(&s,.Changed,"blue")
    testing.expect(t,count==1 && event.value==2)
}

@(test)
a_field_reports_what_it_holds_when_enter_submits_it :: proc(t:^testing.T) {
    s:Test_Game
    test_game_init(t,&s)
    defer test_game_destroy(&s)
    tree_node(&s.tree,-1,{kind=.Field,name="nick",bind_text="Test.nick",layout={width=fixed(120),height=fixed(24)}})
    testing.expect(t,test_game_instance(&s))
    ctx:Context
    test_game_context(t,&ctx,&s,font=true)
    defer context_destroy(&ctx)
    input:=test_input()
    test_frame(&ctx,&input,test_game_build,&s)
    test_point(&input,test_rect(t,&ctx,tree_element_id(&ctx,"nick")))
    test_frame(&ctx,&input,test_game_build,&s)
    test_press(&input);test_release(&input)
    test_frame(&ctx,&input,test_game_build,&s)
    test_type(&input,"Zed")
    test_frame(&ctx,&input,test_game_build,&s)
    test_key(&input,.Enter)
    test_frame(&ctx,&input,test_game_build,&s)
    event,count:=test_game_events(&s,.Submitted,"nick")
    testing.expect_value(t,count,1)
    testing.expect_value(t,strings.string_from_null_terminated_ptr(&event.text[0],len(event.text)),"Zed")
    testing.expect_value(t,bound_bytes(raw_data(s.instance.values),s.instance.bounds[0].text),"Zed")
}

@(test)
an_action_clicks_its_button_and_a_hold_waits_for_it :: proc(t:^testing.T) {
    s:Test_Game
    test_game_init(t,&s)
    defer test_game_destroy(&s)
    root:=tree_node(&s.tree,-1,{kind=.Box,name="bar",layout={gap=4}})
    tree_node(&s.tree,root,{kind=.Button,name="use",text="Use",action="use",layout={width=fixed(60),height=fixed(20)}})
    tree_node(&s.tree,root,{kind=.Button,name="skip",text="Skip",action="use",hold=0.5,layout={width=fixed(60),height=fixed(20)}})
    tree_node(&s.tree,root,{kind=.Action_Bar,name="actions"})
    // The tree keeps the name of the action, to say which one a game lacks.
    testing.expect_value(t,tree_action_name(&s.tree,&s.tree.nodes[1]),"use")
    testing.expect_value(t,tree_action_name(&s.tree,&s.tree.nodes[0]),"")
    testing.expect(t,test_game_instance(&s))
    ctx:Context
    test_game_context(t,&ctx,&s)
    defer context_destroy(&ctx)
    input:=test_input()
    test_frame(&ctx,&input,test_game_build,&s)
    testing.expect_value(t,s.instance.bar_count,2)
    // The bar shows what the last build found: a build that finds other
    // buttons, or their texts in another language, asks for the frame that shows them.
    testing.expect(t,s.result.animating,"The build that found the buttons asks for the next frame")
    test_frame(&ctx,&input,test_game_build,&s)
    testing.expect(t,!s.result.animating && test_paint(&ctx,"Use")!=nil)
    s.held,s.pressed=true,true
    test_frame(&ctx,&input,test_game_build,&s)
    _,used:=test_game_events(&s,.Clicked,"use")
    _,skipped:=test_game_events(&s,.Clicked,"skip")
    testing.expect(t,used==1 && skipped==0)
    testing.expect(t,s.result.animating,"A hold in progress keeps the frames coming")
    s.pressed=false
    for _ in 0..<40 {
        test_frame(&ctx,&input,test_game_build,&s)
        if _,c:=test_game_events(&s,.Clicked,"skip");c>0 {skipped+=c}
    }
    testing.expect_value(t,skipped,1)
    // A passive tree takes no action.
    s.passive,s.held,s.pressed=true,true,true
    test_frame(&ctx,&input,test_game_build,&s)
    _,used=test_game_events(&s,.Clicked,"use")
    testing.expect_value(t,used,0)
    // The press that shows a tree does not click its button: it waits for the next one.
    tree_instance_destroy(&s.instance)
    testing.expect(t,test_game_instance(&s))
    s.passive=false
    test_frame(&ctx,&input,test_game_build,&s)
    s.pressed=false
    test_frame(&ctx,&input,test_game_build,&s)
    _,used=test_game_events(&s,.Clicked,"use")
    testing.expect_value(t,used,0)
    s.held=false
    test_frame(&ctx,&input,test_game_build,&s)
    s.held,s.pressed=true,true
    test_frame(&ctx,&input,test_game_build,&s)
    _,used=test_game_events(&s,.Clicked,"use")
    testing.expect_value(t,used,1)
    // A press read from a fixed tick lasts for every frame of that tick: it clicks once, also
    // when it was let go within the tick.
    test_frame(&ctx,&input,test_game_build,&s)
    _,used=test_game_events(&s,.Clicked,"use")
    testing.expect_value(t,used,0)
    s.held,s.pressed=false,false
    test_frame(&ctx,&input,test_game_build,&s)
    s.pressed=true
    for _ in 0..<2 {
        test_frame(&ctx,&input,test_game_build,&s)
        if _,c:=test_game_events(&s,.Clicked,"use");c>0 {used+=c}
    }
    testing.expect_value(t,used,1)
}

@(test)
hovering_shows_a_tooltip_and_dragging_drops_on_a_target :: proc(t:^testing.T) {
    s:Test_Game
    test_game_init(t,&s)
    defer test_game_destroy(&s)
    root:=tree_node(&s.tree,-1,{kind=.Box,name="slots",layout={gap=40}})
    item:=tree_node(&s.tree,root,{kind=.Box,name="item",flags={.Draggable},layout={width=fixed(30),height=fixed(30)}})
    tip:=tree_node(&s.tree,item,{kind=.Tooltip,name="tip"})
    tree_node(&s.tree,tip,{kind=.Button,name="about",text="Sword",layout={width=fixed(50),height=fixed(16)}})
    tree_node(&s.tree,root,{kind=.Box,name="target",flags={.Drop},layout={width=fixed(30),height=fixed(30)}})
    testing.expect(t,test_game_instance(&s))
    ctx:Context
    test_game_context(t,&ctx,&s)
    defer context_destroy(&ctx)
    input:=test_input()
    test_frame(&ctx,&input,test_game_build,&s)
    item_rect:=test_rect(t,&ctx,tree_element_id(&ctx,"item"))
    test_point(&input,item_rect)
    for _ in 0..<10 {test_frame(&ctx,&input,test_game_build,&s)}
    _,shown:=widget_rect(&ctx,tree_element_id(&ctx,"about"))
    testing.expect(t,!shown,"The tooltip waits")
    for _ in 0..<30 {test_frame(&ctx,&input,test_game_build,&s)}
    _,shown=widget_rect(&ctx,tree_element_id(&ctx,"about"))
    testing.expect(t,shown,"The tooltip shows after the delay")
    // Drag the item to the target.
    test_press(&input)
    test_frame(&ctx,&input,test_game_build,&s)
    target:=test_rect(t,&ctx,tree_element_id(&ctx,"target"))
    input.pointer={item_rect.x+30,item_rect.y+15}
    test_frame(&ctx,&input,test_game_build,&s)
    _,dragged:=test_game_events(&s,.Dragged,"item")
    testing.expect_value(t,dragged,1)
    test_point(&input,target)
    test_frame(&ctx,&input,test_game_build,&s)
    test_release(&input)
    test_frame(&ctx,&input,test_game_build,&s)
    dropped,count:=test_game_events(&s,.Dropped,"target")
    testing.expect_value(t,count,1)
    testing.expect_value(t,dropped.from,base.name_hash("item"))
    testing.expect_value(t,ctx.drag.id,Id(0))
}

@(test)
a_played_animation_reports_its_end :: proc(t:^testing.T) {
    s:Test_Game
    test_game_init(t,&s)
    defer test_game_destroy(&s)
    shake:=anim_tween(&s.tree.anims,.Offset,{0,0,0,0},{4,0,0,0},0.1,.Linear)
    s.tree.anim_names[shake-1]=base.name_hash("shake")
    tree_node(&s.tree,-1,{kind=.Box,name="card",layout={width=fixed(20),height=fixed(20)}})
    testing.expect(t,test_game_instance(&s))
    testing.expect(t,!tree_play(&s.tree,&s.instance,base.name_hash("card"),base.name_hash("missing")))
    testing.expect(t,tree_play(&s.tree,&s.instance,base.name_hash("card"),base.name_hash("shake")))
    ctx:Context
    test_game_context(t,&ctx,&s)
    defer context_destroy(&ctx)
    input:=test_input()
    finished:=0
    for _ in 0..<12 {
        test_frame(&ctx,&input,test_game_build,&s)
        event,count:=test_game_events(&s,.Finished,"card")
        if count>0 {finished+=1;testing.expect_value(t,event.from,base.name_hash("shake"))}
    }
    testing.expect_value(t,finished,1)
}

@(test)
rich_text_breaks_its_words_with_their_styles :: proc(t:^testing.T) {
    spans:[RICH_SPANS]Rich_Span
    style:=Text_Style{size=12,color={255,255,255,255}}
    count,_:=rich_parse("Press <prompt=jump> to <b>jump</b> <color=#ff8800>now</color> <odd>",style,spans[:])
    testing.expect_value(t,count,8)
    testing.expect_value(t,spans[1].prompt,base.name_hash("jump"))
    testing.expect(t,spans[3].text=="jump" && spans[3].style.font==FONT_SEMIBOLD)
    testing.expect(t,spans[5].text=="now" && spans[5].style.color==Color{255,136,0,255})
    testing.expect(t,spans[7].text=="<odd>","What is not a tag is text")
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_FONT))
    defer context_destroy(&ctx)
    input:=test_input()
    build :: proc(ctx:^Context,user:rawptr) {
        rich_text(ctx,id(ctx,"rich"),"one two three four five six seven",{size=12,color={255,255,255,255}},{width=fixed(60)})
    }
    test_frame(&ctx,&input,build)
    // The words of a span on a line are one piece, without the space the line breaks at.
    broken:[8]string
    lines:=test_text_lines(&ctx,id(&ctx,"rich"),broken[:])
    testing.expect(t,lines>1 && broken[0]=="one two")
    r:=test_rect(t,&ctx,id(&ctx,"rich"))
    testing.expect(t,r.h>12*TEXT_LINE*2,"The words break into several lines")
}

@(test)
a_progress_fills_from_the_side_its_style_says :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_SMALL))
    defer context_destroy(&ctx)
    build :: proc(ctx:^Context,user:rawptr) {
        if box(ctx,{direction=.Column,gap=4}) {
            progress(ctx,{value=0.25,width=fixed(40),height=fixed(10),fill={255,0,0,255},track={0,0,255,255},fill_mode=.Left})
            progress(ctx,{value=0.5,width=fixed(10),height=fixed(40),fill={255,0,0,255},track={0,0,255,255},fill_mode=.Up})
            progress(ctx,{value=0.5,width=fixed(40),height=fixed(40),fill={255,0,0,255},track={0,0,255,255},fill_mode=.Radial})
        }
    }
    input:=test_input(64,128)
    frame:=test_frame(&ctx,&input,build)
    image:=test_raster(&ctx,frame,64,128,1,{0,0,0,255})
    defer test_image_destroy(&image)
    testing.expect(t,test_color_near(test_pixel(&image,36,5),{255,0,0,255},8),"Left fills from the right edge")
    testing.expect(t,test_color_near(test_pixel(&image,3,5),{0,0,255,255},8))
    testing.expect(t,test_color_near(test_pixel(&image,5,48),{255,0,0,255},8),"Up fills from the bottom")
    testing.expect(t,test_color_near(test_pixel(&image,5,16),{0,0,255,255},8))
    testing.expect(t,test_color_near(test_pixel(&image,30,78),{255,0,0,255},8),"Radial fills clockwise from the top")
    testing.expect(t,test_color_near(test_pixel(&image,10,78),{0,0,255,255},8))
}

@(test)
sounds_of_the_style_play_as_the_node_changes :: proc(t:^testing.T) {
    s:Test_Game
    test_game_init(t,&s)
    defer test_game_destroy(&s)
    loud:Node_Style
    loud.sounds[.Show],loud.sounds[.Hover],loud.sounds[.Press]={1,1},{2,2},{3,3}
    style,_:=tree_style(&s.tree,loud)
    tree_node(&s.tree,-1,{kind=.Button,name="go",text="Go",style=style,layout={width=fixed(40),height=fixed(20)}})
    testing.expect(t,test_game_instance(&s))
    ctx:Context
    test_game_context(t,&ctx,&s)
    defer context_destroy(&ctx)
    input:=test_input()
    test_frame(&ctx,&input,test_game_build,&s)
    testing.expect_value(t,s.sounds,1)
    test_point(&input,test_rect(t,&ctx,tree_element_id(&ctx,"go")))
    test_frame(&ctx,&input,test_game_build,&s)
    test_frame(&ctx,&input,test_game_build,&s)
    testing.expect_value(t,s.sounds,2)
    test_press(&input);test_release(&input)
    test_frame(&ctx,&input,test_game_build,&s)
    testing.expect_value(t,s.sounds,3)
}

@(test)
a_hidden_node_keeps_its_room_and_a_collapsed_one_gives_it_away :: proc(t:^testing.T) {
    s:Test_Game
    test_game_init(t,&s)
    defer test_game_destroy(&s)
    style,_:=tree_style(&s.tree,{fill={40,40,40,255},text={size=12,color={255,255,255,255}}})
    root:=tree_node(&s.tree,-1,{kind=.Box,name="hud",layout={direction=.Column}})
    row :: proc(s:^Test_Game,root:i32,style:u16,name:string,flags:Node_Flags) {
        box:=tree_node(&s.tree,root,{kind=.Box,name=name,style=style,flags=flags,layout={width=fixed(40),height=fixed(10)}})
        tree_node(&s.tree,box,{kind=.Text,style=style,text=name})
    }
    row(&s,root,style,"first",{.Invisible})
    row(&s,root,style,"kept",{})
    row(&s,root,style,"gone",{.Collapsed})
    row(&s,root,style,"last",{})
    testing.expect(t,test_game_instance(&s))
    ctx:Context
    test_game_context(t,&ctx,&s,font=true)
    defer context_destroy(&ctx)
    input:=test_input()
    build :: proc(ctx:^Context,user:rawptr) {
        s:=cast(^Test_Game)user
        tree_values_refresh(&s.instance,&s.host.host,0)
        s.result=tree_build(ctx,&s.tree,&s.instance,{events=s.events[:],track=true})
    }
    test_frame(&ctx,&input,build,&s)
    test_frame(&ctx,&input,build,&s)
    first:=test_paint(&ctx,"first")
    testing.expect(t,first!=nil && first.hidden,"A hidden node is laid out and draws nothing")
    testing.expect(t,test_paint(&ctx,"gone")==nil,"A collapsed node is not built")
    hud:=test_rect(t,&ctx,tree_element_id(&ctx,"hud"))
    kept:=test_rect(t,&ctx,tree_element_id(&ctx,"kept"))
    last:=test_rect(t,&ctx,tree_element_id(&ctx,"last"))
    testing.expect_value(t,kept.y-hud.y,f32(10))
    testing.expect_value(t,last.y-kept.y,f32(10))
}

@(test)
hovering_applies_the_hovered_rule_of_its_style :: proc(t:^testing.T) {
    s:Test_Game
    test_game_init(t,&s)
    defer test_game_destroy(&s)
    red:=Color{255,0,0,255}
    root:=tree_node(&s.tree,-1,{kind=.Box,name="root",layout={gap=20}})
    for name in ([]string{"label","button"}) {
        style,_:=tree_style(&s.tree,{text={size=14,color={255,255,255,255}}})
        tree_style_variant(&s.tree,{style=style,states={.Hovered},patch={fields={.Text_Color},values={text={color=red}}}})
        tree_node(&s.tree,root,{kind=.Text if name=="label" else .Button,name=name,text="Hi",style=style,layout={width=fixed(60),height=fixed(20)}})
    }
    testing.expect(t,test_game_instance(&s))
    ctx:Context
    test_game_context(t,&ctx,&s)
    defer context_destroy(&ctx)
    input:=test_input()
    test_frame(&ctx,&input,test_game_build,&s)
    for name in ([]string{"label","button"}) {
        test_point(&input,test_rect(t,&ctx,tree_element_id(&ctx,name)))
        for _ in 0..<3 {test_frame(&ctx,&input,test_game_build,&s)}
        found:=false
        for p in ctx.paints[:ctx.paint_count] {if (test_paint_is_text(p) || p.kind==.Box) && p.style.color==red {found=true}}
        testing.expectf(t,found,"%s draws its text red under the pointer",name)
    }
    // Pressed over a Text, the rule of Pressed applies.
    blue:=Color{0,0,255,255}
    tree_style_variant(&s.tree,{style=0,states={.Pressed},patch={fields={.Text_Color},values={text={color=blue}}}})
    test_point(&input,test_rect(t,&ctx,tree_element_id(&ctx,"label")))
    test_press(&input)
    for _ in 0..<2 {test_frame(&ctx,&input,test_game_build,&s)}
    {
        found:=false
        for p in ctx.paints[:ctx.paint_count] {if test_paint_is_text(p) && p.style.color==blue {found=true}}
        testing.expect(t,found,"A Text draws its Pressed look while the pointer holds over it")
    }
    // Passive, as the preview in Edit, a Text ignores the pointer; a node a tool shows in a state draws it.
    test_release(&input)
    s.passive=true
    for _ in 0..<2 {test_frame(&ctx,&input,test_game_build,&s)}
    {
        found:=false
        for p in ctx.paints[:ctx.paint_count] {if test_paint_is_text(p) && (p.style.color==blue || p.style.color==red) {found=true}}
        testing.expect(t,!found,"A passive tree takes no hover nor press")
        s.shown,s.shown_states=2,{.Hovered}
        input.pointer={-100,-100}
        for _ in 0..<2 {test_frame(&ctx,&input,test_game_build,&s)}
        reds:=0
        for p in ctx.paints[:ctx.paint_count] {if (test_paint_is_text(p) || p.kind==.Box) && p.style.color==red {reds+=1}}
        testing.expect_value(t,reds,1)
        s.shown=3
        for _ in 0..<2 {test_frame(&ctx,&input,test_game_build,&s)}
        reds=0
        for p in ctx.paints[:ctx.paint_count] {if (test_paint_is_text(p) || p.kind==.Box) && p.style.color==red {reds+=1}}
        testing.expect_value(t,reds,1)
    }
}

// Options written Label=Value bind what they name, a number or a text, and a
// value no option has shows none of them until a step moves it.
@(test)
options_written_label_equals_value_bind_that_value :: proc(t:^testing.T) {
    s:Test_Game
    test_game_init(t,&s)
    defer test_game_destroy(&s)
    style,_:=tree_style(&s.tree,{text={size=12,color={255,255,255,255}}})
    root:=tree_node(&s.tree,-1,{kind=.Box,name="menu",layout={direction=.Column,gap=4}})
    tree_node(&s.tree,root,{kind=.Selector,name="scale",style=style,bind_value="Test.volume",text="Half = 0.5|Full=1",layout={width=fixed(160),height=fixed(24)}})
    tree_node(&s.tree,root,{kind=.Selector,name="mood",style=style,bind_value="Test.mood",text="Calm=calm|Angry=angry",layout={width=fixed(160),height=fixed(24)}})
    testing.expect(t,test_game_instance(&s))
    s.values.volume=0.5
    copy(s.values.mood[:],"angry")
    ctx:Context
    test_game_context(t,&ctx,&s,font=true)
    defer context_destroy(&ctx)
    input:=test_input()
    test_frame(&ctx,&input,test_game_build,&s)
    testing.expect(t,test_paint(&ctx,"Half")!=nil && test_paint(&ctx,"Angry")!=nil)
    ctx.focus,ctx.focus_ring=tree_element_id(&ctx,"scale"),true
    test_key(&input,.Right)
    test_frame(&ctx,&input,test_game_build,&s)
    event,count:=test_game_events(&s,.Changed,"scale")
    testing.expect(t,count==1 && event.value==1)
    testing.expect_value(t,test_game_number(&s,1),1.0)
    ctx.focus=tree_element_id(&ctx,"mood")
    test_key(&input,.Right)
    test_frame(&ctx,&input,test_game_build,&s)
    event,count=test_game_events(&s,.Changed,"mood")
    testing.expect(t,count==1 && base.text_get(event.text[:])=="calm")
    testing.expect(t,bound_bytes(raw_data(s.instance.values),s.instance.bounds[2].value)=="calm")
    // A value no option has shows none, and stepping left takes the last.
    s.values.volume=0.75
    ctx.focus=tree_element_id(&ctx,"scale")
    test_frame(&ctx,&input,test_game_build,&s)
    testing.expect(t,test_paint(&ctx,"Full")==nil && test_paint(&ctx,"Half")==nil)
    test_key(&input,.Left)
    test_frame(&ctx,&input,test_game_build,&s)
    testing.expect_value(t,test_game_number(&s,1),1.0)
    // A value on a text field needs its options to name it.
    bad:Test_Game
    test_game_init(t,&bad)
    defer test_game_destroy(&bad)
    tree_node(&bad.tree,-1,{kind=.Selector,name="plain",bind_value="Test.mood",text="Calm|Angry"})
    testing.expect(t,!test_game_instance(&bad) && bad.instance.failure.binding==.Value)
}

// A control bound to a storage its host commits writes the game itself, for a
// text as for a number; a host that does not leaves the event to the game.
@(test)
a_commit_writes_the_field_of_a_storage_the_host_lets_write :: proc(t:^testing.T) {
    s:Test_Game
    test_game_init(t,&s)
    defer test_game_destroy(&s)
    style,_:=tree_style(&s.tree,{text={size=12,color={255,255,255,255}}})
    root:=tree_node(&s.tree,-1,{kind=.Box,name="menu",layout={direction=.Column,gap=4}})
    tree_node(&s.tree,root,{kind=.Slider,name="volume",style=style,bind_value="Test.volume",range={0,1,0.25},layout={width=fixed(112),height=fixed(20)}})
    tree_node(&s.tree,root,{kind=.Selector,name="mood",style=style,bind_value="Test.mood",text="Calm=calm|Angry=angry",layout={width=fixed(160),height=fixed(24)}})
    host:=test_host(&s.host,&s.schema,s.type,&s.values)
    host.source=proc(user:rawptr,name:u64) -> (type:serial.Type_Index,storage,ok:bool) {
        if name!=base.name_hash("Test") {return}
        return (^Test_Host)(user).type,true,true
    }
    host.commits=proc(user:rawptr,name:u64) -> bool {return name==base.name_hash("Test")}
    testing.expect(t,tree_instance_init(&s.instance,&s.tree,host,nil,TEST_LANGUAGE))
    tree_values_refresh(&s.instance,host,0)
    node:=[2]i32{1,2}
    testing.expect(t,tree_commit_event(&s.instance,{node=node[0],kind=.Changed,value=0.5},host))
    testing.expect_value(t,s.values.volume,f32(0.5))
    event:=Tree_Event{node=node[1],kind=.Changed}
    base.text_set(event.text[:],"angry")
    testing.expect(t,tree_commit_event(&s.instance,event,host))
    testing.expect(t,string(s.values.mood[:5])=="angry")
    testing.expect(t,!tree_commit_event(&s.instance,{node=-1,kind=.Changed,value=9},host))
    host.commits=nil
    testing.expect(t,!tree_commit_event(&s.instance,{node=node[0],kind=.Changed,value=0.75},host))
    testing.expect_value(t,s.values.volume,f32(0.5))
}

// A bound value changes its interface only when what it shows changes: a
// float that moves under the decimals of its text or a pixel of its bar
// copies nothing and rebuilds no node; one that changes the text or the fill
// does, once.
@(test)
a_value_changes_the_interface_only_when_what_it_shows_changes :: proc(t:^testing.T) {
    s:Test_Game
    test_game_init(t,&s)
    defer test_game_destroy(&s)
    style,_:=tree_style(&s.tree,{text={size=12,color={255,255,255,255}}})
    root:=tree_node(&s.tree,-1,{kind=.Box,name="hud",layout={direction=.Column}})
    tree_node(&s.tree,root,{kind=.Text,name="time",style=style,text="{time:1} s",fields={{"time","Test.stats.seconds"},{},{},{}}})
    tree_node(&s.tree,root,{kind=.Progress,name="bar",style=style,bind_value="Test.ratio",layout={width=fixed(100),height=fixed(8)}})
    testing.expect(t,test_game_instance(&s))
    s.values.stats.seconds,s.values.ratio=1,0.5
    ctx:Context
    test_game_context(t,&ctx,&s)
    defer context_destroy(&ctx)
    input:=test_input()
    test_frame(&ctx,&input,test_game_build,&s)
    test_frame(&ctx,&input,test_game_build,&s)
    refresh :: proc(s:^Test_Game) -> bool {
        changed,_:=tree_values_refresh(&s.instance,&s.host.host,0)
        return changed
    }
    Case :: struct {seconds,ratio:f32,changes:bool}
    cases:=[]Case{
        {1.01,0.5,false},{1.04,0.503,false},{1.02,0.497,false}, // under a tenth and a pixel of the bar
        {1.06,0.497,true},{1.07,0.497,false},                     // the text says 1.1, once
        {1.07,0.52,true},{1.07,0.521,false},                      // the bar moves two pixels, once
    }
    for c in cases {
        s.values.stats.seconds,s.values.ratio=c.seconds,c.ratio
        testing.expectf(t,refresh(&s)==c.changes,"%v: changed should be %v",c,c.changes)
        testing.expect(t,s.instance.dirty_any==c.changes,"what changes nothing shown marks no node to build")
        test_frame(&ctx,&input,test_game_build,&s)
    }
    testing.expect(t,test_paint(&ctx,"1.1 s")!=nil)
    s.values.stats.seconds=0h7fc00000 // NaN shows anew
    testing.expect(t,refresh(&s))
}
