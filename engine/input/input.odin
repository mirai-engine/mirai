package input

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "mirai:core"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"
import si "mirai:std/input"
import "mirai:std/math"

// Input actions. A game reads actions (JUMP, MOVE) instead of keys; the
// Input_Map says which keys, mouse buttons, mouse movement and gamepad
// controls drive each one. The Actions of a seat are computed once per fixed
// tick from the core.Input of the tick and from its own state of the tick before, so a tick
// simulated again gives the same.
//
// Each library declares its actions as an enum @(actions), and beside it the
// defaults of the ones it wants driven (Action_Bindings). The map is built in
// the first input phase, and again whenever Input_Settings changes: those
// defaults, and over them the actions the setting names (settings.odin). A
// step reads the actions of an enum through Input_Of(E).

ACTION_CAPACITY :: 64
ACTION_BINDINGS :: 8 // bindings of one action
GAMEPAD_ANY :: u8(core.GAMEPAD_CAPACITY) // the buttons of every gamepad joined, and of each axis the widest value

// An input action of the world: what the map, a seat, a mask and data that
// names an action hold. Its values are the members of the @(actions) enums,
// which the generator places one library after the other (core/names.odin):
// Walk_Action.Jump is "jump". Code that needs the value of a member asks its
// Input_Of (action_of).
@(names,actions)
Action :: distinct u8

// Bit i is the action of value i.
@(name_bits="Action")
Action_Mask :: distinct u64

ALL_ACTIONS :: max(Action_Mask)

action_bit :: #force_inline proc "contextless" (action:Action) -> Action_Mask {return Action_Mask(1)<<u64(action)}

// A set of actions a seat takes only while it is in it (contexts.odin). Its
// values are the constants of this type in any package, below
// CONTEXT_CAPACITY: MENU :: input.Input_Context(1) is "menu".
@(names)
Input_Context :: distinct u8

CONTEXT_CAPACITY :: 16

// The context of the actions that name none, which every seat is always in.
@(name="base") CONTEXT_BASE : Input_Context : 0

// The context of an action that reads input whatever a seat is in, under what
// a higher layer takes: the menu of the game, which a modal context must not
// silence. Its value is reserved.
@(name="always") CONTEXT_ALWAYS : Input_Context : CONTEXT_CAPACITY-1

CHORD_CAPACITY :: si.CHORD_CAPACITY

// How a player looks around (Axis2: x right, y up, in points of mouse
// movement): it turns the look of the body its seat drives, or a camera that
// orbits it. The sensitivity of a player is the scale of its bindings.
// The mouse moves it by a displacement; a stick or keys bound with it turn it
// at a rate (actions_update), so a stick held turns as far at any frame rate.
@(actions)
Look_Action :: enum u8 {Look}

// Where a player moves the body its seat drives (Axis2: x right, y forward).
@(actions)
Move_Action :: enum u8 {Move}

move_action_defaults :: proc "contextless" () -> [Move_Action]Action_Bindings {
    return {.Move=action_default(.Axis2,binding_keys(.A,.D,.S,.W),binding_gamepad_stick(.Left))}
}

// Radians the look turns per unit of the look action: a point of mouse movement.
LOOK_SPEED :: f32(0.12*math.RAD_PER_DEG)

// Points a second a look stick held all the way turns: 270 degrees, Lyra's default pitch rate (its
// yaw is 450 with a response curve that slows the middle of the stick; this stick is linear).
LOOK_STICK :: f32(270*math.RAD_PER_DEG)/LOOK_SPEED

// The bindings of look when Input_Settings does not name it.
look_action_defaults :: proc "contextless" () -> [Look_Action]Action_Bindings {
    return {.Look=action_default(.Axis2,binding_mouse_delta(),binding_gamepad_stick(.Right,LOOK_STICK))}
}

Action_Kind :: si.Action_Kind
TAP_SECONDS :: si.TAP_SECONDS
HOLD_SECONDS :: si.HOLD_SECONDS
Action_State :: si.Action_State

// The dead zone of a binding that leaves it at 0: an axis pressed as a
// button, one axis, and the radial one of a stick.
DEAD_ZONE_BUTTON :: f32(0.5)
DEAD_ZONE_AXIS :: f32(0.15)
DEAD_ZONE_STICK :: f32(0.2)

Input_Device :: enum u8 {None,Key,Mouse_Button,Mouse_Axis,Gamepad_Button,Gamepad_Axis}

// Movement of the mouse and the wheel since the previous tick, in window
// points. Y is positive upward, like the Y of a gamepad stick in an action.
Mouse_Axis :: enum u8 {X,Y,Wheel_X,Wheel_Y}

Gamepad_Stick :: enum u8 {Left,Right}

// An input a binding reads, named as the enums of core name it: the keys, the
// mouse buttons and axes with Mouse_ before them (and the wheel as Wheel_X
// and Wheel_Y), and the gamepad buttons and axes. The codes of a device follow
// the order of its enum (code_device).
Input_Code :: enum u8 {
    None,
    A,B,C,D,E,F,G,H,I,J,K,L,M,N,O,P,Q,R,S,T,U,V,W,X,Y,Z,
    Zero,One,Two,Three,Four,Five,Six,Seven,Eight,Nine,
    F1,F2,F3,F4,F5,F6,F7,F8,F9,F10,F11,F12,
    Escape,Enter,Tab,Space,Backspace,Delete,Insert,
    Home,End,Page_Up,Page_Down,Left,Right,Up,Down,
    Left_Shift,Right_Shift,Left_Control,Right_Control,Left_Alt,Right_Alt,Left_Super,Right_Super,
    Minus,Equals,Left_Bracket,Right_Bracket,Semicolon,Apostrophe,Comma,Period,Slash,Backslash,Grave,
    Mouse_Left,Mouse_Right,Mouse_Middle,Mouse_X1,Mouse_X2,
    Mouse_X,Mouse_Y,Wheel_X,Wheel_Y,
    South,East,West,North,Back,Guide,Start,Left_Stick,Right_Stick,Left_Shoulder,Right_Shoulder,
    Dpad_Up,Dpad_Down,Dpad_Left,Dpad_Right,
    Left_X,Left_Y,Right_X,Right_Y,Left_Trigger,Right_Trigger,
}

