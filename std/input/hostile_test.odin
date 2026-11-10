package mirai_input

import "core:mem"
import "core:testing"
import "mirai:std/base"

// The input is handed sizes that are zero, negative or huge, actions, codes
// and axes it does not have, and numbers that are NaN or infinite, and is
// held against a model of its actions and bindings: what it takes is what the
// model takes, what it refuses changes nothing, and nothing stays allocated.

@(private="file") HOSTILE_ROUNDS :: #config(INPUT_HOSTILE_ROUNDS,400)

@(private="file") HOSTILE_ACTIONS :: 40
@(private="file") HOSTILE_BINDINGS :: 60
@(private="file") HOSTILE_CODES :: 600
@(private="file") HOSTILE_AXES :: 80

@(private="file")
hostile_u32 :: proc(h:^base.Hostile) -> u32 {
    switch base.hostile_int(h,8) {
    case 0: return 0
    case 1: return max(u32)
    case 2: return 1
    }
    return u32(base.hostile_int(h,100))
}

@(private="file")
hostile_name :: proc(h:^base.Hostile) -> u64 {
    switch base.hostile_int(h,5) {
    case 0: return 0
    case 1: return max(u64)
    }
    return u64(base.hostile_int(h,12))
}

// A size: below the limit, one past it, empty, negative or beyond any memory.
@(private="file")
hostile_size :: proc(h:^base.Hostile,limit:int) -> int {
    switch base.hostile_int(h,8) {
    case 0: return 0
    case 1: return -1
    case 2: return 1<<50
    case 3: return max(int)
    case 4: return limit+1
    }
    return base.hostile_int(h,limit)
}

// What a binding asks of its action and of its codes.
@(private="file")
Hostile_Binding :: struct {kind:Action_Kind,codes:int,on_axes:bool}

