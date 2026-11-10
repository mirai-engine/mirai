package editor

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/ai_store"
import "mirai:editor/history"
import "mirai:std/base"
import "mirai:ui"

// The thread of a session: what the user asked, on the right; the answers of
// the agent as text, with the entities it names as pills; the calls of each
// turn folded under "N steps"; and the line of what the agent does now.

AI_ENTITY_MARK :: "](entity:" // the agent names an entity as [Name](entity:ID)
AI_ASSET_MARK :: "](asset:"   // and an asset as [Name](asset:path under the assets folder)
AI_ASSET_PATH_BYTES :: 256
AI_ENTITY_TEXT :: ui.Color{217,204,245,255}
AI_BUBBLE_ROOM :: f32(40) // what a message of the user leaves free at its left
AI_PARAGRAPH_GAP :: f32(8) // between the paragraphs of one message
AI_STEP_HEAD :: f32(24)
AI_STEP_ROW :: f32(22)
AI_DOING_HEIGHT :: f32(26)
AI_DECLINED_HEIGHT :: f32(36)
AI_REVIEWED_NOTE :: "Reviewed"

Ai_Entity_Mark :: struct {
    name:string,
    id:base.Entity_Id,
    asset:string, // the path of an asset it names instead of an entity
    end:int,      // bytes the mark takes
}

// The mark of an entity or an asset that starts text, when one does.
ai_entity_mark :: proc(text:string) -> (mark:Ai_Entity_Mark,ok:bool) {
    if len(text)<2 || text[0]!='[' {return}
    close:=strings.index_byte(text,']')
    if close<2 {return}
    name:=text[1:close]
    if strings.index_byte(name,'[')>=0 || strings.index_byte(name,'\n')>=0 {return}
    if strings.has_prefix(text[close:],AI_ASSET_MARK) {
        start:=close+len(AI_ASSET_MARK)
        end:=start
        for end<len(text) && text[end]!=')' && text[end]!='\n' && end-start<AI_ASSET_PATH_BYTES {end+=1}
        if end>=len(text) || text[end]!=')' || end==start {return}
        return {name=name,asset=text[start:end],end=end+1},true
    }
    if !strings.has_prefix(text[close:],AI_ENTITY_MARK) {return}
    start:=close+len(AI_ENTITY_MARK)
    end:=start
    for end<len(text) && text[end]!=')' && text[end]!=' ' && end-start<24 {end+=1}
    if end>=len(text) || text[end]!=')' {return}
    id,parsed:=ai_entity_id_parse(text[start:end])
    if !parsed {return}
    return {name=name,id=id,end=end+1},true
}

// An id of an entity as the API writes it, 0x and its hexadecimal digits, or in decimal.
ai_entity_id_parse :: proc(text:string) -> (id:base.Entity_Id,ok:bool) {
    value:u64
    if strings.has_prefix(text,"0x") {value,ok=strconv.parse_u64_of_base(text[2:],16)} else {value,ok=strconv.parse_u64_of_base(text,10)}
    return base.Entity_Id(value),ok && value!=0
}

ai_entity_marks_any :: proc(text:string) -> bool {return strings.contains(text,AI_ENTITY_MARK) || strings.contains(text,AI_ASSET_MARK)}

// The text with the name of each entity in place of its mark.
ai_entity_marks_plain :: proc(text:string,buffer:[]u8) -> string {
    if !ai_entity_marks_any(text) {return text}
    used,at:=0,0
    for at<len(text) && used<len(buffer) {
        if mark,ok:=ai_entity_mark(text[at:]);ok {
            used+=copy(buffer[used:],mark.name)
            at+=mark.end
            continue
        }
        buffer[used]=text[at];used+=1;at+=1
    }
    return ai_utf8_cut(string(buffer[:used]),used)
}

// Text cut to at most bytes, at the start of a character.
ai_utf8_cut :: proc(text:string,bytes:int) -> string {
    if len(text)<=bytes {return text}
    end:=bytes
    for end>0 && (text[end]&0xc0)==0x80 {end-=1}
    return text[:end]
}

// A call of the API the turn made, as its note keeps it: "Tool: method
// target · +1.2 s · 3.4 ms", or "Tool failed: method target · +1.2 s · why".
// A call that names entities or assets has "· ref ids and paths" after its
// target, for the search of the chats.
Ai_Call :: struct {method,target,failure:string,failed:bool}

ai_call_parse :: proc(text:string) -> (call:Ai_Call,ok:bool) {
    rest:string
    switch {
    case strings.has_prefix(text,"Tool: "):        rest=text[len("Tool: "):]
    case strings.has_prefix(text,"Tool failed: "): rest=text[len("Tool failed: "):];call.failed=true
    case: return
    }
    head:=rest
    if dot:=strings.index(rest," · ");dot>=0 {head=rest[:dot]}
    call.method=head
    if space:=strings.index_byte(head,' ');space>=0 {call.method,call.target=head[:space],head[space+1:]}
    if call.failed {
        if dot:=strings.last_index(rest," · ");dot>=0 {call.failure=rest[dot+len(" · "):]}
    }
    return call,true
}

