package mirai_input

import "base:runtime"
import "core:math/linalg"
import "mirai:std/base"
import "mirai:std/math"

// Input actions. The game does not read keys: it reads actions ("jump",
// "move") that are bound to abstract codes, so the same logic serves any
// keyboard layout, controller or replay. The window layer reports the state
// of the codes with input_set_code and input_set_axis; once per tick
// input_update turns them into the state of every action; the game queries
// the actions. The package knows nothing about a window system: a code is any
// u16 the host decides, and a `code_count` of 512 comfortably holds the
// ranges below.

// A key, mouse button or gamepad button.
Input_Code :: distinct u16
// An analog axis: a stick, a trigger, mouse movement or the wheel.
Axis_Code :: distinct u16

// Suggested layout of the codes: the host maps its own values onto it.
CODE_KEYBOARD :: Input_Code(0)   // 256 keys
CODE_MOUSE :: Input_Code(256)    // 32 buttons
CODE_GAMEPAD :: Input_Code(288)  // 32 buttons for each of 7 pads
AXIS_GAMEPAD :: Axis_Code(0)     // 8 axes for each of 8 pads
AXIS_MOUSE :: Axis_Code(64)      // x, y, wheel x, wheel y
code_gamepad :: #force_inline proc "contextless" (pad,button:u16) -> Input_Code {return CODE_GAMEPAD+Input_Code(pad*32+button)}
axis_gamepad :: #force_inline proc "contextless" (pad,axis:u16) -> Axis_Code {return AXIS_GAMEPAD+Axis_Code(pad*8+axis)}

// Handle of an action: its index plus one. Zero is none.
Action :: distinct u16

Action_Kind :: enum u8 {
    Button, // down or up
    Axis,   // a value from -1 to 1 times the scale of its binding
    Axis2,  // a vector at most as long as the scale of its binding, except from unbounded axes
}

Binding_Kind :: enum u8 {
    Code,        // Button: down while the code is
    Axis_Above,  // Button: down while the axis, times `scale`, reaches `dead_zone` (a trigger used as a button)
    Code_Axis,   // Axis: from a negative and a positive code, times `scale`
    Analog,      // Axis: an analog axis with a dead zone, times `scale`
    Codes_2D,    // Axis2: left, right, down and up codes, times `scale`; diagonals keep its length
    Analog_2D,   // Axis2: two analog axes with a radial dead zone, times `scale`
    Delta,       // Axis: an unbounded axis times `scale`, as is: mouse movement, a wheel
    Delta_2D,    // Axis2: two unbounded axes times `scale`; the vector is not limited to unit length
}

CHORD_CAPACITY :: 2

@(private)
Binding :: struct {
    action:u16, // index
    kind:Binding_Kind,
    chord_count:u8,
    codes:[4]u16,
    chord:[CHORD_CAPACITY]u16, // codes that must be held too
    scale,dead_zone:f32,
}

// What an action is doing this tick. Plain data: copy it to record or send it.
Action_State :: struct {
    down:bool,          // a button is held, or an axis is away from zero
    pressed:bool,       // became down this tick
    released:bool,      // stopped being down this tick
    tapped:bool,        // released after being held at most `tap` seconds
    hold_started:bool,  // has been held for `hold` seconds, as of this tick
    holding:bool,       // has been held for at least `hold` seconds
    held:f32,           // s held so far, counting this tick; 0 when up
    released_held:f32,  // s, on the tick it was released: how long it had been held
    value:f32,          // Axis: the value; Axis2: its length; Button: 1 while down
    vector:math.Vec2,   // Axis2
}

Input :: struct {
    down,latched_down,latched_up:[]u64, // per code: held, and pressed or released since the last update
    axes:[]f32,
    bindings:[]Binding,
    kinds:[]Action_Kind,
    names:[]u64,
    states:[]Action_State,
    accum:[]Accum,
    taken,taken_axes:[]u8, // per code and axis: the most codes of a held chord that uses it this update
    code_count,axis_count,action_count,binding_count:int,
    tap,hold:f32,          // s
    chorded:bool,          // some binding has a chord
    failed:u64,
    allocator:runtime.Allocator,
}
Input_Desc :: struct {
    max_actions,max_bindings:int,
    code_count:int,                // 512 when 0
    axis_count:int,                // 64 when 0
    tap,hold:f32,                  // s; TAP_SECONDS and HOLD_SECONDS when 0
    allocator:runtime.Allocator,   // context.allocator when unset
}

