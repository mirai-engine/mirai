package input

import "core:fmt"
import "core:os"
import "core:reflect"
import "core:strings"
import "mirai:core"
import "mirai:host"
import "mirai:project"
import "mirai:std/serial"

// The bindings the player changed are an option of the player: an input.mirai
// in the folder of its options (host.App.options), read over the one of the
// project when the map is built, with the actions whose kind or bindings
// differ from what the code and the project give.

// The input.mirai of the options of the player; "" without options.
input_options_file :: proc(app:^host.App) -> string {
    return host.app_options_file(app,project.INPUT_FILE)
}

// Writes the actions of the map that differ from the defaults of the code and
// input.mirai of the project to the input.mirai of the options of the
// player, or removes it when none does. False without options, or when the
// file could not be written or holds a binding no input.mirai can name.
input_options_write :: proc(m:^Input_Map,app:^host.App) -> bool {
    path:=input_options_file(app)
    if path=="" {return false}
    below:Input_Map
    file,text:string
    if app.root!="" {
        project_path:=project.path(app.root,project.INPUT_FILE,allocator=context.temp_allocator)
        if data,read_error:=os.read_entire_file(project_path,context.temp_allocator);read_error==nil {file,text=project_path,string(data)}
    }
    problems:core.Problems
    input_map_make(&below,app.info,file,text,&problems)
    written,ok:=input_map_text(m,&below,app.info)
    if !ok {return false}
    if written=="" {
        if os.is_file(path) {return os.remove(path)==nil}
        return true
    }
    return serial.file_write_atomic(path,transmute([]u8)written)==.None
}

// The text of an input.mirai with what m has over below: the tap and hold
// seconds, and each action whose kind or bindings differ. "" when nothing
// differs; ok false for a binding that the file cannot name.
input_map_text :: proc(m,below:^Input_Map,info:^core.World_Info,allocator:=context.temp_allocator) -> (text:string,ok:bool) {
    b:=strings.builder_make(allocator)
    fields:=0
    strings.write_string(&b,"{")
    if m.tap_seconds!=below.tap_seconds {fmt.sbprintf(&b,"\n    \"tap_seconds\": %v",m.tap_seconds);fields+=1}
    if m.hold_seconds!=below.hold_seconds {fmt.sbprintf(&b,"%s\n    \"hold_seconds\": %v",fields>0?",":"",m.hold_seconds);fields+=1}
    actions:=0
    for value in 0..<ACTION_CAPACITY {
        action:=Action(value)
        if m.declared&action_bit(action)==0 || input_map_action_same(m,below,action) {continue}
        name,declared:=core.name_of(info,Action,i64(value))
        if !declared {continue}
        if actions==0 {fmt.sbprintf(&b,"%s\n    \"actions\": [",fields>0?",":"")}
        fmt.sbprintf(&b,"%s\n        {{\"name\": %q, \"kind\": %q, \"bindings\": [",actions>0?",":"",name,reflect.enum_string(m.kinds[action]))
        count:=0
        for &binding in m.bindings[:m.binding_count] {
            if binding.action!=action {continue}
            if count>0 {strings.write_string(&b,", ")}
            input_binding_text(&b,binding) or_return
            count+=1
        }
        strings.write_string(&b,"]}")
        actions+=1
    }
    if actions>0 {strings.write_string(&b,"\n    ]");fields+=1}
    if fields==0 {return "",true}
    strings.write_string(&b,"\n}\n")
    return strings.to_string(b),true
}

// Whether an action has the same kind and bindings, in order, in two maps;
// a scale of 0 is the scale 1 it means.
input_map_action_same :: proc(a,b:^Input_Map,action:Action) -> bool {
    same :: proc(a,b:Input_Binding) -> bool {
        a,b:=a,b
        if a.scale==0 {a.scale=1}
        if b.scale==0 {b.scale=1}
        return a==b
    }
    if b.declared&action_bit(action)==0 || a.kinds[action]!=b.kinds[action] {return false}
    i,j:=0,0
    for {
        for i<int(a.binding_count) && a.bindings[i].action!=action {i+=1}
        for j<int(b.binding_count) && b.bindings[j].action!=action {j+=1}
        if i>=int(a.binding_count) || j>=int(b.binding_count) {return i>=int(a.binding_count) && j>=int(b.binding_count)}
        if !same(a.bindings[i],b.bindings[j]) {return false}
        i+=1;j+=1
    }
}

