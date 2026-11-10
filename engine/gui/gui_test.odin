package gui

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:testing"
import "mirai:core"
import inp "mirai:engine/input"
import "mirai:host"
import gpu "mirai:render"
import "mirai:std/base"
import "mirai:ui"

// A node of a screen is found where its tree was built, in window points at
// the scale of its context; one that was not built is not.
@(test)
the_rect_of_a_node_of_a_screen_is_in_window_points :: proc(t:^testing.T) {
    tree:ui.Widget_Tree
    testing.expect(t,ui.tree_init(&tree))
    defer ui.tree_destroy(&tree)
    root:=ui.tree_node(&tree,-1,{kind=.Box,name="root",layout={padding=ui.padding_all(10)}})
    ui.tree_node(&tree,root,{kind=.Button,name="play",text="Play",layout={width=ui.fixed(40),height=ui.fixed(20)}})
    ui.tree_node(&tree,root,{kind=.Box,name="gone",flags={.Collapsed}})
    instance:ui.Tree_Instance
    testing.expect(t,ui.tree_instance_init(&instance,&tree,nil))
    defer ui.tree_instance_destroy(&instance)
    ctx:ui.Context
    testing.expect(t,ui.context_init(&ctx,{no_font=true}))
    defer ui.context_destroy(&ctx)
    e:=core.entity_make(4,2)
    ui.frame_begin(&ctx,{size={400,300},scale=2,dt=1.0/60,pointer_absent=true})
    ui.id_push(&ctx,screen_scope(&ctx,e))
    ui.tree_build(&ctx,&tree,&instance,{})
    ui.id_pop(&ctx)
    ui.frame_end(&ctx)
    rect,found:=screen_node_rect(&ctx,&tree,e,1)
    testing.expect(t,found)
    testing.expect_value(t,rect,ui.Rect{20,20,80,40})
    _,found=screen_node_rect(&ctx,&tree,core.entity_make(5,2),1)
    testing.expect(t,!found,"another screen builds under another scope")
    _,found=screen_node_rect(&ctx,&tree,e,2)
    testing.expect(t,!found)
}

@(test)
the_events_of_a_frame_wait_for_a_tick_that_does_not_run_again :: proc(t:^testing.T) {
    gui:Gui
    events:UI_Events
    defer {delete(gui.pending);delete(gui.arrived.items);delete(events.items)}
    append(&gui.pending,UI_Event{entity=core.entity_make(1,1),name=7,kind=.Clicked})
    gui_events_deliver(&events,&gui,core.Time{tick=3,resimulating=true})
    testing.expect(t,len(events.items)==0 && len(gui.pending)==1)
    gui_events_deliver(&events,&gui,core.Time{tick=5})
    testing.expect(t,len(events.items)==1 && len(gui.pending)==0 && events.items[0].name==7)
}

@(test)
a_name_asked_is_kept_once_for_the_screen_it_was_asked_of :: proc(t:^testing.T) {
    gui_:Gui
    a,b:=core.entity_make(1,1),core.entity_make(2,1)
    events:=events_this_frame(&gui_)
    clicked(events,a,"play")
    clicked(events,a,"play")
    clicked(events,b,"play")
    clicked(events,a,"")
    asked_merge(&gui_,events)
    testing.expect_value(t,events.asked_count,0)
    testing.expect_value(t,gui_.names_asked_count,2)
    testing.expect(t,gui_.names_asked[0].name==base.name_hash("play") && gui_.names_asked[0].entity==a,"what was asked, each once")
}

@(test)
the_helpers_read_the_events_of_a_frame :: proc(t:^testing.T) {
    entity:=core.entity_make(1,1)
    gui_:Gui
    defer delete(gui_.arrived.items)
    append(&gui_.arrived.items,
        UI_Event{entity=entity,name=base.name_hash("play"),kind=.Clicked},
        UI_Event{entity=entity,name=base.name_hash("volume"),kind=.Changed,value=0.5},
        UI_Event{entity=entity,kind=.Back},
        UI_Event{kind=.Menu},
    )
    events:=events_this_frame(&gui_)
    testing.expect(t,menu_pressed(events))
    testing.expect(t,clicked(events,entity,"play") && !clicked(events,entity,"quit"))
    value,ok:=changed_value(events,entity,"volume")
    testing.expect(t,ok && value==0.5)
    testing.expect(t,back(events,entity))
    testing.expect(t,!clicked(events_this_frame(nil),entity,"play") && !menu_pressed(nil),"without a Gui there are no events")
}

