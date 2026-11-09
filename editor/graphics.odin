package editor

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:reflect"
import "core:strings"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:project"
import gpu "mirai:render"
import "mirai:rhi"
import "mirai:std/base"
import "mirai:ui"

// The Graphics popup of the bar: the Graphics_Settings of the project, which
// the game draws with and the editor too. An option is a row of named
// choices; a preset (erender.GRAPHICS_PRESETS) sets the quality ones, and the
// one on is erender.graphics_quality_of, what the fields are at. Antialiasing offers Off, TAA and the techniques active plugins offer
// (erender.antialiasing_offer), and a plugin adds rows of its own: the fields
// of its @(storage,setting="machine") tagged `graphics=Label`, an enum or a
// bool. A choice is written to the edited World and to the settings at once,
// and changes neither the document nor its history.

GRAPHICS_WIDTH :: f32(420)
GRAPHICS_LABEL_WIDTH :: f32(108)
GRAPHICS_ROW :: f32(25)

Graphics_Option :: enum u8 {Resolution,Antialiasing,Frame_Generation,Indirect_Light,Probes,Reflections,Lights,Glass_Shadows,Glass_Layers,Textures,Detail,Frame_Limit,Vsync,Fps}
// The choice each option is at; -1 when its values are none of the choices.
Graphics_Choices :: [Graphics_Option]i8

GRAPHICS_OPTION_LABELS :: [Graphics_Option]string{
    .Resolution="Resolution",.Antialiasing="Antialiasing",.Frame_Generation="Frame generation",.Indirect_Light="Indirect light",.Probes="Light probes",.Reflections="Reflections",
    .Lights="Shadowed lights",.Glass_Shadows="Glass shadows",.Glass_Layers="Glass layers",.Textures="Textures",.Detail="Detail",.Frame_Limit="Frame limit",.Vsync="VSync",.Fps="Show FPS",
}
GRAPHICS_CHOICE_LABELS :: [Graphics_Option][]string{
    .Resolution={"Auto","50%","75%","100%"},
    .Antialiasing={"Off","TAA"},
    .Frame_Generation={"Off","On"},
    .Indirect_Light={"Off","Probes"},
    .Probes={"Low","Medium","High"},
    .Reflections={"Off","Traced","Detailed"},
    .Lights={"2","4","8","16"},
    .Glass_Shadows={"Off","Colored"},
    .Glass_Layers={"1","2"},
    .Textures={"1K","2K","4K","8K"},
    .Detail={"Low","Medium","High","Ultra"},
    .Frame_Limit={"30","60","120","144","240","Off"},
    .Vsync={"Off","On"},
    .Fps={"Off","On"},
}
// The render_scale of each choice; 0: the target of the preset (Auto).
GRAPHICS_RESOLUTIONS :: [?]f32{0,0.5,0.75,1}
GRAPHICS_LIGHTS :: [?]u32{2,4,8,16}
GRAPHICS_FRAME_LIMITS :: [?]u32{30,60,120,144,240,0}
GRAPHICS_QUALITY_LABELS :: [erender.Graphics_Quality]string{.Low="Low",.Medium="Medium",.High="High",.Ultra="Ultra",.Custom="Custom"}

@(storage)
Graphics :: struct {
    scroll:[2]f32,
}

