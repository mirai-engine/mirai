package input

import "base:intrinsics"
import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:reflect"
import "core:strings"
import "mirai:core"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"
import si "mirai:std/input"
import "mirai:std/math"

// Input actions. A game reads actions (JUMP, MOVE) instead of keys; the
// Input_Map says which keys, mouse buttons, mouse movement and gamepad
// controls drive each one. Actions is computed once per fixed tick from the
// core.Input of the tick and from its own state of the tick before, so a tick
// simulated again gives the same.
//
// Each library declares its actions as an enum @(actions), and the defaults
// of the ones it wants driven without input.mirai ([E]Action_Default). The
// map is built once, in the first input phase: those defaults, and then
// input.mirai of the project, which gives the kind and the bindings of the
// actions it names. A step reads the actions of an enum through Input_Of(E).

ACTION_CAPACITY :: 64
BINDING_CAPACITY :: 192
DEFAULT_BINDING_CAPACITY :: 4
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
// movement): the locomotion turns a body with it, and a camera that orbits
// turns with it. The sensitivity of a player is the scale of its bindings.
@(actions)
Look_Action :: enum u8 {Look}

// Radians the look turns per unit of the look action: a point of mouse movement.
LOOK_SPEED :: f32(0.12*math.RAD_PER_DEG)

// The bindings of look when input.mirai of the project does not name it.
@(storage,host)
Look_Actions :: struct {defaults:[Look_Action]Action_Default}

look_actions_default :: proc "contextless" () -> Look_Actions {
    return {defaults={.Look=action_default(.Axis2,binding_mouse_delta(),binding_gamepad_stick(.Right,25))}}
}

Action_Kind :: si.Action_Kind
TAP_TICKS :: si.TAP_TICKS
HOLD_TICKS :: si.HOLD_TICKS
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

// code is a core.Key, core.Mouse_Button, Mouse_Axis, core.Gamepad_Button or core.Gamepad_Axis.
Input_Code :: struct {device:Input_Device,code:u8}

// One way of driving an action. What the codes mean follows from the kind of
// the action and from their device:
//   Button  one key or button; or one axis, down from dead_zone (0: 0.5) on
//   Axis    a negative and a positive key or button; one gamepad axis, with
//           dead zone (0: 0.15); or one mouse axis, as it comes
//   Axis2   left, right, down and up keys or buttons; two gamepad axes, with
//           a radial dead zone (0: 0.2); or two mouse axes, as they come
// A chord is keys or buttons that must be held too (binding_chord).
Input_Binding :: struct {
    action:Action,
    count:u8,       // codes in use; 0: none
    gamepad:u8,     // 0 to 3, or GAMEPAD_ANY; of its gamepad codes and of its chord
    chord_count:u8,
    codes:[4]Input_Code,
    chord:[CHORD_CAPACITY]Input_Code,
    scale:f32,      // of the value; 0: 1
    dead_zone:f32,
}

// How an action is driven when input.mirai of the project does not name it.
// Whoever declares an enum @(actions) gives the defaults of its members in a
// storage of its package that has a field [E]Action_Default, set by the
// default of the storage (<name>_default() or <NAME>_DEFAULT): the compiler
// asks for every member, the map reads those defaults when it is built, and
// nothing reads the storage.
Action_Default :: struct {
    kind:Action_Kind,
    input_context:Input_Context,
    count:u8, // bindings given, also those beyond the capacity, which the map reports
    bindings:[DEFAULT_BINDING_CAPACITY]Input_Binding,
}

action_default :: proc "contextless" (kind:Action_Kind,bindings:..Input_Binding) -> (d:Action_Default) {
    d.kind,d.count=kind,u8(min(len(bindings),255))
    for binding,i in bindings[:min(len(bindings),DEFAULT_BINDING_CAPACITY)] {d.bindings[i]=binding}
    return
}

// The default of an action of a context other than the base one.
action_default_in :: proc "contextless" (input_context:Input_Context,kind:Action_Kind,bindings:..Input_Binding) -> (d:Action_Default) {
    d=action_default(kind,..bindings)
    d.input_context=input_context
    return
}

// The actions of the project and their bindings, by value of Action.
@(storage,shared,keep)
Input_Map :: struct {
    kinds:[ACTION_CAPACITY]Action_Kind,
    contexts:[ACTION_CAPACITY]Input_Context,
    bindings:[BINDING_CAPACITY]Input_Binding,
    declared:Action_Mask,
    binding_count:u32,
    tap_ticks,hold_ticks:u32, // 0: TAP_TICKS and HOLD_TICKS
    built:bool,               // from the defaults of the code and input.mirai
}

// What every action of the map is doing this tick, by value of Action.
@(storage,keep)
Actions :: struct {
    states:[ACTION_CAPACITY]Action_State,
    count:u32, // the values below it are updated
}

// Presentation actions: edges and deltas last one frame, not one fixed tick.
@(storage,keep)
Frame_Actions :: struct {actions:Actions}