// A frame step reads an event once, in frames with several ticks and with none.
@(test)
events_this_frame_gives_each_event_once_whatever_ticks_ran :: proc(t:^testing.T) {
    gui:Gui
    events:UI_Events
    defer {delete(gui.pending);delete(gui.arrived.items);delete(events.items)}
    event:=UI_Event{entity=core.entity_make(1,1),name=7,kind=.Clicked}
    read :: proc(t:^testing.T,gui:^Gui,want:int,loc:=#caller_location) {
        testing.expect_value(t,len(events_this_frame(gui).items),want,loc=loc)
    }
    // Two ticks: the second leaves UI_Events empty, this frame still has it, the next one does not.
    append(&gui.pending,event)
    gui_events_deliver(&events,&gui,core.Time{tick=1})
    gui_events_deliver(&events,&gui,core.Time{tick=2})
    testing.expect_value(t,len(events.items),0)
    gui_events_frame(&events,&gui,core.Time{tick=2})
    read(t,&gui,1)
    gui_events_deliver(&events,&gui,core.Time{tick=3})
    gui_events_frame(&events,&gui,core.Time{tick=3})
    read(t,&gui,0)
    // Stopped: no tick runs, and it comes through the frame phase, once.
    append(&gui.pending,event)
    gui_events_frame(&events,&gui,core.Time{tick=3})
    read(t,&gui,1)
    gui_events_frame(&events,&gui,core.Time{tick=3})
    read(t,&gui,0)
    // A tick that runs again gave them already.
    append(&gui.pending,event)
    gui_events_deliver(&events,&gui,core.Time{tick=4})
    gui_events_frame(&events,&gui,core.Time{tick=4})
    gui_events_deliver(&events,&gui,core.Time{tick=4,resimulating=true})
    gui_events_frame(&events,&gui,core.Time{tick=4})
    read(t,&gui,0)
}

@(test)
a_tick_that_runs_again_gets_the_events_it_got :: proc(t:^testing.T) {
    gui:Gui
    events:UI_Events
    defer {delete(gui.pending);delete(gui.arrived.items);delete(events.items)}
    append(&gui.pending,UI_Event{entity=core.entity_make(1,1),name=7,kind=.Clicked})
    gui_events_deliver(&events,&gui,core.Time{tick=5})
    gui_events_deliver(&events,&gui,core.Time{tick=6})
    testing.expect_value(t,len(events.items),0)
    gui_events_deliver(&events,&gui,core.Time{tick=5,resimulating=true})
    testing.expect(t,len(events.items)==1 && events.items[0].name==7)
    gui_events_deliver(&events,&gui,core.Time{tick=6,resimulating=true})
    testing.expect_value(t,len(events.items),0)
    // A save took the clock back: tick 5 of the new run did not get them.
    gui_events_deliver(&events,&gui,core.Time{tick=2})
    gui_events_deliver(&events,&gui,core.Time{tick=5,resimulating=true})
    testing.expect_value(t,len(events.items),0)
}

@(test)
the_top_screen_of_each_player_takes_input_and_the_rest_are_passive :: proc(t:^testing.T) {
    plan:=[?]Planned{
        {order=0,input=.Passive},             // a HUD of the window
        {order=5,input=.Menu},                // a menu, covered by the modal
        {order=9,input=.Modal},               // on top of the window
        {order=20,input=.Menu,hiding=true},   // going away: it takes nothing
        {order=1,input=.Menu,player=1},       // the menu of the first player
        {order=3,input=.Passive,player=1},    // over it, a HUD that takes nothing
        {order=50,world=true,input=.Menu},    // world widgets never take input
    }
    stack_resolve(plan[:])
    tops:=[?]bool{false,false,true,false,true,false,false}
    for entry,i in plan {
        testing.expectf(t,entry.top==tops[i] && entry.passive==!tops[i],"screen %d: top %v passive %v",i,entry.top,entry.passive)
    }
}

@(test)
a_screen_back_on_top_gets_its_focus_back :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,ui.context_init(&ctx,{no_font=true}))
    defer ui.context_destroy(&ctx)
    menu:Instance
    // On top, it keeps what has the focus.
    ui.focus_set(&ctx,ui.Id(11))
    focus_restore(&ctx,&menu,true)
    instance_built(&menu,&Planned{top=true},{present=true})
    menu.focus=ctx.focus
    // Covered by another screen, which moves the focus to its own widgets.
    focus_restore(&ctx,&menu,false)
    instance_built(&menu,&Planned{},{present=true})
    ui.focus_set(&ctx,ui.Id(22))
    // On top again: the focus comes back to where it was.
    focus_restore(&ctx,&menu,true)
    testing.expect_value(t,ctx.focus,ui.Id(11))
    // Still on top, the focus moves as navigation moves it.
    instance_built(&menu,&Planned{top=true},{present=true})
    ui.focus_set(&ctx,ui.Id(33))
    focus_restore(&ctx,&menu,true)
    testing.expect_value(t,ctx.focus,ui.Id(33))
}

@(test)
a_hidden_screen_builds_until_nothing_of_it_shows :: proc(t:^testing.T) {
    gui:Gui
    defer {delete(gui.instances);delete(gui.unblock)}
    e:=core.entity_make(3,1)
    append(&gui.instances,Instance{entity=e,blocking=true})
    instance:=&gui.instances[0]
    testing.expect(t,!screen_hiding(instance)) // never shown: a hidden screen does not start
    gui.frame=1
    instance.seen=1
    instance_built(instance,&Planned{},{present=true})
    testing.expect(t,screen_hiding(instance))
    // Its entity is hidden: it builds hidden while its nodes play as they hide.
    hiding:=Planned{hiding=true}
    instance_built(instance,&hiding,{present=true,animating=true})
    instances_sweep(&gui)
    testing.expect_value(t,len(gui.instances),1)
    testing.expect(t,screen_hiding(&gui.instances[0]))
    // Nothing is left of it: it goes, and the seats it blocked are let go.
    instance_built(&gui.instances[0],&hiding,{present=false})
    testing.expect(t,!screen_hiding(&gui.instances[0]))
    instances_sweep(&gui)
    testing.expect_value(t,len(gui.instances),0)
    testing.expect(t,len(gui.unblock)==1 && gui.unblock[0]==e)
}