TAP_SECONDS :: f32(0.2)
HOLD_SECONDS :: f32(0.5)

input_init :: proc(in_:^Input,desc:Input_Desc) -> bool {
    allocator:=desc.allocator if desc.allocator.procedure!=nil else context.allocator
    in_^={allocator=allocator,tap=desc.tap if desc.tap>0 else TAP_SECONDS,hold=desc.hold if desc.hold>0 else HOLD_SECONDS}
    in_.code_count=desc.code_count if desc.code_count>0 else 512
    in_.axis_count=desc.axis_count if desc.axis_count>0 else 64
    if desc.max_actions<=0 || desc.max_actions>int(max(u16)) || desc.max_bindings<=0 || desc.max_bindings>max(int)/size_of(Binding) || in_.code_count>int(max(u16))+1 || in_.axis_count>int(max(u16))+1 {in_^={};return false}
    words:=base.bits_words(in_.code_count)
    e:[11]runtime.Allocator_Error
    in_.down,e[0]=make([]u64,words,allocator)
    in_.latched_down,e[1]=make([]u64,words,allocator)
    in_.latched_up,e[2]=make([]u64,words,allocator)
    in_.axes,e[3]=make([]f32,in_.axis_count,allocator)
    in_.bindings,e[4]=make([]Binding,desc.max_bindings,allocator)
    in_.kinds,e[5]=make([]Action_Kind,desc.max_actions,allocator)
    in_.names,e[6]=make([]u64,desc.max_actions,allocator)
    in_.states,e[7]=make([]Action_State,desc.max_actions,allocator)
    in_.accum,e[8]=make([]Accum,desc.max_actions,allocator)
    in_.taken,e[9]=make([]u8,in_.code_count,allocator)
    in_.taken_axes,e[10]=make([]u8,in_.axis_count,allocator)
    for error in e {if error!=nil {input_destroy(in_);return false}}
    return true
}
input_destroy :: proc(in_:^Input) {
    if in_.allocator.procedure==nil {in_^={};return}
    delete(in_.down,in_.allocator);delete(in_.latched_down,in_.allocator);delete(in_.latched_up,in_.allocator)
    delete(in_.axes,in_.allocator);delete(in_.bindings,in_.allocator);delete(in_.kinds,in_.allocator)
    delete(in_.names,in_.allocator);delete(in_.states,in_.allocator);delete(in_.accum,in_.allocator)
    delete(in_.taken,in_.allocator);delete(in_.taken_axes,in_.allocator)
    in_^={}
}

// Declares an action; Action(0) when there is no room. `name` is its name_hash, for input_find_action.
input_add_action :: proc(in_:^Input,kind:Action_Kind,name:u64=0) -> Action {
    if in_.action_count>=len(in_.kinds) {in_.failed+=1;return 0}
    in_.kinds[in_.action_count]=kind
    in_.names[in_.action_count]=name
    in_.action_count+=1
    return Action(in_.action_count)
}
input_find_action :: proc "contextless" (in_:^Input,name:u64) -> Action {
    for i in 0..<in_.action_count {if in_.names[i]==name {return Action(i+1)}}
    return 0
}

