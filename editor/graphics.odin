package editor

import "core:fmt"
import "core:mem"
import "core:reflect"
import "core:strconv"
import "core:strings"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:project"
import gpu "mirai:render"
import "mirai:rhi"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:editor/kit"
import "mirai:ui"

// The Graphics popup of the bar: the Graphics_Settings of the project, which
// the game draws with and the editor too, and the settings of the machine of
// plugins. A row is a field of one of them tagged `graphics=Label`
// (Graphics_Row); a preset (erender.GRAPHICS_PRESETS) sets the quality ones,
// and the one on is erender.graphics_quality_of, what the fields are at. A
// choice is written to the edited World and to the settings at once, and
// changes neither the document nor its history.

GRAPHICS_WIDTH :: f32(520)
GRAPHICS_LABEL_GAP :: f32(16) // from the widest name of a row to its choices
GRAPHICS_QUALITY_LABELS :: [erender.Graphics_Quality]string{.Low="Low",.Medium="Medium",.High="High",.Ultra="Ultra",.Custom="Custom"}
// The section of Graphics_Settings whose rows go to the Frame rate card.
GRAPHICS_RATE_SECTION :: "Frames"
// The rows graphics.status reports, at most.
GRAPHICS_ROWS_CAPACITY :: 32

@(storage)
Graphics :: struct {
    scroll:[2]f32,
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
    popup:=graphics_popup(g)
    current:=graphics_settings(s)
    if !ui.popup_is_open(ctx,popup) || current==nil {return}
    offered:=erender.antialiasing_offered(s.app.renderer)
    rows:=graphics_rows_of(s,offered)
    next:=current^
    changed:=false
    preset_labels:=GRAPHICS_QUALITY_LABELS
    shown:=erender.graphics_quality_of(current^)
    label_width:=ui.metric(ctx,"label_width")
    label_width=max(label_width,ui.text_width(&ctx.font,"Preset",ui.metric(ctx,"font_small"))+GRAPHICS_LABEL_GAP)
    for each in rows {label_width=max(label_width,ui.text_width(&ctx.font,each.label,ui.metric(ctx,"font_small"))+GRAPHICS_LABEL_GAP)}
    row_height:=ui.metric(ctx,"control")
    row:=ui.Box{width=ui.GROW,height=ui.fixed(row_height),gap=8,align_y=.Center}
    segment:=ui.Button{variant="tab",width=-1,height=ui.metric(ctx,"row")-4,size=ui.metric(ctx,"font_small"),center=true,padding=2}
    if ui.popup(ctx,popup,{width=GRAPHICS_WIDTH,align_right=true,flush=true}) {
        ui.id_push(ctx,popup)
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"bar_height")),padding={BAND_INSET,0,BAND_INSET,0},gap=12,align_y=.Center}) {
            ui.label(ctx,"Graphics",ui.metric(ctx,"font"),ui.tone(ctx,"text"),font=ui.FONT_SEMIBOLD)
            ui.spacer(ctx)
            ui.label(ctx,fmt.tprintf("%.0f fps",s.app.stats.fps),ui.metric(ctx,"font_small"),ui.tone(ctx,"text"),font=ui.FONT_MEDIUM)
            gpu_ms:=f32(0)
            if s.app.renderer!=nil {gpu_ms=gpu.renderer_stats(s.app.renderer).gpu_ms}
            ui.label(ctx,fmt.tprintf("GPU %.1f ms",gpu_ms),ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"))
        }
        if ui.scroll_area(ctx,ui.id(ctx,"rows"),&gs.scroll,{height=ui.FIT,max_height=max(ctx.size.y-ui.metric(ctx,"bar_height")-row_height-80,row_height),gap=0,fade=ui.tone(ctx,"popup")}) {
            // Two sections, each under its band that folds it: what the presets set,
            // and the frame rate. A section_card ends with the if that opens it.
            for rate in ([]bool{false,true}) {
                if section_card(s,ui.id(ctx,"graphics_section",int(rate)+1),"Frame rate" if rate else "Quality") {
                    if !rate {
                        ui.box_begin(ctx,row)
                        defer ui.box_end(ctx,{})
                        ui.label(ctx,"Preset",ui.metric(ctx,"font_small"),ui.tone(ctx,"text_label"),label_width)
                        if kit.segments(ctx,ui.GROW,ui.metric(ctx,"row")) {
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
                    for &each,r in rows {
                        if each.rate==rate {graphics_row(s,&each,r,row,segment,label_width)}
                    }
                }
            }
        }
        ui.id_pop(ctx)
    }
    if changed {graphics_commit(s,next)}
}

// A row: a field of a setting of the machine tagged `graphics=Label`. A
// bool or an enum offers a choice for each of its values, named by
// `choices=A|B` in their order or else by their names; a number offers the
// values `choices` lists, each `label:value` or a label that is its value. The
// text of the technique of antialiasing offers Off, TAA and the techniques
// active plugins offer (erender.antialiasing_offer). The rows of
// GRAPHICS_RATE_SECTION go to the Frame rate card, the others to Quality.
Graphics_Row :: struct {
    storage:int,
    type:serial.Type, // of the field
    offset:uintptr,
    label:string,
    rate:bool,
    choices:[]string,
    values:[]f64,   // of each choice of a number, a bool or an enum
    texts:[]string, // of each choice of a text
}

// The rows of Graphics_Settings, then those of the settings of plugins, in
// the order of their settings and fields.
graphics_rows_of :: proc(s:^Session,offered:[]erender.Antialiasing_Desc=nil) -> []Graphics_Row {
    rows:=make([dynamic]Graphics_Row,context.temp_allocator)
    if s.info==nil {return rows[:]}
    for engine in ([]bool{true,false}) {
        for &info,index in s.info.storages {
            if info.setting!=.Machine || (info.type==erender.Graphics_Settings)!=engine {continue}
            // By its type info: the type of a plugin is of the module of its library.
            schema,type:=type_schema(s.info,info.info)
            if schema==nil {continue}
            section:=""
            for field in serial.schema_fields(schema,type) {
                if field.section!="" {section=field.section}
                if field.graphics=="" {continue}
                row:=Graphics_Row{storage=index,type=schema.types[field.type],offset=uintptr(field.offset),label=field.graphics,rate=section==GRAPHICS_RATE_SECTION}
                if graphics_row_choices(&row,schema,field.choices,offered) {append(&rows,row)}
            }
        }
    }
    return rows[:]
}

// The choices of a row from its type and its tag; false for a type without them.
@(private="file")
graphics_row_choices :: proc(row:^Graphics_Row,schema:^serial.Schema,listed:string,offered:[]erender.Antialiasing_Desc) -> bool {
    listed:=listed
    labels:=make([dynamic]string,context.temp_allocator)
    values:=make([dynamic]f64,context.temp_allocator)
    for entry in strings.split_iterator(&listed,"|") {
        label,_,value:=strings.partition(entry,":")
        append(&labels,label)
        number,_:=strconv.parse_f64(value if value!="" else label)
        append(&values,number)
    }
    #partial switch row.type.kind {
    case .Bool:
        row.choices,row.values=make([]string,2,context.temp_allocator),make([]f64,2,context.temp_allocator)
        row.choices[0],row.choices[1],row.values[1]="Off","On",1
        if len(labels)==2 {row.choices[0],row.choices[1]=labels[0],labels[1]}
    case .Enum:
        members:=schema.choices[row.type.first:][:row.type.count]
        row.choices,row.values=make([]string,len(members),context.temp_allocator),make([]f64,len(members),context.temp_allocator)
        for member,i in members {row.choices[i],row.values[i]=i<len(labels)?labels[i]:readable(member.name),f64(member.value)}
    case .Int,.Uint,.Float:
        if len(labels)==0 {return false}
        row.choices,row.values=labels[:],values[:]
    case .Array:
        if schema.types[row.type.elem].size!=1 {return false}
        row.choices=make([]string,2+len(offered),context.temp_allocator)
        row.texts=make([]string,len(row.choices),context.temp_allocator)
        row.choices[0],row.texts[0]="Off",erender.ANTIALIASING_OFF
        row.choices[1],row.texts[1]="TAA",erender.ANTIALIASING_TAA
        for &d,i in offered {row.choices[2+i],row.texts[2+i]=base.text_get(d.label[:]),base.text_get(d.name[:])}
    case: return false
    }
    return true
}

