package editor

import "core:fmt"
import "core:mem"
import "core:reflect"
import "core:slice"
import "core:strings"
import "mirai:core"
import "mirai:editor/api"
import "mirai:engine/gui"
import input "mirai:engine/input"
import "mirai:host"
import "mirai:platform"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// The input actions in Project Settings and in input.get: the actions the
// code declares, with the kind and the bindings that Input_Settings of the
// project gives them over the defaults of the code. An edit changes the
// setting in the edited World and in the games that play, the file of the
// project keeps it like any setting, and the maps build again from it.

// How far a stick or trigger moves from where it was, and how many points
// the mouse moves, to be the input a binding listens for.
INPUT_LISTEN_AXIS :: f32(0.6)
INPUT_LISTEN_MOUSE :: f32(160)

Input_Dialog :: struct {
    code:input.Input_Map, // the defaults of the code
    loaded,unsaved:bool,  // unsaved: a value changes that the file does not have yet
    listen:Input_Listen,
}

// A binding that waits for the next key, button or axis; Escape cancels it.
Input_Listen :: struct {
    active:bool,
    whole:bool,   // every input of the binding comes from what is pressed, one after the other
    action:input.Action,
    binding:int,  // among the bindings of the action; -1: a new one
    slot:int,     // the input that comes next
    gathered:input.Input_Binding,
    axes:[core.GAMEPAD_CAPACITY][core.Gamepad_Axis]f32, // of the gamepads, as they were
    mouse:[2]f32, // moved since it began
}

// Reads the actions of the code again.
input_settings_load :: proc(s:^Session) {
    st:=&s.settings_dialog.input
    input.input_map_make(&st.code,s.info,nil,nil)
    st.loaded,st.unsaved,st.listen=true,false,{}
}

// Input_Settings of the edited World; nil without it.
@(private)
input_settings_of :: proc(s:^Session) -> ^input.Input_Settings {
    if s.info==nil || s.edit_world==nil {return nil}
    return core.world_storage_of(edited_world(s),input.Input_Settings)
}

// What drives an action: its entry in Input_Settings, or the default of the code.
@(private)
input_driven :: proc(s:^Session,action:input.Action) -> input.Action_Bindings {
    if settings:=input_settings_of(s);settings!=nil {
        name,_:=core.name_of(s.info,input.Action,i64(action))
        if entry:=input.input_settings_find(settings,name);entry!=nil {return entry.driven}
    }
    return s.settings_dialog.input.code.actions[action]
}

// Whether two ways of driving an action are the same; a scale of 0 is the scale 1 it means.
@(private)
input_same :: proc(a,b:input.Action_Bindings) -> bool {
    a,b:=a,b
    for &binding in a.bindings {if binding.scale==0 {binding.scale=1}}
    for &binding in b.bindings {if binding.scale==0 {binding.scale=1}}
    return a==b
}