// offered: the techniques of antialiasing plugins offer. One the settings name
// that none offers is the TAA, which draws then.
graphics_choices :: proc(g:erender.Graphics_Settings,offered:[]erender.Antialiasing_Desc=nil) -> (c:Graphics_Choices) {
    resolutions,lights_table,limits:=GRAPHICS_RESOLUTIONS,GRAPHICS_LIGHTS,GRAPHICS_FRAME_LIMITS
    for &choice in c {choice=-1}
    for scale,i in resolutions {
        if g.render_scale==scale {c[.Resolution]=i8(i)}
    }
    technique:=g.antialiasing
    name:=base.text_get(technique[:])
    c[.Antialiasing]=0 if name==erender.ANTIALIASING_OFF else 1
    for &d,i in offered {
        if base.text_get(d.name[:])==name {c[.Antialiasing]=i8(i+2)}
    }
    c[.Frame_Generation]=i8(g.frame_generation)
    c[.Indirect_Light]=i8(g.indirect_light)
    c[.Probes]=i8(g.light_probes)
    c[.Reflections]=i8(g.reflections)
    for lights,i in lights_table {
        if g.shadowed_lights==lights {c[.Lights]=i8(i)}
    }
    c[.Glass_Shadows]=i8(g.glass_shadows)
    if g.glass_layers>=1 && g.glass_layers<=2 {c[.Glass_Layers]=i8(g.glass_layers)-1}
    c[.Textures]=i8(g.textures)
    c[.Detail]=i8(g.detail)
    for limit,i in limits {
        if g.frame_limit==limit {c[.Frame_Limit]=i8(i)}
    }
    c[.Vsync]=i8(g.vsync)
    c[.Fps]=i8(g.show_fps)
    return
}

// The choices of an option: of Antialiasing, Off, TAA and the techniques offered.
graphics_labels :: proc(option:Graphics_Option,offered:[]erender.Antialiasing_Desc) -> []string {
    labels:=GRAPHICS_CHOICE_LABELS
    // A copy: the table is on the stack of this procedure.
    list:=make([]string,len(labels[option])+(len(offered) if option==.Antialiasing else 0),context.temp_allocator)
    copy(list,labels[option])
    if option==.Antialiasing {for &d,i in offered {list[len(labels[option])+i]=base.text_get(d.label[:])}}
    return list
}

// Sets what a choice of an option stands for; false when the option has no such choice.
graphics_choose :: proc(g:^erender.Graphics_Settings,option:Graphics_Option,choice:int,offered:[]erender.Antialiasing_Desc=nil) -> bool {
    resolutions,lights,limits:=GRAPHICS_RESOLUTIONS,GRAPHICS_LIGHTS,GRAPHICS_FRAME_LIMITS
    if choice<0 || choice>=len(graphics_labels(option,offered)) {return false}
    switch option {
    case .Resolution:     g.render_scale=resolutions[choice]
    case .Antialiasing:
        g.antialiasing={}
        switch choice {
        case 0: base.text_set(g.antialiasing[:],erender.ANTIALIASING_OFF)
        case 1: base.text_set(g.antialiasing[:],erender.ANTIALIASING_TAA)
        case:   g.antialiasing=offered[choice-2].name
        }
    case .Frame_Generation: g.frame_generation=choice==1
    case .Indirect_Light: g.indirect_light=erender.Indirect_Light(choice)
    case .Probes:         g.light_probes=erender.Light_Probes(choice)
    case .Reflections:    g.reflections=erender.Reflections(choice)
    case .Lights:         g.shadowed_lights=lights[choice]
    case .Glass_Shadows:  g.glass_shadows=choice==1
    case .Glass_Layers:   g.glass_layers=u32(choice)+1
    case .Textures:       g.textures=erender.Textures(choice)
    case .Detail:         g.detail=erender.Detail(choice)
    case .Frame_Limit:    g.frame_limit=limits[choice]
    case .Vsync:          g.vsync=choice==1
    case .Fps:            g.show_fps=choice==1
    }
    return true
}

// The name of a quality: of its preset, or Custom.
graphics_quality_label :: proc(quality:erender.Graphics_Quality) -> string {
    labels:=GRAPHICS_QUALITY_LABELS
    return labels[quality]
}

// The graphics settings of the edited World; nil for a project without the render library.
graphics_settings :: proc(s:^Session) -> ^erender.Graphics_Settings {
    return core.world_storage_of(edited_world(s),erender.Graphics_Settings)
}

// Applies a preset, by its name, to the graphics settings among list; message
// says what is wrong.
settings_graphics_preset :: proc(list:[]project.Setting,name:string) -> (message:string) {
    labels:=GRAPHICS_QUALITY_LABELS
    for label,preset in labels {
        if preset==.Custom || !strings.equal_fold(label,name) {continue}
        for setting in list {
            if setting.name=="Graphics_Settings" {
                erender.graphics_preset_apply((^erender.Graphics_Settings)(setting.value),preset)
                return ""
            }
        }
        return "The project has no graphics settings"
    }
    return fmt.tprintf("%q is not a preset: Low, Medium, High or Ultra",name)
}

