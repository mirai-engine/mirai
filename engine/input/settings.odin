package input

import "core:fmt"
import "core:strings"
import "mirai:core"
import "mirai:std/base"

// The bindings a project or a player changed are a setting of the machine
// (project/settings.odin): the section Input_Settings of settings.mirai. The
// file of the project holds the actions whose kind, context or bindings
// differ from the defaults of the code, and the one of the player the actions
// the player bound again; an entry replaces the one with the same action of
// the layers under it. The map builds again when the setting changes, and the
// save library writes the options of the player when they rest.

ACTION_NAME :: 32 // bytes of the name of an action in Input_Settings

// Written by the editor and by the options of a game: shared.
@(storage,shared,setting="machine")
Input_Settings :: struct {
    tap_seconds:f32 `mirai:"unit=s"`,  // 0: TAP_SECONDS
    hold_seconds:f32 `mirai:"unit=s"`, // 0: HOLD_SECONDS
    actions:[ACTION_CAPACITY]Action_Setting `mirai:"keyed"`,
}

// How an action is driven, by the name of the action; an empty name is no entry.
Action_Setting :: struct {
    action:[ACTION_NAME]u8 `mirai:"text"`,
    driven:Action_Bindings `mirai:"inline"`,
}

// The entry of an action; nil when the setting has none.
input_settings_find :: proc(settings:^Input_Settings,name:string) -> ^Action_Setting {
    if name=="" {return nil}
    for &entry in settings.actions {
        if base.text_get(entry.action[:])==name {return &entry}
    }
    return nil
}

// Gives an action its entry. False when the setting holds ACTION_CAPACITY
// actions or the name does not fit in ACTION_NAME bytes.
input_settings_put :: proc(settings:^Input_Settings,name:string,driven:Action_Bindings) -> bool {
    if name=="" || len(name)>ACTION_NAME {return false}
    entry:=input_settings_find(settings,name)
    if entry==nil {entry=input_settings_find_free(settings)}
    if entry==nil {return false}
    base.text_set(entry.action[:],name)
    entry.driven=driven
    return true
}

// The action back to the defaults of the code, as far as this layer goes.
input_settings_remove :: proc(settings:^Input_Settings,name:string) {
    if entry:=input_settings_find(settings,name);entry!=nil {entry^={}}
}

@(private="file")
input_settings_find_free :: proc(settings:^Input_Settings) -> ^Action_Setting {
    for &entry in settings.actions {
        if entry.action[0]==0 {return &entry}
    }
    return nil
}

// What is wrong with the setting, with how to fix it; "" when the map takes
// all of it. The editor refuses a change with a problem; the map reports each
// and keeps the defaults of the action.
input_settings_problem :: proc(info:^core.World_Info,settings:^Input_Settings) -> string {
    for seconds,i in ([2]f32{settings.tap_seconds,settings.hold_seconds}) {
        if seconds!=0 && seconds_kept(seconds)==0 {return fmt.tprintf("%s is %v: seconds above 0 and up to %v, or 0 for the default",i==0?"tap_seconds":"hold_seconds",seconds,SECONDS_MAX)}
    }
    for &entry in settings.actions {
        if entry.action[0]==0 {continue}
        if problem:=action_setting_problem(info,&entry);problem!="" {return problem}
    }
    return ""
}

// What is wrong with an entry of the setting; "".
action_setting_problem :: proc(info:^core.World_Info,entry:^Action_Setting) -> string {
    name:=base.text_get(entry.action[:])
    value,declared:=core.name_value(info,Action,name)
    if !declared || value<0 || value>=ACTION_CAPACITY {
        known:=strings.builder_make(context.temp_allocator)
        for entry,i in core.names_of(info,Action) {fmt.sbprintf(&known,"%s%s",i>0?", ":"",entry.name)}
        return fmt.tprintf("Input_Settings binds the action %q, which the code does not declare: rename it to one the code declares (%s) or remove it; a new action is a member %s of an enum @(actions) of the game",name,strings.to_string(known),member_name(name))
    }
    d:=&entry.driven
    if int(d.kind)>=len(Action_Kind) {return fmt.tprintf("the action %q of Input_Settings has the kind %d: %s",name,d.kind,kind_takes(d.kind))}
    if int(d.input_context)>=CONTEXT_CAPACITY {return fmt.tprintf("the action %q of Input_Settings is in the input context %d, and contexts take values below %d: name one the code declares, or leave it out for the base one",name,d.input_context,CONTEXT_CAPACITY)}
    used:=action_bindings(d)
    for &binding,i in d.bindings[len(used):] {
        if binding!={} {return fmt.tprintf("the binding %d of the action %q of Input_Settings comes after one that reads no input: give each binding its inputs, or remove the empty one",len(used)+i,name)}
    }
    for binding,i in used {
        if !binding_suits(d.kind,binding) {
            return fmt.tprintf("the binding %d of the action %q of Input_Settings is not one its kind %v takes: %s; a chord holds one or two keys or buttons, gamepad is 0 for every gamepad or 1 to %d, dead_zone is from 0 to 1 and scale is finite",i,name,d.kind,kind_takes(d.kind),GAMEPAD_ANY)
        }
    }
    return ""
}
