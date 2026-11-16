package editor

import "base:runtime"
import "core:fmt"
import "core:sync"
import "mirai:editor/kit"
import "mirai:ui"

// The log of the editor and of everything that runs in it, as the console
// at the bottom shows it: a ring of the last entries, a line each, with the
// count of each level. The logger of the editor writes here and to the
// logger it replaced.

CONSOLE_CAPACITY :: 2048
CONSOLE_TEXT :: 240
CONSOLE_ROW :: f32(20)

Console_Level :: enum u8 {Debug,Info,Warning,Error}
Console_Levels :: bit_set[Console_Level;u8]

Console_Entry :: struct {
    level:Console_Level,
    length:u16,
    repeats:u32, // the same line again right after
    serial:u64,  // Console.serial when it was written or last repeated
    text:[CONSOLE_TEXT]u8,
}

// The levels the console lists, as the editor keeps them between sessions.
Console_Filter :: struct {
    hidden:Console_Levels, // levels not listed
}

@(storage)
Console :: struct {
    entries:[dynamic]Console_Entry, // a ring
    head:int,                       // the next entry written
    count:int,
    counts:[Console_Level]int,
    using filter:Console_Filter,
    scroll:f32,
    follow:bool,                    // the list stays at its last line
    serial:u64,                     // advances with every entry
    seen:u64,
    mutex:sync.Mutex,
    next:runtime.Logger,
}

CONSOLE_DEFAULT :: Console{filter={hidden={.Debug}}}

// A logger that writes to the console and then to next.
console_logger :: proc(c:^Console,next:runtime.Logger) -> runtime.Logger {
    if len(c.entries)==0 {resize(&c.entries,CONSOLE_CAPACITY)}
    c.next=next
    c.follow=true
    return {procedure=console_log,data=c,lowest_level=.Debug,options=next.options}
}

@(private)
console_log :: proc(data:rawptr,level:runtime.Logger_Level,text:string,options:runtime.Logger_Options,location:=#caller_location) {
    c:=cast(^Console)data
    shown:=Console_Level.Debug
    switch {
    case level>=.Error:   shown=.Error
    case level>=.Warning: shown=.Warning
    case level>=.Info:    shown=.Info
    }
    console_add(c,shown,text)
    if c.next.procedure!=nil && level>=c.next.lowest_level {c.next.procedure(c.next.data,level,text,options,location)}
}

// Adds a line to the console without logging it anywhere else.
console_add :: proc(c:^Console,level:Console_Level,text:string) {
    sync.mutex_lock(&c.mutex)
    defer sync.mutex_unlock(&c.mutex)
    if len(c.entries)==0 {return}
    if c.count>0 {
        last:=&c.entries[(c.head+len(c.entries)-1)%len(c.entries)]
        if last.level==level && string(last.text[:last.length])==text[:min(len(text),CONSOLE_TEXT)] {
            last.repeats+=1
            c.serial+=1
            last.serial=c.serial
            return
        }
    }
    entry:=&c.entries[c.head]
    if c.count==len(c.entries) {c.counts[entry.level]-=1} else {c.count+=1}
    entry.level=level
    entry.repeats=0
    entry.length=u16(copy(entry.text[:],text))
    for &b in entry.text[:entry.length] {
        if b=='\n' || b=='\r' || b=='\t' {b=' '}
    }
    c.head=(c.head+1)%len(c.entries)
    c.counts[level]+=1
    c.serial+=1
    entry.serial=c.serial
}

console_clear :: proc(c:^Console) {
    sync.mutex_lock(&c.mutex)
    defer sync.mutex_unlock(&c.mutex)
    c.head,c.count,c.counts=0,0,{}
    c.serial+=1
}

@(private)
console_destroy :: proc(c:^Console) {
    delete(c.entries)
    c.entries={}
}

// The entry at a position of the ring, the oldest first.
@(private)
console_at :: proc(c:^Console,index:int) -> ^Console_Entry {
    first:=(c.head-c.count+len(c.entries))%len(c.entries)
    return &c.entries[(first+index)%len(c.entries)]
}

LEVEL_COLORS :: [Console_Level]ui.Color{.Debug={100,108,122,255},.Info={150,158,171,255},.Warning={255,196,92,255},.Error={255,112,112,255}}

// The filters and the clear of the bar of the console.
@(private)
console_tools :: proc(s:^Session) {
    c:=s.console
    ctx:=s.gui.ctx
    names:=[Console_Level]string{.Debug="Debug",.Info="Info",.Warning="Warnings",.Error="Errors"}
    if kit.segments(ctx,ui.FIT,28) {
        for level in ([4]Console_Level{.Error,.Warning,.Info,.Debug}) {
            shown:=level not_in c.hidden
            if kit.toggle(ctx,ui.id(ctx,"console_level",int(level)+1),fmt.tprintf("%s %d",names[level],c.counts[level]),&shown,0) {
                if shown {c.hidden-={level}} else {c.hidden+={level}}
            }
        }
    }
    if ui.button(ctx,ui.id(ctx,"console_clear"),{label="Clear",variant="field",height=24,size=ui.metric(ctx,"font_small")}).clicked {console_clear(c)}
}

@(private)
console_build :: proc(s:^Session,height:f32) {
    c:=s.console
    ctx:=s.gui.ctx
    colors:=LEVEL_COLORS
    sync.mutex_lock(&c.mutex)
    defer sync.mutex_unlock(&c.mutex)
    shown:=make([dynamic]i32,0,c.count,context.temp_allocator)
    for i in 0..<c.count {
        if console_at(c,i).level not_in c.hidden {append(&shown,i32(i))}
    }
    room:=max(height,CONSOLE_ROW)
    end:=max(f32(len(shown))*CONSOLE_ROW-room,0)
    if c.serial!=c.seen && c.follow {c.scroll=end}
    c.seen=c.serial
    list:=ui.id(ctx,"console_list")
    before:=c.scroll
    first,last:=ui.list_begin(ctx,list,&c.scroll,len(shown),CONSOLE_ROW,room)
    for index in first..<last {
        entry:=console_at(c,int(shown[index]))
        text:=string(entry.text[:entry.length])
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(CONSOLE_ROW),gap=6,align_y=.Center}) {
            if ui.box(ctx,{width=ui.fixed(6),height=ui.fixed(6),fill=colors[entry.level],radius=3}) {}
            ui.label(ctx,text,ui.metric(ctx,"font_small"),entry.level==.Info || entry.level==.Debug?ui.tone(ctx,"text"):colors[entry.level],0)
            if entry.repeats>0 {ui.label(ctx,fmt.tprintf("x%d",entry.repeats+1),ui.metric(ctx,"font_label"),ui.tone(ctx,"text_faint"))}
        }
    }
    ui.list_end(ctx,list,len(shown),last,CONSOLE_ROW)
    // Scrolling up stops following; back at the end it follows again.
    if c.scroll!=before {c.follow=c.scroll>=end-1}
}
