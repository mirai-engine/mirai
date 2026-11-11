package gui

import "mirai:core"
import inp "mirai:engine/input"
import "mirai:host"
import "mirai:platform"

// What the screens ask of the game and the window: the Menu action, the clock
// and the mouse. A game writes none of it: a screen says Modal and pause, and
// the mouse is the game's while the seat with it drives a body the mouse
// turns and no Modal is up. A cursor that stays free needs a seat that drives
// nothing, a look not bound to the mouse, or a Modal screen.

// The menu of the game: what opens and closes it (menu_pressed).
@(actions)
Menu_Action :: enum u8 {Menu}

// The bindings of the menu action when Input_Settings does not name it.
menu_action_defaults :: proc "contextless" () -> [Menu_Action]inp.Action_Bindings {
    return {.Menu=inp.action_default_in(inp.CONTEXT_ALWAYS,.Button,inp.binding_key(.Escape),inp.binding_gamepad_button(.Start))}
}

// Whether a screen stops the clock this frame.
screen_pauses :: proc "contextless" (screen:UI_Screen,hiding:bool) -> bool {
    return screen.pause && screen.input==.Modal && !hiding
}

@(private)
menu_report :: proc(gui:^Gui,pressed:bool) {
    if pressed && !gui.escape_used {append(&gui.pending,UI_Event{entity=core.NONE,kind=.Menu,item=-1,from_item=-1})}
}

// The clock is held while a pause screen shows, and given back when none
// does. A network session does not stop it, and the clock the game itself
// stopped is not the screen's to give back.
@(private)
clock_apply :: proc(gui:^Gui,paused:bool,requests:^core.Clock_Requests,role:core.Network_Role) {
    wanted:=gui.pausing && role==.Standalone
    if wanted==gui.clock_held || wanted && paused {return}
    gui.clock_held=wanted
    if wanted {
        core.pause(requests)
    } else if role!=.Client {
        core.resume(requests)
    }
}

// Whether the game should hold the mouse.
mouse_wanted :: proc(seats:core.Read(inp.Seat),drivables:core.Read(inp.Drivable),state:^inp.Seats,bindings:^inp.Input_Map,look:inp.Action,modal:bool) -> bool {
    if modal || !inp.action_reads_mouse(bindings,look) {return false}
    return inp.body_of(drivables,inp.focused(state,seats))!=core.NONE
}

// After the screens have ended: what they ask of the game and the window.
// The mouse waits while the editor has it, or for a world the window does not see.
@(step="ui",stage="end",after="gui_frame_end")
gui_window_apply :: proc(
    gui:^Gui,app:^host.App,menu:inp.Frame_Input_Of(Menu_Action),look:inp.Frame_Input_Of(inp.Look_Action),seats:core.Read(inp.Seat),drivables:core.Read(inp.Drivable),state:core.Ref(inp.Seats),bindings:core.Ref(inp.Input_Map),
    clock:core.Ref(core.Clock),clock_requests:^core.Clock_Requests,network:core.Ref(core.Network),
) {
    if gui==nil {return}
    menu_report(gui,inp.pressed(menu,.Menu))
    clock_apply(gui,clock.paused,clock_requests,network.role)
    if app.platform==nil || app.renderer==nil || app.game_input_blocked || app.game_mouse_off {return}
    if wanted:=mouse_wanted(seats,drivables,state.ptr,bindings.ptr,inp.action_of(look,.Look),gui.modal_up);wanted!=platform.window_relative_mouse(app.platform) {
        platform.window_set_relative_mouse(app.platform,wanted)
    }
}
