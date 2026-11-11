package editor

import "core:fmt"
import "core:hash"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "core:time/datetime"
import "core:time/timezone"
import "core:unicode/utf8"
import "mirai:asset"
import "mirai:cook/build"
import "mirai:cook/install"
import "mirai:cook/textures"
import "mirai:platform"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:std/subprocess"
import "mirai:editor/kit"
import "mirai:ui"

// The projects of this machine (project.Recent_Projects) on a screen that
// covers the editor, to choose one or create one. A launcher (--launcher,
// what mirai edit opens without a project) is an editor of the empty
// template that shows only this screen. Opening a project builds its editor
// library in this process, as Build does, and starts the editor on it; an
// editor of a project asks about what is unsaved and ends as it starts it.
// Before the build, the plugins from git a new project was given are added
// and those of its project.mirai checked out (cook/install).

PROJECTS_TEMPLATES :: 8
PROJECTS_WINDOW :: [2]i32{880,560} // points of the launcher, which does not resize, and of the dialog over a project
PROJECTS_SIDEBAR :: 256
PROJECTS_ROW :: 56
PROJECTS_TILE :: 36
PROJECTS_TEMPLATE_CARD :: 60
PROJECTS_FADED :: 0.4 // opacity of what cannot be used while a project opens
@(private) DIALOG_PROJECT_FOLDER :: u32(0x4d50524f)
@(private) DIALOG_PROJECT_LOCATION :: u32(0x4d504c43)

// The fill and the letter of the tile of a project, chosen by its name.
PROJECTS_TILES :: [?][2]ui.Color{
    {{31,58,52,255},{127,212,187,255}},
    {{46,37,96,255},{185,166,255,255}},
    {{66,50,26,255},{240,190,110,255}},
    {{28,46,72,255},{130,180,250,255}},
    {{70,32,44,255},{245,150,170,255}},
    {{46,58,30,255},{180,215,130,255}},
}

PROJECTS_PLUGINS :: 64
PROJECTS_LINKS :: 8
PROJECTS_PLUGINS_WIDTH :: 268

// A plugin of the engine or of the template a new project can get: none of
// the automatic ones, which come with their dependencies.
Projects_Plugin :: struct {
    name:project.Name,
    on:bool,    // project.mirai of the new project names it
    needs:bit_set[0..<PROJECTS_PLUGINS;u64], // the plugins of the list it brings: its dependencies and theirs
    icon_file:[project.RECENT_PATH]u8,
    icon:Plugin_Icon,
}

Projects_Row :: struct {
    name:[64]u8,
    branch:[64]u8,  // checked out in its repository; empty without one or detached
    repository:bool,
    missing:bool,   // the folder or its project.mirai is gone
    opened:[32]u8,  // when an editor last opened it, as the list says it
    thumbnail:u64,  // the key of the image its tile shows in the atlas of previews; 0: its letter
    thumbnail_slot:int,
}

@(storage)
Projects :: struct {
    shown:bool,     // the screen covers the editor: always in a launcher
    launcher:bool,  // this editor only chooses a project
    recent:project.Recent_Projects,
    rows:[project.RECENT_CAPACITY]Projects_Row, // of recent, read when the screen opens
    selected:int,   // the row chosen to open, from 1; 0: none
    engine_branch:[64]u8,           // checked out in the repository of the engine
    home:[project.RECENT_PATH]u8,   // of the user: the paths under it are shown from ~
    search:[64]u8,
    search_length:int,
    scroll:[2]f32,
    creating:bool,  // the dialog of a new project
    name:[64]u8,
    name_length:int,
    location:[project.RECENT_PATH]u8,
    location_length:int,
    templates:[PROJECTS_TEMPLATES][32]u8,
    template_count:int,
    template:int,
    git,lfs:bool,
    remote:[256]u8,
    remote_length:int,
    plugins:[PROJECTS_PLUGINS]Projects_Plugin, // of the engine and the template the new project can get
    plugin_count:int,
    picked:[project.MAX_CATALOG]bool,   // plugins of the catalog the new project gets
    links:[PROJECTS_LINKS]project.Url,  // repositories of plugins added by their address
    links_on:[PROJECTS_LINKS]bool,
    link_count:int,
    plugins_scroll:[2]f32,
    add_scroll:f32,                     // of the catalog in the popup of Add plugin
    // The project being opened: built here, then started.
    opening:[project.RECENT_PATH]u8,
    git_init:bool,  // the editor started on it makes its repository with git, lfs and remote
    install:^install.Job, // its plugins from git, before the build
    from_git:bool,        // this opening started with install: the dialog shows its step
    job:^build.Job,
    shaders:^build.Shaders_Job,
    built:^project.Project,
    error:[1024]u8,
    error_length:int,
    next:bool,      // built: this editor starts it when it ends
    started:subprocess.Process, // the editor started on it, which this process waits for once it closes
    starts:bool,
    starting:bool,  // the build starts once the dialog of the opening was drawn
    start_frame:u64,
}

// Shows the screen, with the list as the file of the engine has it now.
projects_show :: proc(s:^Session) {
    p:=s.projects
    if p==nil {return}
    p.shown,p.creating,p.scroll=true,false,0
    if error:=project.recent_read(s.engine_root,&p.recent);error.code!=.None {notify(s,settings_file_error_text(project.recent_file(s.engine_root,context.temp_allocator),error))}
    projects_rows_read(s)
    _,p.engine_branch=projects_branch(s.engine_root)
    home,_:=os.user_home_dir(context.temp_allocator)
    base.text_set(p.home[:],home)
    p.template_count=0
    for template in build.templates_list(s.engine_root,context.temp_allocator) {
        if p.template_count==PROJECTS_TEMPLATES {break}
        base.text_set(p.templates[p.template_count][:],template.name)
        p.template_count+=1
    }
}

projects_hide :: proc(s:^Session) {
    p:=s.projects
    if p==nil || p.launcher || projects_opening(p) {return}
    p.shown,p.creating=false,false
}

// What the screen says of each project and the image of its tile: read
// once, when it opens. No row stays selected.
@(private)
projects_rows_read :: proc(s:^Session) {
    p:=s.projects
    p.selected=0
    region,has_region:=timezone.region_load("local",context.temp_allocator)
    now:=time.now()
    images:=s.app!=nil && s.thumbnails!=nil && s.app.assets!=nil && s.app.assets.renderer!=nil
    level:=Thumbnail_Level.Large if images && f32(PROJECTS_TILE)*max(s.app.density,1)>THUMBNAIL_SIZE else .Small
    sides:=THUMBNAIL_SIDES
    for &row,i in p.rows {
        row={}
        if i>=project.recent_count(&p.recent) {continue}
        entry:=&p.recent.projects[i]
        folder:=base.text_get(entry.path[:])
        name:=folder[strings.last_index_byte(folder,'/')+1:]
        manifest,error:=project.manifest_read(project.path(folder,project.PROJECT_FILE,allocator=context.temp_allocator))
        row.missing=error.code!=.None && !os.is_file(project.path(folder,project.PROJECT_FILE,allocator=context.temp_allocator))
        if error.code==.None {
            if declared:=base.text_get(manifest.name[:]);declared!="" {name=declared}
            if images && projects_thumbnail_read(folder,&manifest,sides[level],&s.thumbnails.file,&s.thumbnails.image) {
                row.thumbnail=thumbnail_key(transmute([]u8)fmt.tprintf("project %s",folder))
                row.thumbnail_slot=thumbnail_image_put(s,row.thumbnail,level,s.thumbnails.image[:])
                if row.thumbnail_slot<0 {row.thumbnail=0}
            }
        }
        base.text_set(row.name[:],name)
        row.repository,row.branch=projects_branch(folder)
        base.text_set(row.opened[:],projects_when(entry.opened,now,region if has_region else nil))
    }
}

