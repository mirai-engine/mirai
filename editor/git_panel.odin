package editor

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "mirai:asset"
import "mirai:editor/git"
import "mirai:platform"
import "mirai:std/base"
import "mirai:editor/kit"
import "mirai:ui"

// The Git tab of the left panel: a project without a repository makes one; a
// repository shows its branch, the changes that are pending and those kept
// for the next commit, and the last commits; a merge with conflicts shows
// them (git_merge.odin).

GIT_HISTORY_DEFAULT :: 120
GIT_HISTORY_MIN :: 48
GIT_EDGE :: 7 // the band over the history that resizes it
GIT_DISCARD_ROWS :: 6 // files the question to discard lists; the rest is a count

Git_Source :: struct {extension:string,kind:asset.Fourcc}
GIT_SOURCES :: [?]Git_Source{
    {"wav",asset.KIND_SOUND},{"ogg",asset.KIND_SOUND},{"mp3",asset.KIND_SOUND},
    {"png",asset.KIND_TEXTURE},{"jpg",asset.KIND_TEXTURE},{"jpeg",asset.KIND_TEXTURE},{"tga",asset.KIND_TEXTURE},
    {"exr",asset.KIND_TEXTURE},{"hdr",asset.KIND_TEXTURE},{"psd",asset.KIND_TEXTURE},
    {"glb",asset.KIND_MESH},{"gltf",asset.KIND_MESH},{"obj",asset.KIND_MESH},{"fbx",asset.KIND_MESH},{"usd",asset.KIND_MESH},{"usdz",asset.KIND_MESH},
}

git_panel_build :: proc(s:^Session,width,room:f32) {
    g:=s.git;ctx:=s.gui.ctx
    g.panel_frame=s.frame
    if !g.checked {
        ui.label(ctx,"Looking for git...",ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"))
        return
    }
    if !g.available {
        ui.label(ctx,"Git was not found",ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"))
        if ui.button(ctx,ui.id(ctx,"git_check"),{label="Check again",icon=.Refresh,variant="field",width=-1}).clicked {g.checked=false;git_refresh(s)}
        return
    }
    if !g.repository {
        git_init_build(s)
    } else if g.merging {
        git_merge_build(s,width,room)
    } else {
        git_changes_build(s,width,room)
    }
    git_status_build(s)
}

@(private)
git_init_build :: proc(s:^Session) {
    g:=s.git;ctx:=s.gui.ctx
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"control")),gap=8,align_y=.Center}) {
        ui.icon(ctx,ui.icon_user(u8(User_Icon.Folder)),ui.tone(ctx,"text_muted"),14)
        ui.label(ctx,filepath.base(s.project_root),ui.metric(ctx,"font"),ui.tone(ctx,"text"))
    }
    if kit.property(ctx,"Remote") {
        ui.text_field(ctx,ui.id(ctx,"git_remote"),g.remote_field[:],&g.remote_length,{placeholder="https://github.com/user/repo.git",live=true})
    }
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=8,align_y=.Center}) {
        ui.checkbox(ctx,ui.id(ctx,"git_lfs"),&g.lfs)
        ui.label(ctx,"Use Git LFS for textures, meshes and sounds",ui.metric(ctx,"font_small"),ui.tone(ctx,"text_label"))
    }
    if ui.button(ctx,ui.id(ctx,"git_init"),{label="Initialize repository",variant="accent",width=-1,center=true,disabled=git.working(g)}).clicked {
        if message:=git_init(s);message!="" {notify(s,message)}
    }
}