// What a step reads of the actions of an enum @(actions) E: those of the
// machine for the tick, and those of each seat. A step receives it as
// Input_Of(E), and the generator gives it the base of E: pressed(input,.Jump),
// pressed(input,body,.Jump), seat_pressed(input,seat,.Jump).
@(params)
Input_Of :: struct($E:typeid) where intrinsics.type_is_enum(E) {
    actions:core.Ref(Actions),
    seats:core.Read(Seat),
    drivables:core.Read(Drivable),
    base:Action,
}

// The actions of an enum @(actions) E of the machine for the frame, for presentation.
@(params)
Frame_Input_Of :: struct($E:typeid) where intrinsics.type_is_enum(E) {
    actions:core.Ref(Frame_Actions),
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

input_state :: proc "contextless" (input:Input_Of($E),a:E) -> Action_State {return action(input.actions.ptr,action_of(input,a))}
frame_state :: proc "contextless" (input:Frame_Input_Of($E),a:E) -> Action_State {return action(&input.actions.ptr.actions,action_of(input,a))}
body_state :: proc(input:Input_Of($E),body:core.Entity,a:E) -> Action_State {return body_action({input.seats,input.drivables},body,action_of(input,a))}
input_down :: proc "contextless" (input:Input_Of($E),a:E) -> bool {return input_state(input,a).down}
input_pressed :: proc "contextless" (input:Input_Of($E),a:E) -> bool {return input_state(input,a).pressed}
input_released :: proc "contextless" (input:Input_Of($E),a:E) -> bool {return input_state(input,a).released}
input_tapped :: proc "contextless" (input:Input_Of($E),a:E) -> bool {return input_state(input,a).tapped}
input_holding :: proc "contextless" (input:Input_Of($E),a:E) -> bool {return input_state(input,a).holding}
input_value :: proc "contextless" (input:Input_Of($E),a:E) -> f32 {return input_state(input,a).value}
input_vector :: proc "contextless" (input:Input_Of($E),a:E) -> math.Vec2 {return input_state(input,a).vector}
frame_down :: proc "contextless" (input:Frame_Input_Of($E),a:E) -> bool {return frame_state(input,a).down}
frame_pressed :: proc "contextless" (input:Frame_Input_Of($E),a:E) -> bool {return frame_state(input,a).pressed}
frame_released :: proc "contextless" (input:Frame_Input_Of($E),a:E) -> bool {return frame_state(input,a).released}
frame_tapped :: proc "contextless" (input:Frame_Input_Of($E),a:E) -> bool {return frame_state(input,a).tapped}
frame_holding :: proc "contextless" (input:Frame_Input_Of($E),a:E) -> bool {return frame_state(input,a).holding}
frame_value :: proc "contextless" (input:Frame_Input_Of($E),a:E) -> f32 {return frame_state(input,a).value}
frame_vector :: proc "contextless" (input:Frame_Input_Of($E),a:E) -> math.Vec2 {return frame_state(input,a).vector}
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

Input_Map_Error :: enum u8 {
    None,
    Syntax,         // not JSON, or not the shape of the file
    Unknown_Action, // a name that no constant of Action declares
    Unknown_Context, // a context that no constant of Input_Context declares
    Unknown_Kind,   // an action whose kind is not Button, Axis or Axis2
    Unknown_Input,  // a key, button, axis or stick that does not exist
    Invalid,        // a binding that does not suit the kind of its action, or names no input
    Capacity,       // more bindings than the map holds
}

// Builds the map once: the defaults of the code, then input.mirai of the
// project, then the one of the options of the player.
@(step="input",stage="begin")
input_map_build :: proc(bindings:^Input_Map,app:^host.App,problems:^core.Problems) {
    if bindings.built {return}
    file,text:string
    if app.root!="" {
        path:=project.path(app.root,project.INPUT_FILE,allocator=context.temp_allocator)
        if data,read_error:=os.read_entire_file(path,context.temp_allocator);read_error==nil {file,text=path,string(data)}
    }
    options,options_text:string
    if path:=input_options_file(app);path!="" {
        if data,read_error:=os.read_entire_file(path,context.temp_allocator);read_error==nil {options,options_text=path,string(data)}
    }
    input_map_make(bindings,app.info,file,text,problems,options,options_text)
}

// The actions of the machine, in the contexts of the focused seat.
@(step="fixed",stage="input")
input_actions_update :: proc(bindings:^Input_Map,actions:^Actions,input:core.Input,state:core.Ref(Seats),seats:core.Read(Seat)) {
    input:=input
    actions_update(actions,bindings,&input,focused_contexts(state.ptr,seats))
}

@(step="input",stage="end")
input_frame_actions_update :: proc(bindings:core.Ref(Input_Map),actions:^Frame_Actions,input:core.Frame_Input,state:core.Ref(Seats),seats:core.Read(Seat)) {
    input:=input.input
    actions_update(&actions.actions,bindings.ptr,&input,focused_contexts(state.ptr,seats))
}

binding_key :: proc "contextless" (key:core.Key) -> Input_Binding {
    return {count=1,gamepad=GAMEPAD_ANY,codes={0={.Key,u8(key)}}}
}
// Axis: -1 while negative is held and +1 while positive is.
binding_key_axis :: proc "contextless" (negative,positive:core.Key,scale:f32=1) -> Input_Binding {
    return {count=2,gamepad=GAMEPAD_ANY,codes={0={.Key,u8(negative)},1={.Key,u8(positive)}},scale=scale}
}
// Axis2: diagonals keep unit length.
binding_keys :: proc "contextless" (left,right,down,up:core.Key) -> Input_Binding {
    return {count=4,gamepad=GAMEPAD_ANY,codes={{.Key,u8(left)},{.Key,u8(right)},{.Key,u8(down)},{.Key,u8(up)}}}
}
binding_mouse_button :: proc "contextless" (button:core.Mouse_Button) -> Input_Binding {
    return {count=1,gamepad=GAMEPAD_ANY,codes={0={.Mouse_Button,u8(button)}}}
}
binding_mouse_axis :: proc "contextless" (axis:Mouse_Axis,scale:f32=1) -> Input_Binding {
    return {count=1,gamepad=GAMEPAD_ANY,codes={0={.Mouse_Axis,u8(axis)}},scale=scale}
}
// Axis2: the movement of the mouse, times scale.
binding_mouse_delta :: proc "contextless" (scale:f32=1) -> Input_Binding {
    return {count=2,gamepad=GAMEPAD_ANY,codes={0={.Mouse_Axis,u8(Mouse_Axis.X)},1={.Mouse_Axis,u8(Mouse_Axis.Y)}},scale=scale}
}
binding_gamepad_button :: proc "contextless" (button:core.Gamepad_Button,gamepad:=GAMEPAD_ANY) -> Input_Binding {
    return {count=1,gamepad=gamepad,codes={0={.Gamepad_Button,u8(button)}}}
}
binding_gamepad_axis :: proc "contextless" (axis:core.Gamepad_Axis,scale:f32=1,dead_zone:f32=0,gamepad:=GAMEPAD_ANY) -> Input_Binding {
    return {count=1,gamepad=gamepad,codes={0={.Gamepad_Axis,u8(axis)}},scale=scale,dead_zone=dead_zone}
}
// Axis2: a stick, with up positive.
binding_gamepad_stick :: proc "contextless" (stick:Gamepad_Stick,scale:f32=1,dead_zone:f32=0,gamepad:=GAMEPAD_ANY) -> Input_Binding {
    x,y:=core.Gamepad_Axis.Left_X,core.Gamepad_Axis.Left_Y
    if stick==.Right {x,y=.Right_X,.Right_Y}
    return {count=2,gamepad=gamepad,codes={0={.Gamepad_Axis,u8(x)},1={.Gamepad_Axis,u8(y)}},scale=scale,dead_zone=dead_zone}
}

// The binding, driving its action only while the keys or buttons of chord
// are held too: binding_chord(binding_key(.S),code_key(.Left_Control)). A held
// chord in use takes its inputs from the bindings with a shorter chord or
// none, so Ctrl+S does not also press S. At most CHORD_CAPACITY; more, or an
// axis, make a binding the map refuses.
binding_chord :: proc "contextless" (binding:Input_Binding,chord:..Input_Code) -> (b:Input_Binding) {
    b=binding
    b.chord_count=u8(min(len(chord),255))
    for code,i in chord[:min(len(chord),CHORD_CAPACITY)] {b.chord[i]=code}
    return
}
code_key :: proc "contextless" (key:core.Key) -> Input_Code {return {.Key,u8(key)}}
code_mouse_button :: proc "contextless" (button:core.Mouse_Button) -> Input_Code {return {.Mouse_Button,u8(button)}}
code_gamepad_button :: proc "contextless" (button:core.Gamepad_Button) -> Input_Code {return {.Gamepad_Button,u8(button)}}

// Whether the map has an action of that kind.
input_map_has :: proc "contextless" (m:^Input_Map,action:Action,kind:Action_Kind) -> bool {
    return m.declared&action_bit(action)!=0 && m.kinds[action]==kind
}

// Declares an action of a kind. One the map has keeps its bindings when the
// kind is the same and loses them when it changes. False for a value from
// ACTION_CAPACITY on.
input_map_action :: proc "contextless" (m:^Input_Map,action:Action,kind:Action_Kind) -> bool {
    if int(action)>=ACTION_CAPACITY {return false}
    if m.declared&action_bit(action)!=0 && m.kinds[action]!=kind {input_map_unbind(m,action)}
    m.kinds[action]=kind
    m.declared|=action_bit(action)
    return true
}

// False when the map does not have the action, the binding does not suit its kind or the map is full.
input_map_bind :: proc "contextless" (m:^Input_Map,action:Action,binding:Input_Binding) -> bool {
    if int(action)>=ACTION_CAPACITY || m.declared&action_bit(action)==0 || m.binding_count>=BINDING_CAPACITY {return false}
    if _,valid:=binding_kind(m.kinds[action],binding);!valid {return false}
    stored:=binding
    stored.action=action
    m.bindings[m.binding_count]=stored
    m.binding_count+=1
    return true
}

// Removes every binding of an action.
input_map_unbind :: proc "contextless" (m:^Input_Map,action:Action) {
    kept:=u32(0)
    for &binding in m.bindings[:m.binding_count] {
        if binding.action==action {continue}
        m.bindings[kept]=binding;kept+=1
    }
    m.binding_count=kept
}

// The values of the actions of the map are below it.
@(private)
action_end :: #force_inline proc "contextless" (m:^Input_Map) -> int {
    return 64-int(intrinsics.count_leading_zeros(u64(m.declared)))
}

