package editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "mirai:cook/build"
import ka "mirai:cook/kai"
import vcs "mirai:kai"
import "mirai:platform"
import "mirai:project"
import "mirai:std/base"
import "mirai:ui"

// What the launcher does to a project of this machine without a terminal: it
// takes the org's main into its Kai workspace (Update), removes what its
// builds left, restores the pins of its packages when an opening failed, and
// moves its folder to the Trash once a snapshot keeps its working copy in the
// store. The right-click menu of a row reaches each.

// Takes the org's main into the workspace at folder and says what it did.
projects_update :: proc(s:^Session,folder:string) {
    t,message:=kai_team_of(s)
    if t==nil {
        notify(s,message)
        return
    }
    result,e:=ka.project_update_folder(&s.store,t,folder,kai_types(s))
    if e!=.None {
        notify(s,fmt.tprintf("Kai: %s",t.why!=""?t.why:vcs.error_text(e)))
        return
    }
    if p:=s.projects;p!=nil && p.shown {projects_rows_read(s)}
    switch {
    case result.up_to_date: notify(s,fmt.tprintf("Already up to date with %s",ka.BOOKMARK_DEFAULT))
    case result.conflicts==1: notify(s,fmt.tprintf("Updated from %s: 1 file is in conflict, review it in the Kai tab",ka.BOOKMARK_DEFAULT))
    case result.conflicts>1: notify(s,fmt.tprintf("Updated from %s: %d files are in conflict, review them in the Kai tab",ka.BOOKMARK_DEFAULT,result.conflicts))
    case: notify(s,fmt.tprintf("Updated from %s",ka.BOOKMARK_DEFAULT))
    }
}

// Why the launcher may not change the folder of a project: being opened,
// open in this editor, or no folder. "" when it may.
@(private)
projects_busy_refusal :: proc(s:^Session,folder:string) -> string {
    p:=s.projects
    if folder=="" || !os.is_dir(folder) {return fmt.tprintf("%s is not a folder",folder)}
    if projects_opening(p) || p.next {return "A project is being opened: wait for it or cancel it"}
    if s.has_project && !p.launcher && project.path_same(s.project_root,folder) {return "This project is open in this editor: open another one first"}
    return ""
}

// Why the folder of a project may not be removed: busy (projects_busy_refusal),
// the engine, inside it or holding it, the home of the user, the folder of the
// store, or no project. "" when it may.
@(private)
projects_remove_refusal :: proc(s:^Session,folder:string) -> string {
    if refusal:=projects_busy_refusal(s,folder);refusal!="" {return refusal}
    within :: proc(inner,outer:string) -> bool {
        if inner=="" || outer=="" {return false}
        return project.path_same(inner,outer) || (len(inner)>len(outer) && (inner[len(outer)]=='/' || inner[len(outer)]=='\\') && project.path_same(inner[:len(outer)],outer))
    }
    engine:=s.engine_root!="" ? project.path_absolute(s.engine_root,context.temp_allocator) : ""
    if within(engine,folder) {return "This folder holds the engine: it is not removed from here"}
    if within(folder,engine) {return "This project is part of the engine's repository: it is not removed from here"}
    if home,e:=os.user_home_dir(context.temp_allocator);e==nil && within(home,folder) {return "This folder is the home of the user"}
    if s.store.root!="" && within(project.path_absolute(s.store.root,context.temp_allocator),folder) {return "This folder holds the Kai store of this machine"}
    if !os.is_file(project.path(folder,project.PROJECT_FILE,allocator=context.temp_allocator)) && !ka.project_exists(folder) {return fmt.tprintf("%s is not a Mirai project: it has no %s",folder,project.PROJECT_FILE)}
    return ""
}

// Removes what the builds of the project at folder left (build.cache_clean),
// its Kai workspace and its files staying: "" or why not.
projects_cache_clean :: proc(s:^Session,folder:string) -> string {
    absolute:=project.path_absolute(folder,context.temp_allocator)
    if refusal:=projects_busy_refusal(s,absolute);refusal!="" {return refusal}
    if _,e:=build.cache_clean(absolute);e!=nil {return fmt.tprintf("The build cache of %s could not be removed: %v",absolute,e)}
    return ""
}

// The opening that failed has its errors cleared and starts again.
@(private)
projects_retry :: proc(s:^Session,folder:string) {
    p:=s.projects
    p.error_length,p.failed_opening[0],p.error_packages_dirty=0,0,false
    if message:=projects_open(s,folder);message!="" {notify(s,message)}
}