@(private)
git_changes_build :: proc(s:^Session,width,room:f32) {
    g:=s.git;ctx:=s.gui.ctx
    busy:=git.working(g)
    has_remote:=base.text_get(g.remote[:])!=""
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"control")),gap=6,align_y=.Center}) {
        ui.icon(ctx,ui.icon_user(u8(User_Icon.Branch)),ui.tone(ctx,"text_muted"),14)
        // A long name takes the room up to Pull and fades out there.
        ui.label(ctx,base.text_get(g.branch[:]),ui.metric(ctx,"font"),ui.tone(ctx,"text"),0,fade=true)
        behind,ahead:[16]u8
        if ui.button(ctx,ui.id(ctx,"git_pull"),{label="Pull",icon=ui.icon_user(u8(User_Icon.Down)),icon_size=13,detail=g.behind>0?fmt.bprintf(behind[:],"↓%d",g.behind):"",variant="field",disabled=busy || !has_remote}).clicked {
            if message:=git_pull(s);message!="" {notify(s,message)}
        }
        if ui.button(ctx,ui.id(ctx,"git_push"),{label="Push",icon=ui.icon_user(u8(User_Icon.Up)),icon_size=13,detail=g.ahead>0?fmt.bprintf(ahead[:],"↑%d",g.ahead):"",variant="field",disabled=busy || !has_remote || g.upstream && g.ahead==0}).clicked {
            if message:=git.push(s.git,git_roots(s));message!="" {notify(s,message)}
        }
    }
    // The changes take what the message, the buttons and the history leave:
    // those pending first, then those kept.
    history:=len(g.history)>0
    l:=&s.gui.layout
    history_height:=l.git_history>0?l.git_history:GIT_HISTORY_DEFAULT
    git_changes_list(s,busy)
    ui.text_field(ctx,ui.id(ctx,"git_message"),g.message[:],&g.message_length,{placeholder="Commit message",multiline=true,rows=3,live=true,disabled=busy})
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=6}) {
        empty:=len(g.changes)==0 || g.message_length==0
        if ui.button(ctx,ui.id(ctx,"git_commit"),{label="Commit",variant="accent",width=-1,center=true,disabled=busy || empty}).clicked {
            if message:=git_commit(s,false);message!="" {notify(s,message)}
        }
        if ui.button(ctx,ui.id(ctx,"git_commit_push"),{label="Commit and push",variant="field",width=-1,center=true,disabled=busy || empty || !has_remote}).clicked {
            if message:=git_commit(s,true);message!="" {notify(s,message)}
        }
    }
    if !history {return}
    // The edge over the history: dragged, it gives the history more or less of the tab.
    edge:=ui.id(ctx,"git_history_edge")
    it:=ui.interact(ctx,edge)
    lit:=it.hot || it.active
    if ui.box(ctx,{id=edge,width=ui.GROW,height=ui.fixed(GIT_EDGE),align_y=.Center}) {
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(lit?2:1),fill=lit?ui.color_alpha(ui.tone(ctx,"accent"),160):ui.tone(ctx,"divider")}) {}
    }
    if lit {s.gui.cursor=.Resize_Vertical}
    if it.pressed {g.history_drag={history_height,ctx.pointer.y}}
    if it.active {
        history_height=clamp(g.history_drag[0]-(ctx.pointer.y-g.history_drag[1]),GIT_HISTORY_MIN,max(room-ui.metric(ctx,"control")*8,GIT_HISTORY_MIN))
        l.git_history=history_height
    }
    ui.label(ctx,"HISTORY",ui.metric(ctx,"font_caption"),ui.tone(ctx,"text_caption"))
    if ui.scroll_area(ctx,ui.id(ctx,"git_history"),&g.history_scroll,{width=ui.GROW,height=ui.fixed(history_height)}) {
        for &commit,i in g.history {
            ui.id_push(ctx,ui.id(ctx,"commit",i))
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"control")-4),gap=8,align_y=.Center,padding={4,0,12,0}}) {
                if ui.box(ctx,{width=ui.fixed(7),height=ui.fixed(7),fill=i==0?ui.tone(ctx,"accent"):ui.tone(ctx,"text_faint"),radius=3.5}) {}
                ui.label(ctx,base.text_get(commit.subject[:]),ui.metric(ctx,"font_small"),ui.tone(ctx,"text"),0)
                ui.label(ctx,base.text_get(commit.age[:]),ui.metric(ctx,"font_small"),ui.tone(ctx,"text_faint"))
            }
            ui.id_pop(ctx)
        }
    }
}

GIT_HEAD :: 22    // the height of the heads of the changes pending and of those kept
GIT_ROW_PAD :: 4  // between the edges of the list and what its rows hold

@(private)
Git_Row_Kind :: enum u8 {Head,Change,Entity}

// A row of the list of changes: a head, a change of g.changes or an entity
// of g.entities.rows under the change of the scene unfolded.
@(private)
Git_Row :: struct {kind:Git_Row_Kind,kept:bool,change,entity:int}

