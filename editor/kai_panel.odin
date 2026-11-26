package editor

import "core:fmt"
import "core:strings"
import vcs "mirai:kai"
import "mirai:ui"

// The Kai tab of the left panel, in three views. Changes: the working change
// with its description, what it changed, each file with a check of whether
// New change closes it, a file in conflict unfolded into its fields with the
// side each takes, what refused the last snapshot with what resolves it, the
// bookmarks (the workspace's, the org's and every device's) and the log.
// Undo takes back the newest operation; a click on a change of the log
// shows the files it changed, each of which opens what the change did to it
// (kai_detail.odin), and its button, or a click on a shared bookmark, starts
// a new change on it. Publish to main closes the working change and moves
// the repository's main for its org (kai.publish). Team is the machine's
// (kai_team_panel.odin). It draws what kai_read and kai_team_read left: a
// frame reads nothing of the repository. A project with no workspace uses no
// version control, and the tab offers Enable Kai (kai.init).

KAI_HEAD :: 22
KAI_ROW_PAD :: 4

kai_panel_build :: proc(s:^Session,width,room:f32) {
    ctx:=s.gui.ctx
    w:=kai_workspace(s)
    if w==nil {
        if s.kai!=nil && s.kai.error==.Missing {
            kai_line(ctx,"This project does not use version control.")
            if ui.button(ctx,ui.id(ctx,"kai_enable"),{label="Enable Kai",variant="accent",width=-1,center=true}).clicked {kai_ask(s,"kai.init","{{}}")}
            return
        }
        ui.label(ctx,kai_missing(s),ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"),width)
        return
    }
    st:=s.kai.state
    v:=&st.view
    st.width=width
    kai_tabs_build(s)
    t:=s.kai.team
    if st.tab==.Team {
        if t==nil {return}
        if ui.scroll_area(ctx,ui.id(ctx,"kai_team_scroll"),&t.scroll,{width=ui.GROW,height=ui.GROW,direction=.Column,gap=4}) {kai_team_build(s)}
        return
    }
    if st.detail.open {
        kai_detail_build(s)
        return
    }
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"control")),gap=6,align_y=.Center}) {
        ui.icon(ctx,ui.icon_user(u8(User_Icon.Branch)),ui.tone(ctx,"text_muted"),14)
        // The id takes the room the button leaves: a spacer beside it would halve that room.
        ui.label(ctx,v.title,ui.metric(ctx,"font"),ui.tone(ctx,"text"),0,fade=true)
        label:=v.redo?"Redo":"Undo"
        if ui.button(ctx,ui.id(ctx,"kai_undo"),{label=label,icon=.Revert,icon_size=12,variant="field",disabled=v.operation==""}).clicked {
            if _,message:=kai_undo(s);message!="" {notify(s,message)}
        }
    }
    ui.text_field(ctx,ui.id(ctx,"kai_description"),st.description[:],&st.description_length,{placeholder=v.description!=""?v.description:"Describe the change",multiline=true,rows=3,live=true})
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=6}) {
        typed:=strings.trim_space(string(st.description[:st.description_length]))
        if ui.button(ctx,ui.id(ctx,"kai_describe"),{label="Describe",variant="field",width=-1,center=true,disabled=typed==""}).clicked {
            if message:=kai_describe(s,vcs.repo_working(&w.repo),typed);message!="" {notify(s,message)} else {st.description_length=0}
        }
        if ui.button(ctx,ui.id(ctx,"kai_new"),{label="New change",variant="accent",width=-1,center=true}).clicked {
            if message:=kai_new_checked(s,typed);message!="" {notify(s,message)} else {st.description_length=0}
        }
    }
    kai_publish_build(s)
    if ui.scroll_area(ctx,ui.id(ctx,"kai_scroll"),&st.scroll,{width=ui.GROW,height=ui.GROW,direction=.Column,gap=2}) {
        // Checked while any file is: a click then unchecks them all, and with none checks them all.
        some:=false
        for f in v.files {
            if f.changed && kai_checked(st,f.path) {some=true;break}
        }
        if kai_head(ctx,"CHANGES",len(v.files),&some) {kai_checks_reset(st,!some)}
        for &file in v.files {
            ui.id_push(ctx,ui.id(ctx,file.path))
            kai_file_row(s,&file)
            if file.mark=='C' && file.path==st.unfolded {kai_fields_build(s)}
            ui.id_pop(ctx)
        }
        shared:=t!=nil && t.view.org>=0
        if len(v.bookmarks)>0 || shared {
            kai_head(ctx,"BOOKMARKS",len(v.bookmarks)+(shared?len(t.view.shared):0))
            for b in v.bookmarks {
                if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=8,align_y=.Center,padding={KAI_ROW_PAD,0,KAI_ROW_PAD,0}}) {
                    ui.label(ctx,b,ui.metric(ctx,"font_small"),ui.tone(ctx,"text"),0,fade=true)
                }
            }
            kai_shared_build(s)
        }
        kai_head(ctx,"LOG",len(v.rows))
        for &row,i in v.rows {
            ui.id_push(ctx,ui.id(ctx,"change",i))
            kai_log_row(s,&row)
            ui.id_pop(ctx)
        }
    }
}

