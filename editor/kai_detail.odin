package editor

import "core:fmt"
import vmem "core:mem/virtual"
import "core:strings"
import ka "mirai:cook/kai"
import vcs "mirai:kai"
import "mirai:ui"

// The detail of one file of a change, in the Kai tab where the list of the
// view was: what the change did to it (ka.file_detail), read into an arena of
// its own when it opens, and drawn from there, only the rows in sight. In
// the Changes view it is a file of a change picked in the log; in Proposals,
// a file of the stack: a click on one of its lines (a shift-click spans from
// the line picked before) or on the row of an entity starts a comment there,
// and the comments placed on the file show under their lines.

// What the detail lists: a row of the file, or a comment placed after one.
Kai_Detail_Entry :: struct {
    row:i32,  // of view.rows; -1 for a comment
    note:i32, // of the open proposal's notes
}

Kai_Detail :: struct {
    open:bool,
    tab:Kai_Tab,          // the view it shows in
    revision:vcs.Revision,
    change:vcs.Change_Id,
    stack:int,            // Proposals: the file's index over the stack (Kai_Fields.file)
    arena:vmem.Arena,
    view:ka.File_Detail,
    title:string,         // the change and what it did, in the arena
    entries:[dynamic]Kai_Detail_Entry,
    heights:[dynamic]f32,
    offset:f32,
    anchor:i32,           // the line a click picked first, a shift-click spans from it; 0 none
    waiting:bool,         // a peer has the file's bytes: the team's poll reads it again
}

// Reads what the change at revision did to the file at path into out; "" or
// why it does not read. Bytes a peer has are asked of the mesh without
// waiting for them; waiting: they are on their way, and a later call reads
// them (the tab reads again in the team's poll, kai_detail_retry).
kai_detail_read :: proc(s:^Session,revision:vcs.Revision,path:string,out:^ka.File_Detail,allocator:=context.temp_allocator) -> (message:string,waiting:bool) {
    w:=kai_workspace(s)
    if w==nil {return kai_missing(s),false}
    #partial switch e:=ka.file_detail(w,revision,path,out,allocator);e {
    case .None: return "",false
    case .Invalid_Argument: return fmt.tprintf("the change did not change %s: give a file it lists",path),false
    case .Missing:
        org:=kai_mesh_org(s)
        if org=={} {return fmt.tprintf("the bytes of %s are not in this store, and no mesh runs to fetch them from a peer",path),false}
        for address in out.missing {
            if address!={} {vcs.control_object_ask(&s.kai.state.team.control,org,address)}
        }
        return fmt.tprintf("the bytes of %s are on a peer: the mesh is fetching them, ask again in a moment",path),true
    case: return fmt.tprintf("what the change did to %s does not read: %s",path,vcs.error_text(e)),false
    }
}

// Opens the detail of the file at path as revision changed it, in the view
// tab; stack: its index over the proposal's stack. "" or why it does not.
kai_detail_open :: proc(s:^Session,tab:Kai_Tab,revision:vcs.Revision,path:string,stack:=-1) -> string {
    st:=s.kai.state
    kai_detail_close(st)
    d:=&st.detail
    if vmem.arena_init_growing(&d.arena)!=nil {return "no memory for the detail"}
    a:=vmem.arena_allocator(&d.arena)
    d.open,d.tab,d.revision,d.stack=true,tab,revision,stack
    if message,waiting:=kai_detail_read(s,revision,path,&d.view,a);waiting {
        d.view={path=strings.clone(path,a)}
        d.title,d.waiting="Fetching from a peer",true
        return ""
    } else if message!="" {
        kai_detail_close(st)
        return message
    }
    w:=kai_workspace(s)
    id:=""
    if c,e:=vcs.change_get(w.repo.s,revision,context.temp_allocator);e==.None {
        d.change=c.id
        id=ka.change_text(c.id,context.temp_allocator)
    }
    v:=&d.view
    id=id[:min(len(id),8)]
    switch v.kind {
    case .Text: d.title=fmt.aprintf("%s  +%d -%d",id,v.added,v.removed,allocator=a)
    case .Asset: d.title=fmt.aprintf("%s  +%d -%d ~%d",id,v.added,v.removed,v.changed,allocator=a)
    case .Binary: d.title=fmt.aprintf("%s  binary, %s to %s",id,vcs.bytes_text(i64(v.before)),vcs.bytes_text(i64(v.after)),allocator=a)
    case .Oversized: d.title=fmt.aprintf("%s  too large to show, %s to %s",id,vcs.bytes_text(i64(v.before)),vcs.bytes_text(i64(v.after)),allocator=a)
    }
    kai_detail_place(s)
    return ""
}

// A detail whose bytes were on their way, read again: between frames, by the team's poll.
kai_detail_retry :: proc(s:^Session) {
    d:=&s.kai.state.detail
    if !d.open || !d.waiting {return}
    path:=strings.clone(d.view.path,context.temp_allocator)
    offset:=d.offset
    if message:=kai_detail_open(s,d.tab,d.revision,path,d.stack);message!="" {notify(s,message)}
    d.offset=offset
}

kai_detail_close :: proc(st:^Kai_State) {
    d:=&st.detail
    vmem.arena_destroy(&d.arena)
    delete(d.entries)
    delete(d.heights)
    d^={}
}