// The call that ends a turn is no step of it.
ai_call_finish :: proc(text:string) -> bool {
    call,ok:=ai_call_parse(text)
    return ok && call.method=="finish"
}

// What a call worked on, for its step: the entity, file or asset it names,
// or how many it takes.
ai_call_target :: proc(s:^Session,raw:string,buffer:[]u8) -> string {
    value,error:=json.parse_string(raw,allocator=context.temp_allocator)
    if error!=nil {return ""}
    object,is_object:=value.(json.Object)
    if !is_object {return ""}
    // The API writes the ids of entities as text: a number is no entity (the turn that finish names).
    named :: proc(s:^Session,value:json.Value) -> string {
        text,is_text:=value.(json.String)
        if !is_text || s.edit_world==nil {return ""}
        id,ok:=ai_entity_id_parse(text)
        if !ok {return ""}
        w:=edited_world(s)
        e:=history.change_entity(w,id)
        return entity_name(w,e) if e!=core.NONE else ""
    }
    for key in ([]string{"name","path","asset","material","file","preset"}) {
        text,is_text:=object[key].(json.String)
        if !is_text || text=="" {continue}
        if slash:=strings.last_index_byte(text,'/');slash>=0 && slash<len(text)-1 {text=text[slash+1:]}
        return fmt.bprintf(buffer,"%s",ai_utf8_cut(text,64))
    }
    for key in ([]string{"id","entity"}) {
        if found:=named(s,object[key]);found!="" {return fmt.bprintf(buffer,"%s",ai_utf8_cut(found,64))}
    }
    for key in ([]string{"ids","entities","operations"}) {
        list,is_list:=object[key].(json.Array)
        if !is_list || len(list)==0 {continue}
        if key=="operations" {return fmt.bprintf(buffer,"%d operations",len(list))}
        if len(list)==1 {
            if found:=named(s,list[0]);found!="" {return fmt.bprintf(buffer,"%s",ai_utf8_cut(found,64))}
        }
        return fmt.bprintf(buffer,"%d entities",len(list))
    }
    return ""
}

// The entities and assets a call names, for the search of the chats: each
// id as the API writes it and each path whole, up to what fits.
ai_call_refs :: proc(raw:string,buffer:[]u8) -> string {
    value,error:=json.parse_string(raw,allocator=context.temp_allocator)
    if error!=nil {return ""}
    object,is_object:=value.(json.Object)
    if !is_object {return ""}
    used:=0
    add :: proc(buffer:[]u8,used:^int,text:string) {
        if text=="" || strings.contains(text," · ") || used^+len(text)+1>len(buffer) {return}
        if used^>0 {buffer[used^]=' ';used^+=1}
        used^+=copy(buffer[used^:],text)
    }
    entity :: proc(buffer:[]u8,used:^int,value:json.Value) {
        text,is_text:=value.(json.String)
        if !is_text {return}
        id,ok:=ai_entity_id_parse(text)
        if !ok {return}
        digits:[18]u8
        add(buffer,used,fmt.bprintf(digits[:],"0x%016x",u64(id)))
    }
    for key in ([]string{"path","asset","material","file"}) {
        if text,is_text:=object[key].(json.String);is_text {add(buffer,&used,text)}
    }
    for key in ([]string{"id","entity"}) {entity(buffer,&used,object[key])}
    for key in ([]string{"ids","entities"}) {
        if list,is_list:=object[key].(json.Array);is_list {for item in list {entity(buffer,&used,item)}}
    }
    return string(buffer[:used])
}

// What a link of an answer leads to, for ui.markdown: an entity of the scene
// by its id is a pill with its name now, that selects it; an asset a pill that
// opens its document. One that is gone stays a pill with the name the agent
// wrote, faint.
@(private)
ai_markdown_resolve :: proc(data:rawptr,target,text:string,buffer:[]u8) -> ui.Markdown_Link {
    s:=(^Session)(data)
    switch {
    case strings.has_prefix(target,"entity:"):
        id,ok:=ai_entity_id_parse(target[len("entity:"):])
        if !ok || s.edit_world==nil {return {pill=true,color=s.gui.ctx.theme.text_faint}}
        w:=shown_world(s)
        e:=history.change_entity(w,id)
        if e==core.NONE {return {pill=true,color=s.gui.ctx.theme.text_faint}}
        name:=string(buffer[:copy(buffer,entity_name(w,e))])
        return {label=name,pill=true,live=true,selected=s.selection!=nil && history.selection_has(s.selection,e),color=AI_ENTITY_TEXT}
    case strings.has_prefix(target,"asset:"):
        if a:=s.app!=nil?s.app.assets:nil;a!=nil {
            if _,found:=asset.registry_find_path(&a.registry,target[len("asset:"):]);found {return {pill=true,live=true,color=AI_ENTITY_TEXT}}
        }
        return {pill=true,color=s.gui.ctx.theme.text_faint}
    case strings.has_prefix(target,"play:"):
        // A scene the agent offers to try: a button that plays it.
        if a:=s.app!=nil?s.app.assets:nil;a!=nil {
            if file,found:=asset.registry_find_path(&a.registry,target[len("play:"):]);found && file.kind==asset.KIND_SCENE {return {pill=true,button=true,live=true,icon=.Play}}
        }
        return {pill=true,icon=.Play,color=s.gui.ctx.theme.text_faint}
    }
    return {}
}