// Gives an action what drives it: the entry of Input_Settings, or none when
// that is the default of the code. Says why when it cannot.
@(private)
input_drive :: proc(s:^Session,action:input.Action,driven:input.Action_Bindings) {
    settings:=input_settings_of(s)
    if settings==nil {return}
    name,_:=core.name_of(s.info,input.Action,i64(action))
    if input_same(driven,s.settings_dialog.input.code.actions[action]) {
        input.input_settings_remove(settings,name)
    } else if !input.input_settings_put(settings,name,driven) {
        notify(s,fmt.tprintf("Input_Settings holds %d actions and names of up to %d bytes: %q does not fit",input.ACTION_CAPACITY,input.ACTION_NAME,name))
        return
    }
    settings_runs_take(s,settings_touched(settings_all(s),"","Input_Settings"))
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

// The file of the project takes what changed.
@(private)
input_settings_commit :: proc(s:^Session) {
    s.settings_dialog.input.unsaved=false
    settings_save(s)
}

// The bindings of an action without its nth.
@(private)
input_binding_remove :: proc(driven:^input.Action_Bindings,nth:int) {
    used:=len(input.action_bindings(driven))
    if nth<0 || nth>=used {return}
    copy(driven.bindings[nth:used-1],driven.bindings[nth+1:used])
    driven.bindings[used-1]={}
}

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
    st:=&s.settings_dialog.input
    if !st.loaded {input_settings_load(s)}
    ui.id_push(ctx,ui.id(ctx,"input"))
    defer ui.id_pop(ctx)
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
    driven:=input_driven(s,action)
    ui.id_push(ctx,ui.id(ctx,"action",int(action)+1))
    defer ui.id_pop(ctx)
    row_begin(ctx,"Kind")
    kind:=int(driven.kind)
    kinds:=INPUT_KINDS
    if ui.dropdown(ctx,ui.id(ctx,"kind"),{list=kinds[:]},&kind,{width=-1,height=th.row}) && input.Action_Kind(kind)!=driven.kind {
        st.listen={}
        driven.kind,driven.bindings=input.Action_Kind(kind),{}
        input_drive(s,action,driven)
        input_settings_commit(s)
    }
    if input_same(driven,st.code.actions[action]) {
        ui.spacer(ctx,REVERT_SIDE,1)
    } else if ui.button(ctx,ui.id(ctx,"restore"),{icon=.Revert,icon_size=12,icon_color=th.text_muted,style=.Ghost,width=REVERT_SIDE,height=REVERT_SIDE}).clicked {
        st.listen={}
        input_drive(s,action,st.code.actions[action])
        input_settings_commit(s)
    }
    row_end(ctx)
    for nth in 0..<len(input.action_bindings(&driven)) {
        input_row_rule(ctx)
        if input_binding_row(s,action,&driven,nth) {break}
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
input_binding_row :: proc(s:^Session,action:input.Action,driven:^input.Action_Bindings,nth:int) -> (changed:bool) {
    ctx:=s.gui.ctx
    th:=&ctx.theme
    st:=&s.settings_dialog.input
    l:=&st.listen
    binding:=driven.bindings[nth]
    kind:=driven.kind
    scaled,zoned,padded,zone:=input.binding_uses(kind,binding)
    ui.id_push(ctx,ui.id(ctx,"binding",nth+1))
    defer ui.id_pop(ctx)
    key:=base.hash_combine(u64(action)<<16|u64(nth),0x696e707574)
    menu:=ui.id(ctx,"menu")
    open:=false
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.row),gap=4,align_y=.Center}) {
        menus:=INPUT_MENUS
        device:=menus[input_code_menu(binding.inputs[0])]
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
                it:=input_code_chip(s,id,binding.inputs[group.slot])
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
            input_binding_remove(driven,nth)
            input_drive(s,action,driven^)
            input_settings_commit(s)
            return true
        }
    }
    if !open {return}
    fold_band_begin(s)
    defer fold_band_end(s)
    b:=&driven.bindings[nth]
    if scaled {
        row_begin(ctx,"Scale")
        value:=f64(b.scale!=0?b.scale:1)
        r:=ui.number_field(ctx,ui.id(ctx,"scale"),&value,{decimals=3,speed=0.01})
        if r.changed {b.scale=f32(value);st.unsaved=true;input_drive(s,action,driven^)}
        if st.unsaved && !r.scrubbing && !r.editing {input_settings_commit(s)}
        row_end(ctx)
    }
    if zoned {
        row_begin(ctx,"Dead zone")
        value:=f64(zone)
        r:=ui.number_field(ctx,ui.id(ctx,"dead_zone"),&value,{decimals=3,speed=0.005,min=0.01,max=0.95,has_min=true,has_max=true})
        if r.changed {b.dead_zone=f32(value);st.unsaved=true;input_drive(s,action,driven^)}
        if st.unsaved && !r.scrubbing && !r.editing {input_settings_commit(s)}
        row_end(ctx)
    }
    if padded {
        row_begin(ctx,"Gamepad")
        pads:=INPUT_GAMEPADS
        chosen:=int(b.gamepad)
        if ui.dropdown(ctx,ui.id(ctx,"gamepad"),{list=pads[:]},&chosen,{width=-1,height=th.row}) {
            b.gamepad=u8(chosen)
            input_drive(s,action,driven^)
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
    binding:=binding
    groups:=make([dynamic]Input_Group,context.temp_allocator)
    count:=len(input.binding_inputs(&binding))
    first,_:=input.code_device(binding.inputs[0])
    second,_:=input.code_device(binding.inputs[1])
    paired:=count==2 && first==second && (first==.Gamepad_Axis || first==.Mouse_Axis)
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
    device,_:=input.code_device(code)
    keyboard:=device==.Key || device==.Mouse_Button || device==.Mouse_Axis
    input_kind:ui.Prompt_Input
    input_kind,shown=gui.prompt_input(code,keyboard)
    name,_=strings.replace_all(reflect.enum_string(code),"_"," ",context.temp_allocator)
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
    #partial switch device,_:=input.code_device(code);device {
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
    buttons :: proc(codes:..input.Input_Code) -> (b:input.Input_Binding) {
        copy(b.inputs[:],codes)
        return
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
        add(&choices,.Mouse,"","Wheel",buttons(.Wheel_X,.Wheel_Y))
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
        choices:=input_choices(input_driven(s,action).kind)
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
        prompt,_,shown:=input_code_prompt(s,choice.binding.inputs[group.slot])
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
    input_binding_put(s,action,nth,input_binding_keep(binding,input_binding_old(s,action,nth)))
}

// The nth binding of an action; none for a new one.
@(private)
input_binding_old :: proc(s:^Session,action:input.Action,nth:int) -> input.Input_Binding {
    driven:=input_driven(s,action)
    return nth>=0 && nth<len(input.action_bindings(&driven))?driven.bindings[nth]:{}
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
        for code in gathered.inputs[:min(slot,4)] {
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
        if key in frame.keys_pressed && key!=.Escape {code=input.code_key(key);break}
    }
    for button in core.Mouse_Button {
        if code==.None && button in frame.mouse_pressed {code=input.code_mouse_button(button)}
    }
    for &pad in frame.gamepads {
        if !pad.connected {continue}
        for button in core.Gamepad_Button {
            if code==.None && button in pad.pressed {code=input.code_gamepad_button(button)}
        }
    }
    axis:input.Input_Code
    for &pad,i in frame.gamepads {
        if !pad.connected {continue}
        for value,a in pad.axes {
            if axis==.None && abs(value)>INPUT_LISTEN_AXIS && abs(l.axes[i][a])<=INPUT_LISTEN_AXIS {axis=input.code_gamepad_axis(a)}
        }
        l.axes[i]=pad.axes
    }
    l.mouse+=frame.mouse_delta
    mouse:=abs(l.mouse.x)>INPUT_LISTEN_MOUSE || abs(l.mouse.y)>INPUT_LISTEN_MOUSE
    wheel:=frame.wheel!={}
    kind:=input_driven(s,l.action).kind
    if binding,found:=input_listen_take(l,kind,input_binding_old(s,l.action,l.binding),code,axis,mouse,abs(l.mouse.x)>=abs(l.mouse.y),wheel,abs(frame.wheel.x)>abs(frame.wheel.y));found {
        input_binding_put(s,l.action,l.binding,binding)
    }
}

// The binding the input completes: a code (a key or a button), a gamepad
// axis that moved, the mouse that moved (wide: more across than up) or its
// wheel. found false while it waits for more.
input_listen_take :: proc(l:^Input_Listen,kind:input.Action_Kind,old:input.Input_Binding,code,axis:input.Input_Code,mouse,wide,wheel,wheel_wide:bool) -> (binding:input.Input_Binding,found:bool) {
    keep :: input_binding_keep
    need:=kind==.Axis2?4:kind==.Axis?2:1
    device,_:=input.code_device(code)
    switch {
    case code!=.None && kind==.Button:
        return keep({inputs={0=code}},old),true
    case device==.Key && !l.whole:
        b:=old
        b.inputs[l.slot]=code
        return b,true
    case device==.Key:
        l.gathered.inputs[l.slot]=code
        l.slot+=1
        if l.slot<need {return}
        return keep({inputs=l.gathered.inputs},old),true
    case axis!=.None && kind!=.Axis2:
        return keep({inputs={0=axis}},old),true
    case axis!=.None && kind==.Axis2:
        #partial switch axis {
        case .Left_X,.Left_Y:   return keep(input.binding_gamepad_stick(.Left),old),true
        case .Right_X,.Right_Y: return keep(input.binding_gamepad_stick(.Right),old),true
        }
    case (mouse || wheel) && kind==.Axis:
        moved:input.Mouse_Axis=wheel?(wheel_wide?.Wheel_X:.Wheel_Y):(wide?.X:.Y)
        return keep(input.binding_mouse_axis(moved),old),true
    case wheel && kind==.Axis2:
        return keep({inputs={0=.Wheel_X,1=.Wheel_Y}},old),true
    case mouse && kind==.Axis2:
        return keep(input.binding_mouse_delta(),old),true
    }
    return
}

// The binding takes the place of the nth one of the action, or is added
// when nth is -1, and the file has it; a binding that listened stops.
@(private)
input_binding_put :: proc(s:^Session,action:input.Action,nth:int,binding:input.Input_Binding) {
    s.settings_dialog.input.listen={}
    driven:=input_driven(s,action)
    if !input.binding_suits(driven.kind,binding) {return}
    used:=len(input.action_bindings(&driven))
    switch {
    case nth>=0 && nth<used: driven.bindings[nth]=binding
    case used<input.ACTION_BINDINGS: driven.bindings[used]=binding
    case:
        notify(s,fmt.tprintf("An action holds %d bindings: remove one first",input.ACTION_BINDINGS))
        return
    }
    input_drive(s,action,driven)
    input_settings_commit(s)
}

// The seconds of a tap and of a hold.
@(private)
input_timing_rows :: proc(s:^Session) {
    ctx:=s.gui.ctx
    th:=&ctx.theme
    st:=&s.settings_dialog.input
    settings:=input_settings_of(s)
    if settings==nil {return}
    rows:=[2]struct{label:string,value:^f32,default:f32}{
        {"Tap seconds",&settings.tap_seconds,input.TAP_SECONDS},
        {"Hold seconds",&settings.hold_seconds,input.HOLD_SECONDS},
    }
    for row,i in rows {
        if i>0 {input_row_rule(ctx)}
        row_begin(ctx,row.label)
        value:=f64(row.value^>0?row.value^:row.default)
        r:=ui.number_field(ctx,ui.id(ctx,"ticks",i+1),&value,{speed=0.01,min=0.01,max=f64(input.SECONDS_MAX),has_min=true,has_max=true})
        if r.changed {row.value^=f32(value)==row.default?0:f32(value);st.unsaved=true}
        if st.unsaved && !r.scrubbing && !r.editing {input_settings_commit(s)}
        if row.value^==0 {
            ui.spacer(ctx,REVERT_SIDE,1)
        } else if ui.button(ctx,ui.id(ctx,"ticks_restore",i+1),{icon=.Revert,icon_size=12,icon_color=th.text_muted,style=.Ghost,width=REVERT_SIDE,height=REVERT_SIDE}).clicked {
            row.value^=0
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
    tap_seconds:f32 `mirai:"unit=s,label=How long a press may be held and still be a tap"`,
    hold_seconds:f32 `mirai:"unit=s,label=How long a press is held before it is a hold"`,
    actions:[1]input.Action_Setting `mirai:"list,label=The actions the code declares and what drives each, as an entry of Input_Settings writes it"`,
    changed:[1][input.ACTION_NAME]u8 `mirai:"text,list,label=The actions Input_Settings of the project changes from the defaults of the code"`,
}

@(private)
input_api_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="input.get",summary="The input actions of the game and its plugins: what drives each, as an entry of Input_Settings writes it, which of them the project changes, and the seconds of a tap and of a hold. settings.set with Input_Settings changes them.",params=Api_Input_Get_Params,result=Api_Input,writes_result=true,flags={.Read_Only},run=api_input_get})
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
    out:=call.out
    settings:=input_settings_of(s)
    tap,hold:=input.TAP_SECONDS,input.HOLD_SECONDS
    if settings!=nil && settings.tap_seconds>0 {tap=settings.tap_seconds}
    if settings!=nil && settings.hold_seconds>0 {hold=settings.hold_seconds}
    schema:serial.Schema
    serial.schema_init(&schema,context.temp_allocator)
    defer serial.schema_destroy(&schema)
    if s.info.schema!=nil {schema.named=s.info.schema.schema.named}
    type,_:=serial.schema_add_type_info(&schema,type_info_of(input.Action_Setting))
    serial.write_u8(out,'{')
    api.write_key(out,"tap_seconds",true);api.write_number(out,tap)
    api.write_key(out,"hold_seconds");api.write_number(out,hold)
    changed:=make([dynamic]string,context.temp_allocator)
    api.write_key(out,"actions")
    serial.write_u8(out,'[')
    first:=true
    for entry in core.names_of(s.info,input.Action) {
        if entry.value<0 || entry.value>=input.ACTION_CAPACITY {continue}
        if len(only)>0 && !slice.contains(only[:],entry.name) {continue}
        action:=input.Action(entry.value)
        setting:=input.Action_Setting{driven=input_driven(s,action)}
        base.text_set(setting.action[:],entry.name)
        if !input_same(setting.driven,s.settings_dialog.input.code.actions[action]) {append(&changed,entry.name)}
        if !first {serial.write_u8(out,',')}
        first=false
        serial.text_write(out,&schema,type,mem.ptr_to_bytes(&setting),.Line)
    }
    serial.write_u8(out,']')
    api.write_key(out,"changed")
    serial.write_u8(out,'[')
    for name,i in changed {
        if i>0 {serial.write_u8(out,',')}
        serial.text_write_string(out,name)
    }
    serial.text_write_raw(out,"]}")
}