// The changes that are pending, then those kept for the next commit, each
// under its head; a pending scene unfolds into its entities. Only the rows in
// sight are built.
@(private)
git_changes_list :: proc(s:^Session,busy:bool) {
    g:=s.git;ctx:=s.gui.ctx
    git_entities_update(s)
    unfolded:=base.text_get(g.entities.path[:])
    rows:=make([dynamic]Git_Row,context.temp_allocator)
    heights:=make([dynamic]f32,context.temp_allocator)
    row:=ui.metric(ctx,"row")
    counts:[2]int
    for kept in ([2]bool{false,true}) {
        head:=len(rows)
        append(&rows,Git_Row{kind=.Head,kept=kept})
        append(&heights,GIT_HEAD)
        for &change,i in g.changes {
            if !(kept?change.kept:change.pending || change.status=='U') {continue}
            counts[int(kept)]+=1
            append(&rows,Git_Row{kind=.Change,kept=kept,change=i})
            append(&heights,row)
            if kept || unfolded!=base.text_get(change.path[:]) {continue}
            for _,e in g.entities.rows {
                append(&rows,Git_Row{kind=.Entity,change=i,entity=e})
                append(&heights,row)
            }
        }
        // Nothing kept: no head for it.
        if kept && counts[1]==0 {
            resize(&rows,head)
            resize(&heights,head)
        }
    }
    area:=ui.id(ctx,"git_changes")
    view,_:=ui.widget_rect(ctx,area)
    total:f32
    for h in heights {total+=h}
    // Rows taller than the area leave its bar a column of its own.
    bar:=ui.SCROLL_GUTTER if total>view.h+0.5 else 0
    first,last:=ui.rows_begin(ctx,area,&g.scroll,heights[:],ui.GROW,ui.GROW,bar_room=bar)
    registry:=files_registry(s)
    reverted:base.Entity_Id
    for r in rows[first:last] {
        ui.id_push(ctx,ui.id(ctx,r.kept?"git_kept":"git_pending"))
        switch r.kind {
        case .Head: git_changes_head(s,r.kept,counts[int(r.kept)],busy)
        case .Change:
            ui.id_push(ctx,ui.id(ctx,"change",r.change))
            git_change_row(s,registry,&g.changes[r.change],r.kept,busy)
            ui.id_pop(ctx)
        case .Entity:
            ui.id_push(ctx,ui.id(ctx,"change",r.change))
            if id:=git_entity_row(s,r.entity);id!=0 {reverted=id}
            ui.id_pop(ctx)
        }
        ui.id_pop(ctx)
    }
    ui.rows_end(ctx,area,&g.scroll,heights[:],last)
    if reverted!=0 {
        ids:=[1]base.Entity_Id{reverted}
        if _,message:=git_entities_revert(s,ids[:],true);message!="" {notify(s,message)}
    }
}

// The head of the changes pending or kept, with their count: what acts on
// all of them shows while the pointer is on it.
@(private)
git_changes_head :: proc(s:^Session,kept:bool,count:int,busy:bool) {
    g:=s.git;ctx:=s.gui.ctx
    header:=ui.id(ctx,"head")
    _=ui.interact(ctx,header,{.Passive})
    if ui.box(ctx,{id=header,width=ui.GROW,height=ui.fixed(GIT_HEAD),gap=4,align_y=.Center,padding={0,0,GIT_ROW_PAD,0}}) {
        ui.label(ctx,kept?"KEPT":"CHANGES",ui.metric(ctx,"font_caption"),ui.tone(ctx,"text_caption"))
        ui.spacer(ctx)
        if ai_pointer_on(ctx,header) && count>0 {
            if kept {
                if git_row_button(ctx,"unkeep_all",.Cross,"Take all out of what is kept",busy) {git_run(s,.Unkeep,"")}
            } else {
                if git_row_button(ctx,"keep_all",.Check,"Keep all changes",busy || g.merging) {git_run(s,.Keep,"")}
                if git_row_button(ctx,"discard_all",.Revert,"Discard all changes",busy || g.merging) {git_discard_ask(s,"")}
            }
        }
        text:[16]u8
        ui.label(ctx,fmt.bprintf(text[:],"%d",count),ui.metric(ctx,"font_small"),ui.tone(ctx,"text_faint"))
    }
}