// The image of side pixels the tile of the project at folder shows, into
// image: the PNG its manifest names as its thumbnail, else the view an editor
// of it kept of its start scene in its thumbs folder. False for neither.
@(private)
projects_thumbnail_read :: proc(folder:string,m:^project.Manifest,side:int,file:^Thumbnail_File,image:^[dynamic]u8) -> bool {
    if thumbnail:=base.text_get(m.thumbnail[:]);thumbnail!="" {
        if bytes,read_error:=os.read_entire_file(project.path(folder,thumbnail,allocator=context.temp_allocator),context.temp_allocator);read_error==nil {
            if picture,error:=textures.image_decode(bytes,context.temp_allocator);error==.None && picture.width>0 && picture.height>0 {
                projects_cover(picture,side,image)
                return true
            }
        }
    }
    scene:=base.text_get(m.start_scene[:])
    if scene=="" {return false}
    head:[asset.HEADER_SIZE]u8
    bytes,_,error:=serial.file_read_head(project.path(folder,ASSETS_FOLDER,scene,allocator=context.temp_allocator),head[:])
    if error!=.None {return false}
    header,header_error:=asset.header_read(bytes)
    if header_error!=.None || header.kind!=asset.KIND_SCENE {return false}
    return thumbnail_load(thumbnail_folder_of(folder),header.id,side,THUMBNAIL_CAPTURED,file,image)
}

// The middle square of a picture, averaged to side pixels with its alpha premultiplied.
@(private)
projects_cover :: proc(picture:textures.Image,side:int,image:^[dynamic]u8) {
    resize(image,side*side*4)
    square:=min(picture.width,picture.height)
    left,top:=(picture.width-square)/2,(picture.height-square)/2
    span :: proc(at,side,square:int) -> (first,last:int) {return at*square/side,max((at+1)*square/side,at*square/side+1)}
    for y in 0..<side {
        y0,y1:=span(y,side,square)
        for x in 0..<side {
            x0,x1:=span(x,side,square)
            sum:[4]u32
            for py in top+y0..<top+y1 {
                for px in left+x0..<left+x1 {
                    pixel:=picture.pixels[(py*picture.width+px)*4:][:4]
                    alpha:=u32(pixel[3])
                    for channel in 0..<3 {sum[channel]+=u32(pixel[channel])*alpha/255}
                    sum[3]+=alpha
                }
            }
            count:=u32((y1-y0)*(x1-x0))
            for channel in 0..<4 {image[(y*side+x)*4+channel]=u8(sum[channel]/count)}
        }
    }
}

// The branch checked out in the repository a folder is in, read from its
// .git without running git: the project or a folder above it, as the demo
// inside the engine.
@(private)
projects_branch :: proc(folder:string) -> (repository:bool,branch:[64]u8) {
    git,holder:="",folder
    for {
        candidate:=project.path(holder,".git",allocator=context.temp_allocator)
        if os.exists(candidate) {git=candidate;break}
        slash:=strings.last_index_byte(holder,'/')
        if slash<=0 {break}
        holder=holder[:slash]
    }
    if git=="" {return}
    head:=project.path(git,"HEAD",allocator=context.temp_allocator)
    // A worktree: .git is a file that names its folder in the repository.
    if os.is_file(git) {
        data,error:=os.read_entire_file(git,context.temp_allocator)
        if error!=nil {return}
        text:=strings.trim_space(string(data))
        if !strings.has_prefix(text,"gitdir:") {return}
        dir:=strings.trim_space(text[len("gitdir:"):])
        if !os.is_absolute_path(dir) {dir=project.path(holder,dir,allocator=context.temp_allocator)}
        head=project.path(dir,"HEAD",allocator=context.temp_allocator)
    } else if !os.is_dir(git) {return}
    repository=true
    data,error:=os.read_entire_file(head,context.temp_allocator)
    if error!=nil {return}
    text:=strings.trim_space(string(data))
    if strings.has_prefix(text,"ref: refs/heads/") {base.text_set(branch[:],text[len("ref: refs/heads/"):])}
    return
}

// "Today 14:20", "Yesterday", "Oct 12", or with the year when it is another.
@(private)
projects_when :: proc(opened:i64,now:time.Time,region:^datetime.TZ_Region) -> string {
    if opened<=0 {return ""}
    local :: proc(t:time.Time,region:^datetime.TZ_Region) -> datetime.DateTime {
        moment,_:=time.time_to_datetime(t)
        if region!=nil {
            if converted,ok:=timezone.datetime_to_tz(moment,region);ok {moment=converted}
        }
        return moment
    }
    then,today:=local(time.unix(0,opened),region),local(now,region)
    days_then,_:=datetime.date_to_ordinal(then.date)
    days_today,_:=datetime.date_to_ordinal(today.date)
    months:=[12]string{"Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"}
    month:=months[clamp(int(then.month)-1,0,11)]
    switch {
    case days_today==days_then:   return fmt.tprintf("Today %02d:%02d",then.hour,then.minute)
    case days_today==days_then+1: return "Yesterday"
    case then.year==today.year:   return fmt.tprintf("%s %d",month,then.day)
    }
    return fmt.tprintf("%s %d, %d",month,then.day,then.year)
}

// A project the editor opened goes first in the list of the machine.
projects_remember :: proc(s:^Session) {
    recent:project.Recent_Projects
    if project.recent_read(s.engine_root,&recent).code!=.None {return}
    project.recent_add(&recent,s.project_root,time.to_unix_nanoseconds(time.now()))
    if error:=project.recent_write(s.engine_root,&recent);error.code!=.None {log.warnf("%s could not be written",project.recent_file(s.engine_root,context.temp_allocator))}
}

@(private)
projects_recent_save :: proc(s:^Session) {
    p:=s.projects
    if error:=project.recent_write(s.engine_root,&p.recent);error.code!=.None {notify(s,fmt.tprintf("%s could not be written",project.recent_file(s.engine_root,context.temp_allocator)))}
}

// Builds the editor library of a project and starts the editor on it; first
// the steps given and the checkouts of its plugins from git, when it has some
// missing or at another commit.
projects_open :: proc(s:^Session,folder:string,git_init:=false,steps:[]install.Step={}) -> string {
    p:=s.projects
    if p==nil {return "The editor has no projects screen"}
    if projects_opening(p) || p.next {return "A project is being opened"}
    if s.engine_root=="" {return "The root of the engine is unknown: a project cannot be built"}
    absolute:=project.path_absolute(folder,context.temp_allocator)
    if !p.launcher && s.has_project && project.path_same(absolute,s.project_root) {
        projects_hide(s)
        return ""
    }
    if !os.is_file(project.path(absolute,project.PROJECT_FILE,allocator=context.temp_allocator)) {return fmt.tprintf("%s is not a project: it has no %s",absolute,project.PROJECT_FILE)}
    base.text_set(p.opening[:],absolute)
    p.git_init=git_init
    p.error_length=0
    p.from_git=len(steps)>0 || install.sync_needed(absolute)
    if p.from_git {
        all:=make([dynamic]install.Step,context.temp_allocator)
        append(&all,..steps)
        append(&all,install.Step{kind=.Sync})
        p.install=install.job_start(absolute,s.engine_root,all[:])
        return ""
    }
    // The dialog of the opening is drawn first: generating the world of the project takes a while.
    p.starting,p.start_frame=true,s.frame
    return ""
}