@(private) CODE_FIRST :: [Input_Device]Input_Code{.None=.None,.Key=.A,.Mouse_Button=.Mouse_Left,.Mouse_Axis=.Mouse_X,.Gamepad_Button=.South,.Gamepad_Axis=.Left_X}
#assert(int(Input_Code.Mouse_Left)-int(Input_Code.A)==len(core.Key))
#assert(int(Input_Code.Mouse_X)-int(Input_Code.Mouse_Left)==len(core.Mouse_Button))
#assert(int(Input_Code.South)-int(Input_Code.Mouse_X)==len(Mouse_Axis))
#assert(int(Input_Code.Left_X)-int(Input_Code.South)==len(core.Gamepad_Button))
#assert(len(Input_Code)-int(Input_Code.Left_X)==len(core.Gamepad_Axis))

// The device of a code and its member in the enum of that device; None for
// None and for a value no member has.
code_device :: proc "contextless" (code:Input_Code) -> (device:Input_Device,index:u8) {
    switch {
    case code==.None || int(code)>=len(Input_Code): return .None,0
    case code<.Mouse_Left: device=.Key
    case code<.Mouse_X:    device=.Mouse_Button
    case code<.South:      device=.Mouse_Axis
    case code<.Left_X:     device=.Gamepad_Button
    case:                  device=.Gamepad_Axis
    }
    first:=CODE_FIRST
    return device,u8(code)-u8(first[device])
}

code_key :: proc "contextless" (key:core.Key) -> Input_Code {return Input_Code(u8(Input_Code.A)+u8(key))}
code_mouse_button :: proc "contextless" (button:core.Mouse_Button) -> Input_Code {return Input_Code(u8(Input_Code.Mouse_Left)+u8(button))}
code_mouse_axis :: proc "contextless" (axis:Mouse_Axis) -> Input_Code {return Input_Code(u8(Input_Code.Mouse_X)+u8(axis))}
code_gamepad_button :: proc "contextless" (button:core.Gamepad_Button) -> Input_Code {return Input_Code(u8(Input_Code.South)+u8(button))}
code_gamepad_axis :: proc "contextless" (axis:core.Gamepad_Axis) -> Input_Code {return Input_Code(u8(Input_Code.Left_X)+u8(axis))}

// One way of driving an action. What the inputs mean follows from the kind of
// the action and from their device:
//   Button  one key or button; or one axis, down from dead_zone (0: 0.5) on
//   Axis    a negative and a positive key or button; one gamepad axis, with
//           dead zone (0: 0.15); or one mouse axis, as it comes
//   Axis2   left, right, down and up keys or buttons; two gamepad axes, with
//           a radial dead zone (0: 0.2); or two mouse axes, as they come
// A chord is keys or buttons that must be held too (binding_chord). In an
// action a mouse axis drives (look), the others are rates: their value, times
// scale, is per second.
Input_Binding :: struct {
    inputs:[4]Input_Code `mirai:"trim"`,             // up to the first None
    chord:[CHORD_CAPACITY]Input_Code `mirai:"trim"`, // up to the first None
    gamepad:u8,    // 0: every gamepad; n: the gamepad n, of its gamepad inputs and of its chord
    scale:f32,     // of the value; 0: 1
    dead_zone:f32, // 0: the one of its kind
}

// How an action is driven: its kind, its context and its bindings, up to the
// first that reads no input. Whoever declares an enum @(actions) E gives the
// defaults of its members beside it, by the naming rule of defaults:
// <e>_defaults :: proc() -> [E]Action_Bindings, or a constant <E>_DEFAULTS.
// The compiler asks for every member, and the map reads them when it is
// built; the map and Input_Settings hold the same per action.
Action_Bindings :: struct {
    kind:Action_Kind,
    input_context:Input_Context `mirai:"name=context"`,
    bindings:[ACTION_BINDINGS]Input_Binding `mirai:"trim"`,
}

// Bindings beyond ACTION_BINDINGS are left out.
action_default :: proc "contextless" (kind:Action_Kind,bindings:..Input_Binding) -> (d:Action_Bindings) {
    d.kind=kind
    for binding,i in bindings[:min(len(bindings),ACTION_BINDINGS)] {d.bindings[i]=binding}
    return
}

// The default of an action of a context other than the base one.
action_default_in :: proc "contextless" (input_context:Input_Context,kind:Action_Kind,bindings:..Input_Binding) -> (d:Action_Bindings) {
    d=action_default(kind,..bindings)
    d.input_context=input_context
    return
}

// The bindings of an action in use: up to the first that reads no input.
action_bindings :: proc "contextless" (a:^Action_Bindings) -> []Input_Binding {
    n:=0
    for n<ACTION_BINDINGS && a.bindings[n].inputs[0]!=.None {n+=1}
    return a.bindings[:n]
}

// The actions of the project and their bindings, by value of Action: the
// defaults of the code with Input_Settings over them.
@(storage,shared,keep)
Input_Map :: struct {
    actions:[ACTION_CAPACITY]Action_Bindings,
    declared:Action_Mask,
    tap_seconds,hold_seconds:f32, // 0: TAP_SECONDS and HOLD_SECONDS
    built:bool,
    seen:core.Seen, // the revision of Input_Settings it was built from
}