// A title and its count; with check, a checkbox before it: changed when clicked.
@(private)
kai_head :: proc(ctx:^ui.Context,title:string,count:int,check:^bool=nil) -> (changed:bool) {
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(KAI_HEAD),gap=check!=nil?8:4,align_y=.Center,padding={check!=nil?KAI_ROW_PAD:0,0,KAI_ROW_PAD,0}}) {
        if check!=nil {changed=ui.checkbox(ctx,ui.id(ctx,"kai_check_all"),check)}
        ui.label(ctx,title,ui.metric(ctx,"font_caption"),ui.tone(ctx,"text_caption"))
        ui.spacer(ctx)
        text:[16]u8
        ui.label(ctx,fmt.bprintf(text[:],"%d",count),ui.metric(ctx,"font_small"),ui.tone(ctx,"text_faint"))
    }
    return
}

// A changed file: its check, name and folder, and its mark; one in conflict
// unfolds into its fields. A conflict of the parents the change did not touch
// has no check: no new change closes it.
@(private)
kai_file_row :: proc(s:^Session,file:^Kai_File) {
    ctx:=s.gui.ctx
    row:=ui.id(ctx,"row")
    it:=ui.interact(ctx,row,{.Focusable})
    on:=ai_pointer_on(ctx,row)
    if ui.box(ctx,{id=row,width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=8,align_y=.Center,padding={KAI_ROW_PAD,0,KAI_ROW_PAD,0},fill=on?ui.tone(ctx,"chip"):{},radius=ui.metric(ctx,"radius_control")}) {
        st:=s.kai.state
        if file.changed {
            checked:=kai_checked(st,file.path)
            if ui.checkbox(ctx,ui.id(ctx,"check"),&checked) {kai_check(st,file.path,checked)}
        } else {
            ui.spacer(ctx,ui.CHECKBOX_SIDE,ui.CHECKBOX_SIDE)
        }
        conflict:=file.mark=='C'
        if conflict {
            open:=s.kai.state.unfolded==file.path
            ui.icon(ctx,open?.Chevron_Down:.Chevron_Right,ui.tone(ctx,"text_muted"),10)
        }
        slash:=strings.last_index_byte(file.path,'/')
        kai_row_names(ctx,file.path[slash+1:],slash>0?file.path[:slash]:"",ui.tone(ctx,"text"))
        tone:="text_muted"
        switch file.mark {
        case 'A': tone="success"
        case 'D','C': tone="danger"
        }
        letter:=[1]u8{file.mark}
        ui.label(ctx,string(letter[:]),ui.metric(ctx,"font_small"),ui.tone(ctx,tone))
        if it.clicked && conflict {kai_unfold(s,s.kai.state.unfolded==file.path?"":file.path)}
    }
}

// The fields in conflict of the file unfolded: ours and theirs, the one picked
// lit; or, for a file that is not an asset, its sides whole.
@(private)
kai_fields_build :: proc(s:^Session) {
    ctx:=s.gui.ctx
    st:=s.kai.state
    v:=&st.view
    path:=st.unfolded
    for &field,i in v.fields {
        ui.id_push(ctx,ui.id(ctx,"field",i))
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,gap=2,padding={22,0,KAI_ROW_PAD,4}}) {
            kai_row_names(ctx,field.name!=""?field.name:field.path,field.name!=""?field.path:"",ui.tone(ctx,"text"))
            ours,theirs:=field.ours,field.theirs
            if field.kind==.Removed {
                ours=field.ours_has?"kept":"removed"
                theirs=field.theirs_has?"kept":"removed"
            } else if field.kind==.Table {
                ours,theirs="ours whole","theirs whole"
            }
            if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=4}) {
                if ui.button(ctx,ui.id(ctx,"ours"),{label=ours,variant=st.picks[i]?"ghost":"field",width=-1,height=ui.metric(ctx,"control")-6,size=ui.metric(ctx,"font_small")}).clicked {st.picks[i]=false}
                if ui.button(ctx,ui.id(ctx,"theirs"),{label=theirs,variant=st.picks[i]?"field":"ghost",width=-1,height=ui.metric(ctx,"control")-6,size=ui.metric(ctx,"font_small")}).clicked {st.picks[i]=true}
            }
        }
        ui.id_pop(ctx)
    }
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=6,padding={22,0,KAI_ROW_PAD,6}}) {
        if !v.whole && ui.button(ctx,ui.id(ctx,"kai_resolve"),{label="Resolve",variant="accent",width=-1,center=true}).clicked {
            theirs:=make([dynamic]string,context.temp_allocator)
            for field,i in v.fields {if st.picks[i] {append(&theirs,field.path)}}
            if message:=kai_resolve(s,path,.Fields,theirs[:]);message!="" {notify(s,message)}
            return
        }
        if ui.button(ctx,ui.id(ctx,"kai_ours"),{label="Take ours",variant="field",width=-1,center=true}).clicked {
            if message:=kai_resolve(s,path,.Ours,nil);message!="" {notify(s,message)}
            return
        }
        if ui.button(ctx,ui.id(ctx,"kai_theirs"),{label="Take theirs",variant="field",width=-1,center=true}).clicked {
            if message:=kai_resolve(s,path,.Theirs,nil);message!="" {notify(s,message)}
        }
    }
}