// A project is being opened: its plugins installing, about to be built or building.
projects_opening :: proc(p:^Projects) -> bool {return p.starting || p.job!=nil || p.install!=nil}

// Opens the project and starts its build, once the dialog of the opening is on the screen.
@(private)
projects_build_start :: proc(s:^Session) {
    p:=s.projects
    p.starting=false
    absolute:=base.text_get(p.opening[:])
    built:=new(project.Project)
    opened,error:=project.open(absolute,s.engine_root)
    if error.code!=.None {
        free(built)
        p.error_length=copy(p.error[:],fmt.tprintf("%s is not a project: %s",absolute,project_open_error_text(error)))
        notify(s,string(p.error[:p.error_length]))
        return
    }
    built^=opened
    p.built=built
    p.shaders=build.shaders_start(built)
    p.job=build.job_start({project=built,target=.Editor,dev=build.ENGINE_MODE_HERE==.Dev,engine=build.ENGINE_MODE_HERE,runs=engine_folder_here(s)})
    log.infof("building %s to open it",absolute)
}

@(private)
project_open_error_text :: proc(error:project.Error) -> string {
    #partial switch error.code {
    case .Text: return fmt.tprintf("its manifest has %s at line %d",error.detail,error.line)
    }
    return fmt.tprintf("%v",error.code)
}

// Follows the build of the project being opened; between frames.
projects_poll :: proc(s:^Session) {
    p:=s.projects
    // A plugin that could not be installed is said; the project opens without it.
    if p!=nil && p.install!=nil && install.job_poll(p.install) {
        if !p.install.ok {
            p.error_length=copy(p.error[:],p.install.message)
            log.errorf("the plugins of %s: %s",base.text_get(p.opening[:]),p.install.message)
            notify(s,string(p.error[:p.error_length]))
        } else if p.install.message!="" {
            log.info(p.install.message)
        }
        install.job_destroy(p.install)
        p.install=nil
        p.starting,p.start_frame=true,s.frame
    }
    if p!=nil && p.starting && s.frame>p.start_frame+1 {projects_build_start(s)}
    if p==nil || p.job==nil {return}
    if p.shaders!=nil && !build.shaders_poll(p.shaders) {return}
    if !build.job_poll(p.job) {return}
    result:=&p.job.result
    failed:=result.status==.Failed
    if failed {
        text:=result.text
        for d in result.diagnostics {
            if d.severity==.Error {text=fmt.tprintf("%s(%d:%d) %s",d.file,d.line,d.column,d.message);break}
        }
        if text=="" {text=fmt.tprintf("The build failed: %v",result.failure)}
        p.error_length=copy(p.error[:],text)
        log.errorf("%s could not be built: %s",base.text_get(p.opening[:]),text)
    }
    build.job_destroy(p.job)
    build.shaders_destroy(p.shaders)
    project.close(p.built)
    free(p.built)
    p.job,p.shaders,p.built=nil,nil,nil
    if failed {return}
    if p.launcher {
        if projects_start(s) {s.quit=true}
        return
    }
    // The editor of a project ends as the others do, asking about what is unsaved.
    p.next,p.shown=true,false
    quit_request(s)
}

// Starts the editor on the project built. False when it could not.
projects_start :: proc(s:^Session) -> bool {
    p:=s.projects
    exe:=s.program
    if exe=="" {
        notify(s,"The editor program could not be found")
        return false
    }
    command:=make([dynamic]string,context.temp_allocator)
    append(&command,exe,"--project",base.text_get(p.opening[:]))
    if p.git_init {
        append(&command,"--git-init")
        if p.lfs {append(&command,"--git-lfs")}
        if remote:=strings.trim_space(string(p.remote[:p.remote_length]));remote!="" {append(&command,"--git-remote",remote)}
    }
    for arg in s.args {append(&command,arg)}
    preferences_save(s)
    started,error:=subprocess.start({command=command[:],stdin=os.stdin,stdout=os.stdout,stderr=os.stderr})
    if error!=nil {
        log.errorf("%s could not be started: %v",exe,error)
        notify(s,"The editor could not be started on the project")
        return false
    }
    p.started,p.starts=started,true
    log.infof("opening %s",base.text_get(p.opening[:]))
    return true
}

// As the editor ends after asking: the project built waits to be started.
// False when it could not be, and the editor goes on.
projects_next_start :: proc(s:^Session) -> bool {
    p:=s.projects
    if p==nil || !p.next {return true}
    p.next=false
    return projects_start(s)
}

// A quit that was cancelled leaves the project built unopened.
projects_next_cancel :: proc(s:^Session) {
    if p:=s.projects;p!=nil {p.next=false}
}

// Stops the build of a project being opened: when the editor ends.
projects_cancel :: proc(s:^Session) {
    p:=s.projects
    if p==nil {return}
    if p.job!=nil {build.job_destroy(p.job)}
    if p.shaders!=nil {build.shaders_destroy(p.shaders)}
    // Waits for the git it runs: a clone ends on its own.
    install.job_destroy(p.install)
    p.install=nil
    if p.built!=nil {
        project.close(p.built)
        free(p.built)
    }
    p.job,p.shaders,p.built=nil,nil,nil
    p.starting=false
}

// Creates a project from the dialog and opens it.
@(private)
projects_create :: proc(s:^Session) -> string {
    p:=s.projects
    name:=strings.trim_space(string(p.name[:p.name_length]))
    location:=strings.trim_space(string(p.location[:p.location_length]))
    if name=="" {return "Give the project a name"}
    if strings.contains_any(name,"/\\:*?\"<>|") {return "The name is the name of its folder: it cannot have / \\ : * ? \" < > |"}
    if location=="" {return "Choose where the project goes"}
    if p.template<0 || p.template>=p.template_count {return "Choose a template"}
    folder:=project.path(location,name,allocator=context.temp_allocator)
    template:=build.template_folder(s.engine_root,base.text_get(p.templates[p.template][:]),context.temp_allocator)
    switch build.project_create(template,folder,name,s.engine_root) {
    case .None:
    case .Template_Missing: return "The template has no project.mirai"
    case .Folder_Not_Empty: return fmt.tprintf("%s is not an empty folder",folder)
    case .Copy_Failed:      return fmt.tprintf("%s could not be written",folder)
    case .Manifest_Failed:  return "The name does not fit in the manifest of the project"
    }
    p.creating=false
    if p.plugin_count>0 {
        file:=project.path(folder,project.PROJECT_FILE,allocator=context.temp_allocator)
        m,error:=project.manifest_read(file)
        if error.code==.None {
            m.plugins=projects_plugins_named(p,m.plugins[:])
            error=project.manifest_write(file,&m)
        }
        if error.code!=.None {return project.error_text(folder,error,context.temp_allocator)}
    }
    steps:=make([dynamic]install.Step,context.temp_allocator)
    if catalog:=s.plugins_git.catalog;catalog!=nil {
        for i in 0..<project.catalog_count(catalog) {
            if !p.picked[i] || projects_plugin_find(p,catalog.plugins[i].name)>=0 {continue}
            append(&steps,install.Step{kind=.Install,text=base.text_get(catalog.plugins[i].name[:])})
        }
    }
    for i in 0..<p.link_count {
        if p.links_on[i] {append(&steps,install.Step{kind=.Add,text=base.text_get(p.links[i][:])})}
    }
    return projects_open(s,folder,p.git,steps[:])
}

