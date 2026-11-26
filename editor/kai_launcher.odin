package editor

import "core:fmt"
import "core:os"
import "core:strings"
import "mirai:platform"
import "mirai:project"
import "mirai:std/base"
import "mirai:ui"

// The Repositories of the projects screen: the repositories of the orgs this
// machine is in, each pulled into a folder with one click (kai.clone) and
// opened, with how far its pull is in chunks and bytes as the agent counts
// them. Team and pairing shows the Kai tab's Team view, so a machine with no
// project names itself, joins its org with an invite or makes one from here.
// The team opens the first time the view shows.

REPOSITORIES_BUTTONS :: 260 // of the row of the location: its icon, Change and Team and pairing

// The Repositories view, in place of the list of projects.
projects_repositories_build :: proc(s:^Session,width:f32) {
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
        // The folder fades past the room the buttons leave.
        text:=fmt.tprintf("Pulls go to %s",projects_path_shown(p,location))
        size:=ui.metric(ctx,"font_small")
        ui.label(ctx,text,size,ui.tone(ctx,"text_muted"),min(ui.text_width(&ctx.font,text,size)+2,max(width-REPOSITORIES_BUTTONS,40)),fade=true)
        if ui.button(ctx,ui.id(ctx,"repositories_location"),{label="Change",variant="ghost",height=24,size=ui.metric(ctx,"font_small"),disabled=busy}).clicked {
            if !platform.dialog_show(s.app.platform,{kind=.Open_Folder,tag=DIALOG_PROJECT_LOCATION}) {notify(s,"A file dialog is already open")}
        }
        ui.spacer(ctx)
        if ui.button(ctx,ui.id(ctx,"repositories_team"),{label="Team and pairing",icon=ui.icon_user(u8(User_Icon.Users)),variant="toggle",active=p.team,height=28}).clicked {p.team=!p.team}
    }
    if ui.scroll_area(ctx,ui.id(ctx,"repositories_list"),&p.scroll,{width=ui.GROW,height=ui.GROW,direction=.Column,gap=2}) {
        switch {
        case p.team || !t.opened || t.team.name=="":
            if t.opened && t.team.name=="" {kai_line(ctx,"Name yourself and this machine, then join your org with an invite from one of its machines, or make an org, to see its repositories here.","text")}
            kai_team_build(s)
        case:
            projects_repositories_rows(s,busy)
        }
    }
}

// The rows of the repositories, or what to do while there are none.
@(private="file")
projects_repositories_rows :: proc(s:^Session,busy:bool) {
    p:=s.projects
    ctx:=s.gui.ctx
    v:=&s.kai.team.view
    if len(v.repositories)==0 {
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,gap=6,padding={0,24,0,0},align_x=.Center}) {
            ui.label(ctx,"No repositories yet",ui.metric(ctx,"font"),ui.tone(ctx,"text_muted"),font=ui.FONT_SEMIBOLD)
            text:="Publish a project to main from the Kai tab of its editor, here or on another machine of your org."
            if len(v.orgs)==0 {text="Make an org, or join one with an invite from a member, in Team and pairing."}
            if ui.box(ctx,{width=ui.fixed(380),height=ui.FIT}) {
                style:=ui.prose(ctx,ui.metric(ctx,"font_small"),ui.tone(ctx,"text_faint"))
                style.align_x=.Center
                ui.text(ctx,text,style)
            }
        }
        return
    }
    needle:=strings.to_lower(strings.trim_space(string(p.search[:p.search_length])),context.temp_allocator)
    for &r,i in v.repositories {
        o:=&v.orgs[r.org]
        x:=&o.repos[r.repo]
        if needle!="" && !strings.contains(strings.to_lower(x.name,context.temp_allocator),needle) && !strings.contains(strings.to_lower(o.name,context.temp_allocator),needle) {continue}
        ui.id_push(ctx,ui.id(ctx,"repository",i))
        projects_repository_row(s,&r,busy)
        ui.id_pop(ctx)
    }
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
                what=fmt.tprintf("%s, %s: %d chunks, %s pulled",o.name,kind,chunks,base.bytes_text(bytes))
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

// How many repositories the tab counts: those the team read last, once it opened.
projects_repositories_count :: proc(s:^Session) -> int {
    if s.kai==nil || s.kai.team==nil {return 0}
    return len(s.kai.team.view.repositories)
}
