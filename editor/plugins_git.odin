package editor

import "core:fmt"
import "core:log"
import "core:strings"
import "mirai:cook/install"
import "mirai:project"
import "mirai:std/base"
import "mirai:ui"

// Plugins that come from git (cook/install) in the Plugins of the settings:
// those of the project with their update and removal, the address of a
// repository to add one, and the catalog. What git does runs on a thread of
// its own; once a plugin of the project changed, the project builds again
// and the editor starts on the new one, as when a plugin is switched on.

Plugins_Git :: struct {
    job:^install.Job,
    doing:[128]u8,             // what the job does, as the dialog says it
    url:[256]u8,
    url_length:int,
    catalog:^project.Catalog,  // as its checkout on this machine has it; nil until read
    catalog_folder:[project.RECENT_PATH]u8, // of the checkout
    catalog_icons:[project.MAX_CATALOG]Plugin_Icon,
    catalog_message:[160]u8,   // why there is none
    catalog_asked:bool,        // a refresh of the catalog started in this editor
}

plugins_git_busy :: proc(s:^Session) -> bool {return s.plugins_git.job!=nil}

// Starts steps on the project of the editor. False when others still run.
@(private)
plugins_git_start :: proc(s:^Session,steps:[]install.Step,doing:string) -> bool {
    pg:=&s.plugins_git
    if pg.job!=nil {
        notify(s,"Wait for the plugins being installed")
        return false
    }
    base.text_set(pg.doing[:],doing)
    pg.job=install.job_start(s.project_root,s.engine_root,steps)
    return true
}

// Follows the job between frames.
plugins_git_poll :: proc(s:^Session) {
    pg:=&s.plugins_git
    if pg.job==nil || !install.job_poll(pg.job) {return}
    job:=pg.job
    pg.job=nil
    defer install.job_destroy(job)
    catalog:=false
    for step in job.steps {catalog|=step.kind==.Catalog}
    if catalog {plugins_git_catalog_read(s)}
    if job.message!="" {
        if job.ok {log.info(job.message)} else {log.error(job.message)}
    }
    first:=job.message
    if newline:=strings.index_byte(first,'\n');newline>=0 {first=first[:newline]}
    if !job.ok {
        notify(s,first)
    } else if !catalog || job.changed {
        if first!="" {notify(s,first)}
    }
    if !job.changed || !s.has_project {return}
    // The settings dialog writes its whole copy of project.mirai: it takes the plugins and sources the job wrote.
    if p:=&s.settings_project;p.loaded {
        if written,error:=project.manifest_read(project.path(s.project_root,project.PROJECT_FILE,allocator=context.temp_allocator));error.code==.None {
            copy(p.manifest.plugins[:],written.plugins[:])
            copy(p.manifest.sources[:],written.sources[:])
            p.written=written
        }
    }
    settings_plugins_load(s)
    if build_start(s) {notify(s,fmt.tprintf("%s; building the project",first))}
}

// The catalog as its checkout on this machine has it; the first time it is
// asked for, a refresh of the checkout starts.
@(private)
plugins_git_catalog :: proc(s:^Session) -> ^project.Catalog {
    pg:=&s.plugins_git
    if pg.catalog==nil {plugins_git_catalog_read(s)}
    if !pg.catalog_asked && pg.job==nil && s.engine_root!="" {
        pg.catalog_asked=true
        base.text_set(pg.doing[:],"Fetching the catalog")
        pg.job=install.job_start(s.project_root,s.engine_root,[]install.Step{{kind=.Catalog}})
    }
    return pg.catalog
}

@(private)
plugins_git_catalog_read :: proc(s:^Session) {
    pg:=&s.plugins_git
    if pg.catalog==nil {pg.catalog=new(project.Catalog)}
    base.text_set(pg.catalog_message[:],install.catalog_load(s.engine_root,pg.catalog))
    base.text_set(pg.catalog_folder[:],s.engine_root=="" ? "" : install.catalog_folder(s.engine_root,context.temp_allocator))
    pg.catalog_icons={}
    plugins_git_catalog_updates(s)
}

// Which plugins of the catalog it lists at a commit their checkout does not
// have: not one they were moved past with a ref.
@(private)
plugins_git_catalog_updates :: proc(s:^Session) {
    list:=&s.settings_plugins
    catalog:=s.plugins_git.catalog
    for i in 0..<list.count {
        list.catalog_update[i]=false
        if !list.source_catalog[i] || catalog==nil {continue}
        name:=base.text_get(list.names[i][:])
        if entry:=project.catalog_find(catalog,name);entry!=nil && entry.commit!=list.source_commit[i] {
            list.catalog_update[i]=!install.has_commit(s.project_root,name,base.text_get(entry.commit[:]))
        }
    }
}

plugins_git_free :: proc(s:^Session) {
    pg:=&s.plugins_git
    install.job_destroy(pg.job)
    free(pg.catalog)
    pg^={}
}

