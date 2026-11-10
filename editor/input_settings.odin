package editor

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:reflect"
import "core:slice"
import "core:strings"
import "mirai:core"
import "mirai:editor/api"
import "mirai:engine/gui"
import input "mirai:engine/input"
import "mirai:host"
import "mirai:platform"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// The input actions in Project Settings and in input.get and input.set: the
// actions the code declares, with the kind and the bindings that input.mirai
// of the project gives them over the defaults of the code. The file keeps
// only the actions and ticks that differ from the code; the edited World and
// the runs build their maps again from it.

// How far a stick or trigger moves from where it was, and how many points
// the mouse moves, to be the input a binding listens for.
INPUT_LISTEN_AXIS :: f32(0.6)
INPUT_LISTEN_MOUSE :: f32(160)
// The longest tap or hold, in ticks.
INPUT_TICKS_MAX :: 600

Input_Settings :: struct {
    code:input.Input_Map,    // the defaults of the code
    current:input.Input_Map, // input.mirai of the project over them
    problem:[512]u8,         // why input.mirai of the project was not read: nothing is written over it
    loaded,unsaved:bool,     // unsaved: a value changes that the file does not have yet
    listen:Input_Listen,
}

// A binding that waits for the next key, button or axis; Escape cancels it.
Input_Listen :: struct {
    active:bool,
    whole:bool,   // every code of the binding comes from what is pressed, one after the other
    action:input.Action,
    binding:int,  // among the bindings of the action; -1: a new one
    slot:int,     // the code that comes next
    gathered:input.Input_Binding,
    axes:[core.GAMEPAD_CAPACITY][core.Gamepad_Axis]f32, // of the gamepads, as they were
    mouse:[2]f32, // moved since it began
}

@(private)
input_settings_file :: proc(s:^Session) -> string {
    return project.path(s.project_root,project.INPUT_FILE,allocator=context.temp_allocator)
}

// Reads the actions of the code and input.mirai of the project again.
input_settings_load :: proc(s:^Session) {
    st:=&s.settings_dialog.input
    input.input_map_make(&st.code,s.info,"","",nil)
    st.current=st.code
    st.problem={}
    st.loaded,st.unsaved,st.listen=true,false,{}
    if !s.has_project {return}
    path:=input_settings_file(s)
    data,read_error:=os.read_entire_file(path,context.temp_allocator)
    if read_error!=nil {return}
    if error,at:=input.input_map_parse(&st.current,s.info,string(data));error!=.None {
        st.current=st.code
        base.text_set(st.problem[:],input_file_problem(s,path,error,at))
    }
}

@(private)
input_file_problem :: proc(s:^Session,path:string,error:input.Input_Map_Error,at:string) -> string {
    if error==.Unknown_Action {
        return fmt.tprintf("%s names the action %q, which the code does not declare: rename it to one of %s, or remove it",path,at,input_action_names(s))
    }
    return fmt.tprintf("%s could not be read: %v in the action %q; %s, or remove the file",path,error,at,input.input_map_error_fix(error))
}

// The names of the actions the code declares, for an error that lists them.
@(private)
input_action_names :: proc(s:^Session) -> string {
    names:=make([dynamic]string,context.temp_allocator)
    for entry in core.names_of(s.info,input.Action) {
        if entry.value>=0 && entry.value<input.ACTION_CAPACITY {append(&names,entry.name)}
    }
    if len(names)==0 {return "none"}
    return strings.join(names[:],", ",context.temp_allocator)
}

// Writes what the bindings have over the code to input.mirai of the project,
// or removes the file when nothing differs; the edited World and the runs
// build their maps again. "" or what went wrong.
input_settings_write :: proc(s:^Session) -> string {
    st:=&s.settings_dialog.input
    st.unsaved=false
    if !s.has_project {return "There is no project to keep the bindings in"}
    if problem:=base.text_get(st.problem[:]);problem!="" {return problem}
    text,ok:=input.input_map_text(&st.current,&st.code,s.info)
    if !ok {return "A binding cannot be written to input.mirai: give it keys, or buttons and axes one at a time"}
    path:=input_settings_file(s)
    if text=="" {
        if os.is_file(path) && os.remove(path)!=nil {return fmt.tprintf("%s could not be removed",path)}
    } else if serial.file_write_atomic(path,transmute([]u8)text)!=.None {
        return fmt.tprintf("%s could not be written",path)
    }
    input_maps_rebuild(s)
    return ""
}

// The maps of the edited World and of each run build again from the files.
@(private)
input_maps_rebuild :: proc(s:^Session) {
    if s.info==nil {return}
    if s.edit_world!=nil {
        if m:=core.world_storage_of(edited_world(s),input.Input_Map);m!=nil {m.built=false}
    }
    for &r in s.runs {
        if r.world==nil {continue}
        if m:=core.world_storage_of(run_ref(s,&r),input.Input_Map);m!=nil {m.built=false}
    }
}

@(private)
input_settings_commit :: proc(s:^Session) {
    if message:=input_settings_write(s);message!="" {notify(s,message)}
}

// The index in the map of the nth binding of an action; -1 when it has fewer.
@(private)
input_binding_index :: proc(m:^input.Input_Map,action:input.Action,nth:int) -> int {
    n:=0
    for &binding,i in m.bindings[:m.binding_count] {
        if binding.action!=action {continue}
        if n==nth {return i}
        n+=1
    }
    return -1
}

@(private)
input_binding_remove :: proc(m:^input.Input_Map,index:int) {
    if index<0 || index>=int(m.binding_count) {return}
    copy(m.bindings[index:m.binding_count-1],m.bindings[index+1:m.binding_count])
    m.binding_count-=1
    m.bindings[m.binding_count]={}
}

// The action back to the kind and the bindings of the code.
input_action_restore :: proc(m,code:^input.Input_Map,action:input.Action) {
    input.input_map_unbind(m,action)
    input.input_map_action(m,action,code.kinds[action])
    for binding in code.bindings[:code.binding_count] {
        if binding.action==action {input.input_map_bind(m,action,binding)}
    }
}

// A number of ticks as the map keeps it: 0 for the default.
@(private)
input_ticks_kept :: proc(value,default:u32) -> u32 {return value==default?0:value}
@(private)
input_ticks_shown :: proc(value,default:u32) -> u32 {return value>0?value:default}