// Opens a scene the agent offered to try and plays it: at once when it is
// the one open, else once Open (which may ask to save first) has put it in
// its place (ai_play_follow).
ai_play_scene :: proc(s:^Session,path:string) {
    if s.document!=nil && document_path(s.document)==path {
        s.requests+={.Play}
        return
    }
    base.text_set(s.ai.play_after[:],path)
    file_open_path(s,path)
}

// The Play a scene waits for after it opens: it starts once the scene is the
// one open; an Open that did not happen forgets it.
ai_play_follow :: proc(s:^Session) {
    m:=s.ai
    want:=base.text_get(m.play_after[:])
    if want=="" || .Open in s.requests || s.gui!=nil && s.gui.modal!=.None {return}
    if s.document!=nil && document_path(s.document)==want {s.requests+={.Play}}
    m.play_after={}
}

// The style answers are drawn with: their links through ai_markdown_resolve.
@(private)
ai_markdown_style :: proc(s:^Session,size:f32) -> ui.Markdown_Style {
    return {size=size,color=s.gui.ctx.theme.text_body,resolve=ai_markdown_resolve,data=s}
}

// What a click on a link of an answer does: select the entity, or open the
// document of the asset.
@(private)
ai_markdown_follow :: proc(s:^Session,target:string) {
    switch {
    case strings.has_prefix(target,"entity:"):
        id,ok:=ai_entity_id_parse(target[len("entity:"):])
        if !ok || s.edit_world==nil {return}
        if e:=history.change_entity(shown_world(s),id);e!=core.NONE {history.selection_set(s.selection,{e})}
    case strings.has_prefix(target,"asset:"):
        a:=s.app!=nil?s.app.assets:nil
        if a==nil {return}
        file,found:=asset.registry_find_path(&a.registry,target[len("asset:"):])
        if found && !asset_document_show(s,file.id) {notify(s,"The document of the asset could not open")}
    case strings.has_prefix(target,"play:"):
        ai_play_scene(s,target[len("play:"):])
    }
}

// The last answer of the agent in a transcript.
ai_transcript_last_answer :: proc(t:^Ai_Transcript) -> string {
    for index:=t.count-1;index>=0;index-=1 {
        text,kind:=ai_transcript_line(t,index)
        if kind==.Output && strings.trim_space(text)!="" {return text}
    }
    return ""
}

// The chat shows of each turn what was asked and the last message of the
// agent; the calls of a turn that ended fold under its first one, which
// steps counts; while a turn runs, one line with what it does now instead.
@(private)
ai_transcript_shown :: proc(task:^Ai_Task,shown:[]bool,steps:[]int=nil) -> (doing:string) {
    t:=&task.transcript
    start:=0
    for start<t.count {
        end:=start+1
        for end<t.count && t.lines[end].kind!=.Prompt {end+=1}
        running:=end==t.count && !ai_task_finished(task)
        last,first_call,calls:=-1,-1,0
        for index in start..<end {
            text,kind:=ai_transcript_line(t,index)
            hidden:=ai_transcript_hidden(text,kind)
            shown[index]=kind==.Prompt || kind==.Report || kind==.Divider || kind==.Note && !hidden
            if hidden && !ai_call_finish(text) {
                calls+=1
                if first_call<0 {first_call=index}
            }
            if kind==.Output && strings.trim_space(text)!="" {last=index}
            if running && kind!=.Prompt {
                if hidden {doing=text} else if kind==.Output && strings.trim_space(text)!="" {doing=text}
            }
        }
        if !running && first_call>=0 && steps!=nil {
            shown[first_call]=true
            steps[first_call]=calls
        }
        if !running && last>=0 {
            first:=last
            for first>start && t.lines[first-1].kind==.Output {first-=1}
            for first<last {
                text,_:=ai_transcript_line(t,first)
                if strings.trim_space(text)!="" {break}
                first+=1
            }
            for index in first..=last {shown[index]=true}
        }
        start=end
    }
    if !ai_task_finished(task) && doing=="" {doing="Thinking"}
    return
}