// A changed file: its name and its folder, cut where the row ends, and what
// acts on it while the pointer is on the row.
@(private)
git_change_row :: proc(s:^Session,registry:^asset.Registry,change:^git.Change,kept:bool,busy:bool) {
    g:=s.git;ctx:=s.gui.ctx
    row:=ui.id(ctx,"row")
    _=ui.interact(ctx,row,{.Passive})
    if ui.box(ctx,{id=row,width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=8,align_y=.Center,padding={GIT_ROW_PAD,0,GIT_ROW_PAD,0},fill=ai_pointer_on(ctx,row)?ui.tone(ctx,"chip"):{},radius=ui.metric(ctx,"radius_control")}) {
        path:=git.change_path(g,change)
        slash:=strings.last_index_byte(path,'/')
        // A pending scene unfolds into its entities that differ from what is kept.
        if !kept && change.status!='U' && strings.has_suffix(path,SCENE_EXTENSION) {
            open:=base.text_get(g.entities.path[:])==base.text_get(change.path[:])
            if ui.button(ctx,ui.id(ctx,"unfold"),{icon=open?.Chevron_Down:.Chevron_Right,icon_color=ui.tone(ctx,"text_muted"),variant="ghost",width=14,height=18,icon_size=10,disabled=busy && !open}).clicked {
                if message:=git_entities_show(s,open?"":base.text_get(change.path[:]));message!="" {notify(s,message)}
            }
        }
        icon,color:=git_change_icon(s,registry,path)
        ui.icon(ctx,icon,color,14)
        git_row_names(ctx,path[slash+1:],slash>0?path[:slash]:"",ui.tone(ctx,"text"))
        if change.status!='U' && ai_pointer_on(ctx,row) {
            full:=base.text_get(change.path[:])
            if kept {
                if git_row_button(ctx,"unkeep",.Cross,"Take out of what is kept",busy) {git_run(s,.Unkeep,full)}
            } else {
                if git_row_button(ctx,"keep",.Check,"Keep",busy) {git_run(s,.Keep,full)}
                if git_row_button(ctx,"discard",.Revert,"Discard changes",busy) {git_discard_ask(s,full)}
            }
        }
        letter:=[1]u8{change.status}
        status:=ui.tone(ctx,"text_muted")
        switch change.status {
        case 'A': status=ui.tone(ctx,"success")
        case 'D','U': status=ui.tone(ctx,"danger")
        }
        ui.label(ctx,string(letter[:]),ui.metric(ctx,"font_small"),status)
    }
}

// A name and what follows it, faint, in the room a row leaves them: what
// does not fit ends in an ellipsis.
@(private)
git_row_names :: proc(ctx:^ui.Context,name,rest:string,color:ui.Color) {
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=8,align_y=.Center}) {
        size:=ui.metric(ctx,"font_small")
        ui.text(ctx,name,{size=size,color=color,align_y=.Center,ellipsis=true},height=ui.fixed(size+6))
        if rest!="" {ui.text(ctx,rest,{size=size,color=ui.tone(ctx,"text_faint"),align_y=.Center,ellipsis=true},ui.GROW,ui.fixed(size+6))}
    }
}

// An entity of the scene unfolded that differs from what git keeps, under
// those it hangs from: a click selects it, and reverting it puts it back as
// kept with what hangs from it. The entity to revert, or 0.
@(private)
git_entity_row :: proc(s:^Session,index:int) -> (reverted:base.Entity_Id) {
    g:=s.git;ctx:=s.gui.ctx
    entity:=&g.entities.rows[index]
    ui.id_push(ctx,ui.id(ctx,"entity",index))
    defer ui.id_pop(ctx)
    row:=ui.id(ctx,"row")
    it:=ui.interact(ctx,row,{.Focusable})
    on:=ai_pointer_on(ctx,row)
    if ui.box(ctx,{id=row,width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=8,align_y=.Center,padding={22+f32(entity.depth)*12,0,GIT_ROW_PAD,0},fill=on?ui.tone(ctx,"chip"):{},radius=ui.metric(ctx,"radius_control")}) {
        same:=entity.change==.Same
        git_row_names(ctx,base.text_get(entity.name[:]),base.text_get(entity.components[:]),same?ui.tone(ctx,"text_muted"):ui.tone(ctx,"text"))
        if on && git_row_button(ctx,"revert",.Revert,same?"Revert what hangs from it":"Revert",git.working(g)) {reverted=entity.id}
        letters:=[Git_Entity_Change]string{.Same="",.Added="A",.Changed="M",.Removed="D"}
        tones:=[Git_Entity_Change]string{.Same="text_muted",.Added="success",.Changed="text_muted",.Removed="danger"}
        ui.label(ctx,letters[entity.change],ui.metric(ctx,"font_small"),ui.tone(ctx,tones[entity.change]))
    }
    if it.clicked {git_select(s,entity.id)}
    return
}

@(private)
git_row_button :: proc(ctx:^ui.Context,name:string,icon:ui.Icon,tip:string,disabled:bool) -> bool {
    return ui.button(ctx,ui.id(ctx,name),{icon=icon,tip=tip,icon_color=ui.tone(ctx,"text_muted"),variant="ghost",width=18,height=18,icon_size=12,disabled=disabled}).clicked
}