// A change of the log: its id, description and bookmarks; a click shows the
// files it changed, and its button starts a new change on it.
@(private)
kai_log_row :: proc(s:^Session,row:^Kai_Row) {
    ctx:=s.gui.ctx
    st:=s.kai.state
    id:=ui.id(ctx,"row")
    it:=ui.interact(ctx,id,{.Focusable})
    on:=ai_pointer_on(ctx,id)
    picked:=st.picked==row.revision
    if ui.box(ctx,{id=id,width=ui.GROW,height=ui.fixed(ui.metric(ctx,"control")-4),gap=8,align_y=.Center,padding={KAI_ROW_PAD,0,KAI_ROW_PAD,0},fill=picked?ui.tone(ctx,"chip_active"):on?ui.tone(ctx,"chip"):{},radius=ui.metric(ctx,"radius_control")}) {
        if ui.box(ctx,{width=ui.fixed(7),height=ui.fixed(7),fill=row.working?ui.tone(ctx,"accent"):ui.tone(ctx,"text_faint"),radius=3.5}) {}
        ui.label(ctx,row.change[:min(len(row.change),8)],ui.metric(ctx,"font_small"),ui.tone(ctx,"text_faint"))
        text:=row.description!="" ? row.description : "(no description)"
        if cut:=strings.index_byte(text,'\n');cut>=0 {text=text[:cut]}
        kai_row_names(ctx,text,row.bookmarks,row.conflicts>0?ui.tone(ctx,"danger"):ui.tone(ctx,"text"))
        if !row.working && ui.icon_button(ctx,ui.id(ctx,"new"),.Plus,ui.metric(ctx,"row")-4,tip="Start a change on it").clicked {
            parents:=[1]vcs.Revision{row.revision}
            if message:=kai_new(s,parents[:],"");message!="" {notify(s,message)}
            return
        }
    }
    if it.clicked {
        st.picked=picked?{}:row.revision
        kai_read(s)
        return
    }
    if !picked {return}
    for &file,k in st.view.picked {
        ui.id_push(ctx,ui.id(ctx,"file",k))
        if kai_file_open_row(ctx,&file) {
            if message:=kai_detail_open(s,row.revision,file.path);message!="" {notify(s,message)}
        }
        ui.id_pop(ctx)
    }
}

// A file a change changed, indented under it: its name, folder and mark; true when it is clicked.
@(private)
kai_file_open_row :: proc(ctx:^ui.Context,file:^Kai_File,picked:=false) -> bool {
    row:=ui.id(ctx,"row")
    it:=ui.interact(ctx,row,{.Focusable})
    on:=ai_pointer_on(ctx,row)
    if ui.box(ctx,{id=row,width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=8,align_y=.Center,padding={KAI_ROW_PAD+12,0,KAI_ROW_PAD,0},fill=picked?ui.tone(ctx,"chip_active"):on?ui.tone(ctx,"chip"):{},radius=ui.metric(ctx,"radius_control")}) {
        slash:=strings.last_index_byte(file.path,'/')
        kai_row_names(ctx,file.path[slash+1:],slash>0?file.path[:slash]:"",ui.tone(ctx,"text"))
        letter:=[1]u8{file.mark}
        ui.label(ctx,string(letter[:]),ui.metric(ctx,"font_small"),ui.tone(ctx,file.mark=='A'?"success":file.mark=='M'?"text_muted":"danger"))
    }
    return it.clicked
}

// A name and what follows it, faint, cut with an ellipsis where the row ends.
@(private)
kai_row_names :: proc(ctx:^ui.Context,name,rest:string,color:ui.Color) {
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=8,align_y=.Center}) {
        size:=ui.metric(ctx,"font_small")
        ui.text(ctx,name,{size=size,color=color,align_y=.Center,ellipsis=true},height=ui.fixed(size+6))
        if rest!="" {ui.text(ctx,rest,{size=size,color=ui.tone(ctx,"text_faint"),align_y=.Center,ellipsis=true},ui.GROW,ui.fixed(size+6))}
    }
}