@(private)
input_bind :: proc "contextless" (in_:^Input,action:Action,kind:Binding_Kind,codes:[4]u16,scale,dead_zone:f32) -> bool {
    expected:Action_Kind
    switch kind {
    case .Code,.Axis_Above: expected=.Button
    case .Code_Axis,.Analog,.Delta: expected=.Axis
    case .Codes_2D,.Analog_2D,.Delta_2D: expected=.Axis2
    }
    used,on_axes:=binding_span(kind)
    limit:=on_axes?in_.axis_count:in_.code_count
    for i in 0..<used {if int(codes[i])>=limit {in_.failed+=1;return false}}
    if action==0 || int(action)>in_.action_count || in_.kinds[action-1]!=expected || in_.binding_count>=len(in_.bindings) {in_.failed+=1;return false}
    in_.bindings[in_.binding_count]={action=u16(action-1),kind=kind,codes=codes,scale=scale,dead_zone=dead_zone}
    in_.binding_count+=1
    return true
}
// A button action goes down while the code is held.
input_bind_code :: proc "contextless" (in_:^Input,action:Action,code:Input_Code) -> bool {return input_bind(in_,action,.Code,{u16(code),0,0,0},1,0)}
// A button action goes down while an axis, times `scale`, is at least `threshold`.
input_bind_axis_button :: proc "contextless" (in_:^Input,action:Action,axis:Axis_Code,threshold:f32=0.5,scale:f32=1) -> bool {return input_bind(in_,action,.Axis_Above,{u16(axis),0,0,0},scale,threshold)}
// An axis action reads -1 while `negative` is held and +1 while `positive` is, times `scale`.
input_bind_codes_axis :: proc "contextless" (in_:^Input,action:Action,negative,positive:Input_Code,scale:f32=1) -> bool {return input_bind(in_,action,.Code_Axis,{u16(negative),u16(positive),0,0},scale,0)}
// An axis action reads an analog axis: values inside `dead_zone` read 0 and the rest is rescaled so the range stays continuous up to 1, then times `scale`.
input_bind_axis :: proc "contextless" (in_:^Input,action:Action,axis:Axis_Code,dead_zone:f32=0.15,scale:f32=1) -> bool {return input_bind(in_,action,.Analog,{u16(axis),0,0,0},scale,dead_zone)}
// A 2D action built from four codes, times `scale`.
input_bind_codes_2d :: proc "contextless" (in_:^Input,action:Action,left,right,down,up:Input_Code,scale:f32=1) -> bool {return input_bind(in_,action,.Codes_2D,{u16(left),u16(right),u16(down),u16(up)},scale,0)}
// A 2D action read from two analog axes with a radial dead zone, then times `scale`.
input_bind_axes_2d :: proc "contextless" (in_:^Input,action:Action,x,y:Axis_Code,dead_zone:f32=0.2,scale:f32=1) -> bool {return input_bind(in_,action,.Analog_2D,{u16(x),u16(y),0,0},scale,dead_zone)}
// An axis action reads an unbounded axis times `scale`, without dead zone or limit: the movement of the mouse or a wheel since the last tick.
input_bind_delta :: proc "contextless" (in_:^Input,action:Action,axis:Axis_Code,scale:f32=1) -> bool {return input_bind(in_,action,.Delta,{u16(axis),0,0,0},scale,0)}
// A 2D action read from two unbounded axes.
input_bind_delta_2d :: proc "contextless" (in_:^Input,action:Action,x,y:Axis_Code,scale:f32=1) -> bool {return input_bind(in_,action,.Delta_2D,{u16(x),u16(y),0,0},scale,0)}

// The binding added last drives its action only while every code of chord is
// held too. A held chord whose binding is in use takes its codes, and those of
// the binding, from the bindings with a shorter chord or none: Ctrl+S does
// not also press S, nor Ctrl. False without a binding, with no codes or more
// than CHORD_CAPACITY, or with a code out of range.
input_chord :: proc "contextless" (in_:^Input,chord:..Input_Code) -> bool {
    if in_.binding_count==0 || len(chord)==0 || len(chord)>CHORD_CAPACITY {in_.failed+=1;return false}
    for code in chord {if int(code)>=in_.code_count {in_.failed+=1;return false}}
    binding:=&in_.bindings[in_.binding_count-1]
    for code,i in chord {binding.chord[i]=u16(code)}
    binding.chord_count=u8(len(chord))
    in_.chorded=true
    return true
}

// How many codes a binding of a kind reads, and whether they are axes.
@(private)
binding_span :: proc "contextless" (kind:Binding_Kind) -> (used:int,on_axes:bool) {
    switch kind {
    case .Code:                       return 1,false
    case .Code_Axis:                  return 2,false
    case .Codes_2D:                   return 4,false
    case .Axis_Above,.Analog,.Delta:  return 1,true
    case .Analog_2D,.Delta_2D:        return 2,true
    }
    return 0,false
}
// Removes every binding of an action.
input_unbind :: proc "contextless" (in_:^Input,action:Action) {
    if action==0 || int(action)>in_.action_count {return}
    kept:=0
    for i in 0..<in_.binding_count {
        if in_.bindings[i].action==u16(action-1) {continue}
        in_.bindings[kept]=in_.bindings[i];kept+=1
    }
    in_.binding_count=kept
}