// What the settings of a project that fixes none are on the device of the editor.
graphics_base :: proc(s:^Session) -> erender.Graphics_Settings {
    if s.app.device==nil {return erender.GRAPHICS_SETTINGS_DEFAULT}
    return erender.graphics_settings_for_device(rhi.device_info(s.app.device)^)
}

// Keeps the graphics settings in the edited World and the settings of the project.
// Graphics are a preference of this machine: the change goes to the engine
// layer, and the editor draws with it now. A value the project fixes wins
// again when the settings are read.
graphics_commit :: proc(s:^Session,next:erender.Graphics_Settings) -> bool {
    g:=graphics_settings(s)
    if g==nil {return false}
    if s.engine_root!="" {
        if s.settings_engine==nil {settings_engine_load(s)}
        if engine:=(^erender.Graphics_Settings)(setting_engine_value(s,"Graphics_Settings"));engine!=nil {
            // Only the fields that change: what the project fixes stays its own.
            before,after:=g^,next
            for field in reflect.struct_fields_zipped(erender.Graphics_Settings) {
                size:=field.type.size
                was:=([^]u8)(&before)[field.offset:][:size]
                now:=([^]u8)(&after)[field.offset:][:size]
                if mem.compare(was,now)==0 {continue}
                mem.copy(rawptr(uintptr(engine)+field.offset),raw_data(now),size)
            }
            settings_save(s,.Engine)
            g=graphics_settings(s)
            if g!=nil {g^=next}
            return g!=nil
        }
    }
    g^=next
    settings_save(s)
    return true
}

@(private)
graphics_popup :: proc(g:^Editor_Ui) -> ui.Id {return shell_id(g,"graphics_popup")}