// The API calls of a turn, saved as notes: they fold under its steps.
@(private)
ai_transcript_hidden :: proc(text:string,kind:ai_store.Line_Kind) -> bool {
    return kind==.Note && (strings.has_prefix(text,"Tool: ") || strings.has_prefix(text,"Tool failed: "))
}

// The room above a line: a message apart from the one before it, and the
// steps of a turn and its answer close to it.
@(private)
ai_message_gap :: proc(t:^Ai_Transcript,index:int,step:bool) -> f32 {
    if index==0 {return 0}
    kind,previous:=t.lines[index].kind,t.lines[index-1].kind
    if kind==.Prompt {return AI_MESSAGE_GAP}
    if step {return 4}
    text,_:=ai_transcript_line(t,index-1)
    if ai_transcript_hidden(text,previous) {return 4}
    return AI_PARAGRAPH_GAP if previous==kind else AI_MESSAGE_GAP
}

// A line that goes on the message of the shown line before it: the lines of
// one answer, or of one message of the user, are drawn as one by the first.
@(private)
ai_line_continues :: proc(t:^Ai_Transcript,index:int,shown:[]bool,held_first:int=-1) -> bool {
    if index==0 || index==held_first || !shown[index] || !shown[index-1] {return false}
    kind:=t.lines[index].kind
    return kind==t.lines[index-1].kind && (kind==.Output || kind==.Prompt)
}

// The text of the message a line starts: it and the lines that go on it, by
// their breaks, in the temporary allocator. A line cut at AI_LINE_BYTES goes
// on without one.
@(private)
ai_message_text :: proc(t:^Ai_Transcript,index:int,shown:[]bool,held_first:int=-1) -> string {
    end:=index+1
    for end<t.count && ai_line_continues(t,end,shown,held_first) {end+=1}
    if end==index+1 {text,_:=ai_transcript_line(t,index);return text}
    b:=strings.builder_make(context.temp_allocator)
    for line in index..<end {
        text,_:=ai_transcript_line(t,line)
        if line>index && int(t.lines[line-1].length)<AI_LINE_BYTES-3 {strings.write_byte(&b,'\n')}
        strings.write_string(&b,text)
    }
    return strings.to_string(b)
}

// The width the text of a message of the user takes, and the bubble around it.
@(private)
ai_bubble_room :: proc(ctx:^ui.Context,text:string,width,size:f32) -> (room,bubble:f32) {
    room=min(ui.text_width(&ctx.font,text,size)+1,width-AI_BUBBLE_ROOM-20)
    return room,room+20
}

// Notes go a point smaller than the messages they are among.
@(private)
ai_note_size :: proc(th:^ui.Theme,size:f32) -> f32 {return size<=th.font_small?th.font_caption:th.font_small}

@(private)
ai_line_measure :: proc(s:^Session,task:^Ai_Task,index,steps:int,open:bool,width,size:f32,shown:[]bool,held_first:int,live:bool) -> f32 {
    ctx:=s.gui.ctx
    t:=&task.transcript
    th:=&ctx.theme
    text,kind:=ai_transcript_line(t,index)
    gap:=ai_message_gap(t,index,steps>0)
    if steps>0 {return gap+AI_STEP_HEAD+(f32(steps)*AI_STEP_ROW if open else 0)}
    switch kind {
    case .Prompt:
        message:=ai_message_text(t,index,shown,held_first)
        room,_:=ai_bubble_room(ctx,message,width,size)
        return gap+ui.text_height(ctx,ai_chat_paragraph_text(ctx,message,room,size),ui.prose(ctx,size),room)+10
    case .Output:
        return gap+ui.markdown_height(ctx,ai_message_text(t,index,shown),width,ai_markdown_style(s,size))
    case .Report:
        return gap+(live?ai_report_height(s,text,width,size):AI_STEP_ROW)
    case .Divider:
        return gap+AI_DIVIDER_HEIGHT
    case .Note:
        if strings.has_prefix(text,AI_REVIEWED_NOTE) {return gap+AI_STEP_ROW}
        note:=ai_note_size(th,size)
        return gap+ui.text_height(ctx,ai_chat_paragraph_text(ctx,text,width,note),ui.prose(ctx,note),width)
    }
    return gap
}

// Seconds as the thread tells how long something took: 12s, 3m 05s, 1h 02m.
ai_elapsed :: proc(seconds:f32) -> string {
    total:=int(max(seconds,0))
    switch {
    case total<60:   return fmt.tprintf("%ds",total)
    case total<3600: return fmt.tprintf("%dm %02ds",total/60,total%60)
    }
    return fmt.tprintf("%dh %02dm",total/3600,(total%3600)/60)
}