@(private="file")
Bind_Test_World :: struct {
    using world:core.Test_World,
    healths:core.Table(Bind_Test_Health),
    match:Bind_Test_Match,
}
@(private="file") Bind_Test_Health :: struct {value:f32,most:f32}

@(private="file") @(storage,setting="machine")
Bind_Test_Match :: struct {seconds:f32}

@(test)
paths_read_the_components_and_storages_of_the_world_by_name :: proc(t:^testing.T) {
    w:Bind_Test_World
    if !core.test_world_init(t,&w) {return}
    defer core.test_world_destroy(&w)
    e:=core.create(&w.entities)
    core.add(&w.healths,e,Bind_Test_Health{3,10})
    core.test_world_settle(&w)
    gui:Gui
    gui.allocator=context.allocator
    defer gui_free(&gui)
    b:=Bind{gui=&gui,world=core.test_world_ref(&w)}
    host:=bind_host(&b)
    // A component, by its name, is the row of the entity with its stamp.
    _,storage,found:=host.source(host.user,base.name_hash("Bind_Test_Health"))
    testing.expect(t,found && !storage)
    data,stamp:=host.fetch(host.user,base.name_hash("Bind_Test_Health"),base.Entity(e))
    testing.expect(t,data!=nil && (^Bind_Test_Health)(data).value==3)
    _,_=core.get(core.read(&w.healths),e)
    _,same:=host.fetch(host.user,base.name_hash("Bind_Test_Health"),base.Entity(e))
    testing.expect_value(t,same,stamp)
    core.get(&w.healths,e).value=4
    _,moved:=host.fetch(host.user,base.name_hash("Bind_Test_Health"),base.Entity(e))
    testing.expect(t,moved!=stamp,"a write moves the stamp")
    none,_:=host.fetch(host.user,base.name_hash("Bind_Test_Health"),base.Entity(core.entity_make(9,1)))
    testing.expect(t,none==nil)
    // A storage has no stamps: its bytes are compared.
    _,storage,found=host.source(host.user,base.name_hash("Bind_Test_Match"))
    testing.expect(t,found && storage)
    data,stamp=host.fetch(host.user,base.name_hash("Bind_Test_Match"),0)
    testing.expect(t,data==&w.match && stamp==0)
    // A control bound to a storage writes it; one bound to a component asks the game.
    testing.expect(t,host.commits(host.user,base.name_hash("Bind_Test_Match")) && !host.commits(host.user,base.name_hash("Bind_Test_Health")))
    _,_,found=host.source(host.user,base.name_hash("Missing"))
    testing.expect(t,!found)

    // With the memory ending at each request in turn, a name that finds none
    // for its source is not found, and with memory enough it is.
    Limit :: struct {owner:runtime.Allocator,remaining:int}
    limit_proc :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
        limit:=(^Limit)(data)
        if size>0 && (mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed) {
            if limit.remaining<=0 {return nil,.Out_Of_Memory}
            limit.remaining-=1
        }
        return limit.owner.procedure(limit.owner.data,mode,size,alignment,old_memory,old_size,loc)
    }
    named,refused:=false,false
    for served:=0;!named && served<64;served+=1 {
        limit:=Limit{context.allocator,served}
        limited:=runtime.Allocator{limit_proc,&limit}
        low:Gui
        low.allocator=limited
        low.sources=make([dynamic]Bound_Source,limited)
        binding:=Bind{gui=&low,world=core.test_world_ref(&w)}
        {
            context.allocator=limited
            low_host:=bind_host(&binding)
            _,_,named=low_host.source(low_host.user,base.name_hash("Bind_Test_Health"))
            row,_:=low_host.fetch(low_host.user,base.name_hash("Bind_Test_Health"),base.Entity(e))
            testing.expectf(t,(row!=nil)==named,"with %d requests served: found %v, its row %v",served,named,row!=nil)
        }
        refused||=!named
        limit.remaining=max(int)
        gui_free(&low)
    }
    testing.expect(t,named && refused,"refused without memory, and with it the source is found")
}