// The host reports a code going down or up. False when the code is out of range.
input_set_code :: proc "contextless" (in_:^Input,code:Input_Code,is_down:bool) -> bool {
    if int(code)>=in_.code_count {return false}
    was:=base.bits_test(in_.down,int(code))
    if was==is_down {return true}
    base.bits_assign(in_.down,int(code),is_down)
    base.bits_set(in_.latched_down if is_down else in_.latched_up,int(code))
    return true
}
// The host reports the position of an axis, normally from -1 to 1.
input_set_axis :: proc "contextless" (in_:^Input,axis:Axis_Code,value:f32) -> bool {
    if int(axis)>=in_.axis_count {return false}
    in_.axes[axis]=value
    return true
}
// Releases every code and zeroes every axis, as when the window loses focus. The actions go up on the next update.
input_release_all :: proc "contextless" (in_:^Input) {
    for code in 0..<in_.code_count {
        if base.bits_test(in_.down,code) {base.bits_set(in_.latched_up,code)}
    }
    base.bits_clear_all(in_.down)
    for &axis in in_.axes {axis=0}
}

@(private)
dead_zone_scalar :: proc "contextless" (value,dead_zone:f32) -> f32 {
    magnitude:=abs(value)
    if magnitude<=dead_zone {return 0}
    rescaled:=min((magnitude-dead_zone)/max(1-dead_zone,1e-6),1)
    return rescaled if value>0 else -rescaled
}

// Drives an action in the next update besides its bindings, as one more
// binding would: a button held, an axis at a value or an Axis2 at a vector,
// whatever its devices do. False for an action it does not have.
input_feed_action :: proc "contextless" (in_:^Input,action:Action,down:bool,axis:f32,vector:math.Vec2) -> bool {
    if action==0 || int(action)>in_.action_count {return false}
    total:=&in_.accum[action-1]
    total.down||=down
    if abs(axis)>abs(total.axis) {total.axis=axis}
    if linalg.length2(vector)>linalg.length2(total.vector) {total.vector=vector}
    return true
}

// Computes the state of every action from the codes and axes as they are
// now and from what input_feed_action gave: call it once per tick of dt
// seconds, after the host reported them.
input_update :: proc "contextless" (in_:^Input,dt:f32) {
    bindings:=in_.bindings[:in_.binding_count]
    if in_.chorded {
        for &taken in in_.taken {taken=0}
        for &taken in in_.taken_axes {taken=0}
        for &binding in bindings {
            if binding.chord_count==0 || !chord_held(in_,&binding) {continue}
            if read:=binding_read(in_,&binding);!read.down && !read.quick && read.axis==0 && read.vector=={} {continue}
            level:=binding.chord_count
            for code in binding.chord[:binding.chord_count] {in_.taken[code]=max(in_.taken[code],level)}
            used,on_axes:=binding_span(binding.kind)
            taken:=on_axes?in_.taken_axes:in_.taken
            for code in binding.codes[:used] {taken[code]=max(taken[code],level)}
        }
    }
    for &binding in bindings {
        if binding.chord_count>0 && !chord_held(in_,&binding) {continue}
        if in_.chorded && chord_overruled(in_,&binding) {continue}
        read:=binding_read(in_,&binding)
        total:=&in_.accum[binding.action]
        total.down||=read.down
        total.quick||=read.quick
        if abs(read.axis)>abs(total.axis) {total.axis=read.axis}
        if linalg.length2(read.vector)>linalg.length2(total.vector) {total.vector=read.vector}
    }
    for action in 0..<in_.action_count {
        total:=in_.accum[action]
        input_finish(in_,action,in_.kinds[action],total.down,total.quick,total.axis,total.vector,dt)
    }
    for &total in in_.accum[:in_.action_count] {total={}}
    base.bits_clear_all(in_.latched_down)
    base.bits_clear_all(in_.latched_up)
}
@(private)
code_axis :: #force_inline proc "contextless" (in_:^Input,code:u16) -> f32 {return 1 if base.bits_test(in_.down,int(code)) else 0}

// What one binding gives its action now.
@(private)
binding_read :: proc "contextless" (in_:^Input,binding:^Binding) -> (r:Accum) {
    switch binding.kind {
    case .Code:
        code:=int(binding.codes[0])
        if base.bits_test(in_.down,code) {r.down=true}
        else if base.bits_test(in_.latched_down,code) {r.quick=true}
    case .Axis_Above:
        r.down=in_.axes[binding.codes[0]]*binding.scale>=binding.dead_zone
    case .Code_Axis:
        r.axis=binding.scale*(code_axis(in_,binding.codes[1])-code_axis(in_,binding.codes[0]))
    case .Analog:
        r.axis=dead_zone_scalar(in_.axes[binding.codes[0]],binding.dead_zone)*binding.scale
    case .Codes_2D:
        v:=math.Vec2{code_axis(in_,binding.codes[1])-code_axis(in_,binding.codes[0]),code_axis(in_,binding.codes[3])-code_axis(in_,binding.codes[2])}
        if v.x!=0 && v.y!=0 {v*=0.70710678}
        r.vector=v*binding.scale
    case .Analog_2D:
        raw:=math.Vec2{in_.axes[binding.codes[0]],in_.axes[binding.codes[1]]}
        length:=linalg.length(raw)
        if length>binding.dead_zone {r.vector=raw/length*min((length-binding.dead_zone)/max(1-binding.dead_zone,1e-6),1)*binding.scale}
    case .Delta:
        r.axis=in_.axes[binding.codes[0]]*binding.scale
    case .Delta_2D:
        r.vector=math.Vec2{in_.axes[binding.codes[0]],in_.axes[binding.codes[1]]}*binding.scale
    }
    return
}