// How long the turn of a line worked: the latest time since its start that
// its notes give (+1.2 s), up to its next message.
@(private)
ai_turn_seconds :: proc(t:^Ai_Transcript,index:int) -> (seconds:f32,ok:bool) {
    for line in index..<t.count {
        text,kind:=ai_transcript_line(t,line)
        if kind==.Prompt {break}
        if kind!=.Note {continue}
        at:=strings.index(text," · +")
        if at<0 {continue}
        rest:=text[at+len(" · +"):]
        if space:=strings.index(rest," s");space>0 {
            if value,parsed:=strconv.parse_f32(rest[:space]);parsed {seconds,ok=max(seconds,value),true}
        }
    }
    return
}

// The kinds of tool the agent itself reports over ACP, as its steps keep
// them in place of the method of a call of the API.
@(private)
ai_step_of_agent :: proc(method:string) -> bool {
    switch method {
    case "read","edit","delete","move","search","execute","think","fetch","switch_mode","other": return true
    }
    return false
}

// The icon of a step: the kind of tool of the agent, or the area of the API it called.
@(private)
ai_step_icon :: proc(method:string) -> ui.Icon {
    user :: proc(icon:User_Icon) -> ui.Icon {return ui.icon_user(u8(icon))}
    switch method {
    case "execute":    return user(.Terminal)
    case "read":       return .Eye
    case "edit":       return .Edit
    case "delete":     return user(.Trash)
    case "move":       return .Move
    case "search":     return user(.Search)
    case "fetch":      return .Link
    case "think":      return .Sparkle
    case "permission": return user(.Shield)
    }
    area:=method
    if dot:=strings.index_byte(method,'.');dot>=0 {area=method[:dot]}
    switch area {
    case "scene","history":        return .Scene
    case "material":               return .Material
    case "build","engine":         return user(.Hammer)
    case "play","player":          return .Play
    case "asset","import":         return user(.Folder)
    case "prefab":                 return .Prefab
    case "git":                    return user(.Branch)
    case "panel":                  return .Layers
    case "audio","sound_set":      return .Sound
    case "editor","view","camera": return user(.Camera)
    }
    return .Dot
}