// What every action of the map is doing this tick, by value of Action.
Actions :: struct {
    states:[ACTION_CAPACITY]Action_State,
    count:u32, // the values below it are updated
}

// Presentation actions of each local slot: edges and deltas last one frame,
// not one fixed tick.
@(storage,keep)
Frame_Actions :: struct {slots:[LOCAL_CAPACITY]Actions}

// What a step reads of the actions of an enum @(actions) E: those of the
// focused local seat for the tick, and those of each seat. A step receives it
// as Input_Of(E), and the generator gives it the base of E:
// pressed(input,.Jump), pressed(input,body,.Jump), seat_pressed(input,seat,.Jump).
@(params)
Input_Of :: struct($E:typeid) where intrinsics.type_is_enum(E) {
    state:core.Ref(Seats),
    seats:^core.Table(Seat,.Read),
    base:Action,
}

// The actions of an enum @(actions) E of the local slots for the frame, for
// presentation: those of the focused slot, or of a slot. Released while a
// block takes them from the seat of the slot.
@(params)
Frame_Input_Of :: struct($E:typeid) where intrinsics.type_is_enum(E) {
    actions:core.Ref(Frame_Actions),
    state:core.Ref(Seats),
    seats:^core.Table(Seat,.Read),
    base:Action,
}

// The action of the world a member is: what a mask, a hold or data take.
action_of :: proc{input_action_of,frame_action_of}
input_action_of :: #force_inline proc "contextless" (input:Input_Of($E),a:E) -> Action {return input.base+Action(a)}
frame_action_of :: #force_inline proc "contextless" (input:Frame_Input_Of($E),a:E) -> Action {return input.base+Action(a)}

// The state of an action: of the machine this tick or this frame, or of the
// seat that drives body this tick. Released for one the map does not have.
down :: proc{input_down,frame_down,body_down}
pressed :: proc{input_pressed,frame_pressed,body_pressed}
released :: proc{input_released,frame_released,body_released}
tapped :: proc{input_tapped,frame_tapped,body_tapped}
holding :: proc{input_holding,frame_holding,body_holding}
value :: proc{input_value,frame_value,body_value}
vector :: proc{input_vector,frame_vector,body_vector}

input_state :: proc(input:Input_Of($E),a:E) -> Action_State {return seat_action(input.seats,focused(input.state.ptr,input.seats),action_of(input,a))}
frame_state :: proc(input:Frame_Input_Of($E),a:E) -> Action_State {return slot_frame_state(input,input.state.focus,a)}
body_state :: proc(input:Input_Of($E),body:core.Entity,a:E) -> Action_State {return body_action(input.seats,body,action_of(input,a))}
// The state of an action of a local slot this frame.
slot_frame_state :: proc(input:Frame_Input_Of($E),slot:int,a:E) -> Action_State {
    if slot<0 || slot>=LOCAL_CAPACITY {return {}}
    if seat,ok:=core.get(input.seats,local_seat(input.seats,slot));ok && seat.blocked&action_bit(action_of(input,a))!=0 {return {}}
    return action(&input.actions.ptr.slots[slot],action_of(input,a))
}
input_down :: proc(input:Input_Of($E),a:E) -> bool {return input_state(input,a).down}
input_pressed :: proc(input:Input_Of($E),a:E) -> bool {return input_state(input,a).pressed}
input_released :: proc(input:Input_Of($E),a:E) -> bool {return input_state(input,a).released}
input_tapped :: proc(input:Input_Of($E),a:E) -> bool {return input_state(input,a).tapped}
input_holding :: proc(input:Input_Of($E),a:E) -> bool {return input_state(input,a).holding}
input_value :: proc(input:Input_Of($E),a:E) -> f32 {return input_state(input,a).value}
input_vector :: proc(input:Input_Of($E),a:E) -> math.Vec2 {return input_state(input,a).vector}
frame_down :: proc(input:Frame_Input_Of($E),a:E) -> bool {return frame_state(input,a).down}
frame_pressed :: proc(input:Frame_Input_Of($E),a:E) -> bool {return frame_state(input,a).pressed}
frame_released :: proc(input:Frame_Input_Of($E),a:E) -> bool {return frame_state(input,a).released}
frame_tapped :: proc(input:Frame_Input_Of($E),a:E) -> bool {return frame_state(input,a).tapped}
frame_holding :: proc(input:Frame_Input_Of($E),a:E) -> bool {return frame_state(input,a).holding}
frame_value :: proc(input:Frame_Input_Of($E),a:E) -> f32 {return frame_state(input,a).value}
frame_vector :: proc(input:Frame_Input_Of($E),a:E) -> math.Vec2 {return frame_state(input,a).vector}
body_down :: proc(input:Input_Of($E),body:core.Entity,a:E) -> bool {return body_state(input,body,a).down}
body_pressed :: proc(input:Input_Of($E),body:core.Entity,a:E) -> bool {return body_state(input,body,a).pressed}
body_released :: proc(input:Input_Of($E),body:core.Entity,a:E) -> bool {return body_state(input,body,a).released}
body_tapped :: proc(input:Input_Of($E),body:core.Entity,a:E) -> bool {return body_state(input,body,a).tapped}
body_holding :: proc(input:Input_Of($E),body:core.Entity,a:E) -> bool {return body_state(input,body,a).holding}
body_value :: proc(input:Input_Of($E),body:core.Entity,a:E) -> f32 {return body_state(input,body,a).value}
body_vector :: proc(input:Input_Of($E),body:core.Entity,a:E) -> math.Vec2 {return body_state(input,body,a).vector}