@(test)
tree_events_become_ui_events_with_the_entity_a_drop_came_from :: proc(t:^testing.T) {
    screen,inventory:=core.entity_make(4,2),core.entity_make(7,1)
    drop:=ui.Tree_Event{name=base.name_hash("slot"),kind=.Dropped,item=2,from=base.name_hash("icon"),from_item=5,from_owner=u64(inventory)}
    event:=event_of(screen,drop)
    testing.expect(t,event.entity==screen && event.kind==.Dropped && event.item==2)
    testing.expect(t,event.from==base.name_hash("icon") && event.from_item==5 && event.from_entity==inventory)
    field:=ui.Tree_Event{name=base.name_hash("name"),kind=.Submitted,item=-1}
    _=base.text_set(field.text[:],"Ada")
    events:UI_Events
    defer delete(events.items)
    append(&events.items,event,event_of(screen,field))
    append(&events.items,event_of(screen,{name=base.name_hash("buy"),kind=.Clicked,item=3}))
    append(&events.items,event_of(screen,{name=base.name_hash("fade"),kind=.Finished,from=base.name_hash("out")}))
    append(&events.items,UI_Event{entity=screen,kind=.Back})
    found,dropped_ok:=dropped(&events,screen,"slot")
    testing.expect(t,dropped_ok && found.from_entity==inventory)
    item,clicked_ok:=clicked_item(&events,screen,"buy")
    testing.expect(t,clicked_ok && item==3 && clicked(&events,screen,"buy") && !clicked(&events,inventory,"buy"))
    text,submitted_ok:=submitted(&events,screen,"name")
    testing.expect(t,submitted_ok && text=="Ada")
    testing.expect(t,finished(&events,screen,"fade","out") && !finished(&events,screen,"fade","in"))
    testing.expect(t,back(&events,screen) && !back(&events,inventory))
}

@(test)
prompts_follow_the_bindings_of_the_family :: proc(t:^testing.T) {
    JUMP,MOVE,LOOK :: inp.Action(20),inp.Action(21),inp.Action(1)
    m:inp.Input_Map
    inp.input_map_action(&m,JUMP,.Button)
    inp.input_map_bind(&m,JUMP,inp.binding_key(.Space))
    inp.input_map_bind(&m,JUMP,inp.binding_gamepad_button(.South))
    inp.input_map_bind(&m,JUMP,inp.binding_gamepad_button(.North,gamepad=2))
    inp.input_map_action(&m,MOVE,.Axis2)
    inp.input_map_bind(&m,MOVE,inp.binding_keys(.A,.D,.S,.W))
    inp.input_map_bind(&m,MOVE,inp.binding_gamepad_stick(.Left))
    inp.input_map_bind(&m,MOVE,{count=4,gamepad=inp.GAMEPAD_ANY,codes={{.Gamepad_Button,u8(core.Gamepad_Button.Dpad_Left)},{.Gamepad_Button,u8(core.Gamepad_Button.Dpad_Right)},{.Gamepad_Button,u8(core.Gamepad_Button.Dpad_Down)},{.Gamepad_Button,u8(core.Gamepad_Button.Dpad_Up)}}})
    inp.input_map_action(&m,LOOK,.Axis2)
    inp.input_map_bind(&m,LOOK,inp.binding_mouse_delta())
    out:[ui.PROMPT_CAPACITY]ui.Prompt
    count:=prompts_of(&m,JUMP,.Keyboard,-1,out[:])
    testing.expect(t,count==1 && out[0].input==.Key && out[0].text=="Space")
    count=prompts_of(&m,JUMP,.PlayStation,0,out[:])
    testing.expect(t,count==1 && out[0].input==.South && out[0].family==.PlayStation)
    count=prompts_of(&m,JUMP,.Xbox,-1,out[:])
    testing.expect(t,count==2 && out[1].input==.North)
    count=prompts_of(&m,MOVE,.Keyboard,-1,out[:])
    testing.expect(t,count==4 && out[0].text=="A" && out[3].text=="W")
    count=prompts_of(&m,MOVE,.Nintendo,-1,out[:])
    testing.expect(t,count==2 && out[0].input==.Stick_Left && out[1].input==.Dpad)
    count=prompts_of(&m,LOOK,.Keyboard,-1,out[:])
    testing.expect(t,count==1 && out[0].input==.Mouse_Move)
    testing.expect_value(t,prompts_of(&m,LOOK,.Xbox,-1,out[:]),0)

    // A chord comes first, joined by a Plus; a family that does not show it shows nothing of that binding.
    inp.input_map_unbind(&m,JUMP)
    inp.input_map_bind(&m,JUMP,inp.binding_chord(inp.binding_key(.S),inp.code_key(.Left_Control)))
    inp.input_map_bind(&m,JUMP,inp.binding_chord(inp.binding_gamepad_button(.South),inp.code_key(.Left_Shift)))
    count=prompts_of(&m,JUMP,.Keyboard,-1,out[:])
    testing.expect(t,count==3 && out[0].text=="Left_Control" && out[1].input==.Plus && out[2].text=="S")
    testing.expect_value(t,prompts_of(&m,JUMP,.Xbox,-1,out[:]),0)
}