// ---------------------------------------------------------------- panel

// A card of the Input category: an action, or the ticks (action -1).
@(private)
Input_Card :: struct {
    title:string,
    action:i64,
}

INPUT_TIMING :: "Timing"

// The cards of the category: an action each and the ticks, those whose name has needle.
@(private)
input_cards :: proc(s:^Session,needle:string) -> []Input_Card {
    cards:=make([dynamic]Input_Card,context.temp_allocator)
    every:=needle=="" || base.contains_fold("Input",needle)
    for entry in core.names_of(s.info,input.Action) {
        if entry.value<0 || entry.value>=input.ACTION_CAPACITY {continue}
        title:=readable(entry.name)
        if every || base.contains_fold(title,needle) {append(&cards,Input_Card{title,entry.value})}
    }
    if every || base.contains_fold(INPUT_TIMING,needle) || base.contains_fold("Tap ticks",needle) || base.contains_fold("Hold ticks",needle) {append(&cards,Input_Card{INPUT_TIMING,-1})}
    return cards[:]
}

@(private)
input_sections :: proc(s:^Session,needle:string) -> []string {
    cards:=input_cards(s,needle)
    titles:=make([]string,len(cards),context.temp_allocator)
    for card,i in cards {titles[i]=card.title}
    return titles
}

@(private)
input_settings_cards :: proc(s:^Session,needle:string) {
    ctx:=s.gui.ctx
    th:=&ctx.theme
    st:=&s.settings_dialog.input
    if !st.loaded {input_settings_load(s)}
    ui.id_push(ctx,ui.id(ctx,"input"))
    defer ui.id_pop(ctx)
    if problem:=base.text_get(st.problem[:]);problem!="" {
        if section_card(s,settings_card_id(s,SETTINGS_CATEGORY_INPUT,0),"") {ui.paragraph(ctx,problem,th.font_small,th.text_muted)}
        return
    }
    for card,k in input_cards(s,needle) {
        // The card ends with the if that opens it: its rows go inside.
        if section_card(s,settings_card_id(s,SETTINGS_CATEGORY_INPUT,k),card.title) {
            if card.action<0 {input_timing_rows(s)} else {input_action_rows(s,input.Action(card.action))}
        }
    }
}

@(private)
INPUT_KINDS :: [?]string{"Button","Axis","Axis2"}
@(private)
INPUT_GAMEPADS :: [?]string{"Any","1","2","3","4"}

// The kind of an action, a row per binding and the row that adds one, ruled
// as the rows of the cards of the other categories.
@(private)
input_action_rows :: proc(s:^Session,action:input.Action) {
    ctx:=s.gui.ctx
    th:=&ctx.theme
    st:=&s.settings_dialog.input
    m:=&st.current
    ui.id_push(ctx,ui.id(ctx,"action",int(action)+1))
    defer ui.id_pop(ctx)
    row_begin(ctx,"Kind")
    kind:=int(m.kinds[action])
    kinds:=INPUT_KINDS
    if ui.dropdown(ctx,ui.id(ctx,"kind"),{list=kinds[:]},&kind,{width=-1,height=th.row}) && input.Action_Kind(kind)!=m.kinds[action] {
        st.listen={}
        input.input_map_action(m,action,input.Action_Kind(kind))
        input_settings_commit(s)
    }
    if input.input_map_action_same(m,&st.code,action) {
        ui.spacer(ctx,REVERT_SIDE,1)
    } else if ui.button(ctx,ui.id(ctx,"restore"),{icon=.Revert,icon_size=12,icon_color=th.text_muted,style=.Ghost,width=REVERT_SIDE,height=REVERT_SIDE}).clicked {
        st.listen={}
        input_action_restore(m,&st.code,action)
        input_settings_commit(s)
    }
    row_end(ctx)
    for nth:=0;;nth+=1 {
        index:=input_binding_index(m,action,nth)
        if index<0 {break}
        input_row_rule(ctx)
        if input_binding_row(s,action,nth,index) {break}
    }
    input_row_rule(ctx)
    l:=&st.listen
    row_begin(ctx,"")
    if l.active && l.action==action && l.binding<0 {
        input_listen_chip(s,ui.id(ctx,"adding"),l.gathered,l.slot)
    } else {
        add,menu:=ui.id(ctx,"add"),ui.id(ctx,"add_menu")
        open:=ui.popup_is_open(ctx,menu)
        if ui.button(ctx,add,{label="Add binding",icon=.Plus,icon_size=11,icon_color=th.text_muted,style=.Ghost,height=th.row,size=th.font_small,active=open}).clicked && !open {
            anchor,_:=ui.widget_rect(ctx,add)
            ui.popup_open(ctx,menu,anchor)
        }
        input_choices_menu(s,menu,action,-1)
    }
    row_end(ctx)
}

@(private)
input_row_rule :: proc(ctx:^ui.Context) {
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(1),fill=ctx.theme.row_rule}) {}
}