// The state of an action of a seat this tick, as seat_action sees it.
seat_state :: proc(input:Input_Of($E),seat:core.Entity,a:E) -> Action_State {return seat_action(input.seats,seat,action_of(input,a))}
seat_down :: proc(input:Input_Of($E),seat:core.Entity,a:E) -> bool {return seat_state(input,seat,a).down}
seat_pressed :: proc(input:Input_Of($E),seat:core.Entity,a:E) -> bool {return seat_state(input,seat,a).pressed}
seat_released :: proc(input:Input_Of($E),seat:core.Entity,a:E) -> bool {return seat_state(input,seat,a).released}
seat_tapped :: proc(input:Input_Of($E),seat:core.Entity,a:E) -> bool {return seat_state(input,seat,a).tapped}
seat_holding :: proc(input:Input_Of($E),seat:core.Entity,a:E) -> bool {return seat_state(input,seat,a).holding}
seat_value :: proc(input:Input_Of($E),seat:core.Entity,a:E) -> f32 {return seat_state(input,seat,a).value}
seat_vector :: proc(input:Input_Of($E),seat:core.Entity,a:E) -> math.Vec2 {return seat_state(input,seat,a).vector}

// The file that held the bindings of a project before Input_Settings: one
// found is not read, and the map says where they go.
@(private) OLD_BINDINGS_FILE :: "input.mirai"

// Builds the map from the defaults of the code and Input_Settings, the first
// time and whenever the setting was handed out to write (its revision moved):
// a frame that wrote nothing looks at no byte of it.
@(step="input",stage="begin")
input_map_build :: proc(bindings:^Input_Map,settings:core.Ref(Input_Settings),written:core.Stamp(Input_Settings),app:^host.App,problems:^core.Problems) {
    seen:=bindings.seen
    if !core.touched(written,&seen) && bindings.built {return}
    input_map_make(bindings,app.info,settings.ptr,problems)
    bindings.seen=seen
    if app.root=="" {return}
    if old:=project.path(app.root,OLD_BINDINGS_FILE,allocator=context.temp_allocator);os.is_file(old) {
        input_report(problems,"input.old_file","%s is no longer read: its bindings go in the section Input_Settings of %s (Project Settings > Input, or settings.set, writes them); bind the actions there again and delete %s",old,project.path(app.root,project.SETTINGS_FILE,allocator=context.temp_allocator),old)
    }
}

// The actions of each local slot for the frame, in the contexts of its seat.
@(step="input",stage="end")
input_frame_actions_update :: proc(bindings:core.Ref(Input_Map),actions:^Frame_Actions,input:core.Frame_Input,state:core.Ref(Seats),seats:^core.Table(Seat,.Read),frame:core.Frame_Time) {
    count:=state.local_count
    for slot in 0..<LOCAL_CAPACITY {
        if slot>=count {
            if actions.slots[slot].count!=0 {actions.slots[slot]={}}
            continue
        }
        own:=slot_input(input.input,slot,count,state.focus)
        contexts:^Context_Stack
        if row:=core.row_of(seats,local_seat(seats,slot));row>=0 {contexts=&seats.values[row].contexts}
        actions_update(&actions.slots[slot],bindings.ptr,&own,frame.dt,contexts)
    }
}

binding_key :: proc "contextless" (key:core.Key) -> Input_Binding {
    return {inputs={0=code_key(key)}}
}
// Axis: -1 while negative is held and +1 while positive is.
binding_key_axis :: proc "contextless" (negative,positive:core.Key,scale:f32=1) -> Input_Binding {
    return {inputs={0=code_key(negative),1=code_key(positive)},scale=scale}
}
// Axis2: diagonals keep the length of scale.
binding_keys :: proc "contextless" (left,right,down,up:core.Key,scale:f32=1) -> Input_Binding {
    return {inputs={code_key(left),code_key(right),code_key(down),code_key(up)},scale=scale}
}
binding_mouse_button :: proc "contextless" (button:core.Mouse_Button) -> Input_Binding {
    return {inputs={0=code_mouse_button(button)}}
}
binding_mouse_axis :: proc "contextless" (axis:Mouse_Axis,scale:f32=1) -> Input_Binding {
    return {inputs={0=code_mouse_axis(axis)},scale=scale}
}
// Axis2: the movement of the mouse, times scale.
binding_mouse_delta :: proc "contextless" (scale:f32=1) -> Input_Binding {
    return {inputs={0=.Mouse_X,1=.Mouse_Y},scale=scale}
}
// gamepad: 0 for every gamepad, n for the gamepad n.
binding_gamepad_button :: proc "contextless" (button:core.Gamepad_Button,gamepad:u8=0) -> Input_Binding {
    return {inputs={0=code_gamepad_button(button)},gamepad=gamepad}
}
binding_gamepad_axis :: proc "contextless" (axis:core.Gamepad_Axis,scale:f32=1,dead_zone:f32=0,gamepad:u8=0) -> Input_Binding {
    return {inputs={0=code_gamepad_axis(axis)},scale=scale,dead_zone=dead_zone,gamepad=gamepad}
}
// Axis2: a stick, with up positive.
binding_gamepad_stick :: proc "contextless" (stick:Gamepad_Stick,scale:f32=1,dead_zone:f32=0,gamepad:u8=0) -> Input_Binding {
    if stick==.Right {return {inputs={0=.Right_X,1=.Right_Y},scale=scale,dead_zone=dead_zone,gamepad=gamepad}}
    return {inputs={0=.Left_X,1=.Left_Y},scale=scale,dead_zone=dead_zone,gamepad=gamepad}
}