// The choice a row is at in the setting at data; -1 when its value is none of
// them. A technique none offers is the TAA, which draws then.
graphics_row_choice :: proc(row:^Graphics_Row,data:rawptr) -> int {
    at:=rawptr(uintptr(data)+row.offset)
    if row.texts!=nil {
        name:=base.text_get(([^]u8)(at)[:int(row.type.size)])
        for text,i in row.texts {if text==name {return i}}
        return 1
    }
    value:=f64(0)
    if row.type.kind==.Float {
        value=row.type.size==8?(^f64)(at)^:f64((^f32)(at)^)
    } else {
        switch row.type.size {
        case 1: value=f64((^u8)(at)^)
        case 2: value=f64((^u16)(at)^)
        case 4: value=f64((^u32)(at)^)
        case 8: value=f64((^i64)(at)^)
        }
    }
    for each,i in row.values {if each==value {return i}}
    return -1
}

// Writes a choice of a row into the setting at data.
@(private="file")
graphics_row_write :: proc(row:^Graphics_Row,data:rawptr,choice:int) {
    at:=rawptr(uintptr(data)+row.offset)
    if row.texts!=nil {
        text:=([^]u8)(at)[:int(row.type.size)]
        for &b in text {b=0}
        base.text_set(text,row.texts[choice])
        return
    }
    value:=row.values[choice]
    if row.type.kind==.Float {
        if row.type.size==8 {(^f64)(at)^=value} else {(^f32)(at)^=f32(value)}
    } else {
        switch row.type.size {
        case 1: (^u8)(at)^=u8(value)
        case 2: (^u16)(at)^=u16(value)
        case 4: (^u32)(at)^=u32(value)
        case 8: (^i64)(at)^=i64(value)
        }
    }
}

