package editor

import "core:fmt"
import "core:strings"
import "mirai:asset"
import "mirai:std/base"
import "mirai:ui"

// The assets of a message: assets of the project dragged onto the chat (a
// material, a scene, a prefab) that the next message is about. They go as
// chips over the composer and, when it is sent, by their paths in the
// context of the turn; the agent reads and changes them with the API.

AI_ATTACHMENTS :: 8

// The path and kind of an asset of the registry; empty when it is gone.
@(private)
ai_attachment_file :: proc(s:^Session,id:base.Asset_Id) -> (path:string,kind:asset.Fourcc) {
    if s.app==nil || s.app.assets==nil {return}
    if file,found:=asset.registry_find(&s.app.assets.registry,id);found {return file.path,file.kind}
    return
}

// Attaches an asset to the next message; once each.
ai_attachment_add :: proc(s:^Session,id:base.Asset_Id) {
    m:=s.ai
    if m==nil || id=={} {return}
    for known in m.attachments[:m.attachment_count] {if known==id {return}}
    if m.attachment_count>=AI_ATTACHMENTS {notify(s,fmt.tprintf("A message takes at most %d assets",AI_ATTACHMENTS));return}
    m.attachments[m.attachment_count]=id
    m.attachment_count+=1
    m.focus=true
}

@(private)
ai_attachment_remove :: proc(m:^Ai,index:int) {
    if index<0 || index>=m.attachment_count {return}
    copy(m.attachments[index:m.attachment_count-1],m.attachments[index+1:m.attachment_count])
    m.attachment_count-=1
}

@(private)
ai_attachment_label :: proc(s:^Session,id:base.Asset_Id) -> string {
    path,_:=ai_attachment_file(s,id)
    return path!=""?asset_name(path):"Missing asset"
}

@(private)
ai_attachment_rows :: proc(s:^Session,width:f32) -> int {
    m:=s.ai
    if m.attachment_count==0 {return 0}
    ctx:=s.gui.ctx
    used:=f32(0);rows:=1
    for id in m.attachments[:m.attachment_count] {
        size:=ai_chip_width(ctx,ai_attachment_label(s,id),width)
        if used>0 && used+size>width {rows+=1;used=0}
        used+=size+5
    }
    return rows
}

// The assets of the next message as chips with the icon of their kind;
// taking one out detaches it.
@(private)
ai_attachments_build :: proc(s:^Session,width:f32,rows:int) {
    if rows<=0 {return}
    m:=s.ai;ctx:=s.gui.ctx
    remove:=-1
    used:=f32(0);row:=0
    for id,i in m.attachments[:m.attachment_count] {
        label:=ai_attachment_label(s,id)
        _,kind:=ai_attachment_file(s,id)
        icon,color:=asset_icon(s,kind)
        size:=ai_chip_width(ctx,label,width)
        if used>0 && used+size>width {ui.box_end(ctx,{});row+=1;used=0}
        if row>=rows {break}
        if used==0 {ui.box_begin(ctx,{width=ui.GROW,height=ui.fixed(AI_CHIP_HEIGHT),gap=5,align_y=.Center})}
        if ui.box(ctx,{width=ui.fixed(size),height=ui.fixed(AI_CHIP_HEIGHT),padding={5,0,5,0},gap=4,align_y=.Center,fill=ui.tone(ctx,"field"),radius=ui.metric(ctx,"radius_control")}) {
            ui.icon(ctx,icon,color,12)
            ui.label(ctx,ai_chat_menu_label(ctx,label,max(size-AI_CHIP_ROOM-AI_CHIP_PIN_ROOM,1),ui.metric(ctx,"font_small")),ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"),size-40-AI_CHIP_PIN_ROOM)
            if path,_:=ai_attachment_file(s,id);path!="" {ai_chip_pin(s,ui.id(ctx,"pin_attachment",i+1),AI_PIN_ASSET,path,label)}
            if ui.button(ctx,ui.id(ctx,"remove_attachment",i+1),{icon=.Cross,icon_color=ui.tone(ctx,"text_muted"),icon_size=10,padding=-1,variant="ghost",width=12,height=12}).clicked {remove=i}
        }
        used+=size+5
    }
    if used>0 {ui.box_end(ctx,{})}
    ai_attachment_remove(m,remove)
}

// The paths of the assets a turn takes, as its context lists them.
@(private)
ai_attachment_paths :: proc(s:^Session,task:^Ai_Task) -> []string {
    paths:=make([dynamic]string,context.temp_allocator)
    for id in task.attachments[:task.attachment_count] {
        if path,_:=ai_attachment_file(s,id);path!="" {append(&paths,path)}
    }
    return paths[:]
}

// The line of the instructions that names them, with their kinds.
@(private)
ai_attachments_prompt :: proc(s:^Session,task:^Ai_Task,b:^strings.Builder) {
    paths:=ai_attachment_paths(s,task)
    if len(paths)==0 {return}
    strings.write_string(b,"- The user dragged these assets of the project onto the chat: this message is about them. Read and change them through the API, as their kinds take:")
    for id,i in task.attachments[:task.attachment_count] {
        path,kind:=ai_attachment_file(s,id)
        if path=="" {continue}
        fmt.sbprintf(b,"%s `%s` (%s)",i==0?"":",",path,asset_kind_label(s,kind))
    }
    strings.write_string(b,".\n")
}