// Restores the pins of the packages of the project whose opening failed
// (ka.packages_restore) and opens it again.
projects_retry_packages :: proc(s:^Session) {
    p:=s.projects
    folder:=strings.clone(base.text_get(p.failed_opening[:]),context.temp_allocator)
    if _,e:=ka.project_packages_restore(&s.store,folder,kai_types(s));e!=.None {
        notify(s,fmt.tprintf("Kai could not restore the package pins of %s: %s",folder,vcs.error_text(e)))
        return
    }
    projects_retry(s,folder)
}

// Cleans the build cache of the project whose opening failed and opens it again.
projects_retry_clean :: proc(s:^Session) {
    p:=s.projects
    folder:=strings.clone(base.text_get(p.failed_opening[:]),context.temp_allocator)
    if message:=projects_cache_clean(s,folder);message!="" {
        notify(s,message)
        return
    }
    projects_retry(s,folder)
}

// Asks to confirm the removal of the local copy at folder; a Kai workspace is
// snapshotted first, so the confirmation says what no org has of it.
projects_remove_ask :: proc(s:^Session,folder:string) {
    p:=s.projects
    absolute:=project.path_absolute(folder,context.temp_allocator)
    if refusal:=projects_remove_refusal(s,absolute);refusal!="" {
        notify(s,refusal)
        return
    }
    p.removing_kai,p.removing_unpublished=false,false
    if ka.project_exists(absolute) {
        aside,why,ok:=projects_set_aside(s,absolute)
        if !ok {
            notify(s,why)
            return
        }
        p.removing_kai,p.removing_unpublished=true,aside.unpublished
    }
    base.text_set(p.removing[:],absolute)
}

// Snapshots the Kai workspace at folder (ka.project_set_aside): why not when ok is false.
@(private)
projects_set_aside :: proc(s:^Session,folder:string) -> (aside:ka.Set_Aside,why:string,ok:bool) {
    if s.store.root=="" {return {},"This project is a Kai workspace and the editor has no store to snapshot it in: it stays",false}
    t,_:=kai_team_of(s)
    e:vcs.Error
    aside,e=ka.project_set_aside(&s.store,t,folder,kai_types(s))
    if e!=.None {
        reason:=vcs.error_text(e)
        if t!=nil && t.why!="" {reason=t.why}
        return aside,fmt.tprintf("Kai could not snapshot %s, so it stays: %s",folder,reason),false
    }
    return aside,"",true
}

// Moves the local copy at folder to the Trash after a snapshot keeps its
// working copy in the store, drops the link of a last workspace to its org's
// repository, so All projects offers to pull it again, and removes it from
// the recent projects: "" or why nothing was removed.
projects_remove_local :: proc(s:^Session,folder:string) -> string {
    p:=s.projects
    absolute:=project.path_absolute(folder,context.temp_allocator)
    if refusal:=projects_remove_refusal(s,absolute);refusal!="" {return refusal}
    aside:ka.Set_Aside
    kai:=ka.project_exists(absolute)
    if kai {
        why:string
        ok:bool
        if aside,why,ok=projects_set_aside(s,absolute);!ok {return why}
    }
    if !platform.trash(absolute) {return fmt.tprintf("%s could not be moved to the Trash: nothing was removed",absolute)}
    if kai && aside.linked && aside.alone {
        if t,_:=kai_team_of(s);t!=nil {
            if e:=vcs.team_unlink(t,aside.repo);e!=.None {notify(s,fmt.tprintf("Kai: %s",t.why!=""?t.why:vcs.error_text(e)))}
        }
    }
    for i:=project.recent_count(&p.recent)-1;i>=0;i-=1 {
        if project.path_same(base.text_get(p.recent.projects[i].path[:]),absolute) {project.recent_remove(&p.recent,i)}
    }
    projects_recent_save(s)
    if project.path_same(base.text_get(p.removing[:]),absolute) {p.removing[0]=0}
    if project.path_same(base.text_get(p.failed_opening[:]),absolute) {p.error_length,p.failed_opening[0],p.error_packages_dirty=0,0,false}
    if s.kai!=nil && s.kai.team!=nil {kai_team_read(s)}
    projects_rows_read(s)
    return ""
}

@(private)
projects_menu_id :: proc(s:^Session) -> ui.Id {return shell_id(s.gui,"projects_row_menu")}

// Opens the right-click menu of the row of folder at the pointer.
@(private)
projects_menu_open :: proc(s:^Session,folder:string) {
    ctx:=s.gui.ctx
    base.text_set(s.projects.menu[:],folder)
    ui.popup_open(ctx,projects_menu_id(s),{ctx.pointer.x,ctx.pointer.y,0,0})
}