// The entries of the detail: its rows, and in Proposals the comments on its
// file under the line or the entity they hang on; those outdated or on the
// whole file first. Run again when the proposal is read again.
kai_detail_place :: proc(s:^Session) {
    st:=s.kai.state
    d:=&st.detail
    if !d.open {return}
    clear(&d.entries)
    v:=&d.view
    notes:[]ka.Proposal_Note
    if d.tab==.Proposals && st.team.view.shown {notes=st.team.view.proposal.notes[:]}
    // Where each note goes: -1 first, else after that row.
    after:=make([]i32,len(notes),context.temp_allocator)
    for &n,k in notes {
        after[k]=-2
        if n.path!=v.path || n.change!=d.change {continue}
        after[k]=-1
        if n.outdated {continue}
        #partial switch n.anchor.kind {
        case .Lines:
            last:=i32(n.anchor.line+n.anchor.lines-1)
            for row,i in v.rows {
                if row.new>0 && row.new<=last {after[k]=i32(i)}
            }
        case .Structural:
            for row,i in v.rows {
                if row.key==n.anchor.key {after[k]=i32(i);break}
            }
        }
    }
    for at,k in after {
        if at==-1 {append(&d.entries,Kai_Detail_Entry{-1,i32(k)})}
    }
    for _,i in v.rows {
        append(&d.entries,Kai_Detail_Entry{i32(i),-1})
        for at,k in after {
            if at==i32(i) {append(&d.entries,Kai_Detail_Entry{-1,i32(k)})}
        }
    }
    resize(&d.heights,len(d.entries))
    for &h in d.heights {h=0}
}

// The detail: its file, the change and what it did, then its rows; in
// Proposals, the comment that a click on a line starts.
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
    if !d.waiting && (v.kind==.Text || v.kind==.Asset) {
        row:=ui.metric(ctx,"row")
        if len(d.heights)>0 && d.heights[0]!=row {
            for &h in d.heights {h=row}
        }
        area:=ui.id(ctx,"kai_detail_rows")
        first,last:=ui.rows_begin(ctx,area,&d.offset,d.heights[:],ui.GROW,ui.GROW)
        for e,i in d.entries[first:last] {
            ui.id_push(ctx,ui.id(ctx,"entry",first+i))
            if e.row>=0 {kai_detail_row(s,&v.rows[e.row])} else {kai_detail_note(s,e.note)}
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
    if d.tab==.Proposals && st.team.view.shown {kai_comment_build(s)}
}

// A row of the detail: a line with its numbers before and after, a fold of
// the lines kept, or a row of an asset with its entity.
@(private)
kai_detail_row :: proc(s:^Session,row:^ka.Detail_Row) {
    ctx:=s.gui.ctx
    st:=s.kai.state
    d:=&st.detail
    f:=&st.team.fields
    size:=ui.metric(ctx,"font_small")
    id:=ui.id(ctx,"row")
    // In Proposals a line of the revision, or an entity's row, takes a comment.
    commented:=d.tab==.Proposals && (row.new>0 || row.key!=0)
    it:=ui.interact(ctx,id,commented?{.Focusable}:{})
    on:=commented && ai_pointer_on(ctx,id)
    picked:=commented && (row.key!=0 ? f.key==row.key : f.key==0 && kai_lines_hold(f,row.new))
    tone:="text"
    switch row.mark {
    case '+': tone="success"
    case '-': tone="danger"
    case 0: tone="text_faint"
    }
    if ui.box(ctx,{id=id,width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=6,align_y=.Center,padding={KAI_ROW_PAD,0,KAI_ROW_PAD,0},fill=picked?ui.tone(ctx,"chip_active"):on?ui.tone(ctx,"chip"):{},radius=ui.metric(ctx,"radius_control")}) {
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
    if !it.clicked || !commented {return}
    f.file=d.stack
    if row.key!=0 {
        f.key,f.entity,f.lines_length,d.anchor=row.key,false,0,0
        return
    }
    f.key=0
    from:=row.new
    if .Shift in ctx.input.modifiers && d.anchor>0 {from=d.anchor} else {d.anchor=row.new}
    text:[16]u8
    a,b:=min(from,row.new),max(from,row.new)
    f.lines_length=copy(f.lines[:],a==b?fmt.bprintf(text[:],"%d",a):fmt.bprintf(text[:],"%d-%d",a,b))
}

// Whether line is in the span the lines field holds.
@(private)
kai_lines_hold :: proc(f:^Kai_Fields,line:i32) -> bool {
    if line<=0 || f.lines_length==0 {return false}
    anchor,ok:=ka.lines_of(string(f.lines[:f.lines_length]))
    return ok && u32(line)>=anchor.line && u32(line)<anchor.line+anchor.lines
}

// A comment placed in the detail, under the line or the entity it hangs on.
@(private)
kai_detail_note :: proc(s:^Session,note:i32) {
    ctx:=s.gui.ctx
    notes:=s.kai.state.team.view.proposal.notes[:]
    if int(note)>=len(notes) {return}
    n:=&notes[note]
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=6,align_y=.Center,padding={KAI_ROW_PAD+36,0,KAI_ROW_PAD,0}}) {
        ui.icon(ctx,.Speech,ui.tone(ctx,n.outdated?"text_faint":"accent"),12)
        text:[96]u8
        who:=n.outdated?fmt.bprintf(text[:],"%s, outdated",n.author):n.author
        kai_row_names(ctx,who,n.text,ui.tone(ctx,n.outdated?"text_faint":"text"))
    }
}