// The binding, driving its action only while the keys or buttons of chord
// are held too: binding_chord(binding_key(.S),code_key(.Left_Control)). A held
// chord in use takes its inputs from the bindings with a shorter chord or
// none, so Ctrl+S does not also press S. At most CHORD_CAPACITY, and no axis:
// the map refuses more.
binding_chord :: proc "contextless" (binding:Input_Binding,chord:..Input_Code) -> (b:Input_Binding) {
    b=binding
    b.chord={}
    for code,i in chord[:min(len(chord),CHORD_CAPACITY)] {b.chord[i]=code}
    if len(chord)>CHORD_CAPACITY {b.inputs={}}
    return
}

// The inputs of a binding in use, and of its chord: up to the first None.
binding_inputs :: proc "contextless" (b:^Input_Binding) -> []Input_Code {
    n:=0
    for n<len(b.inputs) && b.inputs[n]!=.None {n+=1}
    return b.inputs[:n]
}
chord_inputs :: proc "contextless" (b:^Input_Binding) -> []Input_Code {
    n:=0
    for n<CHORD_CAPACITY && b.chord[n]!=.None {n+=1}
    return b.chord[:n]
}

// The gamepad a binding reads as std/input numbers it: 0 to 3, or GAMEPAD_ANY.
@(private)
binding_pad :: #force_inline proc "contextless" (b:^Input_Binding) -> u8 {
    return b.gamepad==0?GAMEPAD_ANY:b.gamepad-1
}

// Whether the map has an action of that kind.
input_map_has :: proc "contextless" (m:^Input_Map,action:Action,kind:Action_Kind) -> bool {
    return int(action)<ACTION_CAPACITY && m.declared&action_bit(action)!=0 && m.actions[action].kind==kind
}

// Declares an action of a kind. One the map has keeps its bindings when the
// kind is the same and loses them when it changes. False for a value from
// ACTION_CAPACITY on.
input_map_action :: proc "contextless" (m:^Input_Map,action:Action,kind:Action_Kind) -> bool {
    if int(action)>=ACTION_CAPACITY {return false}
    if m.declared&action_bit(action)!=0 && m.actions[action].kind!=kind {input_map_unbind(m,action)}
    m.actions[action].kind=kind
    m.declared|=action_bit(action)
    return true
}

// False when the map does not have the action, the binding does not suit its
// kind or the action holds ACTION_BINDINGS already.
input_map_bind :: proc "contextless" (m:^Input_Map,action:Action,binding:Input_Binding) -> bool {
    if int(action)>=ACTION_CAPACITY || m.declared&action_bit(action)==0 {return false}
    a:=&m.actions[action]
    used:=len(action_bindings(a))
    if used>=ACTION_BINDINGS || !binding_suits(a.kind,binding) {return false}
    a.bindings[used]=binding
    return true
}

// Removes every binding of an action.
input_map_unbind :: proc "contextless" (m:^Input_Map,action:Action) {
    if int(action)<ACTION_CAPACITY {m.actions[action].bindings={}}
}

// The values of the actions of the map are below it.
@(private)
action_end :: #force_inline proc "contextless" (m:^Input_Map) -> int {
    return 64-int(intrinsics.count_leading_zeros(u64(m.declared)))
}

// The defaults of the actions that the code of a world declares, and then the
// actions Input_Settings names over them (none with settings nil). What the
// code and the setting do not agree on is a problem of the world that says
// how to fix it (none with problems nil): an action the setting cannot give
// keeps its default.
input_map_make :: proc(m:^Input_Map,info:^core.World_Info,settings:^Input_Settings,problems:^core.Problems) {
    result:Input_Map
    result.built=true
    names:=core.names_of(info,Action)
    for entry in core.names_of(info,Input_Context) {
        if entry.value==i64(CONTEXT_ALWAYS) && entry.name!="always" {
            input_report(problems,"input.context_value","the input context %q (%s:%d) has the value %d, which CONTEXT_ALWAYS reserves: give it a free one",entry.name,entry.file,entry.line,entry.value)
            continue
        }
        if entry.value<CONTEXT_CAPACITY {continue}
        input_report(problems,"input.context_value","the input context %q (%s:%d) has the value %d; contexts take values below %d: give it a free one",entry.name,entry.file,entry.line,entry.value,CONTEXT_CAPACITY)
    }
    if info!=nil {
        for &enum_actions in info.actions {
            if enum_actions.defaults==nil || enum_actions.info==nil {continue}
            members:=runtime.type_info_base(enum_actions.info).variant.(runtime.Type_Info_Enum) or_continue
            defaults:=make([]Action_Bindings,len(members.values),context.temp_allocator)
            enum_actions.defaults(raw_data(defaults))
            for &d,member in defaults {
                action:=Action(enum_actions.base+i64(member))
                name,declared:=core.name_of(info,Action,i64(action))
                if !declared || int(action)>=ACTION_CAPACITY {continue}
                if int(d.input_context)>=CONTEXT_CAPACITY {
                    input_report(problems,"input.default_context","the default of the action %q puts it in the input context of value %d; contexts take values below %d: declare it as a free one",name,d.input_context,CONTEXT_CAPACITY)
                    d.input_context=CONTEXT_BASE
                }
                input_map_action(&result,action,d.kind)
                result.actions[action].input_context=d.input_context
                for binding,i in action_bindings(&d) {
                    if !input_map_bind(&result,action,binding) {
                        input_report(problems,"input.default_binding","the default binding %d of the action %q is not one its kind %v takes: %s",i,name,d.kind,kind_takes(d.kind))
                    }
                }
            }
        }
    }
    if settings!=nil {
        result.tap_seconds,result.hold_seconds=seconds_kept(settings.tap_seconds),seconds_kept(settings.hold_seconds)
        for &entry in settings.actions {
            name:=base.text_get(entry.action[:])
            if name=="" {continue}
            if problem:=action_setting_problem(info,&entry);problem!="" {
                input_report(problems,"input.settings","%s",problem)
                continue
            }
            value,_:=core.name_value(info,Action,name)
            result.actions[value]=entry.driven
            result.declared|=action_bit(Action(value))
        }
    }
    unbound:=strings.builder_make(context.temp_allocator)
    for entry in names {
        if entry.value>=ACTION_CAPACITY || result.declared&action_bit(Action(entry.value))!=0 {continue}
        input_map_action(&result,Action(entry.value),.Button)
        fmt.sbprintf(&unbound,"%s%q (%s:%d)",strings.builder_len(unbound)>0?", ":"",entry.name,entry.file,entry.line)
    }
    if strings.builder_len(unbound)>0 {
        input_report(problems,"input.action_unbound","%s: no binding, neither a default in code nor in Input_Settings; give each its kind and default bindings beside its enum (<enum>_defaults :: proc() -> [E]Action_Bindings), or bind it in Project Settings > Input",strings.to_string(unbound))
    }
    m^=result
}