@(test)
the_dpad_and_the_stick_navigate_and_repeat_while_held :: proc(t:^testing.T) {
    pads:[core.GAMEPAD_CAPACITY]core.Gamepad
    pads[1]={connected=true,down={.Dpad_Down},pressed={.Dpad_Down,.South}}
    r:Pad_Repeat
    testing.expect_value(t,pad_input(&r,pads[:],-1,0.016),ui.Pads{.Down,.Accept})
    // Another player's gamepad does not reach this one.
    other:Pad_Repeat
    testing.expect_value(t,pad_input(&other,pads[:],0,0.016),ui.Pads{})
    pads[1].pressed={}
    testing.expect_value(t,pad_input(&r,pads[:],-1,0.3),ui.Pads{})
    testing.expect_value(t,pad_input(&r,pads[:],-1,0.15),ui.Pads{.Down}) // past the delay it repeats
    testing.expect_value(t,pad_input(&r,pads[:],-1,0.05),ui.Pads{})
    testing.expect_value(t,pad_input(&r,pads[:],-1,0.06),ui.Pads{.Down})
    // The stick past half its travel is a direction too.
    pads[1].down={}
    pads[1].axes[.Left_X]=0.8
    testing.expect_value(t,pad_input(&r,pads[:],-1,0.016),ui.Pads{.Right})
    testing.expect_value(t,pad_input(&r,pads[:],1,0.016),ui.Pads{})
}

@(test)
the_family_of_a_player_follows_the_devices_it_has :: proc(t:^testing.T) {
    pads:[core.GAMEPAD_CAPACITY]core.Gamepad
    pads[0]={connected=true,family=.PlayStation}
    pads[1]={connected=true,family=.Nintendo}
    first,second:ui.Prompt_Family
    // The first player has the keyboard and gamepad 0; the second, gamepad 1.
    used :: proc(first,second:^ui.Prompt_Family,device:core.Device,pads:[]core.Gamepad) {
        family_update(first,device,pads,true,0)
        family_update(second,device,pads,false,1)
    }
    used(&first,&second,{gamepad=true,slot=0},pads[:])
    testing.expect(t,first==.PlayStation && second==.Keyboard)
    used(&first,&second,{gamepad=true,slot=1},pads[:])
    testing.expect(t,first==.PlayStation && second==.Nintendo)
    used(&first,&second,{},pads[:])
    testing.expect(t,first==.Keyboard && second==.Nintendo)
}

@(test)
a_context_without_changes_or_input_shows_its_last_frame :: proc(t:^testing.T) {
    s:Surface
    key:=Surface_Key{size={1280,720},scale=1,density=1}
    input:=ui.Input{size={1280,720},pointer={10,10}}
    testing.expect(t,!surface_skips(&s,false,input,key,{},false)) // nothing shown yet
    s.shown,s.key,s.input=true,key,input
    testing.expect(t,surface_skips(&s,false,input,key,{},false))
    testing.expect(t,!surface_skips(&s,true,input,key,{},false))  // a ui step draws in it
    testing.expect(t,!surface_skips(&s,false,input,key,{},true))  // an interface changed
    moved:=input
    moved.pointer={11,10}
    testing.expect(t,!surface_skips(&s,false,moved,key,{},false))
    moved.pointer_absent=true
    s.input.pointer_absent=true
    testing.expect(t,surface_skips(&s,false,moved,key,{},false))  // a pointer that is absent moves nothing
    pressed:core.Input
    pressed.gamepads[2].pressed={.North}
    testing.expect(t,!surface_skips(&s,false,input,key,pressed,false))
    resized:=key
    resized.scale=1.5
    testing.expect(t,!surface_skips(&s,false,input,resized,{},false))
    s.viewed=true
    testing.expect(t,!surface_skips(&s,false,input,key,{},false))  // a camera is drawn every frame
}

@(test)
the_reference_scales_the_interfaces_with_the_scale_of_the_player :: proc(t:^testing.T) {
    testing.expect_value(t,surface_scale({1920,1080},{reference={1280,720}},1),f32(1.5))
    testing.expect_value(t,surface_scale({960,540},{reference={1280,720}},2),f32(1.5))
    testing.expect_value(t,surface_scale({1920,1080},{},0),f32(1))
}

@(test)
a_modal_on_top_blocks_the_seats_it_covers_until_it_leaves :: proc(t:^testing.T) {
    w:Seats_Test_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    first,second,menu,pause:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    core.add(&w.seats,first,inp.Seat{})
    core.add(&w.seats,second,inp.Seat{slot=1})
    core.test_world_settle(&w)
    state:inp.Seats
    requests:inp.Seat_Requests
    defer delete(requests.items)
    contexts:inp.Input_Contexts
    context_requests:inp.Context_Requests
    defer delete(context_requests.items)
    gui:Gui
    defer {delete(gui.instances);delete(gui.unblock)}
    append(&gui.instances,Instance{entity=menu,modal=true,taking=true,player=2},Instance{entity=pause,modal=true,taking=true})
    testing.expect(t,modal_apply(&gui,{&state},core.read(&w.seats),&requests,{&contexts},&context_requests))
    testing.expect_value(t,len(requests.items),2)
    testing.expect(t,requests.items[0].kind==.Block_Add && requests.items[0].seat==second && requests.items[0].owner==menu)
    testing.expect(t,requests.items[1].kind==.Block_Add && requests.items[1].seat==core.NONE && requests.items[1].owner==pause)
    testing.expect_value(t,len(context_requests.items),0)
    clear(&requests.items)
    // Applied by input, the blocks are not asked again.
    state.blocks[0]={owner=menu,seat=second,mask=inp.ALL_ACTIONS,active=true}
    state.blocks[1]={owner=pause,mask=inp.ALL_ACTIONS,active=true}
    testing.expect(t,modal_apply(&gui,{&state},core.read(&w.seats),&requests,{&contexts},&context_requests) && len(requests.items)==0)
    // Off the top, or gone, they give the seats back.
    gui.instances[0].modal,gui.instances[0].taking=false,false
    pop(&gui.instances)
    append(&gui.unblock,pause)
    testing.expect(t,!modal_apply(&gui,{&state},core.read(&w.seats),&requests,{&contexts},&context_requests))
    testing.expect_value(t,len(requests.items),2)
    testing.expect(t,requests.items[0].kind==.Block_Remove && requests.items[1].kind==.Block_Remove)
    testing.expect(t,!gui.instances[0].blocking)
}

