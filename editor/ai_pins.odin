package editor

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/ai_store"
import "mirai:editor/history"
import "mirai:std/base"
import "mirai:ui"

// The references the user keeps with every message: a chip of the composer
// pinned with its toggle stays above it across turns, in the pins table. The
// delta of a turn names each by its identifier or path, so a compaction loses
// nothing; the composer keeps a copy made when the table changes.

AI_PINS :: 32
AI_PIN_LABEL_BYTES :: 96
AI_CHIP_PIN_ROOM :: f32(16) // of a chip that can be pinned, for its toggle and its gap

AI_PIN_ASSET :: "asset"
AI_PIN_ENTITY :: "entity"
AI_PIN_IMAGE :: "image"
AI_PIN_GROUP :: "annotations"
AI_PIN_AGENT :: "agent"

Ai_Pin_Row :: struct {
    id:i64,
    kind:[16]u8,
    ref:[AI_PATH_BYTES]u8,
    label:[AI_PIN_LABEL_BYTES]u8,
}

// Reads the pins when the table changed.
@(private)
ai_pins_sync :: proc(m:^Ai) -> string {
    if m==nil || m.pins_loaded || m.store.db==nil {return ""}
    m.pins_loaded=true
    m.pin_count=0
    pins,message:=ai_store.pins(&m.store)
    if message!="" {return message}
    for &pin in pins[:min(len(pins),AI_PINS)] {
        row:=&m.pins[m.pin_count]
        row^={id=pin.id}
        base.text_set(row.kind[:],pin.kind)
        base.text_set(row.ref[:],pin.ref)
        base.text_set(row.label[:],pin.label)
        m.pin_count+=1
    }
    return ""
}

@(private)
ai_pin_at :: proc(m:^Ai,kind,ref:string) -> int {
    for &row,index in m.pins[:m.pin_count] {
        if base.text_get(row.ref[:])==ref && base.text_get(row.kind[:])==kind {return index}
    }
    return -1
}

// Pins a reference, or takes the pin out if it has one.
ai_pin_toggle :: proc(m:^Ai,kind,ref,label:string) -> string {
    if m==nil {return ""}
    if message:=ai_pins_sync(m);message!="" {return message}
    if at:=ai_pin_at(m,kind,ref);at>=0 {
        if message:=ai_store.pin_remove(&m.store,m.pins[at].id);message!="" {return message}
    } else {
        if m.pin_count>=AI_PINS {return fmt.tprintf("At most %d references can be pinned",AI_PINS)}
        if len(ref)>=AI_PATH_BYTES {return "The path of this reference is too long to pin it"}
        if message:=ai_store.pin_add(&m.store,kind,ref,label);message!="" {return message}
    }
    m.pins_loaded=false
    return ""
}

// The pins that do not show as a chip of what the next message takes: the
// chip of the message carries the toggle while it is there.
@(private)
ai_pins_listed :: proc(s:^Session,out:[]int) -> int {
    m:=s.ai
    if message:=ai_pins_sync(m);message!="" {notify(s,message)}
    count:=0
    for &row,index in m.pins[:m.pin_count] {
        if ai_pin_in_message(s,&row) {continue}
        out[count]=index
        count+=1
    }
    return count
}

@(private)
ai_pin_in_message :: proc(s:^Session,row:^Ai_Pin_Row) -> bool {
    m:=s.ai
    ref:=base.text_get(row.ref[:])
    switch base.text_get(row.kind[:]) {
    case AI_PIN_ASSET:
        for id in m.attachments[:m.attachment_count] {
            if path,_:=ai_attachment_file(s,id);path==ref {return true}
        }
    case AI_PIN_IMAGE:
        for i in 0..<m.reference_count {if base.text_get(m.references[i][:])==ref {return true}}
    case AI_PIN_GROUP:
        for i in 0..<m.annotations.group_count {if base.text_get(m.annotations.groups[i][:])==ref {return true}}
    case AI_PIN_AGENT:
        id,ok:=strconv.parse_int(ref,10)
        return ok && m.about==id
    case AI_PIN_ENTITY:
        if s.selection==nil || asset_document_in_front(s)!=nil {return false}
        id,ok:=base.entity_id_parse(ref)
        if !ok {return false}
        w:=shown_world(s)
        e:=history.change_entity(w,id)
        if e==core.NONE {return false}
        for selected in s.selection.entities {if entity_author(w,selected)==e {return true}}
    }
    return false
}

@(private)
ai_chip_width :: proc(ctx:^ui.Context,label:string,width:f32) -> f32 {
    return min(width,math.ceil(ui.text_width(&ctx.font,label,ctx.theme.font_small))+AI_CHIP_ROOM+AI_CHIP_PIN_ROOM)
}