@(private)
input_report :: proc(problems:^core.Problems,code,format:string,args:..any) {
    if problems==nil {return}
    message:=fmt.tprintf(format,..args)
    log.warn(message)
    core.report(problems,core.NONE,code,"%s",message)
}

/// What the bindings of an action of a kind read, for whoever fixes one.
kind_takes :: proc(kind:Action_Kind) -> string {
    switch kind {
    case .Button: return "a Button reads one input: a key, a button, or an axis pressed past its dead_zone"
    case .Axis:   return "an Axis reads two keys or buttons (negative, positive), one gamepad axis, or one of Mouse_X, Mouse_Y, Wheel_X and Wheel_Y"
    case .Axis2:  return "an Axis2 reads four keys or buttons (left, right, down, up), the two axes of a stick (Left_X and Left_Y, Right_X and Right_Y), Mouse_X and Mouse_Y, or Wheel_X and Wheel_Y"
    }
    return "its kind is Button, Axis or Axis2"
}

// The seconds of a tap or a hold as the map takes them: 0 (the default) for one that is not a time.
@(private)
seconds_kept :: proc "contextless" (seconds:f32) -> f32 {
    return seconds>0 && seconds<=SECONDS_MAX?seconds:0
}

// The identifier of the enum member an action name is: "layer_back" is Layer_Back.
@(private)
member_name :: proc(name:string) -> string {
    b:=strings.builder_make(context.temp_allocator)
    for c,i in transmute([]u8)name {
        strings.write_byte(&b,(i==0 || name[i-1]=='_') && c>='a' && c<='z'?c-32:c)
    }
    return strings.to_string(b)
}

// How std/input reads a binding of an action of that kind.
@(private)
binding_kind :: proc "contextless" (kind:Action_Kind,binding:Input_Binding) -> (result:si.Binding_Kind,valid:bool) {
    binding:=binding
    codes,chord:=binding_inputs(&binding),chord_inputs(&binding)
    if len(codes)==0 || int(binding.gamepad)>core.GAMEPAD_CAPACITY || !(abs(binding.scale)<=SCALE_MAX) || !(binding.dead_zone>=0 && binding.dead_zone<1) {return}
    for code in binding.inputs[len(codes):] {if code!=.None {return}}
    for code in binding.chord[len(chord):] {if code!=.None {return}}
    digital,analog,mouse:=0,0,0
    for code in codes {
        switch device,_:=code_device(code);device {
        case .None: return
        case .Key,.Mouse_Button,.Gamepad_Button: digital+=1
        case .Gamepad_Axis: analog+=1
        case .Mouse_Axis: mouse+=1
        }
    }
    for code in chord {
        #partial switch device,_:=code_device(code);device {
        case .Key,.Mouse_Button,.Gamepad_Button:
        case: return
        }
    }
    count:=len(codes)
    switch kind {
    case .Button:
        if count!=1 {return}
        return digital==1?.Code:.Axis_Above,true
    case .Axis:
        if digital==2 && count==2 {return .Code_Axis,true}
        if count!=1 || digital==1 {return}
        return analog==1?.Analog:.Delta,true
    case .Axis2:
        if digital==4 {return .Codes_2D,true}
        if count!=2 {return}
        if analog==2 {return .Analog_2D,true}
        if mouse==2 {return .Delta_2D,true}
    }
    return
}

@(private) ACTION_AXES :: int(si.AXIS_MOUSE)+len(Mouse_Axis)
@(private) ACTION_CODES :: 512
@(private) SCALE_MAX :: f32(1e6)  // of a binding
SECONDS_MAX :: f32(10) // the longest tap or hold

@(private)
action_code :: proc "contextless" (code:Input_Code,pad:u8) -> u16 {
    device,index:=code_device(code)
    #partial switch device {
    case .Key: return u16(si.CODE_KEYBOARD)+u16(index)
    case .Mouse_Button: return u16(si.CODE_MOUSE)+u16(index)
    case .Gamepad_Button: return u16(si.code_gamepad(u16(pad),u16(index)))
    case .Gamepad_Axis: return u16(si.axis_gamepad(u16(pad),u16(index)))
    case .Mouse_Axis: return u16(si.AXIS_MOUSE)+u16(index)
    }
    return 0
}

