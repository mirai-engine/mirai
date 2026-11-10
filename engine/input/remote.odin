package input

import "core:math/linalg"
import "mirai:core"
import si "mirai:std/input"
import "mirai:std/math"

// The actions of a seat as the end that has its devices took them for a tick,
// for another end to take as its own: a client sends those of the seat that
// drives its body, and the server gives them to the seat of that connection.
// They are the actions as seat_action sees them there, in the contexts, with
// the blocks and the re-arming of that end. What travels is what is down and
// the values of the axes; the end that takes them derives the edges, the taps
// and the holds from the tick before (seat_receive), with its own map.

REMOTE_AXES :: 6 // axis actions away from zero in one tick
#assert(ACTION_CAPACITY<=64)

Remote_Actions :: struct {
    down:Action_Mask,   // buttons held and axes away from zero
    quick:Action_Mask,  // went down and up inside the tick
    motion:Action_Mask, // down by the movement of the mouse of the tick, which a repeated tick does not repeat
    axis_count:u8 `mirai:"bits=3"`,
    axes:[REMOTE_AXES]Remote_Axis,
}

Remote_Axis :: struct {
    action:Action `mirai:"bits=6"`,
    value:[2]f32 `mirai:"precision=0.0009765625"`, // Axis: x; Axis2: x and y
}

// The actions of a seat for another end; ok false when more axis actions are
// away from zero than REMOTE_AXES, and the rest do not go.
seat_remote :: proc(seats:^core.Table(Seat,$A),seat:core.Entity,bindings:^Input_Map) -> (sent:Remote_Actions,ok:bool) {
    ok=true
    row:=core.row_of(seats,seat)
    if row<0 || bindings==nil {return}
    source:=&seats.values[row]
    moved:=motion_actions(bindings)
    off:=source.blocked|source.rearm
    for state,i in source.actions.states[:min(int(source.actions.count),ACTION_CAPACITY)] {
        bit:=action_bit(Action(i))
        if off&bit!=0 {continue}
        if !state.down {
            if state.pressed && state.released {sent.quick|=bit}
            continue
        }
        sent.down|=bit
        sent.motion|=moved&bit
        kind:=bindings.kinds[i]
        if kind==.Button {continue}
        if int(sent.axis_count)>=REMOTE_AXES {
            ok=false
            continue
        }
        sent.axes[sent.axis_count]={action=Action(i),value=kind==.Axis?[2]f32{state.value,0}:state.vector}
        sent.axis_count+=1
    }
    return
}

// The actions of a seat for the tick, from what another end sent of them: the
// edges, taps and holds from the tick before, as if its devices were here.
// The contexts were applied by that end, and the ones of the seat here are not.
seat_receive :: proc(seat:^Seat,bindings:^Input_Map,sent:Remote_Actions,dt:f32) {
    actions_receive(&seat.actions,bindings,sent,dt)
    seat.held=held_buttons(&seat.actions,bindings)
    seat.rearm&=seat.held
    seat.fed=seat.contexts
}

// What a tick whose actions did not arrive takes from the last that did:
// what is held stays held, so it is neither let go nor pressed again; a tap
// and the movement of the mouse were of the tick they were sent for.
remote_repeated :: proc "contextless" (sent:Remote_Actions) -> (out:Remote_Actions) {
    sent:=sent
    out.down=sent.down&~sent.motion
    for axis in sent.axes[:min(int(sent.axis_count),REMOTE_AXES)] {
        if sent.motion&action_bit(axis.action)!=0 {continue}
        out.axes[out.axis_count]=axis
        out.axis_count+=1
    }
    return
}

// The actions of the map for the tick from what another end sent of them. An
// axis it did not send is at zero; what names an action out of the map is
// left out.
actions_receive :: proc(actions:^Actions,m:^Input_Map,sent:Remote_Actions,dt:f32) {
    if m==nil {
        actions^={}
        return
    }
    sent:=sent
    count:=action_end(m)
    values:[ACTION_CAPACITY][2]f32
    for axis in sent.axes[:min(int(sent.axis_count),REMOTE_AXES)] {
        if int(axis.action)<count {values[axis.action]=axis.value}
    }
    tap:=m.tap_seconds>0?m.tap_seconds:TAP_SECONDS
    hold:=m.hold_seconds>0?m.hold_seconds:HOLD_SECONDS
    for i in 0..<count {
        previous:=i<int(actions.count)?actions.states[i]:{}
        bit:=action_bit(Action(i))
        down:=sent.down&bit!=0
        value:f32
        vector:math.Vec2
        switch m.kinds[i] {
        case .Button: value=down?1:0
        case .Axis:   value=down?values[i].x:0
        case .Axis2:
            if down {vector=values[i]}
            value=linalg.length(vector)
        }
        actions.states[i]=si.action_step(previous,down,sent.quick&bit!=0,value,vector,dt,tap,hold)
    }
    for i in count..<int(actions.count) {actions.states[i]={}}
    actions.count=u32(count)
}

// The actions a mouse axis drives: what moves by the movement of the tick.
@(private)
motion_actions :: proc "contextless" (m:^Input_Map) -> (mask:Action_Mask) {
    for &binding in m.bindings[:min(int(m.binding_count),BINDING_CAPACITY)] {
        for code in binding.codes[:min(int(binding.count),len(binding.codes))] {
            if code.device==.Mouse_Axis && int(binding.action)<ACTION_CAPACITY {mask|=action_bit(binding.action)}
        }
    }
    return
}