// What a Modal takes from the seats it covers, its own buttons still get:
// they read the actions they name past its block, and the game does not.
@(test)
the_buttons_of_a_modal_get_the_actions_it_takes_from_the_game :: proc(t:^testing.T) {
    DROP :: inp.Action(4)
    w:Seats_Test_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    seat,inventory,cinematic:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    core.add(&w.seats,seat,inp.Seat{})
    core.test_world_settle(&w)
    bindings:inp.Input_Map
    inp.input_map_action(&bindings,DROP,.Button)
    inp.input_map_bind(&bindings,DROP,inp.binding_key(.X))
    device:=core.Input{keys_down={.X},keys_pressed={.X}}
    inp.seat_feed(core.get(&w.seats,seat),&device,&bindings,false)
    state:inp.Seats
    state.blocks[0]={owner=inventory,mask=inp.ALL_ACTIONS,active=true}
    core.get(&w.seats,seat).blocked=inp.ALL_ACTIONS
    names:=[1]core.Name_Info{{type=inp.Action,value=i64(DROP),name="drop_item"}}
    info:=core.test_world_info(&w)
    info.names=names[:]
    core.test_info_index(info)
    app:=new(host.App)
    defer free(app)
    app.info=info
    gui:Gui
    defer delete(gui.actions)
    instance:=Instance{entity=inventory}
    src:=Source{gui=&gui,app=app,player=1,seat=seat,seat_state=&state,seats=core.read(&w.seats),building=&instance}
    down,pressed:=source_action(&src,base.name_hash("drop_item"))
    testing.expect(t,down && pressed)
    testing.expect(t,!inp.seat_action(core.read(&w.seats),seat,DROP).down,"the game does not get it")
    instance.entity=cinematic
    down,pressed=source_action(&src,base.name_hash("drop_item"))
    testing.expect(t,!down && !pressed,"another interface does not read past the block of the Modal")
}

// A screen on top with an input context puts the seats it covers in it,
// modal for a Modal, instead of blocking them, and takes them out as it leaves.
@(test)
a_screen_with_an_input_context_puts_the_seats_it_covers_in_it :: proc(t:^testing.T) {
    MENU :: inp.Input_Context(1)
    w:Seats_Test_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    inventory:=core.create(&w.entities)
    state:inp.Seats
    requests:inp.Seat_Requests
    defer delete(requests.items)
    contexts:inp.Input_Contexts
    context_requests:inp.Context_Requests
    defer delete(context_requests.items)
    gui:Gui
    defer {delete(gui.instances);delete(gui.unblock)}
    append(&gui.instances,Instance{entity=inventory,modal=true,taking=true,input_context=MENU})
    testing.expect(t,modal_apply(&gui,{&state},core.read(&w.seats),&requests,{&contexts},&context_requests))
    testing.expect_value(t,len(requests.items),0)
    if testing.expect_value(t,len(context_requests.items),1) {
        r:=context_requests.items[0]
        testing.expect(t,!r.leave && r.owner==inventory && r.seat==core.NONE && r.input_context==MENU && r.modal)
    }
    clear(&context_requests.items)
    // Applied by input, it is not asked again.
    contexts.entries[0]={owner=inventory,input_context=MENU,modal=true,active=true}
    testing.expect(t,modal_apply(&gui,{&state},core.read(&w.seats),&requests,{&contexts},&context_requests) && len(context_requests.items)==0)
    gui.instances[0].modal,gui.instances[0].taking=false,false
    testing.expect(t,!modal_apply(&gui,{&state},core.read(&w.seats),&requests,{&contexts},&context_requests))
    testing.expect(t,len(context_requests.items)==1 && context_requests.items[0].leave && !gui.instances[0].entered)
}

@(test)
a_screen_kept_from_its_last_frame_is_built_again_for_another_device_or_language :: proc(t:^testing.T) {
    app:=new(host.App)
    defer free(app)
    instance:Instance
    entry:Planned
    ctx:ui.Context
    rect:=[4]f32{0,0,800,600}
    first:=screen_key(app.assets,&ctx,&instance,&entry,0,rect)
    ctx.game.family=.PlayStation
    pad:=screen_key(app.assets,&ctx,&instance,&entry,0,rect)
    testing.expect(t,pad!=first,"the prompts of another device")
    ctx.game.language=7
    testing.expect(t,screen_key(app.assets,&ctx,&instance,&entry,0,rect)!=pad,"the texts of another language")
}