@(private)
ai_transcript_draw :: proc(s:^Session,m:^Ai,task:^Ai_Task,height,width:f32,size:f32=0) {
    ctx:=s.gui.ctx
    th:=&ctx.theme
    size:=size>0?size:th.font_small
    t:=&task.transcript
    area:=ui.id(ctx,"transcript",task.id)
    held_first:=ai_held_first(task)
    if t.heights_width!=width || t.heights_size!=size || t.heights_held!=held_first {
        t.heights_width,t.heights_size,t.heights_held=width,size,held_first
        for &h in t.heights[:t.count] {h=0}
    }
    shown:[AI_TRANSCRIPT_LINES]bool
    steps:[AI_TRANSCRIPT_LINES]int
    live:[AI_TRANSCRIPT_LINES]bool
    doing:=ai_transcript_shown(task,shown[:t.count],steps[:t.count])
    ai_reports_live(t,live[:t.count])
    declined:=task.declined?ai_transcript_declined(t):-1
    // A line that goes on a message is drawn by its first line: it takes no row.
    // A report follows the review of its agent: it is measured every frame.
    for index in 0..<t.count {
        if !shown[index] || ai_line_continues(t,index,shown[:t.count],held_first) {t.heights[index]=0;continue}
        if t.heights[index]>0 && t.lines[index].kind!=.Report {continue}
        open:=m.steps_task==task.id && m.steps_line==t.dropped+index
        t.heights[index]=ai_line_measure(s,task,index,steps[index],open,width,size,shown[:t.count],held_first,live[index])
        if index==declined {t.heights[index]+=AI_DECLINED_HEIGHT}
    }
    if m.scroll_to>0 {
        line:=m.scroll_to-1-t.dropped
        m.scroll_to=0
        if line>=0 && line<t.count {
            m.scroll=0
            for h in t.heights[:line] {m.scroll+=h}
            m.stick=false
        }
    }
    if ctx.wheel_target==area && ctx.input.wheel.y>0 {m.stick=false}
    if m.stick {m.scroll=max(f32)}
    // Under the last message: the plan of the turn, what the agent does now,
    // the permission it asks and the choices of its question, answered there.
    Extra :: enum u8 {Plan,Doing,Permission,Question}
    extras:[4]Extra
    extra_heights:[4]f32
    extra_count:=0
    if task.plan_count>0 {extras[extra_count],extra_heights[extra_count]=.Plan,f32(task.plan_count)*AI_STEP_ROW+8;extra_count+=1}
    if doing!="" {extras[extra_count],extra_heights[extra_count]=.Doing,AI_DOING_HEIGHT;extra_count+=1}
    if h:=ai_permission_height(ctx,m,task,width);h>0 {extras[extra_count],extra_heights[extra_count]=.Permission,h+8;extra_count+=1}
    if h:=ai_chat_question_height(ctx,task,width);h>0 {extras[extra_count],extra_heights[extra_count]=.Question,h+8;extra_count+=1}
    rows:=make([]f32,t.count+extra_count,context.temp_allocator)
    copy(rows,t.heights[:t.count])
    copy(rows[t.count:],extra_heights[:extra_count])
    note:=ai_note_size(th,size)
    first,last:=ui.rows_begin(ctx,area,&m.scroll,rows,ui.fixed(width+AI_THREAD_MARGIN),height,bar_room=AI_THREAD_MARGIN)
    for index in first..<last {
        if index>=t.count {
            switch extras[index-t.count] {
            case .Plan:
                if ui.box(ctx,{width=ui.fixed(width),height=ui.fixed(rows[index]),direction=.Column,padding={0,8,0,0}}) {ai_plan_build(ctx,task,width)}
            case .Doing:
                if ui.box(ctx,{width=ui.fixed(width),height=ui.fixed(AI_DOING_HEIGHT),gap=7,align_y=.Center,padding={0,4,0,0}}) {
                    pulse_dot(ctx,ai_agent_color(task),true)
                    working:=task.state==.Queued?"Queued":fmt.tprintf("Working for %s",ai_elapsed(ai_task_seconds(task)))
                    ui.label(ctx,working,note,th.text_muted)
                    // What it does now: the tool of the agent under way, or its last step or words.
                    method,target:="",""
                    if kind,title,ok:=ai_tool_call_current(m,task);ok {method,target=kind,title} else if call,ok:=ai_call_parse(doing);ok {method,target=call.method,call.target} else if doing!="Thinking" {target=doing}
                    if method!="" && !ai_step_of_agent(method) {target=target!=""?fmt.tprintf("%s %s",method,target):method}
                    if target!="" {
                        ui.icon(ctx,ai_step_icon(method),th.text_faint,12)
                        room:=width-ui.text_width(&ctx.font,working,note)-50
                        ui.label(ctx,ai_chat_menu_label(ctx,target,max(room,1),note),note,th.text_faint,0)
                    }
                }
            case .Permission:
                if ui.box(ctx,{width=ui.fixed(width),height=ui.fixed(rows[index]),direction=.Column,padding={0,8,0,0}}) {ai_permission_build(s,task,width)}
            case .Question:
                if ui.box(ctx,{width=ui.fixed(width),height=ui.fixed(rows[index]),direction=.Column,gap=6,padding={0,8,0,0}}) {ai_chat_question_build(s,task,width)}
            }
            continue
        }
        if rows[index]==0 {continue}
        text,kind:=ai_transcript_line(t,index)
        gap:=ai_message_gap(t,index,steps[index]>0)
        ui.box_begin(ctx,{width=ui.fixed(width),height=ui.fixed(rows[index]),direction=.Column,padding={0,gap,0,0}})
        switch {
        case steps[index]>0:
            ai_steps_build(s,m,task,index,steps[index],width,note)
        case kind==.Prompt:
            // What the user asked, in a box on the right.
            message:=ai_message_text(t,index,shown[:t.count],held_first)
            room,bubble:=ai_bubble_room(ctx,message,width,size)
            held:=held_first>=0 && index>=held_first
            if ui.box(ctx,{width=ui.GROW,height=ui.GROW}) {
                ui.spacer(ctx)
                if ui.box(ctx,{width=ui.fixed(bubble),height=ui.GROW,direction=.Column,padding={10,5,10,5},fill=held?{}:th.field,radius=th.radius_popup}) {
                    ui.text(ctx,ai_chat_paragraph_text(ctx,message,room,size),ui.prose(ctx,size,held?th.text_body:th.text))
                    if held {
                        if ui.box(ctx,{width=ui.fixed(bubble),height=ui.fixed(rows[index]-gap),float={to=.Parent}}) {
                            ui.canvas(ctx,ui.id(ctx,"held",index),ui.GROW,ui.GROW,u32(User_Icon.Dashed_Box),u64(transmute(u32)th.well_stroke_hover),{.Passive})
                        }
                    }
                }
            }
        case kind==.Output:
            if target:=ui.markdown(ctx,ui.id(ctx,"answer",t.dropped+index),ai_message_text(t,index,shown[:t.count]),width,ai_markdown_style(s,size));target!="" {ai_markdown_follow(s,target)}
        case kind==.Report && live[index]:
            ai_report_build(s,text,width,size)
        case kind==.Report:
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(AI_STEP_ROW),align_y=.Center}) {
                ui.label(ctx,ai_chat_menu_label(ctx,ai_report_label(m,text),width,note),note,th.text_faint,0)
            }
        case kind==.Divider:
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(AI_DIVIDER_HEIGHT),gap=8,align_y=.Center}) {
                if ui.box(ctx,{width=ui.GROW,height=ui.fixed(1),fill=th.divider}) {}
                ui.label(ctx,text,th.font_caption,th.text_muted)
                if ui.box(ctx,{width=ui.GROW,height=ui.fixed(1),fill=th.divider}) {}
            }
        case strings.has_prefix(text,AI_REVIEWED_NOTE):
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(AI_STEP_ROW),gap=6,align_y=.Center}) {
                ui.icon(ctx,.Check,th.success,11)
                ui.label(ctx,text,note,th.text_faint,0)
            }
        case:
            ui.text(ctx,ai_chat_paragraph_text(ctx,text,width,note),ui.prose(ctx,note,task.state==.Failed?th.danger:th.text_faint))
        }
        // The changes the user reverted: one click takes them back for review.
        if index==declined && ui.button(ctx,ui.id(ctx,"declined",task.id),{label="Restore",icon=.Revert,icon_color=ai_agent_color(task),icon_size=12,style=.Field,height=AI_DECLINED_HEIGHT-6,size=th.font_small}).clicked {
            if message:=ai_task_restore(s,m,task);message!="" {notify(s,message)}
        }
        ui.box_end(ctx,{})
    }
    ui.rows_end(ctx,area,&m.scroll,rows,last)
    total:f32
    for h in rows {total+=h}
    if ctx.wheel_target==area && ctx.input.wheel.y<0 {m.stick=m.scroll>=total-height-1}
    // Away from the end, a button over the bottom of the thread goes back to it.
    if !m.stick && total>height+1 {
        if rect,found:=ui.widget_rect(ctx,area);found {
            side:=th.control
            if ui.box(ctx,{width=ui.fixed(side),height=ui.fixed(side),float={to=.Surface,offset={rect.x+rect.w*0.5-side*0.5,rect.y+rect.h-side-8}}}) {
                if ui.button(ctx,ui.id(ctx,"to_end",task.id),{icon=ui.icon_user(u8(User_Icon.Down)),icon_color=th.text_muted,icon_size=13,style=.Field,width=side,height=side}).clicked {m.stick=true}
            }
        }
    }
}