// Keeps, takes out of what is kept or discards a change by its path from the
// root of the repository, or all of them with none, and says why it could not.
@(private)
git_run :: proc(s:^Session,operation:git.Operation,path:string) {
    paths:=[1]string{path}
    if message:=git_changes_run(s,operation,path!=""?paths[:]:nil);message!="" {notify(s,message)}
}

// The icon of a changed file with the color of its kind, as the browser has them.
@(private)
git_change_icon :: proc(s:^Session,registry:^asset.Registry,path:string) -> (icon:ui.Icon,color:ui.Color) {
    relative:=strings.trim_prefix(path,"assets/")
    if registry!=nil && relative!=path {
        if file,found:=asset.registry_find_path(registry,relative);found && file.state==.Asset {
            icon,_=asset_file_icon(s,file)
            return icon,asset_file_color(s,file)
        }
    }
    if kind,found:=asset.kind_of_extension(path);found {return asset_icon(s,kind)}
    for &declared in asset_plugin_kinds(s) {
        if declared.extension!="" && strings.has_suffix(path,declared.extension) {return declared.icon,declared.color}
    }
    // A source of an import, as the asset it makes.
    extension:=strings.to_lower(path[strings.last_index_byte(path,'.')+1:],context.temp_allocator)
    for source in GIT_SOURCES {
        if extension==source.extension {return asset_icon(s,source.kind)}
    }
    switch extension {
    case "slang": return .Material,GIT_CODE_COLOR
    case "odin":  return ui.icon_user(u8(User_Icon.Terminal)),GIT_CODE_COLOR
    }
    return ui.icon_user(u8(User_Icon.List)),GIT_FILE_COLOR
}

// Asks before discarding: what goes back to what is kept cannot come back.
@(private)
git_discard_ask :: proc(s:^Session,path:string) {
    base.text_set(s.gui.discard_path[:],path)
    s.gui.modal=.Git_Discard
}

@(private)
git_discard_modal :: proc(s:^Session) {
    g:=s.git;gui:=s.gui;ctx:=gui.ctx
    path:=base.text_get(gui.discard_path[:])
    closed:=false
    defer if closed {modal_close(gui)}
    if ui.modal(ctx,shell_id(gui,"git_discard"),{width=400,padding=16,gap=12,close=&closed}) {
        files:=make([dynamic]^git.Change,context.temp_allocator)
        for &change in g.changes {
            if change.pending && change.status!='U' && (path=="" || base.text_get(change.path[:])==path) {append(&files,&change)}
        }
        ui.label(ctx,len(files)==1?"Discard changes?":fmt.tprintf("Discard %d changes?",len(files)),ui.metric(ctx,"font_heading"),ui.tone(ctx,"text"),font=ui.FONT_SEMIBOLD)
        registry:=files_registry(s)
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,gap=2}) {
            for change in files[:min(len(files),GIT_DISCARD_ROWS)] {
                file:=git.change_path(g,change)
                icon,color:=git_change_icon(s,registry,file)
                if ui.box(ctx,{width=ui.GROW,height=ui.fixed(26),gap=8,padding={8,0,8,0},align_y=.Center,fill=ui.tone(ctx,"field"),radius=4}) {
                    ui.icon(ctx,icon,color,14)
                    ui.label(ctx,file,ui.metric(ctx,"font_small"),ui.tone(ctx,"text"),0)
                }
            }
            if len(files)>GIT_DISCARD_ROWS {ui.label(ctx,fmt.tprintf("and %d more",len(files)-GIT_DISCARD_ROWS),ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"))}
        }
        untracked:=0
        for change in files {if !change.tracked {untracked+=1}}
        if untracked>0 {ui.label(ctx,untracked==1?"A new file goes to the trash":fmt.tprintf("%d new files go to the trash",untracked),ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"))}
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"control")),gap=8,align_x=.End,align_y=.Center}) {
            if ui.button(ctx,shell_id(gui,"git_discard_cancel"),{label="Cancel",variant="field",width=90,height=ui.metric(ctx,"control"),center=true}).clicked {closed=true}
            if ui.button(ctx,shell_id(gui,"git_discard_confirm"),{label="Discard",variant="danger",width=90,height=ui.metric(ctx,"control"),center=true,disabled=len(files)==0}).clicked {
                gui.modal=.None
                git_run(s,.Discard,path)
            }
        }
    }
}