// The defaults of the actions that the code of a world declares
// (Action_Default), and then the text of input.mirai (file, "" without one)
// over them. What the code and the file do not agree on is a problem of the
// world that says how to fix it (none with problems nil); a file with an
// error is not read.
input_map_make :: proc(m:^Input_Map,info:^core.World_Info,file,text:string,problems:^core.Problems,options:="",options_text:="") {
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
    defaulted:Action_Mask
    if info!=nil {
        for &storage in info.storages {
            for &given in action_defaults(info,&storage) {
                d,action:=given.default,given.action
                name,declared:=core.name_of(info,Action,i64(action))
                switch {
                case given.unknown!=nil:
                    input_report(problems,"input.default_unknown","%s gives defaults to the members of %v, which is not an enum @(actions); mark it @(actions), or remove the defaults",storage.name,given.unknown)
                case !declared || int(action)>=ACTION_CAPACITY:
                    input_report(problems,"input.default_unknown","%s gives a default to the action of value %d, which no enum @(actions) declares; declare the action or remove its default",storage.name,action)
                case defaulted&action_bit(action)!=0:
                    input_report(problems,"input.default_twice","the action %q has two defaults, the second in %s; leave one",name,storage.name)
                case int(d.count)>DEFAULT_BINDING_CAPACITY:
                    input_report(problems,"input.default_bindings","the default of the action %q in %s has %d bindings, and a default holds %d; bind the rest in %s",name,storage.name,d.count,DEFAULT_BINDING_CAPACITY,project.INPUT_FILE)
                    fallthrough
                case:
                    defaulted|=action_bit(action)
                    input_map_action(&result,action,d.kind)
                    if int(d.input_context)<CONTEXT_CAPACITY {
                        result.contexts[action]=d.input_context
                    } else {
                        input_report(problems,"input.default_context","the default of the action %q in %s puts it in the input context of value %d; contexts take values below %d: declare it as a free one",name,storage.name,d.input_context,CONTEXT_CAPACITY)
                    }
                    for binding in d.bindings[:min(int(d.count),DEFAULT_BINDING_CAPACITY)] {
                        if !input_map_bind(&result,action,binding) {
                            input_report(problems,"input.default_binding","a default binding of the action %q in %s does not suit its kind %v, or the map holds %d bindings already; fix that binding",name,storage.name,d.kind,BINDING_CAPACITY)
                        }
                    }
                }
            }
        }
    }
    if file!="" {
        error,at:=input_map_parse(&result,info,text)
        switch error {
        case .None:
        case .Unknown_Action:
            known:=strings.builder_make(context.temp_allocator)
            for entry,i in names {fmt.sbprintf(&known,"%s%s",i>0?", ":"",entry.name)}
            input_report(problems,"input.unknown_action","%s names the action %q, which the code does not declare, and was not read; declare it as a member %s of the enum @(actions) of the game, or rename it to one the code declares: %s",file,at,member_name(at),strings.to_string(known))
        case .Syntax, .Unknown_Context, .Unknown_Kind, .Unknown_Input, .Invalid, .Capacity:
            input_report(problems,"input.file","%s was not read: %v in the action %q; %s",file,error,at,input_map_error_fix(error))
        }
    }
    // The options of the player: a file that does not read leaves the bindings
    // of the project; an action the game no longer declares is only left out.
    if options!="" {
        gone:=make([dynamic]string,context.temp_allocator)
        if error,at:=input_map_parse(&result,info,options_text,&gone);error!=.None {
            input_report(problems,"input.options","%s, the bindings the player chose, was not read: %v in the action %q; the player binds again from the options menu, or delete the file",options,error,at)
        } else if len(gone)>0 {
            input_report(problems,"input.options_gone","%s binds %v, which the game no longer declares, and those were left out; the rest of what the player chose holds, and they go when the player changes the options again",options,gone[:])
        }
    }
    unbound:=strings.builder_make(context.temp_allocator)
    for entry in names {
        if entry.value>=ACTION_CAPACITY || result.declared&action_bit(Action(entry.value))!=0 {continue}
        input_map_action(&result,Action(entry.value),.Button)
        fmt.sbprintf(&unbound,"%s%q (%s:%d)",strings.builder_len(unbound)>0?", ":"",entry.name,entry.file,entry.line)
    }
    if strings.builder_len(unbound)>0 {
        where_:=file!=""?file:project.INPUT_FILE
        input_report(problems,"input.action_unbound","%s: no binding, neither a default in code nor in %s; give each its kind and default bindings where it is declared (a host storage with a field [E]Action_Default), or bind it in Project Settings > Input",strings.to_string(unbound),where_)
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

// How to fix a file with that error.
input_map_error_fix :: proc(error:Input_Map_Error) -> string {
    #partial switch error {
    case .Syntax:        return `write {"actions":[{"name":...,"kind":...,"bindings":[...]}]} in JSON`
    case .Unknown_Context: return "name a constant of input.Input_Context in its context, or leave it out for the base one"
    case .Unknown_Kind:  return "its kind is Button, Axis or Axis2"
    case .Unknown_Input: return "name keys, buttons, axes and sticks as the enums of core and input name them"
    case .Invalid:       return "give it bindings that suit its kind, and a chord of one or two keys or buttons"
    case .Capacity:      return fmt.tprintf("the map holds %d bindings: remove some",BINDING_CAPACITY)
    }
    return ""
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

@(private)
Given_Default :: struct {
    action:Action,
    default:Action_Default,
    unknown:typeid, // the enum of a field [E]Action_Default that is not @(actions)
}

// The defaults of a storage: those of its fields [E]Action_Default, in the
// value its default gives it, each with the action of its member.
@(private)
action_defaults :: proc(info:^core.World_Info,storage:^core.Storage_Info) -> []Given_Default {
    if storage.default==nil || storage.info==nil {return nil}
    record,is_struct:=runtime.type_info_base(storage.info).variant.(runtime.Type_Info_Struct)
    if !is_struct {return nil}
    value:[]u8
    found:=make([dynamic]Given_Default,context.temp_allocator)
    for i in 0..<int(record.field_count) {
        array,is_array:=runtime.type_info_base(record.types[i]).variant.(runtime.Type_Info_Enumerated_Array)
        if !is_array || array.elem.id!=Action_Default {continue}
        actions:=core.actions_of(info,array.index.id)
        if actions==nil {
            append(&found,Given_Default{unknown=array.index.id})
            continue
        }
        if value==nil {
            value=make([]u8,storage.info.size,context.temp_allocator)
            storage.default(raw_data(value))
        }
        defaults:=([^]Action_Default)(&value[record.offsets[i]])[:array.count]
        for d,member in defaults {append(&found,Given_Default{action=Action(actions.base+i64(member)),default=d})}
    }
    return found[:]
}

// How std/input reads a binding of an action of that kind.
@(private)
binding_kind :: proc "contextless" (kind:Action_Kind,binding:Input_Binding) -> (result:si.Binding_Kind,valid:bool) {
    binding:=binding
    count:=int(binding.count)
    if count<1 || count>4 || binding.gamepad>GAMEPAD_ANY {return}
    digital,analog,mouse:=0,0,0
    for code in binding.codes[:count] {
        switch code.device {
        case .None: return
        case .Key: if int(code.code)>=len(core.Key) {return};digital+=1
        case .Mouse_Button: if int(code.code)>=len(core.Mouse_Button) {return};digital+=1
        case .Gamepad_Button: if int(code.code)>=len(core.Gamepad_Button) {return};digital+=1
        case .Gamepad_Axis: if int(code.code)>=len(core.Gamepad_Axis) {return};analog+=1
        case .Mouse_Axis: if int(code.code)>=len(Mouse_Axis) {return};mouse+=1
        }
    }
    if int(binding.chord_count)>CHORD_CAPACITY {return}
    for code in binding.chord[:binding.chord_count] {
        switch code.device {
        case .Key: if int(code.code)>=len(core.Key) {return}
        case .Mouse_Button: if int(code.code)>=len(core.Mouse_Button) {return}
        case .Gamepad_Button: if int(code.code)>=len(core.Gamepad_Button) {return}
        case .None, .Mouse_Axis, .Gamepad_Axis: return
        }
    }
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

@(private)
action_code :: proc "contextless" (code:Input_Code,gamepad:u8) -> u16 {
    #partial switch code.device {
    case .Key: return u16(si.CODE_KEYBOARD)+u16(code.code)
    case .Mouse_Button: return u16(si.CODE_MOUSE)+u16(code.code)
    case .Gamepad_Button: return u16(si.code_gamepad(u16(gamepad),u16(code.code)))
    case .Gamepad_Axis: return u16(si.axis_gamepad(u16(gamepad),u16(code.code)))
    case .Mouse_Axis: return u16(si.AXIS_MOUSE)+u16(code.code)
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
taken_at :: proc "contextless" (taken:^Taken,code:Input_Code,gamepad:u8) -> ^u8 {
    n:=int(action_code(code,gamepad))
    if code.device==.Mouse_Axis || code.device==.Gamepad_Axis {return &taken.axes[n]}
    return &taken.codes[n]
}

// What a binding reads goes to its layer. A gamepad code stands for that of
// every gamepad too, and one of every gamepad for that of each.
@(private)
inputs_take :: proc "contextless" (taken:^Taken,binding:^Input_Binding,level:u8) {
    take :: proc "contextless" (taken:^Taken,code:Input_Code,gamepad,level:u8) {
        if code.device!=.Gamepad_Button && code.device!=.Gamepad_Axis {
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
    for code in binding.codes[:binding.count] {take(taken,code,binding.gamepad,level)}
    for code in binding.chord[:binding.chord_count] {take(taken,code,binding.gamepad,level)}
}

// Whether a higher layer reads something a binding reads.
@(private)
inputs_taken :: proc "contextless" (taken:^Taken,binding:^Input_Binding,level:u8) -> bool {
    for code in binding.codes[:binding.count] {if taken_at(taken,code,binding.gamepad)^>level {return true}}
    for code in binding.chord[:binding.chord_count] {if taken_at(taken,code,binding.gamepad)^>level {return true}}
    return false
}

// The states of the actions of a map for one tick: from the input of the
// tick and from the states the previous tick left in actions. Only the
// actions of the contexts of the seat read input (without contexts, those of
// the base one), and a binding does not when a higher layer reads one of its
// inputs, or a modal one is above it. A hold drives its action as one more
// binding, in the same contexts. It allocates nothing.
actions_update :: proc(actions:^Actions,m:^Input_Map,input:^core.Input,contexts:^Context_Stack=nil,holds:[]Action_Hold=nil) {
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
    layer :: proc "contextless" (m:^Input_Map,binding:^Input_Binding,layers:^[CONTEXT_CAPACITY]u8,floor:u8) -> u8 {
        c:=m.contexts[binding.action]
        if c==CONTEXT_ALWAYS {return 1}
        if int(c)>=CONTEXT_CAPACITY || layers[c]<floor {return 0}
        return layers[c]
    }
    scratch:[12<<10]u8
    arena:mem.Arena
    mem.arena_init(&arena,scratch[:])
    state:si.Input
    count:=action_end(m)
    if count==0 || !si.input_init(&state,{
        max_actions=count,max_bindings=max(int(m.binding_count),1),code_count=ACTION_CODES,axis_count=ACTION_AXES,
        tap_ticks=m.tap_ticks,hold_ticks=m.hold_ticks,allocator=mem.arena_allocator(&arena),
    }) {
        actions^={}
        return
    }
    for i in 0..<count {
        si.input_add_action(&state,m.kinds[i])
        if i<int(actions.count) {state.states[i]=actions.states[i]}
    }
    taken:Taken
    if stacked {
        for &binding in m.bindings[:m.binding_count] {
            if int(binding.action)>=count {continue}
            if _,valid:=binding_kind(m.kinds[binding.action],binding);!valid {continue}
            if level:=layer(m,&binding,&layers,floor);level>0 {inputs_take(&taken,&binding,level)}
        }
    }
    for &binding in m.bindings[:m.binding_count] {
        if int(binding.action)>=count {continue}
        kind,valid:=binding_kind(m.kinds[binding.action],binding)
        if !valid {continue}
        level:=layer(m,&binding,&layers,floor)
        if level==0 || stacked && inputs_taken(&taken,&binding,level) {continue}
        codes:[4]u16
        for code,i in binding.codes[:binding.count] {codes[i]=action_code(code,binding.gamepad)}
        action:=si.Action(binding.action)+1
        scale:=binding.scale!=0?binding.scale:1
        zone:=binding.dead_zone
        bound:bool
        switch kind {
        case .Code:       bound=si.input_bind_code(&state,action,si.Input_Code(codes[0]))
        case .Axis_Above: bound=si.input_bind_axis_button(&state,action,si.Axis_Code(codes[0]),zone>0?zone:DEAD_ZONE_BUTTON,scale)
        case .Code_Axis:  bound=si.input_bind_codes_axis(&state,action,si.Input_Code(codes[0]),si.Input_Code(codes[1]),scale)
        case .Analog:     bound=si.input_bind_axis(&state,action,si.Axis_Code(codes[0]),zone>0?zone:DEAD_ZONE_AXIS,scale)
        case .Codes_2D:   bound=si.input_bind_codes_2d(&state,action,si.Input_Code(codes[0]),si.Input_Code(codes[1]),si.Input_Code(codes[2]),si.Input_Code(codes[3]))
        case .Analog_2D:  bound=si.input_bind_axes_2d(&state,action,si.Axis_Code(codes[0]),si.Axis_Code(codes[1]),zone>0?zone:DEAD_ZONE_STICK,scale)
        case .Delta:      bound=si.input_bind_delta(&state,action,si.Axis_Code(codes[0]),scale)
        case .Delta_2D:   bound=si.input_bind_delta_2d(&state,action,si.Axis_Code(codes[0]),si.Axis_Code(codes[1]),scale)
        }
        if bound && binding.chord_count>0 {
            chord:[CHORD_CAPACITY]si.Input_Code
            for code,i in binding.chord[:binding.chord_count] {chord[i]=si.Input_Code(action_code(code,binding.gamepad))}
            si.input_chord(&state,..chord[:binding.chord_count])
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
        if c:=m.contexts[a];c!=CONTEXT_ALWAYS && (int(c)>=CONTEXT_CAPACITY || layers[c]<floor) {continue}
        si.input_feed_action(&state,si.Action(a+1),hold.value.x!=0,hold.value.x,hold.value)
    }

    si.input_update(&state)
    copy(actions.states[:count],state.states[:count])
    for i in count..<int(actions.count) {actions.states[i]={}}
    actions.count=u32(count)
}

// The state of an action of the world this tick, as data names it; released
// for one the map does not have. Code reads its own actions with Input_Of.
action :: #force_inline proc "contextless" (actions:^Actions,a:Action) -> Action_State {
    return u32(a)<actions.count?actions.states[a]:{}
}

// Reads the text of an input file over a map: each action of the file gets
// its kind, and its bindings replace the ones the map had for it; the
// actions the file does not name stay. On an error the map is left as it
// was, and at is the name of the action where it was found.
//
//   {"tap_ticks":12,"hold_ticks":30,"actions":[
//     {"name":"move","kind":"Axis2","bindings":[{"keys":["A","D","S","W"]},{"gamepad_stick":"Left"}]},
//     {"name":"look","kind":"Axis2","bindings":[{"mouse":"Delta","scale":0.1}]},
//     {"name":"jump","kind":"Button","bindings":[{"key":"Space"},{"gamepad_button":"South"}]}]}
//
// name is the name of an action (a member of an enum @(actions), in lower
// case), and context, an optional one of Input_Context. A binding names its input with one of key,
// keys (two for an Axis, four for an Axis2: left, right, down, up),
// mouse_button, mouse (X, Y, Wheel_X, Wheel_Y, or Delta and Wheel for both
// axes), gamepad_button, gamepad_axis and gamepad_stick (Left, Right), with
// the names of the core enums. scale, dead_zone, gamepad (0 to 3; every
// gamepad when absent) and chord (one or two of {"key"}, {"mouse_button"} and
// {"gamepad_button"} held too) are optional.
//
// With skipped, an action the code does not declare (renamed or removed since
// the file was written) is left out and its name appended there, instead of
// failing the whole file: what the options of a player do.
input_map_parse :: proc(m:^Input_Map,info:^core.World_Info,text:string,skipped:^[dynamic]string=nil) -> (error:Input_Map_Error,at:string) {
    value,parse_error:=json.parse_string(text,json.DEFAULT_SPECIFICATION,true,context.temp_allocator)
    root,is_object:=value.(json.Object)
    if parse_error!=.None || !is_object {return .Syntax,""}
    result:=m^
    if ticks,has:=input_number(root["tap_ticks"]);has {result.tap_ticks=u32(max(ticks,0))}
    if ticks,has:=input_number(root["hold_ticks"]);has {result.hold_ticks=u32(max(ticks,0))}
    list,_:=root["actions"].(json.Array)
    for item in list {
        entry,is_action:=item.(json.Object)
        if !is_action {return .Syntax,""}
        name,_:=entry["name"].(json.String)
        found,declared:=core.name_value(info,Action,name)
        if !declared || found<0 || found>=ACTION_CAPACITY {
            if skipped==nil {return .Unknown_Action,name}
            append(skipped,name)
            continue
        }
        action:=Action(found)
        kind_name,_:=entry["kind"].(json.String)
        kind,known:=reflect.enum_from_name(Action_Kind,kind_name)
        if !known {return .Unknown_Kind,name}
        input_map_action(&result,action,kind)
        if context_name,has:=entry["context"].(json.String);has {
            value,named:=core.name_value(info,Input_Context,context_name)
            if !named || value<0 || value>=CONTEXT_CAPACITY {return .Unknown_Context,name}
            result.contexts[action]=Input_Context(value)
        }
        input_map_unbind(&result,action)
        bindings,_:=entry["bindings"].(json.Array)
        for raw in bindings {
            described,is_binding:=raw.(json.Object)
            if !is_binding {return .Syntax,name}
            binding,binding_error,_:=input_binding_parse(described)
            if binding_error!=.None {return binding_error,name}
            if !input_map_bind(&result,action,binding) {return result.binding_count>=BINDING_CAPACITY?.Capacity:.Invalid,name}
        }
    }
    m^=result
    return .None,""
}

@(private="file")
input_number :: proc(value:json.Value) -> (number:f64,ok:bool) {
    #partial switch v in value {
    case json.Float: return v,true
    case json.Integer: return f64(v),true
    }
    return
}

@(private="file")
input_code :: proc(value:json.Value,device:Input_Device,$E:typeid) -> (code:Input_Code,error:Input_Map_Error) {
    name,is_text:=value.(json.String)
    if !is_text {return {},.Syntax}
    found,known:=reflect.enum_from_name(E,name)
    if !known {return {},.Unknown_Input}
    return {device,u8(found)},.None
}

// One binding as input.mirai writes it (see input_map_parse). On an error,
// field is the key whose value is wrong; "" when the binding names no input.
input_binding_parse :: proc(o:json.Object) -> (binding:Input_Binding,error:Input_Map_Error,field:string) {
    binding.gamepad=GAMEPAD_ANY
    if pad,has:=input_number(o["gamepad"]);has {
        if pad<0 || pad>=core.GAMEPAD_CAPACITY {return {},.Unknown_Input,"gamepad"}
        binding.gamepad=u8(pad)
    }
    if scale,has:=input_number(o["scale"]);has {binding.scale=f32(scale)}
    if zone,has:=input_number(o["dead_zone"]);has {binding.dead_zone=f32(zone)}
    code:Input_Code
    switch {
    case "key" in o:
        field="key"
        code,error=input_code(o[field],.Key,core.Key)
        binding.codes[0],binding.count=code,1
    case "keys" in o:
        field="keys"
        keys,is_list:=o[field].(json.Array)
        if !is_list {return {},.Syntax,field}
        if len(keys)!=2 && len(keys)!=4 {return {},.Invalid,field}
        for key,i in keys {
            binding.codes[i],error=input_code(key,.Key,core.Key)
            if error!=.None {break}
        }
        binding.count=u8(len(keys))
    case "mouse_button" in o:
        field="mouse_button"
        code,error=input_code(o[field],.Mouse_Button,core.Mouse_Button)
        binding.codes[0],binding.count=code,1
    case "gamepad_button" in o:
        field="gamepad_button"
        code,error=input_code(o[field],.Gamepad_Button,core.Gamepad_Button)
        binding.codes[0],binding.count=code,1
    case "gamepad_axis" in o:
        field="gamepad_axis"
        code,error=input_code(o[field],.Gamepad_Axis,core.Gamepad_Axis)
        binding.codes[0],binding.count=code,1
    case "gamepad_stick" in o:
        field="gamepad_stick"
        code,error=input_code(o[field],.Gamepad_Axis,Gamepad_Stick)
        if error==.None {binding=binding_gamepad_stick(Gamepad_Stick(code.code),binding.scale,binding.dead_zone,binding.gamepad)}
    case "mouse" in o:
        field="mouse"
        switch name,_:=o[field].(json.String);name {
        case "Delta": binding.codes[0],binding.codes[1],binding.count={.Mouse_Axis,u8(Mouse_Axis.X)},{.Mouse_Axis,u8(Mouse_Axis.Y)},2
        case "Wheel": binding.codes[0],binding.codes[1],binding.count={.Mouse_Axis,u8(Mouse_Axis.Wheel_X)},{.Mouse_Axis,u8(Mouse_Axis.Wheel_Y)},2
        case:
            code,error=input_code(o[field],.Mouse_Axis,Mouse_Axis)
            binding.codes[0],binding.count=code,1
        }
    case:
        return {},.Invalid,""
    }
    if error!=.None {return {},error,field}
    if chord,has:=o["chord"].(json.Array);has {
        field="chord"
        if len(chord)==0 || len(chord)>CHORD_CAPACITY {return {},.Invalid,field}
        for item,i in chord {
            held,is_object:=item.(json.Object)
            if !is_object {return {},.Syntax,field}
            switch {
            case "key" in held:            binding.chord[i],error=input_code(held["key"],.Key,core.Key)
            case "mouse_button" in held:   binding.chord[i],error=input_code(held["mouse_button"],.Mouse_Button,core.Mouse_Button)
            case "gamepad_button" in held: binding.chord[i],error=input_code(held["gamepad_button"],.Gamepad_Button,core.Gamepad_Button)
            case:                          return {},.Invalid,field
            }
            if error!=.None {return {},error,field}
        }
        binding.chord_count=u8(len(chord))
    }
    return binding,.None,""
}

// Whether a binding of an action reads the movement of the mouse.
action_reads_mouse :: proc "contextless" (m:^Input_Map,action:Action) -> bool {
    for &binding in m.bindings[:m.binding_count] {
        if binding.action!=action {continue}
        for code in binding.codes[:min(int(binding.count),4)] {
            if code.device==.Mouse_Axis {return true}
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
    for code in binding.codes[:min(int(binding.count),4)] {gamepad||=code.device==.Gamepad_Button || code.device==.Gamepad_Axis}
    read,valid:=binding_kind(kind,binding)
    if !valid {return}
    switch read {
    case .Code,.Codes_2D:
    case .Code_Axis,.Delta,.Delta_2D: scale=true
    case .Axis_Above: scale,dead_zone,zone=true,true,DEAD_ZONE_BUTTON
    case .Analog:     scale,dead_zone,zone=true,true,DEAD_ZONE_AXIS
    case .Analog_2D:  scale,dead_zone,zone=true,true,DEAD_ZONE_STICK
    }
    if dead_zone && binding.dead_zone>0 {zone=binding.dead_zone}
    return
}