@(private)
graphics_build :: proc(s:^Session) {
    gs:=s.graphics
    g:=s.gui
    ctx:=g.ctx
    th:=&ctx.theme
    popup:=graphics_popup(g)
    current:=graphics_settings(s)
    if !ui.popup_is_open(ctx,popup) || current==nil {return}
    offered:=erender.antialiasing_offered(s.app)
    choices:=graphics_choices(current^,offered)
    defaults:=graphics_choices(graphics_base(s),offered)
    next:=current^
    changed:=false
    option_labels,preset_labels:=GRAPHICS_OPTION_LABELS,GRAPHICS_QUALITY_LABELS
    shown:=erender.graphics_quality_of(current^)
    row:=ui.Box{width=ui.GROW,height=ui.fixed(GRAPHICS_ROW),gap=7,align_y=.Center}
    segment:=ui.Button{style=.Tab,width=-1,height=th.row-4,size=th.font_small,center=true,padding=2}
    if ui.popup(ctx,popup,{width=GRAPHICS_WIDTH,align_right=true,flush=true}) {
        ui.id_push(ctx,popup)
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(40),padding={BAND_INSET,0,BAND_INSET,0},gap=12,align_y=.Center}) {
            ui.label(ctx,"Graphics",13,th.text,font=ui.FONT_SEMIBOLD)
            ui.spacer(ctx)
            ui.label(ctx,fmt.tprintf("%.0f fps",s.app.stats.fps),th.font_small,th.text,font=ui.FONT_MEDIUM)
            gpu_ms:=f32(0)
            if s.app.renderer!=nil {gpu_ms=gpu.renderer_stats(s.app.renderer).gpu_ms}
            ui.label(ctx,fmt.tprintf("GPU %.1f ms",gpu_ms),th.font_small,th.text_muted)
        }
        if ui.scroll_area(ctx,ui.id(ctx,"rows"),&gs.scroll,{height=ui.FIT,max_height=max(ctx.size.y-th.bar_height-GRAPHICS_ROW-80,GRAPHICS_ROW),gap=0,fade=th.popup}) {
            // Two sections, each under its band that folds it: what the presets set,
            // and the frame rate. A section_card ends with the if that opens it.
            for rate in ([]bool{false,true}) {
                if section_card(s,ui.id(ctx,"graphics_section",int(rate)+1),"Frame rate" if rate else "Quality") {
                    if !rate {
                        ui.box_begin(ctx,row)
                        defer ui.box_end(ctx,{})
                        ui.label(ctx,"Preset",th.font_small,th.text_label,GRAPHICS_LABEL_WIDTH)
                        if ui.segments(ctx,ui.GROW,th.row) {
                            for candidate in erender.Graphics_Quality {
                                if candidate==.Custom {continue}
                                button:=segment
                                button.label,button.active=preset_labels[candidate],shown==candidate
                                if ui.button(ctx,ui.id(ctx,"preset",int(candidate)+1),button).clicked {
                                    erender.graphics_preset_apply(&next,candidate)
                                    changed=true
                                }
                            }
                            custom:=segment
                            custom.label,custom.active=preset_labels[.Custom],shown==.Custom
                            ui.button(ctx,ui.id(ctx,"preset_custom"),custom)
                        }
                        ui.spacer(ctx,REVERT_SIDE,1)
                    }
                    for option in Graphics_Option {
                        if (option>=.Frame_Limit)!=rate {continue}
                        if ui.box(ctx,row) {
                            ui.label(ctx,option_labels[option],th.font_small,th.text_label,GRAPHICS_LABEL_WIDTH)
                            if ui.segments(ctx,ui.GROW,th.row) {
                                for label,choice in graphics_labels(option,offered) {
                                    button:=segment
                                    button.label,button.active=label,int(choices[option])==choice
                                    if ui.button(ctx,ui.id(ctx,"choice",int(option)*16+choice+1),button).clicked {
                                        changed|=graphics_choose(&next,option,choice,offered)
                                    }
                                }
                            }
                            if choices[option]!=defaults[option] {
                                if ui.button(ctx,ui.id(ctx,"graphics_reset",int(option)+1),{icon=.Revert,icon_size=12,icon_color=ctx.theme.text_muted,style=.Ghost,width=REVERT_SIDE,height=REVERT_SIDE}).clicked {changed|=graphics_choose(&next,option,int(defaults[option]),offered)}
                            } else {ui.spacer(ctx,REVERT_SIDE,1)}
                        }
                    }
                    if !rate {graphics_plugin_rows(s,row,segment)}
                }
            }
        }
        ui.id_pop(ctx)
    }
    if changed {graphics_commit(s,next)}
}

// A row of a plugin: a field of a setting of the machine it declares, tagged
// `graphics=Label`, of an enum (a choice for each of its values) or a bool.
Graphics_Plugin_Row :: struct {
    storage:int,
    type:^runtime.Type_Info, // of the field
    offset:uintptr,
    label:string,
    choices:[]string,
    values:[]i64, // of each choice
}

// The rows plugins add to the Quality card, in the order of their settings and fields.
graphics_plugin_rows_of :: proc(s:^Session) -> []Graphics_Plugin_Row {
    rows:=make([dynamic]Graphics_Plugin_Row,context.temp_allocator)
    if s.info==nil {return rows[:]}
    for &info,index in s.info.storages {
        if info.setting!=.Machine || info.type==erender.Graphics_Settings {continue}
        // By its type info: the type of a plugin is of the module of its library.
        fields,is_struct:=runtime.type_info_base(info.info).variant.(runtime.Type_Info_Struct)
        if !is_struct {continue}
        for i in 0..<int(fields.field_count) {
            label,tagged:=core.field_option(reflect.Struct_Tag(fields.tags[i]),"graphics")
            if !tagged {continue}
            row:=Graphics_Plugin_Row{storage=index,type=fields.types[i],offset=fields.offsets[i],label=label if label!="" else readable(fields.names[i])}
            #partial switch v in runtime.type_info_base(fields.types[i]).variant {
            case runtime.Type_Info_Boolean:
                row.choices=make([]string,2,context.temp_allocator)
                row.values=make([]i64,2,context.temp_allocator)
                row.choices[0],row.choices[1],row.values[1]="Off","On",1
            case runtime.Type_Info_Enum:
                row.choices=make([]string,len(v.names),context.temp_allocator)
                row.values=make([]i64,len(v.values),context.temp_allocator)
                for name,i in v.names {row.choices[i],row.values[i]=readable(name),i64(v.values[i])}
            case: continue
            }
            append(&rows,row)
        }
    }
    return rows[:]
}