@(test)
events_go_to_the_frame_phase_while_no_tick_runs :: proc(t:^testing.T) {
    gui:Gui
    events:UI_Events
    defer {delete(gui.pending);delete(gui.arrived.items);delete(events.items)}
    // A tick ran in the frame: the frame phase leaves it its events.
    append(&gui.pending,UI_Event{name=7,kind=.Clicked})
    gui_events_deliver(&events,&gui,core.Time{tick=4})
    gui_events_frame(&events,&gui,core.Time{tick=5})
    testing.expect(t,len(events.items)==1 && events.items[0].name==7 && gui.deliveries==1)
    // The time stopped: what the next frame drew goes to its frame phase, once.
    append(&gui.pending,UI_Event{name=8,kind=.Clicked})
    gui_events_frame(&events,&gui,core.Time{tick=5})
    testing.expect(t,len(events.items)==1 && events.items[0].name==8 && len(gui.pending)==0 && gui.deliveries==2)
    gui_events_frame(&events,&gui,core.Time{tick=5})
    testing.expect_value(t,len(events.items),0)
    // A tick that runs again later does not get them.
    gui_events_deliver(&events,&gui,core.Time{tick=5,resimulating=true})
    testing.expect_value(t,len(events.items),0)
}

@(test)
the_last_event_of_a_kind_is_what_a_widget_asks_for :: proc(t:^testing.T) {
    screen:=core.entity_make(4,2)
    events:UI_Events
    defer delete(events.items)
    typed :: proc(kind:ui.Tree_Event_Kind,text:string) -> ui.Tree_Event {
        e:=ui.Tree_Event{name=base.name_hash("name"),kind=kind,item=-1}
        _=base.text_set(e.text[:],text)
        return e
    }
    append(&events.items,event_of(screen,typed(.Changed,"A")),event_of(screen,typed(.Submitted,"Ad")))
    append(&events.items,event_of(screen,typed(.Changed,"Ada")),event_of(screen,typed(.Submitted,"Ada")))
    text,ok:=changed_text(&events,screen,"name")
    testing.expect(t,ok && text=="Ada")
    text,ok=submitted(&events,screen,"name")
    testing.expect(t,ok && text=="Ada")
    _,ok=changed_text(&events,screen,"other")
    testing.expect(t,!ok)
}

@(test)
a_screen_that_shows_a_camera_or_particles_is_built_every_frame :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,ui.context_init(&ctx,{no_font=true}))
    defer ui.context_destroy(&ctx)
    gui:Gui
    instance:=Instance{shown=true}
    entry:Planned
    testing.expect(t,screen_retains(&gui,&ctx,&instance,&entry))
    // Drawn again from what it drew, it would show a texture its source let go.
    instance.live=true
    testing.expect(t,!screen_retains(&gui,&ctx,&instance,&entry))
}

@(test)
the_instances_of_an_entity_are_found_after_others_go :: proc(t:^testing.T) {
    gui:Gui
    defer {delete(gui.instances);delete(gui.unblock);core.entity_map_destroy(&gui.index)}
    a,b:=core.entity_make(1,1),core.entity_make(2,1)
    put :: proc(gui:^Gui,e:core.Entity,slot:int) {
        slots:=core.entity_map_get(&gui.index,e)
        if slots==nil {slots,_=core.entity_map_put(&gui.index,e,Instance_Slots{})}
        append(&gui.instances,Instance{entity=e,slot=slot})
        slots[slot]=i32(len(gui.instances))
    }
    put(&gui,a,0);put(&gui,b,instance_slot(true,2));put(&gui,a,instance_slot(true,0))
    gui.frame=1
    gui.instances[1].seen,gui.instances[2].seen=1,1
    // The screen of a goes and the last instance takes its place.
    instances_sweep(&gui)
    testing.expect_value(t,len(gui.instances),2)
    testing.expect(t,instance_find(&gui,a,0)==nil)
    widget:=instance_find(&gui,a,instance_slot(true,0))
    testing.expect(t,widget!=nil && widget.entity==a && widget.slot==1)
    other:=instance_find(&gui,b,instance_slot(true,2))
    testing.expect(t,other!=nil && other.entity==b)
    gui.frame=2
    instances_sweep(&gui)
    testing.expect(t,len(gui.instances)==0 && core.entity_map_get(&gui.index,a)==nil && core.entity_map_get(&gui.index,b)==nil)
}

@(test)
a_fixed_panel_shows_its_face_toward_the_forward_of_its_entity :: proc(t:^testing.T) {
    rotation:=panel_rotation(quaternion128(1))
    face:=linalg.quaternion_mul_vector3(rotation,[3]f32{0,0,1})
    right:=linalg.quaternion_mul_vector3(rotation,[3]f32{1,0,0})
    testing.expect(t,linalg.distance(face,[3]f32{0,0,-1})<1e-5,"it faces -Z, as any entity")
    testing.expect(t,linalg.distance(right,[3]f32{-1,0,0})<1e-5,"so what looks at it reads it from left to right")
    // Half a turn more and the panel looks at +Z.
    turned:=panel_rotation(quaternion128(quaternion(w=0,x=0,y=1,z=0)))
    testing.expect(t,linalg.distance(linalg.quaternion_mul_vector3(turned,[3]f32{0,0,1}),[3]f32{0,0,1})<1e-5)
}