// Where the edited World, or the application for a shared one, holds a setting.
@(private)
graphics_setting_of :: proc(s:^Session,info:^core.Storage_Info) -> rawptr {
    data:=info.place==.Shared?s.app.shared:s.edit_world
    return rawptr(uintptr(data)+info.offset)
}

// Writes a choice of a row to the edited World and to the layer of the
// engine, as graphics_commit does; false for a choice the row has not.
graphics_row_commit :: proc(s:^Session,row:^Graphics_Row,choice:int) -> bool {
    if choice<0 || choice>=len(row.choices) {return false}
    info:=&s.info.storages[row.storage]
    graphics_row_write(row,graphics_setting_of(s,info),choice)
    if s.engine_root=="" {settings_save(s);return true}
    if s.settings_engine==nil {settings_engine_load(s)}
    if engine:=setting_engine_value(s,info.name);engine!=nil {
        graphics_row_write(row,engine,choice)
        settings_save(s,.Engine)
    } else {settings_save(s)}
    return true
}

@(private="file")
graphics_row :: proc(s:^Session,row:^Graphics_Row,r:int,box:ui.Box,segment:ui.Button,label_width:f32) {
    ctx:=s.gui.ctx
    info:=&s.info.storages[row.storage]
    current:=graphics_row_choice(row,graphics_setting_of(s,info))
    defaults:[INSPECTOR_COMPONENT_BYTES]u8
    if info.info.size<=len(defaults) {
        if info.for_device!=nil && s.app.device!=nil {info.for_device(&defaults[0],rhi.device_info(s.app.device))} else if info.default!=nil {info.default(&defaults[0])}
    }
    base_choice:=graphics_row_choice(row,&defaults[0])
    if ui.box(ctx,box) {
        ui.label(ctx,row.label,ui.metric(ctx,"font_small"),ui.tone(ctx,"text_label"),label_width)
        if kit.segments(ctx,ui.GROW,ui.metric(ctx,"row")) {
            for label,choice in row.choices {
                button:=segment
                button.label,button.active=label,current==choice
                if ui.button(ctx,ui.id(ctx,"graphics_choice",r*16+choice+1),button).clicked {graphics_row_commit(s,row,choice)}
            }
        }
        if current!=base_choice && base_choice>=0 {
            if ui.button(ctx,ui.id(ctx,"graphics_reset",r+1),{icon=.Revert,icon_size=12,icon_color=ui.tone(ctx,"text_muted"),variant="ghost",width=REVERT_SIDE,height=REVERT_SIDE}).clicked {graphics_row_commit(s,row,base_choice)}
        } else {ui.spacer(ctx,REVERT_SIDE,1)}
    }
}