// Fills the form of a new project; template: the one chosen, or the default when negative.
@(private)
projects_new_start :: proc(s:^Session,template:int) {
    p:=s.projects
    p.creating=true
    p.name_length=copy(p.name[:],"new_project")
    p.git,p.lfs,p.remote_length,p.template=true,true,0,0
    p.picked,p.link_count,p.plugins_scroll={},0,0
    for i in 0..<p.template_count {
        if base.text_get(p.templates[i][:])==build.TEMPLATE_DEFAULT {p.template=i}
    }
    if template>=0 && template<p.template_count {p.template=template}
    projects_new_template(s,p.template)
    // Next to the last project, or in a folder Mirai of the home of the user.
    location:=""
    if project.recent_count(&p.recent)>0 {
        last:=base.text_get(p.recent.projects[0].path[:])
        if slash:=strings.last_index_byte(last,'/');slash>0 {location=last[:slash]}
    } else if home,error:=os.user_home_dir(context.temp_allocator);error==nil {
        location=project.path(home,"Mirai",allocator=context.temp_allocator)
    }
    p.location_length=copy(p.location[:],location)
}

// Answers of the folder dialogs of the screen.
@(private)
projects_dialogs_answer :: proc(s:^Session) {
    p:=s.projects
    if p==nil || s.app==nil {return}
    answer:=platform.dialog_result(s.app.platform)
    if answer.state!=.Accepted {return}
    switch answer.tag {
    case DIALOG_PROJECT_FOLDER:
        if !os.is_file(project.path(answer.path,project.PROJECT_FILE,allocator=context.temp_allocator)) {
            notify(s,fmt.tprintf("%s is not a project: it has no %s",answer.path,project.PROJECT_FILE))
            return
        }
        if message:=projects_open(s,answer.path);message!="" {notify(s,message)}
    case DIALOG_PROJECT_LOCATION:
        p.location_length=copy(p.location[:],answer.path)
    }
}


// The launcher: the window, which does not resize, holds only the projects of the machine.
projects_build :: proc(s:^Session) {
    p:=s.projects
    g:=s.gui
    ctx:=g.ctx
    projects_dialogs_answer(s)
    if ui.box(ctx,{width=ui.fixed(ctx.size.x),height=ui.fixed(ctx.size.y),fill=ui.tone(ctx,"panel"),float={to=.Surface},block=true}) {
        projects_body(s,false)
    }
    if !s.headless && platform.WINDOW_CONTROLS==.Right {
        if ui.box(ctx,{width=ui.FIT,height=ui.fixed(ui.metric(ctx,"bar_height")),float={to=.Surface,anchor=.Top_Right,pivot=.Top_Right,layer=ui.LAYER_BAR}}) {window_controls(s)}
    }
    // A project of the list shows its opening in its row; a folder chosen or created, in a dialog.
    if projects_opening(p) && projects_opening_row(p)<0 {projects_loading_build(s)}
    modal_build(s)
    toast_build(s)
    window_outline(s)
}

// The same screen over an open project: a dialog that Escape, its cross or a press outside closes.
projects_popup_build :: proc(s:^Session) {
    p:=s.projects
    g:=s.gui
    ctx:=g.ctx
    projects_dialogs_answer(s)
    if projects_opening(p) {
        projects_loading_build(s)
        return
    }
    closed:=false
    defer if closed {projects_hide(s)}
    if ui.modal(ctx,shell_id(g,"projects"),{width=f32(PROJECTS_WINDOW.x),padding=-1,close=&closed,own_cross=true,fill=ui.tone(ctx,"panel")}) {
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(min(f32(PROJECTS_WINDOW.y),ctx.size.y-2*ui.metric(ctx,"margin")))}) {
            projects_body(s,true)
        }
    }
}

// The side with the mark and what makes or opens a project, and the list or the new project.
@(private)
projects_body :: proc(s:^Session,popup:bool) {
    p:=s.projects
    g:=s.gui
    ctx:=g.ctx
    busy:=projects_opening(p) || p.next
    // Under the buttons of the window at the left of the launcher, or flush with the dialog.
    top:=f32(24) if popup else ui.metric(ctx,"bar_height")+12
    corners:=[4]f32{ui.metric(ctx,"radius_panel"),0,0,ui.metric(ctx,"radius_panel")} if popup else {}
    if ui.box(ctx,{width=ui.fixed(PROJECTS_SIDEBAR),height=ui.GROW,direction=.Column,padding={18,top,18,20},fill=ui.tone(ctx,"bar_top"),corners=corners}) {
        if ui.box(ctx,{width=ui.FIT,height=ui.FIT,gap=8,align_y=.Center}) {
            ui.icon(ctx,ui.icon_user(u8(User_Icon.Mirai)),MARK_ARM,44)
            ui.canvas(ctx,ui.id(ctx,"projects_wordmark"),ui.fixed(WORDMARK_SIZE.x*0.6),ui.fixed(WORDMARK_SIZE.y*0.6),{name=u64(User_Icon.Wordmark)})
        }
        if branch:=base.text_get(p.engine_branch[:]);branch!="" {
            ui.spacer(ctx,0,10)
            ui.label(ctx,fmt.tprintf("Engine on %s",branch),ui.metric(ctx,"font_small"),ui.tone(ctx,"text_faint"),0,fade=true)
        }
        ui.spacer(ctx,0,28)
        new:=ui.button(ctx,ui.id(ctx,"projects_new"),{label="New project",icon=.Plus,variant="toggle" if p.creating else "accent",active=p.creating,width=-1,height=34,disabled=busy || p.template_count==0})
        if new.clicked && !p.creating {projects_new_start(s,-1)}
        ui.spacer(ctx,0,8)
        if ui.button(ctx,ui.id(ctx,"projects_folder"),{label="Open folder",icon=ui.icon_user(u8(User_Icon.Folder)),variant="field",width=-1,height=34,disabled=busy}).clicked {
            if !platform.dialog_show(s.app.platform,{kind=.Open_Folder,tag=DIALOG_PROJECT_FOLDER}) {notify(s,"A file dialog is already open")}
        }
        ui.spacer(ctx)
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(20),gap=8,align_y=.Center}) {
            if ui.checkbox(ctx,ui.id(ctx,"projects_open_last"),&p.recent.open_last) {projects_recent_save(s)}
            ui.label(ctx,"Open the last project at startup",ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"),0,fade=true)
        }
    }
    if ui.box(ctx,{width=ui.fixed(1),height=ui.GROW,fill=ui.tone(ctx,"divider")}) {}
    // Below the buttons of the window at the right of the launcher.
    head:=ui.metric(ctx,"bar_height") if !popup && !s.headless && platform.WINDOW_CONTROLS==.Right else 18
    if ui.box(ctx,{width=ui.GROW,height=ui.GROW,direction=.Column,gap=14,padding={20,head,20,20}}) {
        if p.creating {projects_new_build(s)} else {projects_content(s,popup)}
    }
}

// The row of the list of the project being opened; -1 when it is not in the list.
@(private)
projects_opening_row :: proc(p:^Projects) -> int {
    if !projects_opening(p) {return -1}
    opening:=base.text_get(p.opening[:])
    for i in 0..<project.recent_count(&p.recent) {
        if project.path_same(base.text_get(p.recent.projects[i].path[:]),opening) {return i}
    }
    return -1
}

// What the opening of a project is doing, as its row says it.
@(private)
projects_doing :: proc(p:^Projects) -> string {
    if p.starting {return "Generating the world"}
    if p.shaders!=nil && p.shaders.result.status==.Running {return "Building the shaders"}
    return "Building the editor"
}