// The highest layer whose bindings read each code and axis, as si.Input numbers them.
@(private)
Taken :: struct {
    codes:[ACTION_CODES]u8,
    axes:[ACTION_AXES]u8,
}

@(private)
taken_at :: proc "contextless" (taken:^Taken,code:Input_Code,pad:u8) -> ^u8 {
    n:=int(action_code(code,pad))
    if device,_:=code_device(code);device==.Mouse_Axis || device==.Gamepad_Axis {return &taken.axes[n]}
    return &taken.codes[n]
}

// What a binding reads goes to its layer. A gamepad code stands for that of
// every gamepad too, and one of every gamepad for that of each.
@(private)
inputs_take :: proc "contextless" (taken:^Taken,binding:^Input_Binding,level:u8) {
    take :: proc "contextless" (taken:^Taken,code:Input_Code,gamepad,level:u8) {
        if device,_:=code_device(code);device!=.Gamepad_Button && device!=.Gamepad_Axis {
            at:=taken_at(taken,code,gamepad)
            at^=max(at^,level)
            return
        }
        for pad in 0..=GAMEPAD_ANY {
            if gamepad!=GAMEPAD_ANY && pad!=gamepad && pad!=GAMEPAD_ANY {continue}
            at:=taken_at(taken,code,pad)
            at^=max(at^,level)
        }
    }
    pad:=binding_pad(binding)
    for code in binding_inputs(binding) {take(taken,code,pad,level)}
    for code in chord_inputs(binding) {take(taken,code,pad,level)}
}

// Whether a higher layer reads something a binding reads.
@(private)
inputs_taken :: proc "contextless" (taken:^Taken,binding:^Input_Binding,level:u8) -> bool {
    pad:=binding_pad(binding)
    for code in binding_inputs(binding) {if taken_at(taken,code,pad)^>level {return true}}
    for code in chord_inputs(binding) {if taken_at(taken,code,pad)^>level {return true}}
    return false
}

// The states of the actions of a map for one tick: from the input of the
// tick and from the states the previous tick left in actions. Only the
// actions of the contexts of the seat read input (without contexts, those of
// the base one), and a binding does not when a higher layer reads one of its
// inputs, or a modal one is above it. A hold drives its action as one more
// binding, in the same contexts. It allocates nothing.
actions_update :: proc(actions:^Actions,m:^Input_Map,input:^core.Input,dt:f32,contexts:^Context_Stack=nil,holds:[]Action_Hold=nil) {
    // The layer of each context the seat is in, plus one; 0: not in it.
    layers:[CONTEXT_CAPACITY]u8
    layers[CONTEXT_BASE]=1
    floor:=u8(1) // the lowest layer that gets input: the highest modal one
    stacked:=contexts!=nil && contexts.count>0
    if stacked {
        for c,i in contexts.layers[:min(int(contexts.count),CONTEXT_LAYERS)] {
            if int(c)>=CONTEXT_CAPACITY {continue}
            layers[c]=u8(i+2)
            if contexts.modal&(1<<u8(i))!=0 {floor=u8(i+2)}
        }
    }
    layer :: proc "contextless" (c:Input_Context,layers:^[CONTEXT_CAPACITY]u8,floor:u8) -> u8 {
        if c==CONTEXT_ALWAYS {return 1}
        if int(c)>=CONTEXT_CAPACITY || layers[c]<floor {return 0}
        return layers[c]
    }
    scratch:[20<<10]u8
    arena:mem.Arena
    mem.arena_init(&arena,scratch[:])
    state:si.Input
    count:=action_end(m)
    bindings:=0
    for &a in m.actions[:count] {bindings+=len(action_bindings(&a))}
    if count==0 || !si.input_init(&state,{
        max_actions=count,max_bindings=max(bindings,1),code_count=ACTION_CODES,axis_count=ACTION_AXES,
        tap=m.tap_seconds,hold=m.hold_seconds,allocator=mem.arena_allocator(&arena),
    }) {
        actions^={}
        return
    }
    for i in 0..<count {
        si.input_add_action(&state,m.actions[i].kind)
        if i<int(actions.count) {state.states[i]=actions.states[i]}
    }
    taken:Taken
    if stacked {
        for &a in m.actions[:count] {
            level:=layer(a.input_context,&layers,floor)
            if level==0 {continue}
            for &binding in action_bindings(&a) {
                if binding_suits(a.kind,binding) {inputs_take(&taken,&binding,level)}
            }
        }
    }
    for &a,index in m.actions[:count] {
        level:=layer(a.input_context,&layers,floor)
        if level==0 {continue}
        // Beside the displacement of the mouse, a stick or keys turn at a rate: as far in any dt.
        rate:=action_reads_mouse(m,Action(index))
        for &binding in action_bindings(&a) {
            kind,valid:=binding_kind(a.kind,binding)
            if !valid || stacked && inputs_taken(&taken,&binding,level) {continue}
            pad:=binding_pad(&binding)
            codes:[4]u16
            for code,i in binding_inputs(&binding) {codes[i]=action_code(code,pad)}
            action:=si.Action(index)+1
            scale:=binding.scale!=0?binding.scale:1
            if rate && kind!=.Delta && kind!=.Delta_2D {scale*=dt}
            zone:=binding.dead_zone
            bound:bool
            switch kind {
            case .Code:       bound=si.input_bind_code(&state,action,si.Input_Code(codes[0]))
            case .Axis_Above: bound=si.input_bind_axis_button(&state,action,si.Axis_Code(codes[0]),zone>0?zone:DEAD_ZONE_BUTTON,scale)
            case .Code_Axis:  bound=si.input_bind_codes_axis(&state,action,si.Input_Code(codes[0]),si.Input_Code(codes[1]),scale)
            case .Analog:     bound=si.input_bind_axis(&state,action,si.Axis_Code(codes[0]),zone>0?zone:DEAD_ZONE_AXIS,scale)
            case .Codes_2D:   bound=si.input_bind_codes_2d(&state,action,si.Input_Code(codes[0]),si.Input_Code(codes[1]),si.Input_Code(codes[2]),si.Input_Code(codes[3]),scale)
            case .Analog_2D:  bound=si.input_bind_axes_2d(&state,action,si.Axis_Code(codes[0]),si.Axis_Code(codes[1]),zone>0?zone:DEAD_ZONE_STICK,scale)
            case .Delta:      bound=si.input_bind_delta(&state,action,si.Axis_Code(codes[0]),scale)
            case .Delta_2D:   bound=si.input_bind_delta_2d(&state,action,si.Axis_Code(codes[0]),si.Axis_Code(codes[1]),scale)
            }
            if held:=chord_inputs(&binding);bound && len(held)>0 {
                chord:[CHORD_CAPACITY]si.Input_Code
                for code,i in held {chord[i]=si.Input_Code(action_code(code,pad))}
                si.input_chord(&state,..chord[:len(held)])
            }
        }
    }

    // A code pressed and released inside the tick is not down, and still counts as a press.
    feed :: proc "contextless" (state:^si.Input,code:u16,down,pressed:bool) {
        if down {base.bits_set(state.down,int(code))} else if pressed {base.bits_set(state.latched_down,int(code))}
    }
    for key in core.Key {feed(&state,u16(si.CODE_KEYBOARD)+u16(key),key in input.keys_down,key in input.keys_pressed)}
    for button in core.Mouse_Button {feed(&state,u16(si.CODE_MOUSE)+u16(button),button in input.mouse_down,button in input.mouse_pressed)}
    any:[core.Gamepad_Axis]f32
    for &pad,index in input.gamepads {
        if !pad.connected {continue}
        for button in core.Gamepad_Button {
            down,pressed:=button in pad.down,button in pad.pressed
            feed(&state,u16(si.code_gamepad(u16(index),u16(button))),down,pressed)
            feed(&state,u16(si.code_gamepad(u16(GAMEPAD_ANY),u16(button))),down,pressed)
        }
        for axis in core.Gamepad_Axis {
            value:=pad.axes[axis]
            if axis==.Left_Y || axis==.Right_Y {value=-value}
            state.axes[si.axis_gamepad(u16(index),u16(axis))]=value
            if abs(value)>abs(any[axis]) {any[axis]=value}
        }
    }
    for axis in core.Gamepad_Axis {state.axes[si.axis_gamepad(u16(GAMEPAD_ANY),u16(axis))]=any[axis]}
    mouse:=[Mouse_Axis]f32{.X=input.mouse_delta.x,.Y=-input.mouse_delta.y,.Wheel_X=input.wheel.x,.Wheel_Y=input.wheel.y}
    for axis in Mouse_Axis {state.axes[int(si.AXIS_MOUSE)+int(axis)]=mouse[axis]}
    for hold in holds {
        a:=int(hold.action)
        if a>=count || m.declared&action_bit(hold.action)==0 {continue}
        if c:=m.actions[a].input_context;c!=CONTEXT_ALWAYS && (int(c)>=CONTEXT_CAPACITY || layers[c]<floor) {continue}
        si.input_feed_action(&state,si.Action(a+1),hold.value.x!=0,hold.value.x,hold.value)
    }

    si.input_update(&state,dt)
    copy(actions.states[:count],state.states[:count])
    for i in count..<int(actions.count) {actions.states[i]={}}
    actions.count=u32(count)
}

