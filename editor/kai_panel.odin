package editor

import "core:fmt"
import "core:strings"
import vcs "mirai:kai"
import "mirai:ui"

// The Kai tab of the left panel: the working change with its description,
// what it changed, a file in conflict unfolded into its fields with the side
// each takes, the bookmarks and the log. Undo takes back the newest
// operation; a click on a change of the log starts a new change on it. It
// draws what kai_read left: a frame reads nothing of the repository.

KAI_HEAD :: 22
KAI_ROW_PAD :: 4

kai_panel_build :: proc(s:^Session,width,room:f32) {
    ctx:=s.gui.ctx
    w:=kai_workspace(s)
    if w==nil {
        ui.label(ctx,kai_missing(s),ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"),width)
        return
    }
    st:=s.kai.state
    v:=&st.view
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"control")),gap=6,align_y=.Center}) {
        ui.icon(ctx,ui.icon_user(u8(User_Icon.Branch)),ui.tone(ctx,"text_muted"),14)
        ui.label(ctx,v.title,ui.metric(ctx,"font"),ui.tone(ctx,"text"),0,fade=true)
        ui.spacer(ctx)
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
            if message:=kai_new(s,nil,typed);message!="" {notify(s,message)} else {st.description_length=0}
        }
    }
    if ui.scroll_area(ctx,ui.id(ctx,"kai_scroll"),&st.scroll,{width=ui.GROW,height=ui.GROW,direction=.Column,gap=2}) {
        kai_head(ctx,"CHANGES",len(v.files))
        for &file,i in v.files {
            ui.id_push(ctx,ui.id(ctx,"file",i))
            kai_file_row(s,&file)
            if file.mark=='C' && file.path==st.unfolded {kai_fields_build(s)}
            ui.id_pop(ctx)
        }
        if len(v.bookmarks)>0 {
            kai_head(ctx,"BOOKMARKS",len(v.bookmarks))
            for b in v.bookmarks {
                if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=8,align_y=.Center,padding={KAI_ROW_PAD,0,KAI_ROW_PAD,0}}) {
                    ui.label(ctx,b,ui.metric(ctx,"font_small"),ui.tone(ctx,"text"),0,fade=true)
                }
            }
        }
        kai_head(ctx,"LOG",len(v.rows))
        for &row,i in v.rows {
            ui.id_push(ctx,ui.id(ctx,"change",i))
            kai_log_row(s,&row)
            ui.id_pop(ctx)
        }
    }
}

@(private)
kai_head :: proc(ctx:^ui.Context,title:string,count:int) {
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(KAI_HEAD),gap=4,align_y=.Center,padding={0,0,KAI_ROW_PAD,0}}) {
        ui.label(ctx,title,ui.metric(ctx,"font_caption"),ui.tone(ctx,"text_caption"))
        ui.spacer(ctx)
        text:[16]u8
        ui.label(ctx,fmt.bprintf(text[:],"%d",count),ui.metric(ctx,"font_small"),ui.tone(ctx,"text_faint"))
    }
}

// A changed file: its name and folder, and its mark; one in conflict unfolds
// into its fields.
@(private)
kai_file_row :: proc(s:^Session,file:^Kai_File) {
    ctx:=s.gui.ctx
    row:=ui.id(ctx,"row")
    it:=ui.interact(ctx,row,{.Focusable})
    on:=ai_pointer_on(ctx,row)
    if ui.box(ctx,{id=row,width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=8,align_y=.Center,padding={KAI_ROW_PAD,0,KAI_ROW_PAD,0},fill=on?ui.tone(ctx,"chip"):{},radius=ui.metric(ctx,"radius_control")}) {
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

// A change of the log: its id, description and bookmarks; a click starts a
// new change on it.
@(private)
kai_log_row :: proc(s:^Session,row:^Kai_Row) {
    ctx:=s.gui.ctx
    id:=ui.id(ctx,"row")
    it:=ui.interact(ctx,id,{.Focusable})
    on:=ai_pointer_on(ctx,id)
    if ui.box(ctx,{id=id,width=ui.GROW,height=ui.fixed(ui.metric(ctx,"control")-4),gap=8,align_y=.Center,padding={KAI_ROW_PAD,0,KAI_ROW_PAD,0},fill=on?ui.tone(ctx,"chip"):{},radius=ui.metric(ctx,"radius_control")}) {
        if ui.box(ctx,{width=ui.fixed(7),height=ui.fixed(7),fill=row.working?ui.tone(ctx,"accent"):ui.tone(ctx,"text_faint"),radius=3.5}) {}
        ui.label(ctx,row.change[:min(len(row.change),8)],ui.metric(ctx,"font_small"),ui.tone(ctx,"text_faint"))
        text:=row.description!="" ? row.description : "(no description)"
        if cut:=strings.index_byte(text,'\n');cut>=0 {text=text[:cut]}
        kai_row_names(ctx,text,row.bookmarks,row.conflicts>0?ui.tone(ctx,"danger"):ui.tone(ctx,"text"))
    }
    if it.clicked && !row.working {
        parents:=[1]vcs.Revision{row.revision}
        if message:=kai_new(s,parents[:],"");message!="" {notify(s,message)}
    }
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
