package editor

import "core:fmt"
import "core:os"
import "core:strings"
import ka "mirai:cook/kai"
import vcs "mirai:kai"
import "mirai:platform"
import "mirai:project"
import "mirai:std/base"
import "mirai:ui"

// The org side of the projects screen. All projects lists, after the projects
// of this machine, the repositories of its orgs it has not pulled, each pulled
// into a folder of the location with one click (kai.clone) and opened, with
// how far its pull is in chunks and bytes as the agent counts them. Team and
// pairing shows the Kai tab's Team view in place of the list, so a machine
// with no project names itself, joins its org with an invite or makes one.

// Team, in place of the list: where pulls go, then the Team view.
projects_team_build :: proc(s:^Session,width:f32) {
    p:=s.projects
    ctx:=s.gui.ctx
    if s.kai==nil {return}
    kai_team_open(s)
    t:=s.kai.team
    if t==nil {return}
    t.width=width
    busy:=projects_opening(p) || p.next
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(28),gap=8,align_y=.Center}) {
        location:=strings.trim_space(string(p.location[:p.location_length]))
        ui.icon(ctx,ui.icon_user(u8(User_Icon.Folder)),ui.tone(ctx,"text_faint"),13)
        text:=fmt.tprintf("Pulls go to %s",projects_path_shown(p,location))
        size:=ui.metric(ctx,"font_small")
        ui.label(ctx,text,size,ui.tone(ctx,"text_muted"),min(ui.text_width(&ctx.font,text,size)+2,max(width-120,40)),fade=true)
        if ui.button(ctx,ui.id(ctx,"projects_location"),{label="Change",variant="ghost",height=24,size=ui.metric(ctx,"font_small"),disabled=busy}).clicked {
            if !platform.dialog_show(s.app.platform,{kind=.Open_Folder,tag=DIALOG_PROJECT_LOCATION}) {notify(s,"A file dialog is already open")}
        }
    }
    if ui.scroll_area(ctx,ui.id(ctx,"projects_team_view"),&p.scroll,{width=ui.GROW,height=ui.GROW,direction=.Column,gap=2}) {kai_team_build(s,true)}
}

// Publishes a local org-linked project to main directly from the Launcher.
kai_launcher_publish :: proc(s:^Session,folder:string) {
    t,message:=kai_team_of(s)
    if t==nil {
        notify(s,message)
        return
    }
    change,e:=ka.project_publish_folder(&s.store,t,folder,kai_types(s))
    if e!=.None {
        notify(s,fmt.tprintf("Kai: %s",t.why!=""?t.why:vcs.error_text(e)))
        return
    }
    kai_team_wrote(s)
    if p:=s.projects;p!=nil && p.shown {projects_rows_read(s)}
    notify(s,fmt.tprintf("Published %s to %s",change[:min(len(change),8)],ka.BOOKMARK_DEFAULT))
}

// The repositories of the orgs this machine has not pulled, under the
// projects of All projects; one pulling stays while it pulls.
projects_org_rows :: proc(s:^Session,busy:bool,needle:string) {
    if s.kai==nil || s.kai.team==nil {return}
    ctx:=s.gui.ctx
    t:=s.kai.team
    head:=false
    for &r,i in t.view.repositories {
        o:=&t.view.orgs[r.org]
        x:=&o.repos[r.repo]
        if !projects_unpulled(t,o,x) {continue}
        if needle!="" && !strings.contains(strings.to_lower(x.name,context.temp_allocator),needle) && !strings.contains(strings.to_lower(o.name,context.temp_allocator),needle) {continue}
        if !head {
            head=true
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(28),align_y=.End,padding={4,0,0,4}}) {
                ui.label(ctx,"FROM YOUR ORGS, NOT ON THIS MACHINE",ui.metric(ctx,"font_caption"),ui.tone(ctx,"text_caption"),font=ui.FONT_SEMIBOLD)
            }
        }
        ui.id_push(ctx,ui.id(ctx,"repository",i))
        projects_repository_row(s,&r,busy)
        ui.id_pop(ctx)
    }
}

// Whether a repository of an org is not on this machine: no workspace of it, or one being pulled.
@(private="file")
projects_unpulled :: proc(t:^Kai_Team,o:^ka.Org_View,x:^ka.Repo_View) -> bool {
    pulling:=t.clone.stage!=.None && t.clone.org==o.id && t.clone.repo==x.id
    return !x.linked || pulling
}