// A binding: its device in the column of labels, which folds its options
// when it has any, what drives it and the button that removes it. A click on
// a code listens for another one and a right click lists them. True when it
// changed the bindings of the action.
@(private)
input_binding_row :: proc(s:^Session,action:input.Action,nth,index:int) -> (changed:bool) {
    ctx:=s.gui.ctx
    th:=&ctx.theme
    st:=&s.settings_dialog.input
    m:=&st.current
    l:=&st.listen
    binding:=m.bindings[index]
    kind:=m.kinds[action]
    scaled,zoned,padded,zone:=input.binding_uses(kind,binding)
    ui.id_push(ctx,ui.id(ctx,"binding",nth+1))
    defer ui.id_pop(ctx)
    key:=base.hash_combine(u64(action)<<16|u64(nth),0x696e707574)
    menu:=ui.id(ctx,"menu")
    open:=false
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.row),gap=4,align_y=.Center}) {
        menus:=INPUT_MENUS
        device:=menus[input_code_menu(binding.codes[0])]
        if scaled || zoned || padded {
            open=inspector_section_open(s.inspector,key,true)
            if fold_label(s,ui.id(ctx,"fold"),device,open) {
                inspector_section_toggle(s.inspector,key)
                open=!open
            }
        } else {
            ui.column_label(ctx,device)
        }
        listening:=l.active && l.action==action && l.binding==nth
        if listening && l.whole {
            input_listen_chip(s,ui.id(ctx,"listen"),l.gathered,l.slot)
        } else {
            for group in input_binding_groups(binding) {
                id:=ui.id(ctx,"code",group.slot+1)
                if listening && l.slot==group.slot {
                    input_listen_chip(s,id,{},0)
                    continue
                }
                it:=input_code_chip(s,id,binding.codes[group.slot])
                if it.clicked {input_listen_start(s,action,nth,group.slot,!group.alone)}
                if it.right && !ui.popup_is_open(ctx,menu) {
                    anchor,_:=ui.widget_rect(ctx,id)
                    ui.popup_open(ctx,menu,anchor)
                }
            }
        }
        input_choices_menu(s,menu,action,nth)
        ui.spacer(ctx)
        if ui.button(ctx,ui.id(ctx,"remove"),{icon=.Cross,icon_size=10,icon_color=th.text_muted,style=.Ghost,width=REVERT_SIDE,height=REVERT_SIDE}).clicked {
            st.listen={}
            input_binding_remove(m,index)
            input_settings_commit(s)
            return true
        }
    }
    if !open {return}
    fold_band_begin(s)
    defer fold_band_end(s)
    b:=&m.bindings[index]
    if scaled {
        row_begin(ctx,"Scale")
        value:=f64(b.scale!=0?b.scale:1)
        r:=ui.number_field(ctx,ui.id(ctx,"scale"),&value,{decimals=3,speed=0.01})
        if r.changed {b.scale=f32(value);st.unsaved=true}
        if st.unsaved && !r.scrubbing && !r.editing {input_settings_commit(s)}
        row_end(ctx)
    }
    if zoned {
        row_begin(ctx,"Dead zone")
        value:=f64(zone)
        r:=ui.number_field(ctx,ui.id(ctx,"dead_zone"),&value,{decimals=3,speed=0.005,min=0.01,max=0.95,has_min=true,has_max=true})
        if r.changed {b.dead_zone=f32(value);st.unsaved=true}
        if st.unsaved && !r.scrubbing && !r.editing {input_settings_commit(s)}
        row_end(ctx)
    }
    if padded {
        row_begin(ctx,"Gamepad")
        pads:=INPUT_GAMEPADS
        chosen:=b.gamepad==input.GAMEPAD_ANY?0:int(b.gamepad)+1
        if ui.dropdown(ctx,ui.id(ctx,"gamepad"),{list=pads[:]},&chosen,{width=-1,height=th.row}) {
            b.gamepad=chosen==0?input.GAMEPAD_ANY:u8(chosen-1)
            input_settings_commit(s)
        }
        row_end(ctx)
    }
    return
}

// A chip of a binding: the code of slot, alone when it stands for the whole
// binding (one code, or the two axes of a stick or of the mouse).
@(private)
Input_Group :: struct {slot:int,alone:bool}

@(private)
input_binding_groups :: proc(binding:input.Input_Binding) -> []Input_Group {
    groups:=make([dynamic]Input_Group,context.temp_allocator)
    count:=int(binding.count)
    paired:=count==2 && binding.codes[0].device==binding.codes[1].device && (binding.codes[0].device==.Gamepad_Axis || binding.codes[0].device==.Mouse_Axis)
    if count<=1 || paired {
        append(&groups,Input_Group{0,true})
        return groups[:]
    }
    for slot in 0..<min(count,4) {append(&groups,Input_Group{slot,false})}
    return groups[:]
}

// What a code shows: its prompt as the game finds it (the image of the
// settings or of the pack of UI_Settings, or else its drawing), or its name
// where no prompt shows it.
@(private)
input_code_prompt :: proc(s:^Session,code:input.Input_Code) -> (prompt:ui.Prompt,name:string,shown:bool) {
    keyboard:=code.device==.Key || code.device==.Mouse_Button || code.device==.Mouse_Axis
    input_kind:ui.Prompt_Input
    input_kind,shown=gui.prompt_input(code,keyboard)
    #partial switch code.device {
    case .Key:            name=reflect.enum_string(core.Key(code.code))
    case .Mouse_Button:   name=fmt.tprintf("Mouse %v",core.Mouse_Button(code.code))
    case .Mouse_Axis:     name=fmt.tprintf("Mouse %v",input.Mouse_Axis(code.code))
    case .Gamepad_Button: name=reflect.enum_string(core.Gamepad_Button(code.code))
    case .Gamepad_Axis:   name=reflect.enum_string(core.Gamepad_Axis(code.code))
    }
    if !shown {return}
    prompt={family=keyboard?.Keyboard:.Xbox,input=input_kind}
    if input_kind==.Key {prompt.text=name}
    if settings:=cast(^gui.UI_Settings)setting_value(s,gui.UI_Settings);settings!=nil && s.app!=nil {
        prompt=gui.prompt_shown(s.app.assets,s.app.renderer,settings,host.content_prompts(s.app,settings.prompts),prompt)
    }
    return
}

@(private)
input_code_chip :: proc(s:^Session,id:ui.Id,code:input.Input_Code) -> ui.Interaction {
    ctx:=s.gui.ctx
    th:=&ctx.theme
    it:=ui.interact(ctx,id,{.Focusable})
    if ui.box(ctx,{id=id,width=ui.FIT,height=ui.fixed(th.row),padding={3,0,3,0},gap=4,align_y=.Center,fill=it.hot?th.field_hover:th.well,stroke=th.well_stroke,radius=th.radius_control}) {
        prompt,name,shown:=input_code_prompt(s,code)
        if shown {ui.prompt_glyph(ctx,prompt,th.row-6)} else {ui.label(ctx,name,th.font_small,th.text,0)}
    }
    return it
}

// The menus of Add binding and of a right click on a code, by device.
@(private)
Input_Menu :: enum u8 {Keyboard,Mouse,Gamepad}
@(private)
INPUT_MENUS :: [Input_Menu]string{.Keyboard="Keyboard",.Mouse="Mouse",.Gamepad="Gamepad"}

@(private)
input_code_menu :: proc(code:input.Input_Code) -> Input_Menu {
    #partial switch code.device {
    case .Mouse_Button,.Mouse_Axis:     return .Mouse
    case .Gamepad_Button,.Gamepad_Axis: return .Gamepad
    }
    return .Keyboard
}