// A folder under the home of the user, from ~.
@(private)
projects_path_shown :: proc(p:^Projects,folder:string) -> string {
    home:=base.text_get(p.home[:])
    if home!="" && strings.has_prefix(folder,home) && (len(folder)==len(home) || folder[len(home)]=='/') {
        return fmt.tprintf("~%s",folder[len(home):])
    }
    return folder
}

// The square of a project: its image covering it, or the first letter of its
// name on the fill its name chooses.
@(private)
projects_tile :: proc(ctx:^ui.Context,name:string,side:f32,missing:bool,image:ui.Quad={}) {
    if image.kind!=.Solid && !missing {
        if ui.box(ctx,{width=ui.fixed(side),height=ui.fixed(side),image=image,layer={enabled=true,opacity=1,radius=side*0.22}}) {}
        return
    }
    tiles:=PROJECTS_TILES
    tile:=tiles[hash.fnv32a(transmute([]u8)name)%len(tiles)]
    if missing {tile={ui.tone(ctx,"raised"),ui.tone(ctx,"text_faint")}}
    if ui.box(ctx,{width=ui.fixed(side),height=ui.fixed(side),align_x=.Center,align_y=.Center,fill=tile[0],radius=side*0.22}) {
        if missing || name=="" {
            ui.icon(ctx,ui.icon_user(u8(User_Icon.Folder)),tile[1],side*0.45)
        } else {
            _,width:=utf8.decode_rune_in_string(name)
            ui.label(ctx,strings.to_upper(name[:width],context.temp_allocator),side*0.42,tile[1],font=ui.FONT_SEMIBOLD)
        }
    }
}

// The head of the list, its rows and the templates a project starts from.
@(private)
projects_content :: proc(s:^Session,popup:bool) {
    p:=s.projects
    g:=s.gui
    ctx:=g.ctx
    busy:=projects_opening(p) || p.next
    count:=project.recent_count(&p.recent)
    typing:=ctx.edit.id!=0
    open:=false
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(32),gap=10,align_y=.Center}) {
        ui.label(ctx,"Recent projects",ui.metric(ctx,"font_heading"),ui.tone(ctx,"text"),font=ui.FONT_SEMIBOLD)
        if count>0 {
            if ui.box(ctx,{width=ui.FIT,height=ui.fixed(20),padding={7,0,7,0},align_y=.Center,fill=ui.tone(ctx,"card"),radius=10}) {
                ui.label(ctx,fmt.tprintf("%d",count),ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"))
            }
        }
        ui.spacer(ctx)
        search:=ui.id(ctx,"projects_search")
        named_add(g,search)
        if ui.box(ctx,{width=ui.fixed(220),height=ui.fixed(30)}) {
            ui.text_field(ctx,search,p.search[:],&p.search_length,{placeholder="Search",icon=ui.icon_user(u8(User_Icon.Search)),live=true,height=30,size=ui.metric(ctx,"font")})
        }
        if ui.button(ctx,ui.id(ctx,"projects_open"),{label="Open",variant="accent",width=72,height=30,center=true,disabled=busy || projects_chosen(p)<0}).clicked {open=true}
        if popup && ui.icon_button(ctx,ui.id(ctx,"projects_close"),.Cross,28).clicked {projects_hide(s)}
    }
    if ui.scroll_area(ctx,ui.id(ctx,"projects_list"),&p.scroll,{width=ui.GROW,height=ui.GROW,direction=.Column,gap=2}) {
        needle:=strings.to_lower(strings.trim_space(string(p.search[:p.search_length])),context.temp_allocator)
        opening:=projects_opening_row(p)
        removed:=-1
        shown:=false // the row selected is in the list the search leaves
        for i in 0..<count {
            row:=&p.rows[i]
            folder:=base.text_get(p.recent.projects[i].path[:])
            if needle!="" && !strings.contains(strings.to_lower(base.text_get(row.name[:]),context.temp_allocator),needle) && !strings.contains(strings.to_lower(folder,context.temp_allocator),needle) {continue}
            remove,double:=projects_row(s,i,row,folder,busy,opening==i)
            if remove {removed=i}
            if double {open=true}
            shown|=p.selected==i+1
        }
        if !shown {p.selected=0}
        if removed>=0 {
            project.recent_remove(&p.recent,removed)
            projects_recent_save(s)
            projects_rows_read(s)
        }
        if count==0 {
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(PROJECTS_ROW),align_x=.Center,align_y=.Center}) {
                ui.label(ctx,"No project was opened on this machine yet",ui.metric(ctx,"font"),ui.tone(ctx,"text_muted"))
            }
        }
    }
    if !typing && ctx.popup.count==0 && .Enter in ctx.input.keys_pressed {open=true}
    if chosen:=projects_chosen(p);open && !busy && chosen>=0 {
        if message:=projects_open(s,base.text_get(p.recent.projects[chosen].path[:]));message!="" {notify(s,message)}
    }
    if p.error_length>0 {ui.label(ctx,string(p.error[:p.error_length]),ui.metric(ctx,"font_small"),ui.tone(ctx,"danger_soft"),0,fade=true)}
    if p.template_count==0 {return}
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,gap=10,layer={enabled=busy,opacity=PROJECTS_FADED}}) {
        ui.label(ctx,"START FROM A TEMPLATE",ui.metric(ctx,"font_caption"),ui.tone(ctx,"text_caption"),font=ui.FONT_SEMIBOLD)
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(PROJECTS_TEMPLATE_CARD),gap=10}) {
            for i in 0..<p.template_count {
                if projects_template_card(s,i,busy,false,false).clicked {projects_new_start(s,i)}
            }
        }
    }
}

// The row selected when its project can be opened; -1 for none.
@(private)
projects_chosen :: proc(p:^Projects) -> int {
    i:=p.selected-1
    if i<0 || i>=project.recent_count(&p.recent) || p.rows[i].missing {return -1}
    return i
}

// A row of the list: a click selects it, a double click opens it (open).
// remove: its Remove was clicked.
@(private)
projects_row :: proc(s:^Session,index:int,row:^Projects_Row,folder:string,busy,opening:bool) -> (remove,open:bool) {
    ctx:=s.gui.ctx
    p:=s.projects
    id:=ui.id(ctx,"project_row",index)
    usable:=!busy && !row.missing
    it:=ui.interact(ctx,id,ui.Widget_Flags{.Focusable} if usable else {.Passive})
    if (it.clicked || it.double) && usable {p.selected=index+1}
    open=it.double && usable
    fill,stroke:ui.Color
    if opening || p.selected==index+1 {fill,stroke=ui.tone(ctx,"accent_soft"),ui.tone(ctx,"accent")} else if it.hot && usable {fill=ui.tone(ctx,"card")}
    if ui.box(ctx,{id=id,width=ui.GROW,height=ui.fixed(PROJECTS_ROW),gap=12,padding={10,0,10,0},align_y=.Center,fill=fill,stroke=stroke,stroke_width=1,radius=8,layer={enabled=busy && !opening,opacity=PROJECTS_FADED}}) {
        name:=base.text_get(row.name[:])
        projects_tile(ctx,name,PROJECTS_TILE,row.missing,thumbnail_image_quad(s,row.thumbnail_slot,row.thumbnail))
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,gap=3}) {
            ui.label(ctx,name,ui.metric(ctx,"font"),row.missing?ui.tone(ctx,"text_muted"):ui.tone(ctx,"text"),0,font=ui.FONT_SEMIBOLD)
            ui.label(ctx,projects_path_shown(s.projects,folder),ui.metric(ctx,"font_small"),ui.tone(ctx,"text_faint"),0,fade=true)
        }
        if opening {
            pulse_dot(ctx,MARK_ARM,true)
            ui.label(ctx,projects_doing(s.projects),ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"))
            if ui.button(ctx,ui.id(ctx,"project_cancel"),{label="Cancel",variant="field",height=28,size=ui.metric(ctx,"font_small")}).clicked {projects_cancel(s)}
        } else {
            chip,chip_color,chip_fill:="",ui.tone(ctx,"text_muted"),ui.tone(ctx,"card")
            switch {
            case row.missing:     chip,chip_color,chip_fill="Folder not found",ui.tone(ctx,"danger"),GIT_REMOVED_FILL
            case !row.repository: chip="No repository"
            case:                 chip=base.text_get(row.branch[:])
            }
            if chip!="" {
                if ui.box(ctx,{width=ui.FIT,height=ui.fixed(22),gap=5,padding={8,0,8,0},align_y=.Center,fill=chip_fill,radius=11}) {
                    if row.repository && !row.missing {ui.icon(ctx,ui.icon_user(u8(User_Icon.Branch)),chip_color,12)}
                    ui.label(ctx,chip,ui.metric(ctx,"font_small"),chip_color)
                }
            }
            if row.missing && ui.button(ctx,ui.id(ctx,"project_remove",index),{label="Remove",variant="ghost",height=24,size=ui.metric(ctx,"font_small"),disabled=busy}).clicked {remove=true}
            if ui.box(ctx,{width=ui.fixed(76),height=ui.FIT,align_x=.End}) {
                ui.label(ctx,base.text_get(row.opened[:]),ui.metric(ctx,"font_small"),ui.tone(ctx,"text_faint"))
            }
        }
    }
    return
}