// A binding as input_binding_parse reads it; false when no input.mirai can name it.
input_binding_text :: proc(b:^strings.Builder,binding:Input_Binding) -> bool {
    binding:=binding
    strings.write_string(b,"{")
    codes:=binding.codes[:binding.count]
    same:=true
    for code in codes {same&&=code.device==codes[0].device}
    switch {
    case len(codes)==0 || !same:
        return false
    case len(codes)==1:
        code:=codes[0]
        switch code.device {
        case .Key:            fmt.sbprintf(b,"\"key\": %q",reflect.enum_string(core.Key(code.code)))
        case .Mouse_Button:   fmt.sbprintf(b,"\"mouse_button\": %q",reflect.enum_string(core.Mouse_Button(code.code)))
        case .Mouse_Axis:     fmt.sbprintf(b,"\"mouse\": %q",reflect.enum_string(Mouse_Axis(code.code)))
        case .Gamepad_Button: fmt.sbprintf(b,"\"gamepad_button\": %q",reflect.enum_string(core.Gamepad_Button(code.code)))
        case .Gamepad_Axis:   fmt.sbprintf(b,"\"gamepad_axis\": %q",reflect.enum_string(core.Gamepad_Axis(code.code)))
        case .None:           return false
        }
    case codes[0].device==.Key && (len(codes)==2 || len(codes)==4):
        strings.write_string(b,"\"keys\": [")
        for code,i in codes {fmt.sbprintf(b,"%s%q",i>0?", ":"",reflect.enum_string(core.Key(code.code)))}
        strings.write_string(b,"]")
    case codes[0].device==.Mouse_Axis && len(codes)==2:
        switch {
        case Mouse_Axis(codes[0].code)==.X && Mouse_Axis(codes[1].code)==.Y:             strings.write_string(b,"\"mouse\": \"Delta\"")
        case Mouse_Axis(codes[0].code)==.Wheel_X && Mouse_Axis(codes[1].code)==.Wheel_Y: strings.write_string(b,"\"mouse\": \"Wheel\"")
        case: return false
        }
    case codes[0].device==.Gamepad_Axis && len(codes)==2:
        switch {
        case core.Gamepad_Axis(codes[0].code)==.Left_X && core.Gamepad_Axis(codes[1].code)==.Left_Y:   strings.write_string(b,"\"gamepad_stick\": \"Left\"")
        case core.Gamepad_Axis(codes[0].code)==.Right_X && core.Gamepad_Axis(codes[1].code)==.Right_Y: strings.write_string(b,"\"gamepad_stick\": \"Right\"")
        case: return false
        }
    case:
        return false
    }
    if binding.scale!=0 && binding.scale!=1 {fmt.sbprintf(b,", \"scale\": %v",binding.scale)}
    if binding.dead_zone!=0 {fmt.sbprintf(b,", \"dead_zone\": %v",binding.dead_zone)}
    if binding.gamepad!=GAMEPAD_ANY {fmt.sbprintf(b,", \"gamepad\": %d",binding.gamepad)}
    if binding.chord_count>0 {
        strings.write_string(b,", \"chord\": [")
        for code,i in binding.chord[:min(int(binding.chord_count),CHORD_CAPACITY)] {
            if i>0 {strings.write_string(b,", ")}
            #partial switch code.device {
            case .Key:            fmt.sbprintf(b,"{{\"key\": %q}}",reflect.enum_string(core.Key(code.code)))
            case .Mouse_Button:   fmt.sbprintf(b,"{{\"mouse_button\": %q}}",reflect.enum_string(core.Mouse_Button(code.code)))
            case .Gamepad_Button: fmt.sbprintf(b,"{{\"gamepad_button\": %q}}",reflect.enum_string(core.Gamepad_Button(code.code)))
            case:                 return false
            }
        }
        strings.write_string(b,"]")
    }
    strings.write_string(b,"}")
    return true
}