// A binding the menus offer: in the menu of its device and, when group
// names one, in a submenu of it.
@(private)
Input_Choice :: struct {
    menu:Input_Menu,
    group:string,
    name:string,
    binding:input.Input_Binding,
}

@(private)
Input_Key_Group :: struct {name:string,first,last:core.Key}
@(private)
INPUT_KEY_GROUPS :: [?]Input_Key_Group{
    {"Letters A to M",.A,.M},{"Letters N to Z",.N,.Z},{"Digits",.Zero,.Nine},{"Function keys",.F1,.F12},
    {"Editing",.Escape,.Insert},{"Navigation",.Home,.Down},{"Modifiers",.Left_Shift,.Right_Super},{"Symbols",.Minus,.Grave},
}
@(private)
INPUT_MOUSE_AXES :: [input.Mouse_Axis]string{.X="Move X",.Y="Move Y",.Wheel_X="Wheel X",.Wheel_Y="Wheel Y"}
@(private)
INPUT_GAMEPAD_AXES :: [core.Gamepad_Axis]string{.Left_X="Left stick X",.Left_Y="Left stick Y",.Right_X="Right stick X",.Right_Y="Right stick Y",.Left_Trigger="Left trigger",.Right_Trigger="Right trigger"}

// What the menus offer to an action of a kind, ordered by menu and group: a
// Button every key, button and axis; an Axis every axis and pairs of keys
// and buttons; an Axis2 the sets of four keys or buttons, the sticks and the
// mouse. Other keys for an axis are listened for.
@(private)
input_choices :: proc(kind:input.Action_Kind) -> []Input_Choice {
    choices:=make([dynamic]Input_Choice,context.temp_allocator)
    add :: proc(choices:^[dynamic]Input_Choice,menu:Input_Menu,group,name:string,binding:input.Input_Binding) {append(choices,Input_Choice{menu,group,name,binding})}
    buttons :: proc(codes:..input.Input_Code) -> input.Input_Binding {
        b:=input.Input_Binding{count=u8(len(codes)),gamepad=input.GAMEPAD_ANY}
        copy(b.codes[:],codes)
        return b
    }
    pad :: input.code_gamepad_button
    mouse_axes,pad_axes:=INPUT_MOUSE_AXES,INPUT_GAMEPAD_AXES
    switch kind {
    case .Button:
        groups:=INPUT_KEY_GROUPS
        for g in groups {
            for k in int(g.first)..=int(g.last) {add(&choices,.Keyboard,g.name,readable(reflect.enum_string(core.Key(k))),input.binding_key(core.Key(k)))}
        }
        for button in core.Mouse_Button {add(&choices,.Mouse,"",fmt.tprintf("%s button",readable(reflect.enum_string(button))),input.binding_mouse_button(button))}
        for axis in input.Mouse_Axis {add(&choices,.Mouse,"",mouse_axes[axis],input.binding_mouse_axis(axis))}
        for button in core.Gamepad_Button {add(&choices,.Gamepad,"Buttons",readable(reflect.enum_string(button)),input.binding_gamepad_button(button))}
        for axis in core.Gamepad_Axis {add(&choices,.Gamepad,"Sticks and triggers",pad_axes[axis],input.binding_gamepad_axis(axis))}
    case .Axis:
        add(&choices,.Keyboard,"","A / D",input.binding_key_axis(.A,.D))
        add(&choices,.Keyboard,"","S / W",input.binding_key_axis(.S,.W))
        add(&choices,.Keyboard,"","Q / E",input.binding_key_axis(.Q,.E))
        add(&choices,.Keyboard,"","Left / Right",input.binding_key_axis(.Left,.Right))
        add(&choices,.Keyboard,"","Down / Up",input.binding_key_axis(.Down,.Up))
        for axis in input.Mouse_Axis {add(&choices,.Mouse,"",mouse_axes[axis],input.binding_mouse_axis(axis))}
        for axis in core.Gamepad_Axis {add(&choices,.Gamepad,"",pad_axes[axis],input.binding_gamepad_axis(axis))}
        add(&choices,.Gamepad,"","Dpad left / right",buttons(pad(.Dpad_Left),pad(.Dpad_Right)))
        add(&choices,.Gamepad,"","Dpad down / up",buttons(pad(.Dpad_Down),pad(.Dpad_Up)))
        add(&choices,.Gamepad,"","Shoulders",buttons(pad(.Left_Shoulder),pad(.Right_Shoulder)))
    case .Axis2:
        add(&choices,.Keyboard,"","WASD",input.binding_keys(.A,.D,.S,.W))
        add(&choices,.Keyboard,"","Arrow keys",input.binding_keys(.Left,.Right,.Down,.Up))
        add(&choices,.Mouse,"","Move",input.binding_mouse_delta())
        add(&choices,.Mouse,"","Wheel",buttons({.Mouse_Axis,u8(input.Mouse_Axis.Wheel_X)},{.Mouse_Axis,u8(input.Mouse_Axis.Wheel_Y)}))
        add(&choices,.Gamepad,"","Left stick",input.binding_gamepad_stick(.Left))
        add(&choices,.Gamepad,"","Right stick",input.binding_gamepad_stick(.Right))
        add(&choices,.Gamepad,"","Dpad",buttons(pad(.Dpad_Left),pad(.Dpad_Right),pad(.Dpad_Down),pad(.Dpad_Up)))
    }
    return choices[:]
}