// A template to start a project from: a row of the list, or a tall card of the new project.
@(private)
projects_template_card :: proc(s:^Session,index:int,disabled,chosen,tall:bool) -> ui.Interaction {
    p:=s.projects
    ctx:=s.gui.ctx
    id:=ui.id(ctx,"project_template",index)
    it:=ui.interact(ctx,id,ui.Widget_Flags{.Focusable} if !disabled else {.Passive})
    if disabled {it={}}
    name:=base.text_get(p.templates[index][:])
    game:=name=="game"
    fill,stroke:=ui.tone(ctx,"well"),ui.tone(ctx,"well_stroke_hover") if it.hot else ui.tone(ctx,"well_stroke")
    tile,ink:=ui.tone(ctx,"card"),ui.tone(ctx,"text_muted")
    if game {tile,ink=ui.tone(ctx,"accent_soft"),PROJECTS_TILES[1][1]}
    if chosen {fill,stroke,tile,ink=ui.tone(ctx,"accent_soft"),ui.tone(ctx,"accent"),ui.tone(ctx,"accent"),ui.tone(ctx,"on_accent")}
    side:=f32(40) if tall else 32
    padding:=ui.padding_all(14) if tall else [4]f32{14,0,14,0}
    if ui.box(ctx,{id=id,width=ui.GROW,height=ui.GROW,direction=.Column if tall else .Row,gap=14 if tall else 12,padding=padding,align_y=.Start if tall else .Center,fill=fill,stroke=stroke,stroke_width=1,radius=ui.metric(ctx,"radius_panel")}) {
        if ui.box(ctx,{width=ui.fixed(side),height=ui.fixed(side),align_x=.Center,align_y=.Center,fill=tile,radius=side*0.25}) {
            ui.icon(ctx,.Spawn if game else .Cube,ink,side*0.5)
        }
        ui.label(ctx,strings.to_upper_camel_case(name,context.temp_allocator),ui.metric(ctx,"font"),ui.tone(ctx,"text"),-1 if tall else 0,font=ui.FONT_SEMIBOLD)
        if !tall {ui.icon(ctx,.Chevron_Right,ui.tone(ctx,"text_faint"),14)}
    }
    return it
}

// The steps of opening a project the list does not show: generating its
// world, then building its editor and its shaders at once.
@(private)
projects_loading_build :: proc(s:^Session) {
    p:=s.projects
    g:=s.gui
    ctx:=g.ctx
    folder:=base.text_get(p.opening[:])
    name:=filepath.base(folder)
    Step :: enum u8 {Pending,Current,Done}
    steps:=[4]string{"Installing the plugins from Git","Generating the world","Building the editor","Building the shaders"}
    states:=[4]Step{.Current,.Pending,.Pending,.Pending}
    if p.install==nil {
        states[0],states[1]=.Done,.Current
    }
    if p.install==nil && !p.starting {
        states[1]=.Done
        states[2]=.Current if p.job!=nil && p.job.result.status==.Running else .Done
        states[3]=.Current if p.shaders!=nil && p.shaders.result.status==.Running else .Done
    }
    if ui.modal(ctx,shell_id(g,"projects_loading"),{width=420,padding=-1}) {
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column}) {
            if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=12,padding={20,18,20,12},align_y=.Center}) {
                projects_tile(ctx,name,40,false)
                if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,gap=3}) {
                    ui.label(ctx,fmt.tprintf("Opening %s",name),ui.metric(ctx,"font_heading"),ui.tone(ctx,"text"),0,font=ui.FONT_SEMIBOLD)
                    ui.label(ctx,projects_path_shown(p,folder),ui.metric(ctx,"font_small"),ui.tone(ctx,"text_faint"),0,fade=true)
                }
            }
            if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,padding={20,4,20,16}}) {
                for step,i in steps {
                    if i==0 && !p.from_git {continue}
                    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(30),gap=10,align_y=.Center}) {
                        if ui.box(ctx,{width=ui.fixed(18),height=ui.fixed(18),align_x=.Center,align_y=.Center,fill=ui.tone(ctx,"accent_soft") if states[i]==.Done else {},radius=9}) {
                            switch states[i] {
                            case .Done:    ui.icon(ctx,.Check,MARK_ARM,10)
                            case .Current: pulse_dot(ctx,MARK_ARM,true)
                            case .Pending: if ui.box(ctx,{width=ui.fixed(14),height=ui.fixed(14),stroke=ui.tone(ctx,"border"),stroke_width=1.5,radius=7}) {}
                            }
                        }
                        color:=[Step]ui.Color{.Pending=ui.tone(ctx,"text_faint"),.Current=ui.tone(ctx,"text"),.Done=ui.tone(ctx,"text_muted")}
                        ui.label(ctx,step,ui.metric(ctx,"font"),color[states[i]],font=ui.FONT_SEMIBOLD if states[i]==.Current else 0)
                    }
                }
            }
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(1),fill=ui.tone(ctx,"divider")}) {}
            if ui.box(ctx,{width=ui.GROW,height=ui.FIT,padding={20,12,20,12},align_x=.End,fill=ui.tone(ctx,"panel"),corners={0,0,ui.metric(ctx,"radius_panel"),ui.metric(ctx,"radius_panel")}}) {
                if ui.button(ctx,shell_id(g,"projects_loading_cancel"),{label="Cancel",variant="field",width=90,height=ui.metric(ctx,"control"),center=true}).clicked {projects_cancel(s)}
            }
        }
    }
}