// The state of an action of the world this tick, as data names it; released
// for one the map does not have. Code reads its own actions with Input_Of.
action :: #force_inline proc "contextless" (actions:^Actions,a:Action) -> Action_State {
    return u32(a)<actions.count?actions.states[a]:{}
}

// Whether a binding of an action reads the movement of the mouse.
action_reads_mouse :: proc "contextless" (m:^Input_Map,action:Action) -> bool {
    if int(action)>=ACTION_CAPACITY {return false}
    for &binding in action_bindings(&m.actions[action]) {
        for code in binding_inputs(&binding) {
            if device,_:=code_device(code);device==.Mouse_Axis {return true}
        }
    }
    return false
}

// Whether a binding suits an action of a kind, as input_map_bind takes it.
binding_suits :: proc "contextless" (kind:Action_Kind,binding:Input_Binding) -> bool {
    _,valid:=binding_kind(kind,binding)
    return valid
}

// What a binding of an action of a kind reads of its options: scale, a dead
// zone (zone: the one it uses, its own or the default) and gamepad.
binding_uses :: proc "contextless" (kind:Action_Kind,binding:Input_Binding) -> (scale,dead_zone,gamepad:bool,zone:f32) {
    binding:=binding
    for code in binding_inputs(&binding) {
        device,_:=code_device(code)
        gamepad||=device==.Gamepad_Button || device==.Gamepad_Axis
    }
    read,valid:=binding_kind(kind,binding)
    if !valid {return}
    switch read {
    case .Code:
    case .Code_Axis,.Codes_2D,.Delta,.Delta_2D: scale=true
    case .Axis_Above: scale,dead_zone,zone=true,true,DEAD_ZONE_BUTTON
    case .Analog:     scale,dead_zone,zone=true,true,DEAD_ZONE_AXIS
    case .Analog_2D:  scale,dead_zone,zone=true,true,DEAD_ZONE_STICK
    }
    if dead_zone && binding.dead_zone>0 {zone=binding.dead_zone}
    return
}
