package gui

import "core:testing"
import "mirai:core"
import inp "mirai:engine/input"

// Only a Modal screen that shows and does not hide pauses.
@(test)
a_screen_pauses_only_when_it_is_modal_and_shows :: proc(t:^testing.T) {
    cases:=[?]struct{screen:UI_Screen,hiding,want:bool}{
        {{pause=true,input=.Modal},false,true},
        {{pause=true,input=.Modal},true,false},
        {{pause=true,input=.Menu},false,false},
        {{input=.Modal},false,false},
    }
    for c in cases {testing.expect_value(t,screen_pauses(c.screen,c.hiding),c.want)}
}

// A pause screen stops the clock of a game alone and gives it back when it
// goes; a network session never stops it, and a clock the game stopped is not
// the screen's to give back.
@(test)
a_pause_screen_stops_the_clock_only_in_a_game_alone :: proc(t:^testing.T) {
    requests:core.Clock_Requests
    defer delete(requests.queue.items)
    kind :: proc(r:^core.Clock_Requests) -> (core.Clock_Request_Kind,bool) {
        if len(r.queue.items)==0 {return .Pause,false}
        k:=r.queue.items[0].kind
        clear(&r.queue.items)
        return k,true
    }

    alone:Gui
    alone.pausing=true
    clock_apply(&alone,false,&requests,.Standalone)
    got,asked:=kind(&requests)
    testing.expect(t,asked && got==.Pause && alone.clock_held)
    clock_apply(&alone,true,&requests,.Standalone)
    _,asked=kind(&requests)
    testing.expect(t,!asked,"it asks once")
    alone.pausing=false
    clock_apply(&alone,true,&requests,.Standalone)
    got,asked=kind(&requests)
    testing.expect(t,asked && got==.Resume && !alone.clock_held)

    for role in ([]core.Network_Role{.Server,.Client}) {
        session:Gui
        session.pausing=true
        clock_apply(&session,false,&requests,role)
        _,asked=kind(&requests)
        testing.expectf(t,!asked && !session.clock_held,"a %v does not stop the clock",role)
    }

    // A game that stopped the clock itself keeps it stopped after the menu.
    own:Gui
    own.pausing=true
    clock_apply(&own,true,&requests,.Standalone)
    _,asked=kind(&requests)
    testing.expect(t,!asked && !own.clock_held)
    own.pausing=false
    clock_apply(&own,true,&requests,.Standalone)
    _,asked=kind(&requests)
    testing.expect(t,!asked,"the clock the game stopped stays")

    // A game alone that became a client leaves the clock to the server.
    joined:Gui
    joined.pausing=true
    clock_apply(&joined,false,&requests,.Standalone)
    _,_=kind(&requests)
    joined.pausing=false
    clock_apply(&joined,true,&requests,.Client)
    _,asked=kind(&requests)
    testing.expect(t,!asked && !joined.clock_held,"a client does not resume the clock")
}

// The Menu action becomes one event, unless an interface used that Escape.
@(test)
the_menu_action_is_reported_unless_an_interface_used_escape :: proc(t:^testing.T) {
    gui_:Gui
    defer delete(gui_.pending)
    menu_report(&gui_,false)
    testing.expect_value(t,len(gui_.pending),0)
    gui_.escape_used=true
    menu_report(&gui_,true)
    testing.expect_value(t,len(gui_.pending),0)
    gui_.escape_used=false
    menu_report(&gui_,true)
    delivered:UI_Events
    delivered.items=gui_.pending
    testing.expect(t,len(gui_.pending)==1 && menu_pressed(&delivered))
}

// The mouse is captured while the seat with it drives a body whose look the
// mouse turns and no Modal is up.
@(test)
the_mouse_is_captured_while_the_seat_with_it_drives_a_body_with_look :: proc(t:^testing.T) {
    w:Seats_Test_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    bindings:inp.Input_Map
    LOOK :: inp.Action(0)
    inp.input_map_action(&bindings,LOOK,.Axis2)
    state:=inp.Seats{local_count=1}
    seat,body:=core.create(&w.entities),core.create(&w.entities)
    core.add(&w.seats,seat,inp.Seat{})
    core.add(&w.drivables,body,inp.Drivable{})
    core.test_world_settle(&w)

    wants:=proc(seats:^core.Table(inp.Seat),drivables:^core.Table(inp.Drivable),state:^inp.Seats,bindings:^inp.Input_Map,modal:bool) -> bool {
        return mouse_wanted(core.read(seats),core.read(drivables),state,bindings,LOOK,modal)
    }
    testing.expect(t,!wants(&w.seats,&w.drivables,&state,&bindings,false),"the mouse does not turn its look")
    inp.input_map_bind(&bindings,LOOK,inp.binding_gamepad_stick(.Right))
    testing.expect(t,!wants(&w.seats,&w.drivables,&state,&bindings,false),"a stick does not need the mouse")
    inp.input_map_bind(&bindings,LOOK,inp.binding_mouse_delta())
    testing.expect(t,!wants(&w.seats,&w.drivables,&state,&bindings,false),"no body driven")
    core.edit(&w.drivables,body).seat=seat
    testing.expect(t,wants(&w.seats,&w.drivables,&state,&bindings,false))
    testing.expect(t,!wants(&w.seats,&w.drivables,&state,&bindings,true),"a Modal frees it")
}