// The form of a new project in place of the list: its template, name and
// folder, and its repository beside the plugins it gets.
@(private)
projects_new_build :: proc(s:^Session) {
    p:=s.projects
    g:=s.gui
    ctx:=g.ctx
    busy:=projects_opening(p) || p.next
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(32),gap=10,align_y=.Center}) {
        back:=ui.id(ctx,"new_project_back")
        named_add(g,back)
        if ui.icon_button(ctx,back,ui.icon_user(u8(User_Icon.Back)),28,"field").clicked {p.creating=false}
        ui.label(ctx,"New project",ui.metric(ctx,"font_heading"),ui.tone(ctx,"text"),font=ui.FONT_SEMIBOLD)
    }
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(108),gap=10}) {
        for i in 0..<p.template_count {
            if projects_template_card(s,i,busy,p.template==i,true).clicked && p.template!=i {projects_new_template(s,i)}
        }
    }
    if ui.box(ctx,{width=ui.GROW,height=ui.GROW,gap=14}) {
        if ui.box(ctx,{width=ui.GROW,height=ui.GROW,direction=.Column,gap=10}) {
            if kit.property(ctx,"Name",30) {
                ui.text_field(ctx,ui.id(ctx,"new_project_name"),p.name[:],&p.name_length,{live=true,height=30,size=ui.metric(ctx,"font")})
            }
            if kit.property(ctx,"Location",30) {
                ui.text_field(ctx,ui.id(ctx,"new_project_location"),p.location[:],&p.location_length,{live=true,height=30,size=ui.metric(ctx,"font")})
                if ui.button(ctx,ui.id(ctx,"new_project_browse"),{label="Browse",icon=ui.icon_user(u8(User_Icon.Folder)),variant="field",height=30}).clicked {
                    location:=string(p.location[:p.location_length])
                    if !platform.dialog_show(s.app.platform,{kind=.Open_Folder,tag=DIALOG_PROJECT_LOCATION,location=os.is_dir(location)?location:""}) {notify(s,"A file dialog is already open")}
                }
            }
            if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,gap=10,padding={14,12,14,12},fill=ui.tone(ctx,"well"),stroke=ui.tone(ctx,"divider"),stroke_width=1,radius=ui.metric(ctx,"radius_panel")}) {
                if ui.box(ctx,{width=ui.GROW,height=ui.fixed(20),gap=8,align_y=.Center}) {
                    ui.checkbox(ctx,ui.id(ctx,"new_project_git"),&p.git)
                    ui.label(ctx,"Initialize Git repository",ui.metric(ctx,"font"),ui.tone(ctx,"text"),font=ui.FONT_SEMIBOLD)
                }
                if p.git {
                    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,gap=10,padding={24,0,0,0}}) {
                        if kit.property(ctx,"Remote",30) {
                            ui.text_field(ctx,ui.id(ctx,"new_project_remote"),p.remote[:],&p.remote_length,{placeholder="https://github.com/user/repo.git",live=true,height=30,size=ui.metric(ctx,"font")})
                        }
                        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(20),gap=8,align_y=.Center}) {
                            ui.checkbox(ctx,ui.id(ctx,"new_project_lfs"),&p.lfs)
                            ui.label(ctx,"Use Git LFS for textures, meshes and sounds",ui.metric(ctx,"font_small"),ui.tone(ctx,"text_label"),0,fade=true)
                        }
                    }
                }
            }
        }
        projects_new_plugins(s)
    }
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(32),gap=8,align_x=.End,align_y=.Center}) {
        if ui.button(ctx,ui.id(ctx,"new_project_cancel"),{label="Cancel",variant="field",width=90,height=32,center=true}).clicked {p.creating=false}
        if ui.button(ctx,ui.id(ctx,"new_project_create"),{label="Create",variant="accent",width=90,height=32,center=true,disabled=busy}).clicked {
            if message:=projects_create(s);message!="" {notify(s,message)}
        }
    }
}

// Chooses the template of the new project: the plugins it offers are read
// again, on as it names them; those of the catalog and the repositories
// added stay.
@(private)
projects_new_template :: proc(s:^Session,template:int) {
    p:=s.projects
    p.template=template
    p.plugin_count=0
    if template<0 || template>=p.template_count || s.engine_root=="" {return}
    projects_plugins_read(p,build.template_folder(s.engine_root,base.text_get(p.templates[template][:]),context.temp_allocator),s.engine_root)
}

// The plugins of the engine and of the template a new project can get, all
// but the automatic ones, on as the template names them.
@(private)
projects_plugins_read :: proc(p:^Projects,template,engine_root:string) {
    p.plugin_count=0
    opened,error:=project.open(template,engine_root,context.temp_allocator)
    if error.code!=.None {return}
    defer project.close(&opened)
    rows:=make([]int,len(opened.plugins),context.temp_allocator) // the row of each plugin; -1: none
    for &plugin,i in opened.plugins {
        rows[i]=-1
        if plugin.manifest.automatic || p.plugin_count==PROJECTS_PLUGINS {continue}
        row:=&p.plugins[p.plugin_count]
        row^={name=plugin.manifest.name}
        base.text_set(row.icon_file[:],plugin_icon_file(plugin.folder,base.text_get(plugin.manifest.icon[:])))
        for named in opened.manifest.plugins {row.on|=named==plugin.manifest.name}
        rows[i]=p.plugin_count
        p.plugin_count+=1
    }
    for i in 0..<len(opened.plugins) {
        if rows[i]<0 {continue}
        for &other,k in opened.plugins {
            if k!=i && rows[k]>=0 && project.plugin_reaches(opened.plugins,i,base.text_get(other.manifest.name[:]),false) {p.plugins[rows[i]].needs+={rows[k]}}
        }
    }
}

// The row of the plugin named name; -1: none.
@(private)
projects_plugin_find :: proc(p:^Projects,name:project.Name) -> int {
    for i in 0..<p.plugin_count {
        if p.plugins[i].name==name {return i}
    }
    return -1
}

// A plugin on that brings the one of row i, which cannot go off; -1: none.
@(private)
projects_plugin_needed_by :: proc(p:^Projects,i:int) -> int {
    for k in 0..<p.plugin_count {
        if k!=i && p.plugins[k].on && i in p.plugins[k].needs {return k}
    }
    return -1
}

// The plugins project.mirai of the new project names: those the template
// names that are still on, in its order, then the others turned on.
@(private)
projects_plugins_named :: proc(p:^Projects,template:[]project.Name) -> (names:[project.MAX_PLUGINS]project.Name) {
    count:=0
    for name in template {
        if name=={} || count==len(names) {continue}
        if i:=projects_plugin_find(p,name);i<0 || p.plugins[i].on {
            names[count]=name
            count+=1
        }
    }
    for i in 0..<p.plugin_count {
        if !p.plugins[i].on || count==len(names) {continue}
        named:=false
        for name in template {named|=name==p.plugins[i].name}
        if named {continue}
        names[count]=p.plugins[i].name
        count+=1
    }
    return
}

// What can be cloned as the repository of a plugin: an address of git, not
// a search of the catalog.
@(private)
projects_git_link :: proc(text:string) -> bool {
    if text=="" || strings.contains_any(text," \t") {return false}
    for prefix in ([]string{"https://","http://","ssh://","git://","file://","git@"}) {
        if strings.has_prefix(text,prefix) {return true}
    }
    return strings.has_suffix(text,".git")
}