// The menu of Add binding (nth -1) or of a code of the nth binding: Press an
// input, which listens, and a submenu per device with what the kind of the
// action takes. A choice adds the binding or replaces the nth one.
@(private)
input_choices_menu :: proc(s:^Session,menu:ui.Id,action:input.Action,nth:int) {
    ctx:=s.gui.ctx
    if !ui.popup_is_open(ctx,menu) {return}
    chosen:Maybe(input.Input_Binding)
    if ui.popup(ctx,menu,{min_width=ui.MENU_CHOICE_WIDTH}) {
        if ui.menu_item(ctx,ui.id(ctx,"press"),"Press an input") {input_listen_start(s,action,nth,0,true)}
        choices:=input_choices(s.settings_dialog.input.current.kinds[action])
        menus:=INPUT_MENUS
        for name,device in menus {
            if ui.submenu(ctx,ui.id(ctx,"device",int(device)+1),name) {
                for choice,i in choices {
                    if choice.menu!=device {continue}
                    if choice.group=="" {
                        if input_choice_row(s,ui.id(ctx,"choice",i+1),choice) {chosen=choice.binding}
                        continue
                    }
                    if i>0 && choices[i-1].menu==device && choices[i-1].group==choice.group {continue}
                    if ui.submenu(ctx,ui.id(ctx,"group",i+1),choice.group) {
                        for other,j in choices[i:] {
                            if other.menu!=device || other.group!=choice.group {break}
                            if input_choice_row(s,ui.id(ctx,"choice",i+j+1),other) {chosen=other.binding}
                        }
                    }
                }
            }
        }
    }
    if binding,ok:=chosen.?;ok {input_binding_choose(s,action,nth,binding)}
}

// A choice of the menus: the prompts of its codes and its name.
@(private)
input_choice_row :: proc(s:^Session,id:ui.Id,choice:Input_Choice) -> bool {
    ctx:=s.gui.ctx
    th:=&ctx.theme
    height:=th.row-6
    prompts:[4]ui.Prompt
    count:=0
    width:=ui.text_width(&ctx.font,choice.name,th.font)+12
    for group in input_binding_groups(choice.binding) {
        prompt,_,shown:=input_code_prompt(s,choice.binding.codes[group.slot])
        if !shown {continue}
        prompts[count]=prompt
        count+=1
        width+=(prompt.quad.kind!=.Solid && prompt.aspect>0?height*prompt.aspect:ui.prompt_width(ctx,prompt,height))+7
    }
    it:=ui.popup_row(ctx,id)
    if ui.box(ctx,{id=id,width=ui.grow(width),height=ui.fixed(th.control),padding={6,0,6,0},gap=7,align_y=.Center,fill=it.hot?ui.color_hover(th):{},radius=th.radius_control}) {
        for prompt in prompts[:count] {ui.prompt_glyph(ctx,prompt,height)}
        ui.label(ctx,choice.name,th.font,th.text,0)
    }
    if it.clicked {ui.popup_close(ctx)}
    return it.clicked
}

// A binding chosen from the menus is added, or takes the place of the nth
// one with its options, as one that listened does.
@(private)
input_binding_choose :: proc(s:^Session,action:input.Action,nth:int,binding:input.Input_Binding) {
    m:=&s.settings_dialog.input.current
    old:=input.Input_Binding{gamepad=input.GAMEPAD_ANY}
    if index:=input_binding_index(m,action,nth);index>=0 {old=m.bindings[index]}
    input_binding_put(s,action,nth,input_binding_keep(binding,old))
}

// The binding with the options of old.
@(private)
input_binding_keep :: proc(binding,old:input.Input_Binding) -> input.Input_Binding {
    b:=binding
    b.scale,b.dead_zone,b.gamepad=old.scale,old.dead_zone,old.gamepad
    return b
}

// The chip of a binding that listens: the codes it gathered and the one it waits for.
@(private)
input_listen_chip :: proc(s:^Session,id:ui.Id,gathered:input.Input_Binding,slot:int) {
    gathered:=gathered
    ctx:=s.gui.ctx
    th:=&ctx.theme
    if ui.box(ctx,{id=id,width=ui.FIT,height=ui.fixed(th.row),padding={6,0,6,0},gap=4,align_y=.Center,fill=th.accent_soft,stroke=th.accent,radius=th.radius_control}) {
        for code in gathered.codes[:min(slot,4)] {
            if prompt,name,shown:=input_code_prompt(s,code);shown {ui.prompt_glyph(ctx,prompt,th.row-6)} else {ui.label(ctx,name,th.font_small,th.text,0)}
        }
        ui.label(ctx,"Press an input",th.font_small,th.text_muted,0)
    }
}

@(private)
input_listen_start :: proc(s:^Session,action:input.Action,binding,slot:int,whole:bool) {
    l:=&s.settings_dialog.input.listen
    l^={active=true,whole=whole,action=action,binding=binding,slot=whole?0:slot}
    if s.app!=nil && s.app.platform!=nil {
        frame:=platform.input_frame(s.app.platform)
        for pad,i in frame.gamepads {l.axes[i]=pad.axes}
    }
}

// What a binding that listens takes from the input of this frame, before the
// dialog is built: a press of the mouse binds and does nothing else, and
// Escape cancels.
@(private)
input_listen_poll :: proc(s:^Session) {
    st:=&s.settings_dialog.input
    l:=&st.listen
    ctx:=s.gui.ctx
    if s.app==nil || s.app.platform==nil {return}
    frame:=platform.input_frame(s.app.platform)
    if frame.mouse_pressed!={} {ctx.press_used,ctx.right_press_used=true,true}
    if ui.escape(ctx) {
        l^={}
        return
    }
    code:input.Input_Code
    for key in core.Key {
        if key in frame.keys_pressed && key!=.Escape {code={.Key,u8(key)};break}
    }
    for button in core.Mouse_Button {
        if code.device==.None && button in frame.mouse_pressed {code={.Mouse_Button,u8(button)}}
    }
    for &pad in frame.gamepads {
        if !pad.connected {continue}
        for button in core.Gamepad_Button {
            if code.device==.None && button in pad.pressed {code={.Gamepad_Button,u8(button)}}
        }
    }
    axis:=input.Input_Code{}
    for &pad,i in frame.gamepads {
        if !pad.connected {continue}
        for value,a in pad.axes {
            if axis.device==.None && abs(value)>INPUT_LISTEN_AXIS && abs(l.axes[i][a])<=INPUT_LISTEN_AXIS {axis={.Gamepad_Axis,u8(a)}}
        }
        l.axes[i]=pad.axes
    }
    l.mouse+=frame.mouse_delta
    mouse:=abs(l.mouse.x)>INPUT_LISTEN_MOUSE || abs(l.mouse.y)>INPUT_LISTEN_MOUSE
    wheel:=frame.wheel!={}
    if binding,found:=input_listen_take(st,code,axis,mouse,abs(l.mouse.x)>=abs(l.mouse.y),wheel,abs(frame.wheel.x)>abs(frame.wheel.y));found {
        input_binding_put(s,l.action,l.binding,binding)
    }
}