// The steps of the plan of the turn, one per row: done, the one under way in
// the color of the agent, and those to come.
@(private)
ai_plan_build :: proc(ctx:^ui.Context,task:^Ai_Task,width:f32) {
    th:=&ctx.theme
    small:=th.font_caption
    for &entry in task.plan[:task.plan_count] {
        icon,color,text_color:=ui.Icon.Checkbox,th.text_faint,th.text_muted
        switch entry.status {
        case .Pending:
        case .In_Progress:color,text_color=ai_agent_color(task),th.text
        case .Completed:icon,text_color=.Checkbox_Checked,th.text_faint
        }
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(AI_STEP_ROW),gap=7,align_y=.Center}) {
            ui.icon(ctx,icon,color,11)
            ui.label(ctx,ai_chat_menu_label(ctx,base.text_get(entry.text[:]),max(width-24,1),small),small,text_color,0)
        }
    }
}

// The steps of a turn that ended, folded under how long it worked and how
// many they were; unfolded, one per row with its icon and what it worked on.
@(private)
ai_steps_build :: proc(s:^Session,m:^Ai,task:^Ai_Task,index,count:int,width,size:f32) {
    ctx:=s.gui.ctx;th:=&ctx.theme
    t:=&task.transcript
    open:=m.steps_task==task.id && m.steps_line==t.dropped+index
    id:=ui.id(ctx,"steps",t.dropped+index)
    it:=ui.interact(ctx,id)
    steps:=count==1?"1 step":fmt.tprintf("%d steps",count)
    label:=steps
    if seconds,known:=ai_turn_seconds(t,index);known {label=fmt.tprintf("Worked for %s · %s",ai_elapsed(seconds),steps)}
    head:=ui.text_width(&ctx.font,label,size)+24
    if ui.box(ctx,{id=id,width=ui.fixed(head),height=ui.fixed(AI_STEP_HEAD),gap=6,padding={5,0,5,0},align_y=.Center,fill=it.hot?ui.color_hover(th):{},radius=th.radius_control}) {
        ui.icon(ctx,open?.Chevron_Down:.Chevron_Right,it.hot?th.text_muted:th.text_faint,9)
        ui.label(ctx,label,size,it.hot?th.text_muted:th.text_faint)
    }
    if it.clicked {
        // One turn shows its steps at a time: the one that folds is measured again.
        if previous:=ai_task_find(m,m.steps_task);previous!=nil {previous.transcript.heights_width=0}
        if open {m.steps_task,m.steps_line=0,0} else {m.steps_task,m.steps_line=task.id,t.dropped+index}
        t.heights_width=0
    }
    if !open {return}
    for line in index..<t.count {
        text,kind:=ai_transcript_line(t,line)
        if kind==.Prompt {break}
        call,ok:=ai_call_parse(text)
        if !ok || call.method=="finish" {continue}
        agent:=ai_step_of_agent(call.method)
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(AI_STEP_ROW),gap=6,padding={16,0,0,0},align_y=.Center}) {
            ui.icon(ctx,ai_step_icon(call.method),call.failed?th.danger:th.text_faint,12)
            room:=width-40
            if !agent {
                ui.label(ctx,call.method,size,call.failed?th.danger:th.text_muted)
                room-=ui.text_width(&ctx.font,call.method,size)+6
            }
            detail:=call.failed && !agent?call.failure:call.target
            if detail!="" {ui.label(ctx,ai_chat_menu_label(ctx,detail,max(room,1),size),size,call.failed && agent?th.danger:th.text_faint,0)}
        }
    }
}