// The right-click menu of a row: Open, Update from main, Clean build cache and
// Remove local copy, or Remove from list for a folder that is gone.
projects_row_menu :: proc(s:^Session) {
    p:=s.projects
    ctx:=s.gui.ctx
    popup:=projects_menu_id(s)
    if !ui.popup_is_open(ctx,popup) {return}
    index:=-1
    for i in 0..<p.row_count {
        if project.path_same(base.text_get(p.rows[i].path[:]),base.text_get(p.menu[:])) {index=i}
    }
    if index<0 {
        ui.popup_close(ctx,popup)
        return
    }
    busy:=projects_opening(p) || p.next
    row:=p.rows[index]
    folder:=strings.clone(base.text_get(row.path[:]),context.temp_allocator)
    if ui.popup(ctx,popup,{min_width=200}) {
        ui.id_push(ctx,popup)
        defer ui.id_pop(ctx)
        if !row.missing && ui.menu_item(ctx,ui.id(ctx,"open"),"Open",{icon=.Play,disabled=busy}) {
            if message:=projects_open(s,folder);message!="" {notify(s,message)}
        }
        if row.behind_main && row.main_here && ui.menu_item(ctx,ui.id(ctx,"update"),"Update from main",{icon=ui.icon_user(u8(User_Icon.Down)),disabled=busy}) {projects_update(s,folder)}
        if !row.missing && ui.menu_item(ctx,ui.id(ctx,"clean"),"Clean build cache",{icon=.Refresh,disabled=busy}) {
            if message:=projects_cache_clean(s,folder);message!="" {notify(s,message)} else {notify(s,fmt.tprintf("The build cache of %s was removed: its next opening builds it again",base.text_get(row.name[:])))}
        }
        ui.menu_separator(ctx)
        if row.missing {
            if row.recent_index>=0 && ui.menu_item(ctx,ui.id(ctx,"forget"),"Remove from list",{icon=.Cross,danger=true}) {
                project.recent_remove(&p.recent,row.recent_index)
                projects_recent_save(s)
                projects_rows_read(s)
            }
        } else if ui.menu_item(ctx,ui.id(ctx,"remove"),"Remove local copy",{icon=ui.icon_user(u8(User_Icon.Trash)),danger=true,disabled=busy}) {projects_remove_ask(s,folder)}
    }
}

// The confirmation of Remove local copy: the folder, what Kai kept of it and
// what no org has.
projects_remove_build :: proc(s:^Session) {
    p:=s.projects
    g:=s.gui
    ctx:=g.ctx
    folder:=base.text_get(p.removing[:])
    if folder=="" {return}
    closed:=false
    defer if closed {p.removing[0]=0}
    if ui.modal(ctx,shell_id(g,"projects_remove"),{width=440,padding=16,gap=12,close=&closed}) {
        name:=filepath.base(folder)
        ui.label(ctx,fmt.tprintf("Remove the local copy of %s?",name),ui.metric(ctx,"font_heading"),ui.tone(ctx,"text"),0,font=ui.FONT_SEMIBOLD)
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=8,padding={8,6,8,6},align_y=.Center,fill=ui.tone(ctx,"well"),radius=6}) {
            ui.icon(ctx,ui.icon_user(u8(User_Icon.Folder)),ui.tone(ctx,"text_muted"),14)
            ui.text(ctx,folder,ui.prose(ctx,ui.metric(ctx,"font_small"),ui.tone(ctx,"text")))
        }
        prose:=ui.prose(ctx,ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"))
        what:="The folder moves to the Trash and leaves this list."
        if p.removing_kai {what="Kai snapshotted its working copy into this machine's store. The folder moves to the Trash and leaves this list."}
        ui.text(ctx,what,prose)
        if p.removing_unpublished {
            if ui.box(ctx,{width=ui.GROW,height=ui.FIT,padding={8,6,8,6},fill=ui.tone(ctx,"danger_surface"),stroke=ui.tone(ctx,"danger_stroke"),stroke_width=1,radius=6}) {
                ui.text(ctx,"Unpublished changes or commits exist. They have been snapshotted to your local store, but deleting this folder removes the working copy from disk. Publish first or confirm removal.",ui.prose(ctx,ui.metric(ctx,"font_small"),ui.tone(ctx,"text_body")))
            }
        }
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"control")),gap=8,align_x=.End,align_y=.Center}) {
            if ui.button(ctx,shell_id(g,"projects_remove_cancel"),{label="Cancel",variant="field",width=90,height=ui.metric(ctx,"control"),center=true}).clicked {closed=true}
            if ui.button(ctx,shell_id(g,"projects_remove_confirm"),{label="Remove local copy",variant="danger",height=ui.metric(ctx,"control"),center=true}).clicked {
                there:=strings.clone(folder,context.temp_allocator)
                p.removing[0]=0
                if message:=projects_remove_local(s,there);message!="" {notify(s,message)} else {notify(s,fmt.tprintf("%s moved to the Trash",filepath.base(there)))}
            }
        }
    }
}