// The binding the input completes: a code (a key or a button), a gamepad
// axis that moved, the mouse that moved (wide: more across than up) or its
// wheel. found false while it waits for more.
input_listen_take :: proc(st:^Input_Settings,code,axis:input.Input_Code,mouse,wide,wheel,wheel_wide:bool) -> (binding:input.Input_Binding,found:bool) {
    l:=&st.listen
    m:=&st.current
    kind:=m.kinds[l.action]
    old:input.Input_Binding
    old.gamepad=input.GAMEPAD_ANY
    if index:=input_binding_index(m,l.action,l.binding);index>=0 {old=m.bindings[index]}
    keep :: input_binding_keep
    need:=kind==.Axis2?4:kind==.Axis?2:1
    switch {
    case code.device!=.None && kind==.Button:
        return keep({count=1,codes={0=code}},old),true
    case code.device==.Key && !l.whole:
        b:=old
        b.codes[l.slot]=code
        return b,true
    case code.device==.Key:
        l.gathered.codes[l.slot]=code
        l.slot+=1
        if l.slot<need {return}
        return keep({count=u8(need),codes=l.gathered.codes},old),true
    case axis.device!=.None && kind==.Button:
        return keep({count=1,codes={0=axis}},old),true
    case axis.device!=.None && kind==.Axis:
        return keep({count=1,codes={0=axis}},old),true
    case axis.device!=.None && kind==.Axis2:
        #partial switch core.Gamepad_Axis(axis.code) {
        case .Left_X,.Left_Y:   return keep(input.binding_gamepad_stick(.Left),old),true
        case .Right_X,.Right_Y: return keep(input.binding_gamepad_stick(.Right),old),true
        }
    case (mouse || wheel) && kind==.Axis:
        moved:input.Mouse_Axis=wheel?(wheel_wide?.Wheel_X:.Wheel_Y):(wide?.X:.Y)
        return keep(input.binding_mouse_axis(moved),old),true
    case wheel && kind==.Axis2:
        return keep({count=2,codes={0={.Mouse_Axis,u8(input.Mouse_Axis.Wheel_X)},1={.Mouse_Axis,u8(input.Mouse_Axis.Wheel_Y)}}},old),true
    case mouse && kind==.Axis2:
        return keep(input.binding_mouse_delta(),old),true
    }
    return
}

// The binding takes the place of the nth one of the action, or is added
// when nth is -1, and the file has it; a binding that listened stops.
@(private)
input_binding_put :: proc(s:^Session,action:input.Action,nth:int,binding:input.Input_Binding) {
    st:=&s.settings_dialog.input
    st.listen={}
    m:=&st.current
    if !input.binding_suits(m.kinds[action],binding) {return}
    if index:=input_binding_index(m,action,nth);index>=0 {
        stored:=binding
        stored.action=action
        m.bindings[index]=stored
    } else if !input.input_map_bind(m,action,binding) {
        notify(s,fmt.tprintf("The map holds %d bindings: remove some first",input.BINDING_CAPACITY))
        return
    }
    input_settings_commit(s)
}

// The ticks of a tap and of a hold.
@(private)
input_timing_rows :: proc(s:^Session) {
    ctx:=s.gui.ctx
    th:=&ctx.theme
    st:=&s.settings_dialog.input
    m:=&st.current
    rows:=[2]struct{label:string,value:^u32,code,default:u32}{
        {"Tap ticks",&m.tap_ticks,st.code.tap_ticks,input.TAP_TICKS},
        {"Hold ticks",&m.hold_ticks,st.code.hold_ticks,input.HOLD_TICKS},
    }
    for row,i in rows {
        if i>0 {input_row_rule(ctx)}
        row_begin(ctx,row.label)
        value:=f64(input_ticks_shown(row.value^,row.default))
        r:=ui.number_field(ctx,ui.id(ctx,"ticks",i+1),&value,{integer=true,speed=0.2,min=1,max=INPUT_TICKS_MAX,has_min=true,has_max=true})
        if r.changed {row.value^=input_ticks_kept(u32(value),row.default);st.unsaved=true}
        if st.unsaved && !r.scrubbing && !r.editing {input_settings_commit(s)}
        if row.value^==row.code {
            ui.spacer(ctx,REVERT_SIDE,1)
        } else if ui.button(ctx,ui.id(ctx,"ticks_restore",i+1),{icon=.Revert,icon_size=12,icon_color=th.text_muted,style=.Ghost,width=REVERT_SIDE,height=REVERT_SIDE}).clicked {
            row.value^=row.code
            input_settings_commit(s)
        }
        row_end(ctx)
    }
}

// ---------------------------------------------------------------- API

Api_Input_Get_Params :: struct {
    actions:[API_SECTIONS][64]u8 `mirai:"text,optional,label=Only these actions by their names; none: every action"`,
}

Api_Input :: struct {
    tap_ticks:u32 `mirai:"label=Ticks a press may be held and still be a tap"`,
    hold_ticks:u32 `mirai:"label=Ticks a press is held before it is a hold"`,
    problem:[512]u8 `mirai:"text,label=Why input.mirai of the project was not read, so that input.set does not write over it; empty when it was"`,
    actions:[]Api_Input_Action `mirai:"label=The actions the code declares"`,
}
Api_Input_Action :: struct {
    name:[64]u8 `mirai:"text,label=What input.set and input.mirai call it"`,

    kind:[8]u8 `mirai:"text,label=Button; Axis or Axis2"`,
    source:[8]u8 `mirai:"text,label=code: the default of the code; file: input.mirai of the project changes it"`,
    bindings:serial.Json `mirai:"label=The bindings in effect as input.mirai writes them"`,
}