// The value of an enum or bool field at an address, as a number.
@(private="file")
graphics_field_value :: proc(row:Graphics_Plugin_Row,data:rawptr) -> i64 {
    at:=rawptr(uintptr(data)+row.offset)
    switch row.type.size {
    case 1: return i64((^u8)(at)^)
    case 2: return i64((^u16)(at)^)
    case 4: return i64((^u32)(at)^)
    case 8: return (^i64)(at)^
    }
    return 0
}

@(private="file")
graphics_field_set :: proc(row:Graphics_Plugin_Row,data:rawptr,value:i64) {
    at:=rawptr(uintptr(data)+row.offset)
    switch row.type.size {
    case 1: (^u8)(at)^=u8(value)
    case 2: (^u16)(at)^=u16(value)
    case 4: (^u32)(at)^=u32(value)
    case 8: (^i64)(at)^=value
    }
}

// Where the edited World, or the application for a shared one, holds a setting.
@(private="file")
graphics_setting_of :: proc(s:^Session,info:^core.Storage_Info) -> rawptr {
    data:=info.place==.Shared?s.app.shared:s.edit_world
    return rawptr(uintptr(data)+info.offset)
}

// Writes a field of a plugin's setting of the machine to the edited World
// and to the layer of the engine, as graphics_commit does.
graphics_plugin_commit :: proc(s:^Session,row:Graphics_Plugin_Row,value:i64) {
    info:=&s.info.storages[row.storage]
    graphics_field_set(row,graphics_setting_of(s,info),value)
    if s.engine_root=="" {settings_save(s);return}
    if s.settings_engine==nil {settings_engine_load(s)}
    if engine:=setting_engine_value(s,info.name);engine!=nil {
        graphics_field_set(row,engine,value)
        settings_save(s,.Engine)
    } else {settings_save(s)}
}

@(private)
graphics_plugin_rows :: proc(s:^Session,row:ui.Box,segment:ui.Button) {
    ctx:=s.gui.ctx
    th:=&ctx.theme
    for plugin_row,r in graphics_plugin_rows_of(s) {
        info:=&s.info.storages[plugin_row.storage]
        current:=graphics_field_value(plugin_row,graphics_setting_of(s,info))
        defaults:[INSPECTOR_COMPONENT_BYTES]u8
        if info.info.size<=len(defaults) {
            if info.for_device!=nil && s.app.device!=nil {info.for_device(&defaults[0],rhi.device_info(s.app.device))} else if info.default!=nil {info.default(&defaults[0])}
        }
        base_value:=graphics_field_value(plugin_row,&defaults[0])
        if ui.box(ctx,row) {
            ui.label(ctx,plugin_row.label,th.font_small,th.text_label,GRAPHICS_LABEL_WIDTH)
            if ui.segments(ctx,ui.GROW,th.row) {
                for label,choice in plugin_row.choices {
                    button:=segment
                    button.label,button.active=label,current==plugin_row.values[choice]
                    if ui.button(ctx,ui.id(ctx,"plugin_choice",r*16+choice+1),button).clicked {graphics_plugin_commit(s,plugin_row,plugin_row.values[choice])}
                }
            }
            if current!=base_value {
                if ui.button(ctx,ui.id(ctx,"plugin_reset",r+1),{icon=.Revert,icon_size=12,icon_color=th.text_muted,style=.Ghost,width=REVERT_SIDE,height=REVERT_SIDE}).clicked {graphics_plugin_commit(s,plugin_row,base_value)}
            } else {ui.spacer(ctx,REVERT_SIDE,1)}
        }
    }
}