// The row of a plugin from git besides its switch: update and remove. One of
// the catalog updates only when the catalog lists another commit.
@(private)
plugins_git_row_actions :: proc(s:^Session,index:int) {
    list:=&s.settings_plugins
    name:=base.text_get(list.names[index][:])
    if list.source_catalog[index] && s.plugins_git.catalog==nil {plugins_git_catalog_read(s)}
    available:=!list.source_catalog[index] || list.catalog_update[index]
    ctx:=s.gui.ctx
    ui.id_push(ctx,ui.id(ctx,fmt.tprintf("git %s",name)))
    defer ui.id_pop(ctx)
    busy:=plugins_git_busy(s) || s.build.phase==.Running
    if available && ui.button(ctx,ui.id(ctx,"git_update"),{label=list.source_catalog[index]?"Update available":"Update",variant="ghost",height=20,size=ui.metric(ctx,"font_label"),disabled=busy}).clicked {
        plugins_git_start(s,[]install.Step{{kind=.Update,text=name}},fmt.tprintf("Updating %s",name))
    }
    if ui.button(ctx,ui.id(ctx,"git_remove"),{label="Remove",variant="ghost",height=20,size=ui.metric(ctx,"font_label"),disabled=busy}).clicked {
        plugins_git_start(s,[]install.Step{{kind=.Remove,text=name}},fmt.tprintf("Removing %s",name))
    }
}

@(private) PLUGINS_GIT_ADD_KEY :: u64(0x7067697461646400)
@(private) PLUGINS_GIT_CATALOG_KEY :: u64(0x7067697463617400)

// Under the plugins of the project: what the job does, the address of a
// repository to add, and the catalog, which is fetched once it is opened.
@(private)
settings_plugins_git :: proc(s:^Session) {
    ctx:=s.gui.ctx
    pg:=&s.plugins_git
    busy:=plugins_git_busy(s) || s.build.phase==.Running
    ui.id_push(ctx,ui.id(ctx,"plugins_git"))
    defer ui.id_pop(ctx)
    if pg.job!=nil {
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=8,align_y=.Center}) {
            pulse_dot(ctx,ui.tone(ctx,"accent"),true)
            ui.label(ctx,base.text_get(pg.doing[:]),ui.metric(ctx,"font_small"),ui.tone(ctx,"text"),0)
        }
    }
    if fold_section(s,ui.id(ctx,"add_fold"),PLUGINS_GIT_ADD_KEY,"Add from Git") {
        fold_band_begin(s)
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"control")),gap=6,align_y=.Center}) {
            ui.text_field(ctx,ui.id(ctx,"url"),pg.url[:],&pg.url_length,{placeholder="https://github.com/user/plugin.git",live=true,height=ui.metric(ctx,"control")})
            url:=strings.trim_space(string(pg.url[:pg.url_length]))
            if ui.button(ctx,ui.id(ctx,"add"),{label="Add",variant="field",height=ui.metric(ctx,"control"),disabled=busy || url==""}).clicked {
                if plugins_git_start(s,[]install.Step{{kind=.Add,text=url}},fmt.tprintf("Adding %s",url)) {pg.url_length=0}
            }
        }
        fold_band_end(s)
    }
    if !fold_section(s,ui.id(ctx,"catalog_fold"),PLUGINS_GIT_CATALOG_KEY,"Catalog",folded=true) {return}
    fold_band_begin(s)
    defer fold_band_end(s)
    catalog:=plugins_git_catalog(s)
    count:=catalog==nil?0:project.catalog_count(catalog)
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=6,align_y=.Center}) {
        message:=base.text_get(pg.catalog_message[:])
        switch {
        case message!="": ui.label(ctx,message,ui.metric(ctx,"font_small"),ui.tone(ctx,"text_faint"),0)
        case count==0:    ui.label(ctx,"The catalog has no plugins yet",ui.metric(ctx,"font_small"),ui.tone(ctx,"text_faint"),0)
        case:             ui.label(ctx,fmt.tprintf("%d %s",count,count==1?"plugin":"plugins"),ui.metric(ctx,"font_small"),ui.tone(ctx,"text_faint"),0)
        }
        ui.spacer(ctx)
        if ui.icon_button(ctx,ui.id(ctx,"refresh"),.Refresh,20,tip="Refresh",disabled=busy).clicked {
            plugins_git_start(s,[]install.Step{{kind=.Catalog}},"Fetching the catalog")
        }
    }
    for i in 0..<count {
        entry:=&catalog.plugins[i]
        name:=base.text_get(entry.name[:])
        installed:=false
        for k in 0..<s.settings_plugins.count {installed|=base.text_get(s.settings_plugins.names[k][:])==name}
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")+12),gap=8,align_y=.Center}) {
            plugin_icon_draw(s,&pg.catalog_icons[i],plugin_icon_catalog(s,name),20)
            if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,gap=2}) {
                ui.label(ctx,name,ui.metric(ctx,"font_small"),ui.tone(ctx,"text_label"),0)
                if description:=base.text_get(entry.description[:]);description!="" {ui.label(ctx,description,ui.metric(ctx,"font_label"),ui.tone(ctx,"text_faint"),0)}
            }
            if installed {
                ui.label(ctx,"Installed",ui.metric(ctx,"font_label"),ui.tone(ctx,"text_faint"))
            } else if ui.button(ctx,ui.id(ctx,"install",i),{label="Install",variant="field",height=22,size=ui.metric(ctx,"font_label"),disabled=busy}).clicked {
                plugins_git_start(s,[]install.Step{{kind=.Install,text=name}},fmt.tprintf("Installing %s",name))
            }
        }
    }
}
