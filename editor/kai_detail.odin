package editor

import "core:fmt"
import vmem "core:mem/virtual"
import "core:strings"
import ka "mirai:cook/kai"
import vcs "mirai:kai"
import "mirai:std/base"
import "mirai:ui"

// The detail of one file of a change, in the Kai tab where the list of the
// view was: what the change did to it (ka.file_detail), read into an arena of
// its own when it opens, and drawn from there, only the rows in sight.

Kai_Detail :: struct {
    open:bool,
    revision:vcs.Revision,
    arena:vmem.Arena,
    view:ka.File_Detail,
    title:string,         // the change and what it did, in the arena
    heights:[dynamic]f32,
    offset:f32,
}

// Reads what the change at revision did to the file at path into out; "" or
// why it does not read.
kai_detail_read :: proc(s:^Session,revision:vcs.Revision,path:string,out:^ka.File_Detail,allocator:=context.temp_allocator) -> (message:string) {
    w:=kai_workspace(s)
    if w==nil {return kai_missing(s)}
    #partial switch e:=ka.file_detail(w,revision,path,out,allocator);e {
    case .None: return ""
    case .Invalid_Argument: return fmt.tprintf("the change did not change %s: give a file it lists",path)
    case .Missing: return fmt.tprintf("the bytes of %s are not in this store yet: the agent pulls what the shared bookmarks reach",path)
    case: return fmt.tprintf("what the change did to %s does not read: %s",path,vcs.error_text(e))
    }
}

// Opens the detail of the file at path as revision changed it. "" or why it does not.
kai_detail_open :: proc(s:^Session,revision:vcs.Revision,path:string) -> string {
    st:=s.kai.state
    kai_detail_close(st)
    d:=&st.detail
    if vmem.arena_init_growing(&d.arena)!=nil {return "no memory for the detail"}
    a:=vmem.arena_allocator(&d.arena)
    d.open,d.revision=true,revision
    if message:=kai_detail_read(s,revision,path,&d.view,a);message!="" {
        kai_detail_close(st)
        return message
    }
    w:=kai_workspace(s)
    id:=""
    if c,e:=vcs.change_get(w.repo.s,revision,context.temp_allocator);e==.None {id=ka.change_text(c.id,context.temp_allocator)}
    v:=&d.view
    id=id[:min(len(id),8)]
    switch v.kind {
    case .Text: d.title=fmt.aprintf("%s  +%d -%d",id,v.added,v.removed,allocator=a)
    case .Asset: d.title=fmt.aprintf("%s  +%d -%d ~%d",id,v.added,v.removed,v.changed,allocator=a)
    case .Binary: d.title=fmt.aprintf("%s  binary, %s to %s",id,base.bytes_text(i64(v.before)),base.bytes_text(i64(v.after)),allocator=a)
    case .Oversized: d.title=fmt.aprintf("%s  too large to show, %s to %s",id,base.bytes_text(i64(v.before)),base.bytes_text(i64(v.after)),allocator=a)
    }
    resize(&d.heights,len(v.rows))
    for &h in d.heights {h=0}
    return ""
}

kai_detail_close :: proc(st:^Kai_State) {
    d:=&st.detail
    vmem.arena_destroy(&d.arena)
    delete(d.heights)
    d^={}
}

// The detail: its file, the change and what it did, then its rows.
kai_detail_build :: proc(s:^Session) {
    ctx:=s.gui.ctx
    st:=s.kai.state
    d:=&st.detail
    v:=&d.view
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"control")),gap=6,align_y=.Center}) {
        if ui.icon_button(ctx,ui.id(ctx,"kai_detail_back"),ui.icon_user(u8(User_Icon.Back)),ui.metric(ctx,"row"),tip="Back").clicked {
            kai_detail_close(st)
            return
        }
        slash:=strings.last_index_byte(v.path,'/')
        kai_row_names(ctx,v.path[slash+1:],slash>0?v.path[:slash]:"",ui.tone(ctx,"text"))
    }
    kai_line(ctx,d.title)
    if v.kind==.Text || v.kind==.Asset {
        row:=ui.metric(ctx,"row")
        if len(d.heights)>0 && d.heights[0]!=row {
            for &h in d.heights {h=row}
        }
        area:=ui.id(ctx,"kai_detail_rows")
        first,last:=ui.rows_begin(ctx,area,&d.offset,d.heights[:],ui.GROW,ui.GROW)
        for &r,i in v.rows[first:last] {
            ui.id_push(ctx,ui.id(ctx,"entry",first+i))
            kai_detail_row(s,&r)
            ui.id_pop(ctx)
        }
        ui.rows_end(ctx,area,&d.offset,d.heights[:],last)
        if v.cut>0 {
            text:[64]u8
            kai_line(ctx,fmt.bprintf(text[:],"%d more rows not shown",v.cut))
        }
    } else {
        ui.spacer(ctx)
    }
}

// A row of the detail: a line with its numbers before and after, a fold of
// the lines kept, or a row of an asset with its entity.
@(private)
kai_detail_row :: proc(s:^Session,row:^ka.Detail_Row) {
    ctx:=s.gui.ctx
    d:=&s.kai.state.detail
    size:=ui.metric(ctx,"font_small")
    tone:="text"
    switch row.mark {
    case '+': tone="success"
    case '-': tone="danger"
    case 0: tone="text_faint"
    }
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=6,align_y=.Center,padding={KAI_ROW_PAD,0,KAI_ROW_PAD,0}}) {
        text:[48]u8
        switch {
        case row.mark==0:
            ui.label(ctx,fmt.bprintf(text[:],"%d lines",row.skipped),size,ui.tone(ctx,tone))
        case d.view.kind==.Text:
            for n in ([2]i32{row.old,row.new}) {
                number:=n>0?fmt.bprintf(text[:],"%d",n):""
                if ui.box(ctx,{width=ui.fixed(30),height=ui.FIT,align_x=.End}) {ui.label(ctx,number,size,ui.tone(ctx,"text_faint"))}
            }
            mark:=[1]u8{row.mark}
            ui.label(ctx,string(mark[:]),size,ui.tone(ctx,tone))
            ui.text(ctx,row.text,{size=size,color=ui.tone(ctx,row.mark==' '?"text_muted":tone),align_y=.Center,ellipsis=true},ui.GROW,ui.fixed(size+6))
        case:
            mark:=[1]u8{row.mark}
            ui.label(ctx,string(mark[:]),size,ui.tone(ctx,tone))
            kai_row_names(ctx,row.name!=""?row.name:row.text,row.name!=""?row.text:"",ui.tone(ctx,tone))
        }
    }
}