// What input.set takes.
Api_Input_Set_Params_Kind :: enum u8 {Button,Axis,Axis2}
Api_Input_Set_Params :: struct {
    action:string `mirai:"optional,label=The name of an action, as input.get lists it"`,
    kind:Api_Input_Set_Params_Kind `mirai:"optional,label=The kind the action takes with bindings; without it, the one it has"`,
    bindings:[]serial.Json `mirai:"optional,label=The bindings that replace those of the action, as input.mirai writes them: {'key': 'Space'}, {'keys': ['A', 'D', 'S', 'W']} (two for an Axis, four for an Axis2: left, right, down, up), {'mouse_button': 'Left'}, {'mouse': 'Delta'}, {'gamepad_button': 'South'}, {'gamepad_axis': 'Right_Trigger'} or {'gamepad_stick': 'Left'}, each with scale, dead_zone and gamepad (0 to 3) optional; [] leaves it without any"`,
    reset:bool `mirai:"optional,label=true: the action goes back to the kind and the bindings of the code"`,
    tap_ticks:int `mirai:"optional,min=1,max=600,label=Ticks a press may be held and still be a tap"`,
    hold_ticks:int `mirai:"optional,min=1,max=600,label=Ticks a press is held before it is a hold"`,
}

@(private)
input_api_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="input.get",summary="The input actions of the game and its plugins: the kind, the bindings in effect and whether they come from the code or from input.mirai of the project, and the ticks of a tap and of a hold.",params=Api_Input_Get_Params,result=Api_Input,writes_result=true,flags={.Read_Only},run=api_input_get})
    api_register(s,st,{name="input.set",params=Api_Input_Set_Params,summary="Replaces the kind and the bindings of an input action, puts it back to the default of the code, or changes the ticks of a tap and of a hold; input.mirai of the project keeps what differs from the code, and a Play that starts or runs takes it. It answers with the action it changed.",result=Api_Input,writes_result=true,run=api_input_set})
}

@(private)
api_input_get :: proc(s:^Session,call:^api.Call) {
    input_settings_load(s)
    only:=make([dynamic]string,context.temp_allocator)
    for &name in api.call_params(call,Api_Input_Get_Params).actions {
        wanted:=base.text_get(name[:])
        if wanted=="" {continue}
        if _,declared:=core.name_value(s.info,input.Action,wanted);!declared {
            api.call_failf(call,api.INVALID_PARAMS,"%q is not an input action: the code declares %s",wanted,input_action_names(s))
            return
        }
        append(&only,wanted)
    }
    input_api_write(s,call.out,len(only)>0,only[:])
}

@(private)
input_api_write :: proc(s:^Session,out:^serial.Writer,filtered:=false,only:[]string={}) {
    st:=&s.settings_dialog.input
    m:=&st.current
    serial.write_u8(out,'{')
    api.write_uint(out,"tap_ticks",u64(input_ticks_shown(m.tap_ticks,input.TAP_TICKS)),true)
    api.write_uint(out,"hold_ticks",u64(input_ticks_shown(m.hold_ticks,input.HOLD_TICKS)))
    api.write_text(out,"problem",base.text_get(st.problem[:]))
    api.write_key(out,"actions")
    serial.write_u8(out,'[')
    first:=true
    for entry in core.names_of(s.info,input.Action) {
        if entry.value<0 || entry.value>=input.ACTION_CAPACITY {continue}
        if filtered && !slice.contains(only,entry.name) {continue}
        action:=input.Action(entry.value)
        if !first {serial.write_u8(out,',')}
        first=false
        serial.write_u8(out,'{')
        api.write_text(out,"name",entry.name,true)

        api.write_text(out,"kind",reflect.enum_string(m.kinds[action]))
        api.write_text(out,"source",input.input_map_action_same(m,&st.code,action)?"code":"file")
        api.write_key(out,"bindings")
        serial.write_u8(out,'[')
        b:=strings.builder_make(context.temp_allocator)
        count:=0
        for &binding in m.bindings[:m.binding_count] {
            if binding.action!=action {continue}
            strings.builder_reset(&b)
            if !input.input_binding_text(&b,binding) {continue}
            if count>0 {serial.text_write_raw(out,", ")}
            serial.text_write_raw(out,strings.to_string(b))
            count+=1
        }
        serial.text_write_raw(out,"]}")
    }
    serial.text_write_raw(out,"]}")
}

// Checked whole before the file changes: a call that fails changes nothing.
@(private)
api_input_set :: proc(s:^Session,call:^api.Call) {
    input_settings_load(s)
    st:=&s.settings_dialog.input
    if problem:=base.text_get(st.problem[:]);problem!="" {
        api.call_fail(call,api.INVALID_PARAMS,problem)
        return
    }
    next:=new_clone(st.current,context.temp_allocator)
    if message:=input_set_apply(s,next,call.raw);message!="" {
        api.call_fail(call,api.INVALID_PARAMS,message)
        return
    }
    st.current=next^
    if message:=input_settings_write(s);message!="" {
        api.call_fail(call,api.SERVER_ERROR,message)
        return
    }
    values:[1]string
    api.object_values(call.allocator,call.raw,{"action"},values[:])
    action:=strings.trim(values[0],`"`)
    only:=[1]string{action}
    input_api_write(s,call.out,true,action!=""?only[:]:nil)
}