@(test)
widgets_out_of_sight_are_not_built_and_the_nearest_come_first :: proc(t:^testing.T) {
    view:=Player_View{camera={position={0,0,5},forward={0,0,-5},up={0,1,0},fov_y=90,near=0.1,far=100},rect={0,0,1000,1000}}
    widget:=WORLD_WIDGET_DEFAULT
    _,ahead:=widget_seen(&view,widget,{0,0,0},{},1)
    _,behind:=widget_seen(&view,widget,{0,0,10},{},1)
    _,aside:=widget_seen(&view,widget,{20,0,4},{},1)
    _,edge:=widget_seen(&view,widget,{5.5,0,0},{},1) // its panel, 2 m wide, reaches into the view
    testing.expect(t,ahead && !behind && !aside && edge)
    // A Screen widget keeps the size of the screens: the reference fitted to the view, times the
    // player's scale; a Meters one does not change.
    on_screen:=widget
    on_screen.sizing,on_screen.scale=.Screen,2
    testing.expect_value(t,widget_unit(&view,on_screen,{},1),f32(2))
    testing.expect_value(t,widget_unit(&view,on_screen,{reference={2000,1000}},1),f32(1))
    testing.expect_value(t,widget_unit(&view,on_screen,{reference={2000,1000}},1.5),f32(1.5))
    testing.expect_value(t,widget_unit(&view,widget,{reference={2000,1000}},1.5),widget.scale)
    app:host.App
    _,mesh:=mesh_seen(app.renderer,&app.extras,&view,core.Entity(7),{0,0,10})
    testing.expect(t,mesh,"a mesh not drawn yet is seen: the frame that draws it says where it is")
    candidates:=[?]Widget_Candidate{{player=1,distance=3},{player=0,distance=9},{player=1,distance=1},{player=0,distance=2}}
    sort_candidates(candidates[:])
    testing.expect(t,candidates[0].distance==2 && candidates[1].distance==9 && candidates[2].distance==1 && candidates[3].distance==3)
}

@(test)
the_depth_read_around_the_ray_hides_what_is_behind_where_the_point_falls_in_its_frame :: proc(t:^testing.T) {
    camera:=gpu.Camera{position={0,0,5},forward={0,0,-1},up={0,1,0},fov_y=90,near=0.1}
    view:=Player_View{camera=camera,index=1}
    probes:=[2]gpu.Depth_Probe_Result{{probe={pixel={10,10},view=0,camera=camera,size={1000,600}}},{probe={pixel={500,300},view=1,camera=camera,size={1000,600}}}}
    for &cell in probes[1].cells {cell=3} // a wall 3 m along the view
    view.depth=probe_nearest(probes[:],1,{520,300})
    testing.expect(t,view.depth==&probes[1],"the probe of its view")
    testing.expect(t,scene_hides(&view,{0,0,0},1.01,0.02),"5 m along the view is behind the wall")
    testing.expect(t,!scene_hides(&view,{0,0,2.5},1.01,0.02),"2.5 m is in front of it")
    testing.expect(t,!scene_hides(&view,{0,0,2},1.01,0.02),"on the wall it is what the scene shows")
    // A point off the pixel of the probe falls in the cell where its frame shows it.
    testing.expect(t,scene_hides(&view,{0.1,0,0},1.01,0.02))
    // Out of the patch the probe cannot say, and nothing is reached there until one reads it.
    testing.expect(t,scene_hides(&view,{4,0,0},1.01,0.02))
    for &cell in probes[1].cells {cell=0}
    testing.expect(t,!scene_hides(&view,{0,0,0},1.01,0.02),"where nothing is drawn nothing hides")
    view.depth=nil
    testing.expect(t,!scene_hides(&view,{4,0,0},1.01,0.02),"without a probe yet nothing is known to be in the way")
}

@(test)
what_a_frame_nests_too_deep_is_a_problem_of_the_frame_that_did_it :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,ui.context_init(&ctx,{no_font=true}))
    defer ui.context_destroy(&ctx)
    problems:=new(core.Problems,context.temp_allocator)
    s:=Surface{ctx=&ctx}
    for deep in ([]bool{true,false}) {
        ui.frame_begin(&ctx,{size={100,100}})
        if deep {
            for i in 0..=ui.ID_STACK_DEPTH {ui.id_push(&ctx,ui.id(&ctx,"scope",i+1))}
            for _ in 0..=ui.ID_STACK_DEPTH {ui.id_pop(&ctx)}
        }
        ui.frame_end(&ctx)
        nesting_report(&s,problems)
    }
    problem:=core.problem_find(problems,core.NONE,"gui.nesting")
    testing.expect(t,problem!=nil && problem.count==1)
}