// The pending changes the editor found when it opened, or has when it ends:
// kept or discarded, all or one by one in the Git tab.
@(private)
git_pending_modal :: proc(s:^Session) {
    g:=s.git;gui:=s.gui;ctx:=gui.ctx
    quits:=g.notice==.Quit
    closed:=false
    defer if closed {
        modal_close(gui)
        if quits {projects_next_cancel(s)}
    }
    if ui.modal(ctx,shell_id(gui,"git_pending"),{width=400,padding=16,gap=12,close=&closed}) {
        ui.label(ctx,quits?"Pending changes":"Pending changes from before",ui.metric(ctx,"font_heading"),ui.tone(ctx,"text"),font=ui.FONT_SEMIBOLD)
        registry:=files_registry(s)
        shown,count:=0,git_pending_count(s)
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,gap=2}) {
            for &change in g.changes {
                if !change.pending || change.status=='U' || shown>=GIT_DISCARD_ROWS {continue}
                shown+=1
                file:=git.change_path(g,&change)
                icon,color:=git_change_icon(s,registry,file)
                if ui.box(ctx,{width=ui.GROW,height=ui.fixed(26),gap=8,padding={8,0,8,0},align_y=.Center,fill=ui.tone(ctx,"field"),radius=4}) {
                    ui.icon(ctx,icon,color,14)
                    ui.label(ctx,file,ui.metric(ctx,"font_small"),ui.tone(ctx,"text"),0)
                }
            }
            if count>shown {ui.label(ctx,fmt.tprintf("and %d more",count-shown),ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"))}
        }
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"control")),gap=8,align_x=.End,align_y=.Center}) {
            if ui.button(ctx,shell_id(gui,"git_pending_later"),{label=quits?"Cancel":"Later",variant="field",width=90,height=ui.metric(ctx,"control"),center=true}).clicked {closed=true}
            for operation in ([2]git.Operation{.Discard,.Keep}) {
                keep:=operation==.Keep
                if ui.button(ctx,shell_id(gui,keep?"git_pending_keep":"git_pending_discard"),{label=keep?"Keep all":"Discard",variant=keep?"accent":"danger",width=100,height=ui.metric(ctx,"control"),center=true,disabled=git.working(g)}).clicked {git_pending_take(s,operation)}
            }
        }
    }
}

// Keeps or discards every pending change, as the dialog of the pending
// changes asks: before the editor ends, it ends once they are.
@(private)
git_pending_take :: proc(s:^Session,operation:git.Operation) {
    s.gui.modal=.None
    if message:=git_changes_run(s,operation,nil);message!="" {notify(s,message)} else {s.git.asked=s.git.notice}
}

// The project is in no repository, or git is not there: the editor edits
// nothing until it is.
@(private)
git_missing_modal :: proc(s:^Session) {
    g:=s.git;gui:=s.gui;ctx:=gui.ctx
    if ui.modal(ctx,shell_id(gui,"git_missing"),{width=400,padding=16,gap=12}) {
        ui.label(ctx,g.available?"The project is not a git repository":"Git was not found",ui.metric(ctx,"font_heading"),ui.tone(ctx,"text"),font=ui.FONT_SEMIBOLD)
        if g.available {
            git_init_build(s)
        } else if ui.button(ctx,ui.id(ctx,"git_check"),{label="Check again",icon=.Refresh,variant="field",width=-1}).clicked {
            g.checked=false
            gui.modal=.None
            git_refresh(s)
        }
        if ui.button(ctx,shell_id(gui,"git_missing_quit"),{label="Quit",variant="field",width=-1,center=true}).clicked {s.requests+={.Quit}}
    }
}

// What git does now, or what it last said went wrong.
@(private)
git_status_build :: proc(s:^Session) {
    g:=s.git;ctx:=s.gui.ctx
    doing:=""
    #partial switch g.operation {
    case .Init: doing="Making the repository..."
    case .Commit,.Commit_Push: doing="Committing..."
    case .Keep: doing="Keeping..."
    case .Discard: doing="Discarding..."
    case .Push: doing="Pushing..."
    case .Pull: doing="Pulling..."
    case .Abort: doing="Aborting the merge..."
    case .Finish: doing="Finishing the merge..."
    }
    if doing!="" {ui.label(ctx,doing,ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"));return}
    if failure:=base.text_get(g.error[:]);failure!="" {ui.text(ctx,failure,ui.prose(ctx,ui.metric(ctx,"font_small"),ui.tone(ctx,"danger")))}
}