// How many repositories of the orgs this machine has not pulled.
projects_unpulled_count :: proc(s:^Session) -> int {
    if s.kai==nil || s.kai.team==nil {return 0}
    t:=s.kai.team
    n:=0
    for r in t.view.repositories {
        o:=&t.view.orgs[r.org]
        if projects_unpulled(t,o,&o.repos[r.repo]) {n+=1}
    }
    return n
}

// A repository: its tile, name and org, what main is, and Pull, or how its
// pull goes.
@(private="file")
projects_repository_row :: proc(s:^Session,r:^Kai_Repository,busy:bool) {
    ctx:=s.gui.ctx
    t:=s.kai.team
    o:=&t.view.orgs[r.org]
    x:=&o.repos[r.repo]
    c:=&t.clone
    pulling:=c.stage!=.None && c.org==o.id && c.repo==x.id
    folder:=kai_clone_folder(s,x.name)
    pulled:=folder!="" && os.is_file(project.path(folder,project.PROJECT_FILE,allocator=context.temp_allocator))
    fill,stroke:ui.Color
    if pulling {fill,stroke=ui.tone(ctx,"accent_soft"),ui.tone(ctx,"accent")}
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(PROJECTS_ROW),gap=12,padding={10,0,10,0},align_y=.Center,fill=fill,stroke=stroke,stroke_width=1,radius=8}) {
        projects_tile(ctx,x.name,PROJECTS_TILE,false)
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,gap=3}) {
            ui.label(ctx,x.name,ui.metric(ctx,"font"),ui.tone(ctx,"text"),0,font=ui.FONT_SEMIBOLD)
            kind:=x.public?"public":"org only"
            what:=""
            switch {
            case pulling && c.stage==.Failed: what=string(c.why[:c.why_length])
            case pulling && c.stage==.Waiting:
                chunks,bytes:=kai_clone_progress(t)
                if x.has_size && x.bytes>0 {
                    what=fmt.tprintf("%s, %s: %s / %s pulled",o.name,kind,base.bytes_text(bytes),base.bytes_text(x.bytes))
                } else {
                    what=fmt.tprintf("%s, %s: %d chunks, %s pulled",o.name,kind,chunks,base.bytes_text(bytes))
                }
            case !x.published: what=fmt.tprintf("%s, %s: nobody published it yet",o.name,kind)
            case x.main=="": what=fmt.tprintf("%s, %s: main is published, Pull takes it",o.name,kind)
            case !x.here && !x.linked: what=fmt.tprintf("%s, %s: main %s",o.name,kind,x.main)
            case !x.here: what=fmt.tprintf("%s, %s: main %s is on its way from your org's machines",o.name,kind,x.main)
            case: what=fmt.tprintf("%s, %s: main %s",o.name,kind,x.main)
            }
            ui.label(ctx,what,ui.metric(ctx,"font_small"),pulling && c.stage==.Failed?ui.tone(ctx,"danger"):ui.tone(ctx,"text_faint"),0,fade=true)
        }
        if pulling && c.stage==.Waiting {
            pulse_dot(ctx,MARK_ARM,true)
            ui.label(ctx,len(t.view.peers)>0?"Pulling":"Waiting for your org's machines",ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"))
            if ui.button(ctx,ui.id(ctx,"repository_cancel"),{label="Cancel",variant="field",height=28,size=ui.metric(ctx,"font_small")}).clicked {kai_ask(s,"kai.clone",`{"cancel":true}`)}
            return
        }
        if pulling && c.stage==.Failed && ui.button(ctx,ui.id(ctx,"repository_dismiss"),{label="Dismiss",variant="ghost",height=28,size=ui.metric(ctx,"font_small")}).clicked {kai_ask(s,"kai.clone",`{"cancel":true}`)}
        if x.has_size {
            if ui.box(ctx,{width=ui.fixed(64),height=ui.FIT,align_x=.End}) {
                ui.label(ctx,base.bytes_text(x.bytes),ui.metric(ctx,"font_small"),ui.tone(ctx,"text_faint"))
            }
        }
        another:=c.stage==.Waiting && !pulling // one pull at a time
        if ui.button(ctx,ui.id(ctx,"repository_pull"),{label=pulled?"Open":"Pull",variant="accent",width=72,height=30,center=true,disabled=busy || another || !x.published}).clicked {
            if pulled {
                if message:=projects_open(s,folder);message!="" {notify(s,message)}
            } else {
                kai_ask(s,"kai.clone",`{{"org":%s,"repository":%s,"folder":%s}}`,kai_quote(org_hex(o.id)),kai_quote(x.name),kai_quote(folder))
            }
        }
    }
}