@(private)
chord_held :: proc "contextless" (in_:^Input,binding:^Binding) -> bool {
    for code in binding.chord[:binding.chord_count] {
        if !base.bits_test(in_.down,int(code)) {return false}
    }
    return true
}

// A held chord longer than that of the binding takes one of its codes.
@(private)
chord_overruled :: proc "contextless" (in_:^Input,binding:^Binding) -> bool {
    level:=binding.chord_count
    for code in binding.chord[:binding.chord_count] {
        if in_.taken[code]>level {return true}
    }
    used,on_axes:=binding_span(binding.kind)
    taken:=on_axes?in_.taken_axes:in_.taken
    for code in binding.codes[:used] {
        if taken[code]>level {return true}
    }
    return false
}

@(private)
input_finish :: proc "contextless" (in_:^Input,action:int,kind:Action_Kind,button_down,quick:bool,axis:f32,vector:math.Vec2,dt:f32) {
    down:bool
    value:f32
    switch kind {
    case .Button: down=button_down;value=1 if button_down else 0
    case .Axis: value=axis;down=axis!=0
    case .Axis2: value=linalg.length(vector);down=value>0
    }
    in_.states[action]=action_step(in_.states[action],down,quick,value,kind==.Axis2?vector:{},dt,in_.tap,in_.hold)
}

// The state of an action this tick, from whether it is down with its value
// and vector, and from its state the tick before, dt seconds ago: the edges,
// the tap and the hold. quick: it went down and up inside the tick, so it is
// not down. A threshold is met by the tick nearest to it, so the tap and the
// hold last the same at any tick rate.
action_step :: proc "contextless" (previous:Action_State,down,quick:bool,value:f32,vector:math.Vec2,dt,tap,hold:f32) -> (state:Action_State) {
    dt:=dt if dt>0 else 0
    state.down,state.value,state.vector=down,value,vector
    state.pressed=state.down && !previous.down
    state.released=!state.down && previous.down
    if quick && !state.down && !previous.down {state.pressed=true;state.released=true}
    if state.down {state.held=previous.held+dt if previous.down else dt}
    if state.released {
        state.released_held=previous.held
        state.tapped=previous.held<=tap+dt*0.5
    }
    state.holding=state.down && state.held>=hold-dt*0.5
    state.hold_started=state.holding && !previous.holding
    return
}

action_state :: proc "contextless" (in_:^Input,action:Action) -> Action_State {
    if action==0 || int(action)>in_.action_count {return {}}
    return in_.states[action-1]
}
action_down :: #force_inline proc "contextless" (in_:^Input,action:Action) -> bool {return action_state(in_,action).down}
action_pressed :: #force_inline proc "contextless" (in_:^Input,action:Action) -> bool {return action_state(in_,action).pressed}
action_released :: #force_inline proc "contextless" (in_:^Input,action:Action) -> bool {return action_state(in_,action).released}
action_tapped :: #force_inline proc "contextless" (in_:^Input,action:Action) -> bool {return action_state(in_,action).tapped}
action_hold_started :: #force_inline proc "contextless" (in_:^Input,action:Action) -> bool {return action_state(in_,action).hold_started}
action_holding :: #force_inline proc "contextless" (in_:^Input,action:Action) -> bool {return action_state(in_,action).holding}
action_value :: #force_inline proc "contextless" (in_:^Input,action:Action) -> f32 {return action_state(in_,action).value}
action_vector :: #force_inline proc "contextless" (in_:^Input,action:Action) -> math.Vec2 {return action_state(in_,action).vector}

@(private)
Accum :: struct {
    down,quick:bool, // held now; pressed and released since the last update
    axis:f32,
    vector:math.Vec2,
}