// The toggle of a chip: lit while it is pinned.
@(private)
ai_chip_pin :: proc(s:^Session,id:ui.Id,kind,ref,label:string) {
    if ref=="" {return}
    ctx:=s.gui.ctx;th:=&ctx.theme
    if message:=ai_pins_sync(s.ai);message!="" {notify(s,message)}
    pinned:=ai_pin_at(s.ai,kind,ref)>=0
    icon:=pinned?User_Icon.Pin_Filled:User_Icon.Pin
    if ui.button(ctx,id,{icon=ui.icon_user(u8(icon)),icon_color=pinned?th.accent:th.text_faint,icon_size=10,padding=-1,style=.Ghost,width=12,height=12}).clicked {
        if message:=ai_pin_toggle(s.ai,kind,ref,label);message!="" {notify(s,message)}
    }
}

@(private)
ai_pin_rows :: proc(s:^Session,width:f32) -> int {
    listed:[AI_PINS]int
    count:=ai_pins_listed(s,listed[:])
    if count==0 {return 0}
    ctx:=s.gui.ctx
    used:=f32(0);rows:=1
    for index in listed[:count] {
        size:=min(width,math.ceil(ui.text_width(&ctx.font,base.text_get(s.ai.pins[index].label[:]),ctx.theme.font_small))+AI_CHIP_ROOM)
        if used>0 && used+size>width {rows+=1;used=0}
        used+=size+5
    }
    return rows
}

// The icon of a pinned chip and its color, by what it refers to.
@(private)
ai_pin_look :: proc(s:^Session,row:^Ai_Pin_Row) -> (icon:ui.Icon,color:ui.Color,agent:^Ai_Task) {
    m:=s.ai;th:=&s.gui.ctx.theme
    ref:=base.text_get(row.ref[:])
    icon,color=.Scene,th.text_muted
    switch base.text_get(row.kind[:]) {
    case AI_PIN_ASSET:
        if s.app!=nil && s.app.assets!=nil {
            if file,found:=asset.registry_find_path(&s.app.assets.registry,ref);found {icon,color=asset_icon(s,file.kind)}
        }
    case AI_PIN_IMAGE:
        icon=.Texture
    case AI_PIN_GROUP:
        icon=ai_annotate_icon()
    case AI_PIN_AGENT:
        if id,ok:=strconv.parse_int(ref,10);ok {agent=ai_task_find(m,id)}
    case AI_PIN_ENTITY:
        if id,ok:=base.entity_id_parse(ref);ok {
            w:=shown_world(s)
            if e:=history.change_entity(w,id);e!=core.NONE {icon,_=entity_icon(s,w,e)}
        }
    }
    return
}

// What is pinned and not in the next message, as chips; unpinning takes it out.
@(private)
ai_pins_build :: proc(s:^Session,width:f32,rows:int) {
    if rows<=0 {return}
    m:=s.ai;ctx:=s.gui.ctx;th:=&ctx.theme
    listed:[AI_PINS]int
    count:=ai_pins_listed(s,listed[:])
    used:=f32(0);row:=0
    for index in listed[:count] {
        pin:=&m.pins[index]
        label:=base.text_get(pin.label[:])
        size:=min(width,math.ceil(ui.text_width(&ctx.font,label,th.font_small))+AI_CHIP_ROOM)
        if used>0 && used+size>width {ui.box_end(ctx,{});row+=1;used=0}
        if row>=rows {break}
        if used==0 {ui.box_begin(ctx,{width=ui.GROW,height=ui.fixed(AI_CHIP_HEIGHT),gap=5,align_y=.Center})}
        if ui.box(ctx,{width=ui.fixed(size),height=ui.fixed(AI_CHIP_HEIGHT),padding={5,0,5,0},gap=4,align_y=.Center,fill=th.field,radius=th.radius_control}) {
            icon,color,agent:=ai_pin_look(s,pin)
            if agent!=nil {pulse_dot(ctx,ai_agent_color(agent),false)} else {ui.icon(ctx,icon,color,12)}
            ui.label(ctx,ai_chat_menu_label(ctx,label,max(size-AI_CHIP_ROOM,1),th.font_small),th.font_small,th.text_muted,size-40)
            ai_chip_pin(s,ui.id(ctx,"pinned",index+1),base.text_get(pin.kind[:]),base.text_get(pin.ref[:]),label)
        }
        used+=size+5
    }
    if used>0 {ui.box_end(ctx,{})}
}

// The pins of the project in the delta of every turn: identifiers and paths, no images.
ai_pins_delta_write :: proc(s:^Session,b:^strings.Builder) {
    pins,message:=ai_store.pins(&s.ai.store)
    if message!="" {notify(s,message);return}
    if len(pins)==0 {return}
    strings.write_string(b,"- The user pinned these references for every message of this chat, kind | reference | label. Images are named by their path and are not attached:\n")
    for &pin in pins {fmt.sbprintf(b,"  - %s | %s | %s\n",pin.kind,pin.ref,pin.label)}
}