@(test)
hostile_bindings_through_the_input :: proc(t:^testing.T) {
    memory:base.Hostile_Memory
    context.allocator=base.hostile_memory_begin(&memory)
    defer {
        leaked,bad_frees:=base.hostile_memory_end(&memory)
        testing.expectf(t,leaked==0 && bad_frees==0,"%d allocations were left and %d frees were of nothing",leaked,bad_frees)
    }
    shapes:=[8]Hostile_Binding{{.Button,1,false},{.Button,1,true},{.Axis,2,false},{.Axis,1,true},{.Axis2,4,false},{.Axis2,2,true},{.Axis,1,true},{.Axis2,2,true}}
    h:=base.Hostile{25}
    kinds:[dynamic]Action_Kind
    names:[dynamic]u64
    bound:[dynamic]Action // the action of every binding
    defer {delete(kinds);delete(names);delete(bound)}
    for _ in 0..<HOSTILE_ROUNDS {
        if testing.failed(t) {return}
        clear(&kinds);clear(&names);clear(&bound)
        in_:Input
        desc:=Input_Desc{max_actions=hostile_size(&h,HOSTILE_ACTIONS),max_bindings=hostile_size(&h,HOSTILE_BINDINGS),code_count=hostile_size(&h,HOSTILE_CODES),axis_count=hostile_size(&h,HOSTILE_AXES),tap_ticks=hostile_u32(&h),hold_ticks=hostile_u32(&h)}
        fits:=desc.max_actions>0 && desc.max_actions<=HOSTILE_ACTIONS+1 && desc.max_bindings>0 && desc.max_bindings<=HOSTILE_BINDINGS+1 && desc.code_count<=HOSTILE_CODES+1 && desc.axis_count<=HOSTILE_AXES+1
        ok:=input_init(&in_,desc)
        testing.expect(t,ok==fits && (ok || mem.check_zero_ptr(&in_,size_of(in_))),"The input takes the sizes it can hold and stays zeroed on the others")
        if ok {
            for _ in 0..<60 {
                action:=Action(base.hostile_next(&h) if base.hostile_int(&h,4)==0 else u64(base.hostile_int(&h,len(kinds)+2)))
                code:=Input_Code(base.hostile_next(&h) if base.hostile_int(&h,3)==0 else u64(base.hostile_int(&h,HOSTILE_CODES)))
                axis:=Axis_Code(base.hostile_next(&h) if base.hostile_int(&h,3)==0 else u64(base.hostile_int(&h,HOSTILE_AXES)))
                other:=Input_Code(base.hostile_next(&h) if base.hostile_int(&h,2)==0 else u64(base.hostile_int(&h,HOSTILE_CODES)))
                other_axis:=Axis_Code(base.hostile_next(&h) if base.hostile_int(&h,2)==0 else u64(base.hostile_int(&h,HOSTILE_AXES)))
                a,b:=base.hostile_f32(&h),base.hostile_f32(&h)
                known:=action>0 && int(action)<=len(kinds)
                switch op:=base.hostile_int(&h,19);op {
                case 0..<8:
                    took:bool
                    codes:[4]int
                    switch op {
                    case 0: took=input_bind_code(&in_,action,code);codes={int(code),0,0,0}
                    case 1: took=input_bind_axis_button(&in_,action,axis,a,b);codes={int(axis),0,0,0}
                    case 2: took=input_bind_codes_axis(&in_,action,code,other,a);codes={int(code),int(other),0,0}
                    case 3: took=input_bind_axis(&in_,action,axis,a,b);codes={int(axis),0,0,0}
                    case 4: took=input_bind_codes_2d(&in_,action,code,code+1,other,code);codes={int(code),int(code+1),int(other),int(code)}
                    case 5: took=input_bind_axes_2d(&in_,action,axis,other_axis,a,b);codes={int(axis),int(other_axis),0,0}
                    case 6: took=input_bind_delta(&in_,action,axis,a);codes={int(axis),0,0,0}
                    case 7: took=input_bind_delta_2d(&in_,action,axis,axis+1,a);codes={int(axis),int(axis+1),0,0}
                    }
                    shape:=shapes[op]
                    wanted:=known && kinds[max(int(action),1)-1]==shape.kind && len(bound)<desc.max_bindings
                    for used in codes[:shape.codes] {wanted&&=used<(in_.axis_count if shape.on_axes else in_.code_count)}
                    testing.expectf(t,took==wanted,"A binding of shape %d is taken exactly when its action is of its kind, its codes are in range and there is room",op)
                    if took {append(&bound,action)}
                case 8,9:
                    name:=hostile_name(&h)
                    kind:=Action_Kind(base.hostile_int(&h,3))
                    added:=input_add_action(&in_,kind,name)
                    testing.expect(t,int(added)==(len(kinds)+1 if len(kinds)<desc.max_actions else 0),"An action gets the next handle, or none when there is no room")
                    if added!=0 {append(&kinds,kind);append(&names,name)}
                case 10:
                    input_unbind(&in_,action)
                    #reverse for owner,i in bound {
                        if known && owner==action {ordered_remove(&bound,i)}
                    }
                case 11,12:
                    testing.expect(t,input_set_code(&in_,code,base.hostile_int(&h,2)==0)==(int(code)<in_.code_count),"Only a code in range is reported")
                case 13,14:
                    testing.expect(t,input_set_axis(&in_,axis,a)==(int(axis)<in_.axis_count),"Only an axis in range is reported")
                case 15: input_release_all(&in_)
                case 16,17:
                    input_update(&in_)
                    for i in 1..=len(kinds) {
                        s:=action_state(&in_,Action(i))
                        consistent:=!(s.released && s.down) && (!s.pressed || s.down || s.released) && (s.held_ticks>0)==s.down
                        consistent&&=(!s.tapped || s.released) && (!s.holding || s.down) && (!s.hold_started || s.holding)
                        if !testing.expectf(t,consistent,"The state of an action contradicts itself: %v",s) {return}
                    }
                case 18:
                    name:=hostile_name(&h)
                    first:=0
                    #reverse for held,i in names {if held==name {first=i+1}}
                    testing.expect_value(t,int(input_find_action(&in_,name)),first)
                    testing.expect(t,known || action_state(&in_,action)=={},"An action the input does not have reads as idle")
                }
                if !testing.expect(t,in_.action_count==len(kinds) && in_.binding_count==len(bound),"The input has the actions and the bindings of the model") {return}
            }
            input_destroy(&in_)
        }
        input_destroy(&in_)
        zero:Input
        action:=Action(base.hostile_next(&h))
        refused:=input_add_action(&zero,.Button)==0 && !input_bind_code(&zero,action,0) && !input_set_code(&zero,0,true) && !input_set_axis(&zero,0,1)
        input_update(&zero);input_release_all(&zero);input_unbind(&zero,action)
        testing.expect(t,refused && input_find_action(&zero,1)==0 && action_state(&zero,action)=={},"A zeroed input has no actions, codes or axes")
        input_destroy(&zero)
    }
}