// Reads the params of input.set into a map over the code of the session;
// what is wrong with them, or "".
input_set_apply :: proc(s:^Session,m:^input.Input_Map,raw:string) -> string {
    USAGE :: `params are {"action", "kind", "bindings"} to replace an action, {"action", "reset": true} to put it back, and "tap_ticks" or "hold_ticks"`
    value,parse_error:=json.parse_string(raw,json.DEFAULT_SPECIFICATION,true,context.temp_allocator)
    root,is_object:=value.(json.Object)
    if parse_error!=.None || !is_object {return USAGE}
    ticks:=[2]struct{name:string,value:^u32,default:u32}{{"tap_ticks",&m.tap_ticks,input.TAP_TICKS},{"hold_ticks",&m.hold_ticks,input.HOLD_TICKS}}
    for t in ticks {
        if t.name not_in root {continue}
        number,is_integer:=root[t.name].(json.Integer)
        if !is_integer || number<1 || number>INPUT_TICKS_MAX {return fmt.tprintf("%s is a whole number of ticks from 1 to %d; the default is %d",t.name,INPUT_TICKS_MAX,t.default)}
        t.value^=input_ticks_kept(u32(number),t.default)
    }
    if "action" not_in root {
        if "tap_ticks" in root || "hold_ticks" in root {return ""}
        return fmt.tprintf("action is missing: %s",USAGE)
    }
    name,is_text:=root["action"].(json.String)
    if !is_text {return fmt.tprintf("action is the name of an action in quotes: %s",input_action_names(s))}
    found,declared:=core.name_value(s.info,input.Action,name)
    if !declared || found<0 || found>=input.ACTION_CAPACITY {
        return fmt.tprintf(`%q is not an input action: the code declares %s; names.create {{"type": "Action", "name": %q}} declares a new one`,name,input_action_names(s),name)
    }
    action:=input.Action(found)
    reset,_:=root["reset"].(json.Boolean)
    if reset {
        if "kind" in root || "bindings" in root {return "reset puts back the kind and the bindings of the code: leave out kind and bindings"}
        input_action_restore(m,&s.settings_dialog.input.code,action)
        return ""
    }
    list,has_list:=root["bindings"].(json.Array)
    if !has_list {
        if "bindings" in root {return `bindings is a list of bindings: [{"key": "Space"}, ...]`}
        return fmt.tprintf("give the bindings of %q (with its kind to change it), or reset: true: %s",name,USAGE)
    }
    kind:=m.kinds[action]
    if "kind" in root {
        kind_name,_:=root["kind"].(json.String)
        named,known:=reflect.enum_from_name(input.Action_Kind,kind_name)
        if !known {return fmt.tprintf("kind %q is not a kind: Button, Axis or Axis2",kind_name)}
        kind=named
    }
    bindings:=make([]input.Input_Binding,len(list),context.temp_allocator)
    for item,i in list {
        o,is_binding:=item.(json.Object)
        if !is_binding {return fmt.tprintf(`bindings[%d] is not an object: {"key": "Space"}`,i)}
        input_binding_names_fit(o)
        binding,error,field:=input.input_binding_parse(o)
        if error!=.None {return input_binding_problem(i,o,error,field)}
        if !input.binding_suits(kind,binding) {
            return fmt.tprintf("bindings[%d] does not suit the %v action %q: %s",i,kind,name,input_kind_takes(kind))
        }
        bindings[i]=binding
    }
    input.input_map_action(m,action,kind)
    input.input_map_unbind(m,action)
    if int(m.binding_count)+len(bindings)>input.BINDING_CAPACITY {
        return fmt.tprintf("the map holds %d bindings and would have %d: remove some of other actions",input.BINDING_CAPACITY,int(m.binding_count)+len(bindings))
    }
    for binding in bindings {input.input_map_bind(m,action,binding)}
    return ""
}

// What the bindings of an action of a kind may name.
@(private)
input_kind_takes :: proc(kind:input.Action_Kind) -> string {
    switch kind {
    case .Button: return "a Button takes one key, mouse_button or gamepad_button, or one gamepad_axis or mouse axis pressed past its dead_zone"
    case .Axis:   return "an Axis takes keys with two keys (negative, positive), one gamepad_axis, or mouse X, Y, Wheel_X or Wheel_Y"
    case .Axis2:  return "an Axis2 takes keys with four keys (left, right, down, up), gamepad_stick, or mouse Delta or Wheel"
    }
    return ""
}

// Writes the names of a binding an agent gave as their enums have them, as
// base.name_find takes them.
@(private)
input_binding_names_fit :: proc(o:json.Object) {
    fit :: proc(value:^json.Value,names:[]string) {
        if name,is_text:=value.(json.String);is_text {
            if index,_:=base.name_find(name,names);index>=0 {value^=json.String(names[index])}
        }
    }
    each :: proc(o:json.Object,field:string,names:[]string) {
        if value,has:=&o[field];has {fit(value,names)}
    }
    each(o,"key",reflect.enum_field_names(core.Key))
    if keys,has:=o["keys"].(json.Array);has {
        for &key in keys {fit(&key,reflect.enum_field_names(core.Key))}
    }
    each(o,"mouse_button",reflect.enum_field_names(core.Mouse_Button))
    each(o,"gamepad_button",reflect.enum_field_names(core.Gamepad_Button))
    each(o,"gamepad_axis",reflect.enum_field_names(core.Gamepad_Axis))
    each(o,"gamepad_stick",reflect.enum_field_names(input.Gamepad_Stick))
}

// What is wrong with one binding of the params, with the nearest names it takes.
@(private)
input_binding_problem :: proc(index:int,o:json.Object,error:input.Input_Map_Error,field:string) -> string {
    switch {
    case field=="":
        return fmt.tprintf("bindings[%d] names no input: give it one of key, keys, mouse_button, mouse, gamepad_button, gamepad_axis or gamepad_stick",index)
    case field=="gamepad":
        return fmt.tprintf("bindings[%d].gamepad is %v: a gamepad is 0 to %d; leave it out for every gamepad",index,o[field],input.GAMEPAD_ANY-1)
    case field=="keys" && error==.Invalid:
        return fmt.tprintf("bindings[%d].keys has %d keys: give two (negative, positive) for an Axis or four (left, right, down, up) for an Axis2",index,len(o[field].(json.Array) or_else nil))
    case error==.Syntax:
        return fmt.tprintf("bindings[%d].%s is not %s",index,field,field=="keys"?"a list of names in quotes":"a name in quotes")
    }
    wrong:=fmt.tprintf("%v",o[field])
    if keys,is_list:=o[field].(json.Array);is_list {
        for key in keys {
            name,_:=key.(json.String)
            if _,known:=reflect.enum_from_name(core.Key,name);!known {wrong=string(name);break}
        }
    }
    valid:[]string
    switch field {
    case "key","keys":     valid=reflect.enum_field_names(core.Key)
    case "mouse_button":   valid=reflect.enum_field_names(core.Mouse_Button)
    case "mouse":          valid=slice.concatenate([][]string{reflect.enum_field_names(input.Mouse_Axis),{"Delta","Wheel"}},context.temp_allocator)
    case "gamepad_button": valid=reflect.enum_field_names(core.Gamepad_Button)
    case "gamepad_axis":   valid=reflect.enum_field_names(core.Gamepad_Axis)
    case "gamepad_stick":  valid=reflect.enum_field_names(input.Gamepad_Stick)
    }
    what,_:=strings.replace_all(field=="keys"?"key":field,"_"," ",context.temp_allocator)
    return fmt.tprintf("bindings[%d].%s: %s",index,field,base.name_problem(wrong,fmt.tprintf("a %s",what),valid))
}