// The permission the agent of a session waits for: what it asks, and its
// options as buttons, the first one the accent.
ai_permission_of :: proc(m:^Ai,task:^Ai_Task) -> int {
    for &permission,index in m.permissions[:m.permission_count] {
        if permission.worker>=0 && permission.worker<len(m.workers) && m.workers[permission.worker].task==task.id {return index}
    }
    return -1
}

AI_PERMISSION_BUTTON :: f32(26)

@(private)
ai_permission_height :: proc(ctx:^ui.Context,m:^Ai,task:^Ai_Task,width:f32) -> f32 {
    index:=ai_permission_of(m,task)
    if index<0 {return 0}
    p:=&m.permissions[index]
    th:=&ctx.theme
    title:=ui.text_height(ctx,base.text_get(p.title[:]),ui.prose(ctx,th.font_small,{},ui.FONT_SEMIBOLD),width-18-20)
    return 18+max(title,16)+8+f32(ai_permission_rows(ctx,p,width-18))*(AI_PERMISSION_BUTTON+5)-5
}

@(private)
ai_permission_label :: proc(p:^Ai_Permission,index:int) -> string {
    name:=base.text_get(p.names[index][:])
    return name if name!="" else base.text_get(p.ids[index][:])
}

@(private)
ai_permission_rows :: proc(ctx:^ui.Context,p:^Ai_Permission,width:f32) -> int {
    rows,used:=1,f32(0)
    for index in 0..<p.count {
        size:=min(ui.text_width(&ctx.font,ai_permission_label(p,index),ctx.theme.font_small)+20,width)
        if used>0 && used+size>width {rows+=1;used=0}
        used+=size+5
    }
    return rows
}

@(private)
ai_permission_build :: proc(s:^Session,task:^Ai_Task,width:f32) {
    m:=s.ai;ctx:=s.gui.ctx;th:=&ctx.theme
    index:=ai_permission_of(m,task)
    if index<0 {return}
    p:=&m.permissions[index]
    color:=ai_agent_color(task)
    ui.id_push(ctx,ui.id(ctx,"permission",task.id))
    defer ui.id_pop(ctx)
    answered:=""
    if ui.box(ctx,{width=ui.fixed(width),height=ui.fixed(ai_permission_height(ctx,m,task,width)),direction=.Column,gap=8,padding=ui.padding_all(9),fill=ui.color_alpha(color,13),stroke=ui.color_alpha(color,102),stroke_width=1,radius=th.radius_popup}) {
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=7}) {
            ui.icon(ctx,ui.icon_user(u8(User_Icon.Shield)),color,13)
            ui.text(ctx,base.text_get(p.title[:]),ui.prose(ctx,th.font_small,th.text,ui.FONT_SEMIBOLD))
        }
        used:=f32(0);open:=false
        room:=width-18
        for option in 0..<p.count {
            label:=ai_permission_label(p,option)
            size:=min(ui.text_width(&ctx.font,label,th.font_small)+20,room)
            if !open || used+size>room {
                if open {ui.box_end(ctx,{})}
                ui.box_begin(ctx,{width=ui.GROW,height=ui.fixed(AI_PERMISSION_BUTTON),gap=5})
                open,used=true,0
            }
            used+=size+5
            if ui.button(ctx,ui.id(ctx,"option",option+1),{label=ai_chat_menu_label(ctx,label,size-20),style=option==0?.Accent:.Field,width=size,height=AI_PERMISSION_BUTTON,size=th.font_small,center=true}).clicked {answered=base.text_get(p.ids[option][:])}
        }
        if open {ui.box_end(ctx,{})}
    }
    if answered!="" {
        if message:=ai_permission_answer(s,index,answered,false);message!="" {notify(s,message)}
    }
}