// The plugins a new project starts with, each with its check: those of the
// engine and of the template, those of the catalog and the repositories
// added. Add plugin searches the catalog or takes the address of one.
@(private)
projects_new_plugins :: proc(s:^Session) {
    p:=s.projects
    ctx:=s.gui.ctx
    catalog:=plugins_git_catalog(s)
    count:=catalog==nil?0:project.catalog_count(catalog)
    popup:=ui.id(ctx,"new_project_add_popup")
    row_box:=ui.Box{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")+4),gap=8,padding={6,0,6,0},align_y=.Center}
    if ui.box(ctx,{width=ui.fixed(PROJECTS_PLUGINS_WIDTH),height=ui.GROW,direction=.Column,fill=ui.tone(ctx,"well"),stroke=ui.tone(ctx,"divider"),stroke_width=1,radius=ui.metric(ctx,"radius_panel")}) {
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=8,padding={14,8,8,8},align_y=.Center}) {
            ui.label(ctx,"Plugins",ui.metric(ctx,"font"),ui.tone(ctx,"text"),font=ui.FONT_SEMIBOLD)
            ui.spacer(ctx)
            add:=ui.id(ctx,"new_project_add_plugin")
            if ui.button(ctx,add,{label="Add plugin",icon=.Plus,variant="field",height=ui.metric(ctx,"control"),size=ui.metric(ctx,"font_small"),active=ui.popup_is_open(ctx,popup)}).clicked {
                anchor,_:=ui.widget_rect(ctx,add)
                p.add_scroll=0
                ui.popup_open(ctx,popup,anchor)
            }
        }
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(1),fill=ui.tone(ctx,"divider")}) {}
        if ui.scroll_area(ctx,ui.id(ctx,"new_project_plugins"),&p.plugins_scroll,{width=ui.GROW,height=ui.GROW,direction=.Column,padding={8,4,8,6},fade=ui.tone(ctx,"well")}) {
            for i in 0..<p.plugin_count {
                row:=&p.plugins[i]
                needed:=projects_plugin_needed_by(p,i)
                if ui.box(ctx,row_box) {
                    if needed>=0 {
                        forced:=true
                        ui.checkbox(ctx,ui.id(ctx,"new_project_plugin",i),&forced,disabled=true)
                    } else {
                        ui.checkbox(ctx,ui.id(ctx,"new_project_plugin",i),&row.on)
                    }
                    plugin_icon_draw(s,&row.icon,base.text_get(row.icon_file[:]))
                    ui.label(ctx,base.text_get(row.name[:]),ui.metric(ctx,"font_small"),ui.tone(ctx,"text_label"))
                    if needed>=0 {ui.label(ctx,fmt.tprintf("needed by %s",base.text_get(p.plugins[needed].name[:])),ui.metric(ctx,"font_label"),ui.tone(ctx,"text_faint"),0,fade=true)}
                }
            }
            for i in 0..<count {
                entry:=&catalog.plugins[i]
                if projects_plugin_find(p,entry.name)>=0 {continue}
                name:=base.text_get(entry.name[:])
                if ui.box(ctx,row_box) {
                    ui.checkbox(ctx,ui.id(ctx,"new_project_catalog",i),&p.picked[i])
                    plugin_icon_draw(s,&s.plugins_git.catalog_icons[i],plugin_icon_catalog(s,name))
                    ui.label(ctx,name,ui.metric(ctx,"font_small"),ui.tone(ctx,"text_label"))
                    ui.label(ctx,base.text_get(entry.description[:]),ui.metric(ctx,"font_label"),ui.tone(ctx,"text_faint"),0,fade=true)
                }
            }
            for i in 0..<p.link_count {
                if ui.box(ctx,row_box) {
                    ui.checkbox(ctx,ui.id(ctx,"new_project_link",i),&p.links_on[i])
                    ui.icon(ctx,ui.icon_user(u8(User_Icon.Branch)),ui.tone(ctx,"text_muted"),PLUGIN_ICON_SIZE)
                    ui.label(ctx,base.text_get(p.links[i][:]),ui.metric(ctx,"font_small"),ui.tone(ctx,"text_label"),0,fade=true)
                }
            }
            text:=""
            if count==0 {text=plugins_git_busy(s)?"Fetching the catalog":base.text_get(s.plugins_git.catalog_message[:])}
            if text!="" {
                if ui.box(ctx,row_box) {ui.label(ctx,text,ui.metric(ctx,"font_small"),ui.tone(ctx,"text_faint"),0,fade=true)}
            }
        }
    }
    projects_add_plugin_popup(s,popup)
}

// The popup of Add plugin: the plugins of the catalog its search finds, and
// the address of a repository when the search is one. Taking one checks it.
@(private)
projects_add_plugin_popup :: proc(s:^Session,popup:ui.Id) {
    p:=s.projects
    ctx:=s.gui.ctx
    if !ui.popup_is_open(ctx,popup) {return}
    catalog:=s.plugins_git.catalog
    needle,_:=ui.popup_search(ctx,popup)
    needle=strings.trim_space(needle)
    link:=projects_git_link(needle)
    found:=make([dynamic]int,context.temp_allocator)
    for i in 0..<(catalog==nil?0:project.catalog_count(catalog)) {
        entry:=&catalog.plugins[i]
        if projects_plugin_find(p,entry.name)>=0 {continue}
        if needle=="" || base.contains_fold(base.text_get(entry.name[:]),needle) || base.contains_fold(base.text_get(entry.description[:]),needle) {append(&found,i)}
    }
    row_height:=ASSET_LIST_ROW
    chosen,taken:=-1,false
    if ui.popup(ctx,popup,{width=340,align_right=true,search="Search the catalog or paste a Git link"}) {
        ui.id_push(ctx,popup)
        defer ui.id_pop(ctx)
        if _,changed:=ui.popup_search(ctx,popup);changed {p.add_scroll=0}
        if link && ui.row(ctx,ui.id(ctx,"link"),{label="Add from Git",detail=needle,icon=ui.icon_user(u8(User_Icon.Branch)),icon_color=ui.tone(ctx,"text_muted"),height=row_height}).clicked {taken=true}
        if len(found)>0 {
            rows:=ui.id(ctx,"rows")
            shown:=f32(min(len(found),8))*row_height
            first,last:=ui.list_begin(ctx,rows,&p.add_scroll,len(found),row_height,shown)
            for index in first..<last {
                i:=found[index]
                entry:=&catalog.plugins[i]
                name:=base.text_get(entry.name[:])
                r:=ui.Row{label=name,detail=base.text_get(entry.description[:]),height=row_height,checked=p.picked[i],check_room=true}
                if quad:=plugin_icon_quad(s,&s.plugins_git.catalog_icons[i],plugin_icon_catalog(s,name));quad.kind!=.Solid {r.quad=quad} else {r.icon,r.icon_color=ui.icon_user(u8(User_Icon.Plugin)),ui.tone(ctx,"text_muted")}
                if ui.row(ctx,ui.id(ctx,"row",i+1),r).clicked {chosen=i}
            }
            ui.list_end(ctx,rows,len(found),last,row_height)
        } else if !link {
            text:="No plugin of the catalog matches"
            if plugins_git_busy(s) {text="Fetching the catalog"} else if message:=base.text_get(s.plugins_git.catalog_message[:]);message!="" {text=message}
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(row_height),padding={8,0,8,0},align_y=.Center}) {ui.label(ctx,text,ui.metric(ctx,"font_small"),ui.tone(ctx,"text_faint"),0,fade=true)}
        }
    }
    if chosen>=0 {p.picked[chosen]=true}
    if taken {projects_link_add(p,needle)}
    if chosen>=0 || taken {ui.popup_close(ctx,popup)}
}

// Adds the repository of a plugin to the new project, on; one added before
// is turned on again.
@(private)
projects_link_add :: proc(p:^Projects,url:string) {
    for i in 0..<p.link_count {
        if base.text_get(p.links[i][:])==url {
            p.links_on[i]=true
            return
        }
    }
    if p.link_count==PROJECTS_LINKS {return}
    base.text_set(p.links[p.link_count][:],url)
    p.links_on[p.link_count]=true
    p.link_count+=1
}
