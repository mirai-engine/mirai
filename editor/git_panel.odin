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
// repository shows its branch, the changes to commit and the last commits; a
// merge with conflicts shows them (git_merge.odin).

GIT_HISTORY_DEFAULT :: 120
GIT_HISTORY_MIN :: 48
GIT_EDGE :: 7 // the band over the history that resizes it
GIT_DISCARD_ROWS :: 6 // files the question to discard lists; the rest is a count

Git_Source :: struct {extension:string,kind:asset.Fourcc}
GIT_SOURCES :: [?]Git_Source{
    {"wav",asset.KIND_SOUND},{"ogg",asset.KIND_SOUND},{"mp3",asset.KIND_SOUND},
    {"png",asset.KIND_TEXTURE},{"jpg",asset.KIND_TEXTURE},{"jpeg",asset.KIND_TEXTURE},{"tga",asset.KIND_TEXTURE},
    {"exr",asset.KIND_TEXTURE},{"hdr",asset.KIND_TEXTURE},{"psd",asset.KIND_TEXTURE},
    {"glb",SHOWN_PREFAB},{"gltf",SHOWN_PREFAB},{"obj",SHOWN_PREFAB},{"fbx",SHOWN_PREFAB},{"usd",SHOWN_PREFAB},{"usdz",SHOWN_PREFAB},
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
            if message:=git.push(s.git,s.app.platform,git_roots(s));message!="" {notify(s,message)}
        }
    }
    if documents_dirty(s) || len(assets_unsaved(s))>0 {
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"control")),gap=8,align_y=.Center,padding=ui.padding_xy(8,0),fill=ui.tone(ctx,"card"),radius=ui.metric(ctx,"radius_control")}) {
            if ui.box(ctx,{width=ui.fixed(6),height=ui.fixed(6),fill=UNSAVED_COLOR,radius=3}) {}
            ui.label(ctx,"Unsaved changes",ui.metric(ctx,"font_small"),ui.tone(ctx,"text"))
            ui.spacer(ctx)
            if ui.button(ctx,ui.id(ctx,"git_save"),{label="Save all",variant="field",height=ui.metric(ctx,"control")-6}).clicked {command_run(s,"save_all")}
        }
    }
    // Discarding all of them shows while the pointer is on their head.
    header,list:=ui.id(ctx,"git_changes_head"),ui.id(ctx,"git_changes")
    _=ui.interact(ctx,header,{.Passive})
    on_changes:=ai_pointer_on(ctx,header)
    if ui.box(ctx,{id=header,width=ui.GROW,height=ui.fixed(22),gap=4,align_y=.Center,padding={0,0,12,0}}) {
        ui.label(ctx,"CHANGES",ui.metric(ctx,"font_caption"),ui.tone(ctx,"text_caption"))
        ui.spacer(ctx)
        if on_changes && len(g.changes)>0 && ui.button(ctx,ui.id(ctx,"git_discard_all"),{icon=.Revert,tip="Discard all changes",icon_color=ui.tone(ctx,"text_muted"),variant="ghost",width=18,height=18,icon_size=12,disabled=busy || g.merging}).clicked {git_discard_ask(s,"")}
        count:[16]u8
        ui.label(ctx,fmt.bprintf(count[:],"%d",len(g.changes)),ui.metric(ctx,"font_small"),ui.tone(ctx,"text_faint"))
    }
    // The changes take what the message, the buttons and the history leave.
    history:=len(g.history)>0
    l:=&s.gui.layout
    history_height:=l.git_history>0?l.git_history:GIT_HISTORY_DEFAULT
    if ui.scroll_area(ctx,list,&g.scroll,{width=ui.GROW,height=ui.GROW,gap=1}) {
        registry:=files_registry(s)
        for &change,i in g.changes {
            ui.id_push(ctx,ui.id(ctx,"change",i))
            row:=ui.id(ctx,"row")
            _=ui.interact(ctx,row,{.Passive})
            if ui.box(ctx,{id=row,width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=8,align_y=.Center,padding={4,0,12,0},fill=ai_pointer_on(ctx,row)?ui.tone(ctx,"chip"):{},radius=ui.metric(ctx,"radius_control")}) {
                included:=!change.left_out
                if ui.checkbox(ctx,ui.id(ctx,"include"),&included,busy) {change.left_out=!included}
                path:=git.change_path(g,&change)
                slash:=strings.last_index_byte(path,'/')
                icon,color:=git_change_icon(s,registry,path)
                ui.icon(ctx,icon,color,14)
                if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=8,align_y=.Center,clip_x=true}) {
                    ui.label(ctx,path[slash+1:],ui.metric(ctx,"font_small"),ui.tone(ctx,"text"))
                    if slash>0 {ui.label(ctx,path[:slash],ui.metric(ctx,"font_small"),ui.tone(ctx,"text_faint"),0)}
                }
                // Putting this one back shows while the pointer is on its row.
                if change.status!='U' && ai_pointer_on(ctx,row) && ui.button(ctx,ui.id(ctx,"discard"),{icon=.Revert,tip="Discard changes",icon_color=ui.tone(ctx,"text_muted"),variant="ghost",width=18,height=18,icon_size=12,disabled=busy}).clicked {git_discard_ask(s,base.text_get(change.path[:]))}
                letter:=[1]u8{change.status}
                status:=ui.tone(ctx,"text_muted")
                switch change.status {
                case 'A': status=ui.tone(ctx,"success")
                case 'D','U': status=ui.tone(ctx,"danger")
                }
                ui.label(ctx,string(letter[:]),ui.metric(ctx,"font_small"),status)
            }
            ui.id_pop(ctx)
        }
    }
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

// The icon of a changed file with the color of its kind, as the browser has them.
@(private)
git_change_icon :: proc(s:^Session,registry:^asset.Registry,path:string) -> (icon:ui.Icon,color:ui.Color) {
    relative:=strings.trim_prefix(path,"assets/")
    if registry!=nil && relative!=path {
        if file,found:=asset.registry_find_path(registry,relative);found && file.state==.Asset {
            icon,_=asset_icon(s,shown_kind(file))
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

// Asks before discarding: what goes back to the last commit cannot come back.
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
            if change.status!='U' && (path=="" || base.text_get(change.path[:])==path) {append(&files,&change)}
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
                paths:=[1]string{path}
                if message:=git_discard(s,path!=""?paths[:]:nil);message!="" {notify(s,message)}
            }
        }
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
    case .Push: doing="Pushing..."
    case .Pull: doing="Pulling..."
    case .Abort: doing="Aborting the merge..."
    case .Finish: doing="Finishing the merge..."
    }
    if doing!="" {ui.label(ctx,doing,ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"));return}
    if failure:=base.text_get(g.error[:]);failure!="" {ui.text(ctx,failure,ui.prose(ctx,ui.metric(ctx,"font_small"),ui.tone(ctx,"danger")))}
}
