package editor

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:asset"
import "mirai:cook/build"
import img "mirai:cook/image"
import "mirai:cook/install"
import ka "mirai:cook/kai"
import vcs "mirai:kai"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:store"
import "mirai:ui"

@(test)
projects_say_when_each_was_opened :: proc(t:^testing.T) {
    now,_:=time.datetime_to_time(2026,10,24,15,30,0)
    at :: proc(year,month,day,hour,minute:int) -> i64 {
        moment,_:=time.datetime_to_time(year,month,day,hour,minute,0)
        return time.to_unix_nanoseconds(moment)
    }
    testing.expect_value(t,projects_when(at(2026,10,24,9,5),now,nil),"Today 09:05")
    testing.expect_value(t,projects_when(at(2026,10,23,22,0),now,nil),"Yesterday")
    testing.expect_value(t,projects_when(at(2026,3,2,8,0),now,nil),"Mar 2")
    testing.expect_value(t,projects_when(at(2025,12,31,8,0),now,nil),"Dec 31, 2025")
    testing.expect_value(t,projects_when(0,now,nil),"")
}

@(test)
a_new_project_offers_every_plugin_but_the_automatic_ones :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"projects")
    if folder=="" {return}
    root:=project.path_absolute(folder,context.temp_allocator)
    engine:=project.path(root,"engine",allocator=context.temp_allocator)
    template:=project.path(root,"template",allocator=context.temp_allocator)
    plugin :: proc(t:^testing.T,folder,name:string,dependencies:[]string,automatic:=false) {
        m:project.Plugin_Manifest
        base.text_set(m.name[:],name)
        base.text_set(m.version[:],"1.0.0")
        m.automatic=automatic
        for dependency,i in dependencies {base.text_set(m.dependencies[i][:],dependency)}
        at:=project.path(folder,"plugins",name,allocator=context.temp_allocator)
        testing.expect(t,base.make_directory_all(at)==nil)
        testing.expect_value(t,project.plugin_write(project.path(at,project.PLUGIN_FILE,allocator=context.temp_allocator),&m).code,project.Error_Code.None)
    }
    plugin(t,engine,"physics",{})
    plugin(t,engine,"destruct",{"physics"})
    plugin(t,engine,"vfx",{})
    plugin(t,engine,"destruct_vfx",{"destruct","vfx"},true)
    plugin(t,template,"sample",{})
    m:=project.manifest_default("Game")
    base.text_set(m.plugins[0][:],"sample")
    base.text_set(m.plugins[1][:],"destruct")
    testing.expect_value(t,project.manifest_write(project.path(template,project.PROJECT_FILE,allocator=context.temp_allocator),&m).code,project.Error_Code.None)
    p:=new(Projects)
    defer free(p)
    projects_plugins_read(p,template,engine)
    Row :: struct {name:string,on:bool,needed_by:string}
    rows:=make([dynamic]Row,context.temp_allocator)
    for i in 0..<p.plugin_count {
        by:=projects_plugin_needed_by(p,i)
        append(&rows,Row{base.text_get(p.plugins[i].name[:]),p.plugins[i].on,by<0?"":base.text_get(p.plugins[by].name[:])})
    }
    testing.expect(t,slice.equal(rows[:],[]Row{{"sample",true,""},{"destruct",true,""},{"physics",false,"destruct"},{"vfx",false,""}}),fmt.tprint(rows))
    // What the template names and is still on keeps its order; the rest turned on follows.
    sample,vfx:=0,3
    p.plugins[sample].on,p.plugins[vfx].on=false,true
    named:=projects_plugins_named(p,m.plugins[:])
    testing.expect_value(t,base.text_get(named[0][:]),"destruct")
    testing.expect_value(t,base.text_get(named[1][:]),"vfx")
    testing.expect_value(t,base.text_len(named[2][:]),0)
}

@(test)
add_plugin_takes_a_git_address_and_searches_the_catalog_with_anything_else :: proc(t:^testing.T) {
    for text in ([]string{"https://github.com/user/plugin.git","git@github.com:user/plugin.git","ssh://host/plugin","../plugins/terrain.git"}) {testing.expect(t,projects_git_link(text),text)}
    for text in ([]string{"","terrain","unreal import","https://github.com/user/my plugin"}) {testing.expect(t,!projects_git_link(text),text)}
}

@(test)
projects_read_the_branch_of_the_repository_they_are_in :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"projects")
    if folder=="" {return}
    root:=project.path_absolute(folder,context.temp_allocator)
    inner:=project.path(root,"games/racer",allocator=context.temp_allocator)
    testing.expect(t,base.make_directory_all(inner)==nil)
    repository,_:=projects_branch(inner)
    testing.expect(t,!repository)
    testing.expect(t,base.make_directory_all(project.path(root,".git",allocator=context.temp_allocator))==nil)
    testing.expect(t,os.write_entire_file(project.path(root,".git/HEAD",allocator=context.temp_allocator),"ref: refs/heads/main\n")==nil)
    branch:[64]u8
    repository,branch=projects_branch(inner)
    testing.expect(t,repository)
    testing.expect_value(t,base.text_get(branch[:]),"main")
}

@(test)
projects_show_their_thumbnail_or_the_view_of_their_start_scene :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"projects")
    if folder=="" {return}
    root:=project.path_absolute(folder,context.temp_allocator)
    file:Thumbnail_File
    image:[dynamic]u8
    defer {thumbnail_file_destroy(&file);delete(image)}
    m:=project.manifest_default("racer")
    testing.expect(t,!projects_thumbnail_read(root,&m,THUMBNAIL_SIZE,&file,&image))
    // Desktop/window icon is shown when no thumbnail or captured start scene exists.
    icon_pic:=img.Image{pixels=make([]u8,2*2*4,context.temp_allocator),width=2,height=2}
    for i in 0..<4 {copy(icon_pic.pixels[i*4:][:4],([]u8{20,40,200,255}))}
    testing.expect_value(t,img.image_write(project.path(root,"icon.png",allocator=context.temp_allocator),icon_pic),img.Error.None)
    base.text_set(m.icon[:],"icon.png")
    if testing.expect(t,projects_thumbnail_read(root,&m,THUMBNAIL_SIZE,&file,&image)) {
        testing.expect_value(t,[4]u8{image[0],image[1],image[2],image[3]},[4]u8{20,40,200,255})
    }
    // The view an editor of the project kept of its start scene takes precedence over the icon,
    // even when only the large captured size is on disk.
    id:=base.Asset_Id{0x7261636572,1}
    base.text_set(m.start_scene[:],"levels/main.scene")
    testing.expect(t,base.make_directory_all(project.path(root,ASSETS_FOLDER,"levels",allocator=context.temp_allocator))==nil)
    w:serial.Writer
    serial.writer_init(&w,allocator=context.temp_allocator)
    scratch:=make([dynamic]u8,context.temp_allocator)
    testing.expect_value(t,asset.blob_build(&w,asset.KIND_SCENE,0,id,{},{},nil,&scratch),asset.Error.None)
    testing.expect(t,os.write_entire_file(project.path(root,ASSETS_FOLDER,"levels/main.scene",allocator=context.temp_allocator),serial.writer_bytes(&w))==nil)
    // Scene has no captured view yet -> still falls back to desktop icon.
    if testing.expect(t,projects_thumbnail_read(root,&m,THUMBNAIL_SIZE,&file,&image)) {
        testing.expect_value(t,[4]u8{image[0],image[1],image[2],image[3]},[4]u8{20,40,200,255})
    }
    large_view:=make([]u8,THUMBNAIL_LARGE*THUMBNAIL_LARGE*4,context.temp_allocator)
    for i in 0..<THUMBNAIL_LARGE*THUMBNAIL_LARGE {large_view[i*4+1],large_view[i*4+3]=180,255}
    testing.expect(t,thumbnail_save(thumbnail_folder_of(root),id,THUMBNAIL_LARGE,THUMBNAIL_CAPTURED,large_view,&file))
    // A thumbnail the manifest names and the project does not have leaves the view.
    base.text_set(m.thumbnail[:],"art/cover.png")
    if testing.expect(t,projects_thumbnail_read(root,&m,THUMBNAIL_SIZE,&file,&image)) {
        testing.expect_value(t,[4]u8{image[0],image[1],image[2],image[3]},[4]u8{0,180,0,255})
    }
    // The PNG goes first: its middle square, with its alpha premultiplied.
    picture:=img.Image{pixels=make([]u8,4*2*4,context.temp_allocator),width=4,height=2}
    for x in 0..<4 {
        for y in 0..<2 {
            pixel:=[4]u8{200,100,0,128} if x==1 || x==2 else {0,255,0,255}
            copy(picture.pixels[(y*4+x)*4:][:4],pixel[:])
        }
    }
    testing.expect(t,base.make_directory_all(project.path(root,"art",allocator=context.temp_allocator))==nil)
    testing.expect_value(t,img.image_write(project.path(root,"art/cover.png",allocator=context.temp_allocator),picture),img.Error.None)
    if testing.expect(t,projects_thumbnail_read(root,&m,THUMBNAIL_SIZE,&file,&image)) {
        testing.expect_value(t,len(image),THUMBNAIL_SIZE*THUMBNAIL_SIZE*4)
        for at in ([2]int{0,THUMBNAIL_SIZE*THUMBNAIL_SIZE-1}) {
            testing.expect_value(t,[4]u8{image[at*4],image[at*4+1],image[at*4+2],image[at*4+3]},[4]u8{100,50,0,128})
        }
    }
}

@(test)
projects_open_runs_off_the_frame_and_reports_stages_and_cancel :: proc(t:^testing.T) {
    // Stage labels match each phase of the background opening.
    run:Build_Run
    p:=Projects{run=&run}
    Case :: struct {stage:Build_Stage,label:string}
    for c in ([]Case{{.Preparing,"Generating the world"},{.Building,"Building the editor"},{.Importing,"Refreshing assets"},{.Shaders,"Building the shaders"}}) {
        intrinsics.atomic_store(&run.stage,c.stage)
        testing.expect_value(t,projects_doing(&p),c.label)
    }
    p.cancelling=true
    testing.expect_value(t,projects_doing(&p),"Cancelling")
    p.cancelling=false
    stub:install.Job
    p.install=&stub
    testing.expect_value(t,projects_doing(&p),"Installing plugins")
    p={}

    // Opening a project with a broken manifest runs on the build thread and reports its error on poll.
    folder:=base.test_folder(t,"projects-open")
    if folder=="" {return}
    root:=project.path_absolute(folder,context.temp_allocator)
    engine:=project.path(root,"engine",allocator=context.temp_allocator)
    bad:=project.path(root,"bad",allocator=context.temp_allocator)
    if !testing.expect(t,base.make_directory_all(engine)==nil && base.make_directory_all(bad)==nil) {return}
    if !testing.expect(t,os.write_entire_file(project.path(bad,project.PROJECT_FILE,allocator=context.temp_allocator),"{invalid")==nil) {return}
    s:=Session{projects=&p,engine_root=engine}
    defer projects_cancel(&s)
    testing.expect_value(t,projects_open(&s,bad),"")
    testing.expect(t,projects_opening(&p) && p.run!=nil,"opening starts immediately on a background thread")
    started:=time.tick_now()
    for projects_opening(&p) && time.tick_since(started)<10*time.Second {
        projects_poll(&s)
        time.sleep(time.Millisecond)
    }
    testing.expect(t,!projects_opening(&p))
    testing.expect(t,!p.next)
    testing.expectf(t,strings.contains(string(p.error[:p.error_length]),"is not a project"),"manifest error reported: %q",string(p.error[:p.error_length]))

    // Cancelling an opening request does not start the project.
    p.error_length=0
    testing.expect_value(t,projects_open(&s,bad),"")
    projects_cancel_request(&s)
    started=time.tick_now()
    for projects_opening(&p) && time.tick_since(started)<10*time.Second {
        projects_poll(&s)
        time.sleep(time.Millisecond)
    }
    testing.expect(t,!projects_opening(&p) && !p.cancelling && !p.next)
}

// A project whose shaders could not be built does not open: the Launcher says why and starts
// nothing, as for a build that failed.
@(test)
projects_open_says_why_its_shaders_failed :: proc(t:^testing.T) {
    a:=runtime.heap_allocator()
    r:=new(Build_Run,a)
    r.opened,r.done=true,true
    r.job=new(build.Job,a)
    r.job.allocator,r.job.result.status=a,.Built
    r.shaders=new(build.Shaders_Job,a)
    r.shaders.allocator=a
    r.shaders.result={status=.Failed,message="slangc is missing: mirai setup slang installs it"}
    p:=Projects{run=r,launcher=true}
    s:=Session{projects=&p}
    context.logger=log.nil_logger() // the log says it as an error, which is the case here
    projects_poll(&s)
    error:=string(p.error[:p.error_length])
    testing.expect(t,p.run==nil && !p.next && !s.quit,"the editor does not start")
    testing.expectf(t,strings.contains(error,"shaders") && strings.contains(error,"slangc is missing"),"the error says why: %q",error)
}

@(test)
all_projects_discovers_siblings_and_skips_temporary_copies :: proc(t:^testing.T) {
    testing.expect(t,projects_is_temporary("C:/Users/a/proj/.mirai/tmp/copy"))
    testing.expect(t,!projects_is_temporary("C:/Users/a/proj"))

    folder:=base.test_folder(t,"projects-all")
    if folder=="" {return}
    root:=project.path_absolute(folder,context.temp_allocator)
    engine:=project.path(root,"mirai",allocator=context.temp_allocator)
    siblings:=project.path(root,"mirai-projects",allocator=context.temp_allocator)
    make_proj :: proc(t:^testing.T,dir,name:string) {
        testing.expect(t,base.make_directory_all(dir)==nil)
        m:=project.manifest_default(name)
        testing.expect_value(t,project.manifest_write(project.path(dir,project.PROJECT_FILE,allocator=context.temp_allocator),&m).code,project.Error_Code.None)
    }
    make_proj(t,project.path(engine,"demo",allocator=context.temp_allocator),"Demo")
    p_alpha:=project.path(siblings,"alpha",allocator=context.temp_allocator)
    p_zeta:=project.path(siblings,"zeta",allocator=context.temp_allocator)
    p_beta:=project.path(siblings,"beta",allocator=context.temp_allocator)
    make_proj(t,p_alpha,"Alpha")
    make_proj(t,p_zeta,"Zeta")
    make_proj(t,p_beta,"Beta")
    testing.expect(t,base.make_directory_all(project.path(siblings,"not-a-project",allocator=context.temp_allocator))==nil)

    p:=new(Projects)
    defer free(p)
    project.recent_add(&p.recent,project.path(siblings,"gone",allocator=context.temp_allocator),50)
    project.recent_add(&p.recent,p_zeta,100)
    s:=Session{projects=p,engine_root=engine}

    // Recent view shows only what is in recent; its count beside the tabs is that of All projects,
    // without the recent projects that are gone.
    p.view=.Recent
    projects_rows_read(&s)
    testing.expect_value(t,p.row_count,2)
    testing.expect_value(t,base.text_get(p.rows[0].name[:]),"Zeta")
    testing.expect_value(t,p.all_count,4)

    // All projects keeps recent first, then adds siblings & engine demo alphabetically without duplicates.
    p.view=.All
    projects_rows_read(&s)
    testing.expect_value(t,p.row_count,4)
    testing.expect_value(t,p.all_count,4)
    testing.expect_value(t,base.text_get(p.rows[0].name[:]),"Zeta")
    testing.expect_value(t,base.text_get(p.rows[1].name[:]),"Alpha")

    // Team and New project keep the list they go back to; the rows are read
    // again only when the list changes.
    projects_view_set(&s,.Team)
    testing.expect(t,p.view==.Team && projects_list(p)==.All && p.row_count==4,"Team keeps the All list")
    projects_view_set(&s,p.back)
    testing.expect_value(t,p.view,Projects_View.All)
    projects_view_set(&s,.New_Project)
    testing.expect(t,p.view==.New_Project && projects_list(p)==.All && p.row_count==4,"New project keeps the All list")
    projects_view_set(&s,.Recent)
    testing.expect(t,p.view==.Recent && p.row_count==2,"Recent reads its rows again")
    projects_view_set(&s,.All)
    // A failed opening's error, project and package state go as one.
    p.error_length=copy(p.error[:],"the build failed")
    base.text_set(p.failed_opening[:],p_zeta)
    p.error_packages_dirty=true
    projects_error_clear(p)
    testing.expect(t,p.error_length==0 && base.text_get(p.failed_opening[:])=="" && !p.error_packages_dirty,"the error clears whole")
    testing.expect_value(t,base.text_get(p.rows[2].name[:]),"Beta")
    testing.expect_value(t,base.text_get(p.rows[3].name[:]),"Demo")
}

// The New Project dialog has Version control (Kai) checked: the project is a
// Kai workspace of its own whose first change holds its files. Unchecked, the
// project has no version control and the store is not touched.
@(test)
a_new_project_is_a_kai_workspace_unless_unchecked :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"projects-kai")
    if folder=="" {return}
    root:=project.path_absolute(folder,context.temp_allocator)
    engine:=project.path(root,"engine",allocator=context.temp_allocator)
    template:=project.path(engine,"templates","empty",allocator=context.temp_allocator)
    testing.expect(t,base.make_directory_all(template)==nil)
    m:=project.manifest_default("Template")
    testing.expect_value(t,project.manifest_write(project.path(template,project.PROJECT_FILE,allocator=context.temp_allocator),&m).code,project.Error_Code.None)
    opened,error:=store.open(project.path(root,"store",allocator=context.temp_allocator))
    if !testing.expect_value(t,error,store.Error.None) {return}
    defer store.close(&opened)
    p:=new(Projects);defer free(p)
    s:=Session{projects=p,engine_root=engine,store=opened}
    projects_show(&s)
    Case :: struct {name:string,kai:bool}
    for c in ([]Case{{"checked",true},{"unchecked",false}}) {
        projects_new_start(&s,-1)
        testing.expect(t,p.kai,"Version control (Kai) starts checked")
        p.kai=c.kai
        p.name_length=copy(p.name[:],c.name)
        p.location_length=copy(p.location[:],root)
        made,message:=projects_make(&s)
        if !testing.expectf(t,message=="","%s: %s",c.name,message) {continue}
        testing.expect(t,os.is_file(project.path(made,project.PROJECT_FILE,allocator=context.temp_allocator)))
        testing.expectf(t,ka.project_exists(made)==c.kai,"%s: a Kai workspace is %v",c.name,c.kai)
    }
}

// The launcher's tabs and actions sit below the bar that drags the window on
// every platform: the window takes a press there before any control sees it.
@(test)
the_launcher_keeps_its_tabs_below_the_bar_that_drags_the_window :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    if !prefab_fixture_init(t,f,"projects-bar") {return}
    defer prefab_fixture_destroy(f)
    s:=&f.s
    ctx:ui.Context
    if !testing.expect(t,test_ui_init(&ctx,{})) {return}
    defer ui.context_destroy(&ctx)
    f.gui.ctx,f.gui.begun=&ctx,true
    p:=new(Projects);defer free(p)
    s.projects=p
    defer s.projects=nil
    s.headless=false
    size:=[2]f32{f32(PROJECTS_WINDOW.x),f32(PROJECTS_WINDOW.y)}
    for _ in 0..<2 {
        ui.frame_begin(&ctx,{size=size,pointer_absent=true})
        if ui.box(&ctx,{width=ui.fixed(size.x),height=ui.fixed(size.y)}) {projects_body(s,false)}
        ui.frame_end(&ctx)
    }
    bar:=ui.metric(&ctx,"bar_height")
    for name in ([]string{"projects_tab_recent","projects_tab_all","projects_team","projects_refresh","projects_search","projects_open"}) {
        rect,found:=ui.widget_rect(&ctx,ui.id(&ctx,name))
        testing.expectf(t,found && rect.y>=bar,"%s at %v is not below the bar of %v",name,rect,bar)
    }
}

// Linked Kai workspaces show Publish when ahead of shared main, transition to
// Synced when published directly from the Launcher, and pick up later changes
// on explicit Refresh.
@(test)
projects_list_refreshes_and_publishes_linked_workspaces :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"projects-publish")
    if folder=="" {return}
    root:=project.path_absolute(folder,context.temp_allocator)
    proj:=project.path(root,"game",allocator=context.temp_allocator)
    testing.expect(t,base.make_directory_all(proj)==nil)
    m:=project.manifest_default("Game")
    testing.expect_value(t,project.manifest_write(project.path(proj,project.PROJECT_FILE,allocator=context.temp_allocator),&m).code,project.Error_Code.None)

    opened,se:=store.open(project.path(root,"store",allocator=context.temp_allocator))
    if !testing.expect_value(t,se,store.Error.None) {return}
    defer store.close(&opened)

    p:=new(Projects);defer free(p)
    p.shown=true
    project.recent_add(&p.recent,proj,100)
    k:Kai
    k.mesh_loopback=true
    s:=Session{projects=p,store=opened,kai=&k}
    defer projects_cancel(&s)
    defer kai_team_close(&s)
    kai_team_open(&s)
    if !testing.expect(t,s.kai.team!=nil && s.kai.team.status!=.Closed) {return}
    team:=&s.kai.team.team
    testing.expect_value(t,vcs.team_profile_set(team,"ana","mac"),vcs.Error.None)
    org,oe:=vcs.team_org_create(team,"studio")
    if !testing.expect_value(t,oe,vcs.Error.None) {return}

    kp:ka.Project
    if !testing.expect_value(t,ka.project_create(&kp,proj,&s.store),vcs.Error.None) {return}
    _,je:=ka.project_join(&kp,team,org,false)
    ka.project_close(&kp)
    if !testing.expect_value(t,je,vcs.Error.None) {return}

    projects_rows_read(&s)
    if !testing.expect_value(t,p.row_count,1) {return}
    testing.expect(t,p.rows[0].sync==.Unpublished && p.rows[0].can_publish,"linked unpublished workspace offers Publish")
    testing.expectf(t,p.rows[0].bytes>0 && base.text_get(p.rows[0].size[:])!="","local Kai project reports its size: %d (%q)",p.rows[0].bytes,base.text_get(p.rows[0].size[:]))

    kai_launcher_publish(&s,proj)
    testing.expect(t,p.rows[0].sync==.Synced,"after direct publish the workspace shows Synced")

    // Edit and snapshot the workspace externally; explicit Refresh picks up Publish again.
    testing.expect(t,os.write_entire_file(project.path(proj,"notes.txt",allocator=context.temp_allocator),transmute([]u8)string("updated\n"))==nil)
    if !testing.expect_value(t,ka.project_open(&kp,proj,&s.store),vcs.Error.None) {return}
    _,snap_err:=ka.snapshot(&kp.workspace)
    ka.project_close(&kp)
    testing.expect_value(t,snap_err,vcs.Error.None)

    kai_team_refresh(&s)
    testing.expect(t,p.rows[0].sync==.Ahead && p.rows[0].can_publish,"Refresh reflects new unpublished changes")

    // A non-Kai local project is scanned off-thread so projects_rows_read never blocks the UI thread.
    plain:=project.path(root,"plain",allocator=context.temp_allocator)
    testing.expect(t,base.make_directory_all(project.path(plain,".mirai",allocator=context.temp_allocator))==nil)
    pm:=project.manifest_default("Plain")
    testing.expect_value(t,project.manifest_write(project.path(plain,project.PROJECT_FILE,allocator=context.temp_allocator),&pm).code,project.Error_Code.None)
    testing.expect(t,os.write_entire_file(project.path(plain,"data.bin",allocator=context.temp_allocator),make([]u8,2048,context.temp_allocator))==nil)
    testing.expect(t,os.write_entire_file(project.path(plain,".mirai","cache.bin",allocator=context.temp_allocator),make([]u8,65536,context.temp_allocator))==nil)
    project.recent_add(&p.recent,plain,90)
    projects_rows_read(&s)
    deadline:=time.tick_now()
    for p.size_task!=nil && time.tick_since(deadline)<5*time.Second {
        projects_poll(&s)
        time.sleep(5*time.Millisecond)
    }
    plain_idx:=-1
    for i in 0..<p.row_count {
        if project.path_same(base.text_get(p.rows[i].path[:]),plain) {plain_idx=i;break}
    }
    testing.expectf(t,plain_idx>=0 && p.rows[plain_idx].has_size && p.rows[plain_idx].bytes>=2048 && p.rows[plain_idx].bytes<65536,"off-thread scan computes non-Kai project size skipping .mirai: idx=%d bytes=%d",plain_idx,plain_idx>=0?p.rows[plain_idx].bytes:0)

    testing.expect(t,!projects_refresh_cooling(p),"Refresh starts ready")
    p.refreshed_at=time.tick_now()
    testing.expect(t,projects_refresh_cooling(p),"Refresh cools down right after click")
    p.refreshed_at=time.Tick{_nsec=time.tick_now()._nsec-i64(PROJECTS_REFRESH_COOLDOWN+time.Millisecond)}
    testing.expect(t,!projects_refresh_cooling(p),"Refresh is ready again after 1 second")
}

// Mouse-wheel scrolling works over non-interactive space in the Launcher's Team
// view (projects_build must register its root blocking box with a valid id so
// wheel_target routes into projects_team_view).
@(test)
the_launcher_team_view_scrolls_with_the_wheel :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    if !prefab_fixture_init(t,f,"projects-team-scroll") {return}
    defer prefab_fixture_destroy(f)
    s:=&f.s
    opened,se:=store.open(project.path(f.root,"store",allocator=context.temp_allocator))
    if !testing.expect_value(t,se,store.Error.None) {return}
    defer store.close(&opened)
    s.store=opened
    k:Kai
    k.mesh_loopback=true
    s.kai=&k
    defer kai_team_close(s)
    kai_team_open(s)
    if !testing.expect(t,s.kai.team!=nil && s.kai.team.status!=.Closed) {return}
    team:=&s.kai.team.team
    testing.expect_value(t,vcs.team_profile_set(team,"ana","mac"),vcs.Error.None)
    for i in 0..<10 {
        _,oe:=vcs.team_org_create(team,fmt.tprintf("org-%d",i))
        if !testing.expect_value(t,oe,vcs.Error.None) {return}
    }
    kai_team_wrote(s)

    ctx:ui.Context
    if !testing.expect(t,test_ui_init(&ctx,{})) {return}
    defer ui.context_destroy(&ctx)
    f.gui.ctx,f.gui.begun=&ctx,true
    p:=new(Projects);defer free(p)
    p.shown,p.view=true,.Team
    s.projects=p
    s.headless=true
    defer s.projects=nil
    size:=[2]f32{f32(PROJECTS_WINDOW.x),420}
    for _ in 0..<2 {
        ui.frame_begin(&ctx,{size=size,pointer_absent=true})
        projects_build(s)
        ui.frame_end(&ctx)
    }
    area,found:=ui.widget_rect(&ctx,ui.id(&ctx,"projects_team_view"))
    if !testing.expect(t,found,"projects_team_view exists") {return}
    // Place pointer inside the scroll area over non-interactive padding/gap and scroll down.
    pt:=[2]f32{area.x+4,area.y+area.h-4}
    ui.frame_begin(&ctx,{size=size,pointer=pt,wheel={0,-3}})
    projects_build(s)
    ui.frame_end(&ctx)
    testing.expectf(t,p.scroll.y>0,"wheel scrolls Team view in Launcher: scroll=%v",p.scroll)

    // Returning to the launcher from an open project queues the empty template with --launcher and clears on cancel.
    template:=project.path(f.root,"templates","empty",allocator=context.temp_allocator)
    testing.expect(t,base.make_directory_all(template)==nil)
    old_engine:=s.engine_root
    defer s.engine_root=old_engine
    s.engine_root=f.root
    p.launcher=false
    p.shown=true
    projects_return_to_launcher(s)
    testing.expect(t,p.next && p.next_launcher && !p.shown,"return to launcher queues next_launcher and closes modal")
    testing.expect(t,project.path_same(base.text_get(p.opening[:]),template),"return to launcher targets empty template")
    projects_next_cancel(s)
    testing.expect(t,!p.next && !p.next_launcher,"cancel clears pending launcher return")

    // Long launcher errors wrap onto multiple lines of a read-only field instead of truncating,
    // and can be copied and dismissed.
    p.view=.All
    long_err:="C:/Users/espar/source/repos/mirai/Dreamscape/plugins/unreal/editor/scene/lights.odin(218:16): Undeclared name in render package when building editor library for project"
    p.error_length=copy(p.error[:],long_err)
    for _ in 0..<2 {
        ui.frame_begin(&ctx,{size=size,pointer_absent=true})
        projects_build(s)
        err_frame:=ui.frame_end(&ctx)
        testing.expect(t,!err_frame.overflow && ctx.stats.layout_errors==0,"wrapped error banner lays out cleanly")
    }
    banner:=ui.id(&ctx,"projects_error")
    field_rect,has_field:=ui.widget_rect(&ctx,banner)
    line:=ui.metric(&ctx,"font_small")*ui.TEXT_LINE
    testing.expectf(t,has_field && field_rect.h>2*line,"the field of the error fits its wrapped lines: %v",field_rect)
    copy_rect,has_copy:=ui.widget_rect(&ctx,ui.id_derive(&ctx,banner,"copy"))
    testing.expect(t,has_copy && copy_rect.w>0,"wrapped error banner has copy button")
    dismiss_rect,has_dismiss:=ui.widget_rect(&ctx,ui.id_derive(&ctx,banner,"dismiss"))
    testing.expect(t,has_dismiss && dismiss_rect.w>0,"wrapped error banner has dismiss button")
    p.error_length=0
}

// Remove local copy snapshots a Kai workspace before its folder goes to the Trash: what its
// working copy held stays in the store, the folder leaves the recent projects and its org's
// repository is offered to pull again. The open project, one being opened, the engine, a project
// of the engine, the folder of the store and a folder that is no project are refused.
@(test)
removing_a_local_copy_snapshots_it_and_refuses_unsafe_folders :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"projects-remove")
    if folder=="" {return}
    root:=project.path_absolute(folder,context.temp_allocator)
    join :: proc(parts:..string) -> string {return project.path(..parts,allocator=context.temp_allocator)}
    manifest :: proc(t:^testing.T,at,name:string) {
        testing.expect(t,base.make_directory_all(at)==nil)
        m:=project.manifest_default(name)
        testing.expect_value(t,project.manifest_write(join(at,project.PROJECT_FILE),&m).code,project.Error_Code.None)
    }
    proj:=join(root,"game")
    manifest(t,proj,"Game")
    engine:=join(root,"engine")
    manifest(t,join(engine,"demo"),"Demo")
    plain:=join(root,"plain")
    testing.expect(t,base.make_directory_all(plain)==nil)

    opened,se:=store.open(join(root,"store"))
    if !testing.expect_value(t,se,store.Error.None) {return}
    defer store.close(&opened)
    p:=new(Projects);defer free(p)
    p.shown,p.launcher=true,true
    project.recent_add(&p.recent,proj,100)
    k:Kai
    k.mesh_loopback=true
    s:=Session{projects=p,store=opened,kai=&k,engine_root=engine}
    defer projects_cancel(&s)
    defer kai_team_close(&s)
    kai_team_open(&s)
    if !testing.expect(t,s.kai.team!=nil && s.kai.team.status!=.Closed) {return}
    team:=&s.kai.team.team
    testing.expect_value(t,vcs.team_profile_set(team,"ana","mac"),vcs.Error.None)
    org,oe:=vcs.team_org_create(team,"studio")
    if !testing.expect_value(t,oe,vcs.Error.None) {return}
    kp:ka.Project
    if !testing.expect_value(t,ka.project_create(&kp,proj,&s.store),vcs.Error.None) {return}
    _,je:=ka.project_join(&kp,team,org,false)
    testing.expect_value(t,je,vcs.Error.None)
    _,_,pe:=ka.publish(&kp,team,ka.BOOKMARK_DEFAULT,"first",nil)
    testing.expectf(t,pe==.None,"publish: %s",team.why)
    ka.project_close(&kp)
    testing.expect(t,os.write_entire_file(join(proj,"notes.txt"),transmute([]u8)string("not published\n"))==nil)
    kai_team_wrote(&s)
    projects_rows_read(&s)
    testing.expect_value(t,projects_unpulled_count(&s),0)

    for x in ([]struct{folder,why:string}{{engine,"holds the engine"},{root,"holds the engine"},{join(engine,"demo"),"part of the engine"},{join(root,"store"),"Kai store"},{plain,"not a Mirai project"},{join(root,"nowhere"),"not a folder"}}) {
        refusal:=projects_remove_refusal(&s,x.folder)
        testing.expectf(t,strings.contains(refusal,x.why),"%s is refused as %q: %q",x.folder,x.why,refusal)
    }
    p.next=true
    testing.expect(t,strings.contains(projects_remove_refusal(&s,proj),"being opened"),"a project being opened stays")
    p.next=false
    s.has_project,s.project_root,p.launcher=true,proj,false
    testing.expect(t,strings.contains(projects_remove_refusal(&s,proj),"open in this editor"),"the open project stays")
    s.has_project,s.project_root,p.launcher=false,"",true
    testing.expect_value(t,projects_remove_refusal(&s,proj),"")

    projects_remove_ask(&s,proj)
    removal,asked:=p.removing.?
    testing.expect(t,asked && project.path_same(base.text_get(removal.folder[:]),proj) && removal.kai && removal.unpublished,"the question names the folder and warns of what no org has")
    _,working,_,_,ok:=vcs.workspace_working_info(&s.store,proj)
    if !testing.expect(t,ok,"the workspace is read") {return}
    held :: proc(s:^store.Store,working:vcs.Revision) -> string {
        c,e:=vcs.change_get(s,working,context.temp_allocator)
        if e!=.None {return ""}
        files:=make([dynamic]vcs.File,context.temp_allocator)
        if vcs.tree_files(s,c.tree,&files,context.temp_allocator)!=.None {return ""}
        for f in files {
            if f.path!="notes.txt" {continue}
            bytes,be:=vcs.file_bytes(s,f.address,context.temp_allocator)
            if be==.None {return string(bytes)}
        }
        return ""
    }
    testing.expect_value(t,held(&s.store,working),"not published\n")

    testing.expect_value(t,projects_remove_local(&s,proj),"")
    testing.expect(t,!os.exists(proj),"the folder is gone")
    testing.expect_value(t,project.recent_count(&p.recent),0)
    testing.expect(t,p.removing==nil,"the question went")
    testing.expect_value(t,held(&s.store,working),"not published\n")
    testing.expect_value(t,projects_unpulled_count(&s),1)
    testing.expect(t,strings.contains(projects_remove_refusal(&s,proj),"not a folder"),"a folder removed is not removed twice")
}

// A linked project the org's main moved past shows Update available and an Update button that
// takes main into it; an opening that failed offers to restore the package pins its working copy
// changed and to clean its build cache; a right click on a row opens its menu, whose Remove local
// copy asks to confirm.
@(test)
the_launcher_offers_update_recovery_and_a_row_menu :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    if !prefab_fixture_init(t,f,"projects-update") {return}
    defer prefab_fixture_destroy(f)
    s:=&f.s
    opened,se:=store.open(project.path(f.root,"store",allocator=context.temp_allocator))
    if !testing.expect_value(t,se,store.Error.None) {return}
    defer store.close(&opened)
    s.store=opened
    k:Kai
    k.mesh_loopback=true
    s.kai=&k
    defer kai_team_close(s)
    kai_team_open(s)
    if !testing.expect(t,s.kai.team!=nil && s.kai.team.status!=.Closed) {return}
    team:=&s.kai.team.team
    testing.expect_value(t,vcs.team_profile_set(team,"ana","mac"),vcs.Error.None)
    org,_:=vcs.team_org_create(team,"studio")

    first:=project.path(f.root,"first",allocator=context.temp_allocator)
    second:=project.path(f.root,"second",allocator=context.temp_allocator)
    testing.expect(t,base.make_directory_all(first)==nil)
    m:=project.manifest_default("Game")
    testing.expect_value(t,project.manifest_write(project.path(first,project.PROJECT_FILE,allocator=context.temp_allocator),&m).code,project.Error_Code.None)
    a:ka.Project
    if !testing.expect_value(t,ka.project_create(&a,first,&s.store),vcs.Error.None) {return}
    defer ka.project_close(&a)
    link,_:=ka.project_join(&a,team,org,false)
    _,_,pe:=ka.publish(&a,team,ka.BOOKMARK_DEFAULT,"first",nil)
    testing.expectf(t,pe==.None,"publish: %s",team.why)
    b:ka.Project
    if !testing.expect_value(t,ka.project_clone(&b,team,second,&s.store,org,link.repo),vcs.Error.None) {return}
    _,ce:=ka.clone_checkout(&b,team)
    ka.project_close(&b)
    testing.expectf(t,ce==.None,"checkout: %s",team.why)
    testing.expect(t,os.write_entire_file(project.path(first,"notes.txt",allocator=context.temp_allocator),transmute([]u8)string("from main\n"))==nil)
    _,_,pe=ka.publish(&a,team,ka.BOOKMARK_DEFAULT,"second",nil)
    testing.expectf(t,pe==.None,"publish: %s",team.why)

    ctx:ui.Context
    if !testing.expect(t,test_ui_init(&ctx,{})) {return}
    defer ui.context_destroy(&ctx)
    f.gui.ctx,f.gui.begun=&ctx,true
    p:=new(Projects);defer free(p)
    p.shown,p.launcher=true,true
    s.projects=p
    s.headless=true
    defer s.projects=nil
    defer projects_cancel(s)
    project.recent_add(&p.recent,second,100)
    projects_rows_read(s)
    if !testing.expect_value(t,p.row_count,1) {return}
    testing.expect(t,p.rows[0].sync==.Behind && p.rows[0].main_here,"the row is behind main, which is here")
    size:=[2]f32{f32(PROJECTS_WINDOW.x),f32(PROJECTS_WINDOW.y)}
    frame :: proc(t:^testing.T,ctx:^ui.Context,s:^Session,input:ui.Input) {
        ui.frame_begin(ctx,input)
        projects_build(s)
        out:=ui.frame_end(ctx)
        testing.expect(t,!out.overflow && ctx.stats.layout_errors==0,"the launcher lays out cleanly")
    }
    for _ in 0..<2 {frame(t,&ctx,s,{size=size,pointer_absent=true})}
    update,has_update:=ui.widget_rect(&ctx,ui.id(&ctx,"project_update",0))
    if !testing.expect(t,has_update && update.w>0,"the row shows Update") {return}
    frame(t,&ctx,s,{size=size,pointer=ui.rect_center(update),down={.Left},pressed={.Left}})
    frame(t,&ctx,s,{size=size,pointer=ui.rect_center(update),released={.Left}})
    text,read_error:=os.read_entire_file(project.path(second,"notes.txt",allocator=context.temp_allocator),context.temp_allocator)
    testing.expect(t,read_error==nil && string(text)=="from main\n","Update wrote main's files")
    testing.expect(t,p.rows[0].sync==.Synced,"the row is synced after Update")

    // An opening that failed with changed pins or a git plugin error offers the matching retries.
    p.error_length=copy(p.error[:],"The build failed: packages")
    base.text_set(p.failed_opening[:],second)
    p.error_packages_dirty=true
    base.text_set(p.error_plugin[:],"unreal")
    for _ in 0..<2 {frame(t,&ctx,s,{size=size,pointer_absent=true})}
    _,has_plugin:=ui.widget_rect(&ctx,ui.id(&ctx,"projects_error_plugin"))
    _,has_pins:=ui.widget_rect(&ctx,ui.id(&ctx,"projects_error_packages"))
    _,has_clean:=ui.widget_rect(&ctx,ui.id(&ctx,"projects_error_clean"))
    testing.expect(t,has_plugin && has_pins && has_clean,"the banner offers Update plugin & retry, Restore package pins & retry and Clean cache & retry")
    p.error_packages_dirty=false
    p.error_plugin={}
    frame(t,&ctx,s,{size=size,pointer_absent=true})
    _,has_plugin=ui.widget_rect(&ctx,ui.id(&ctx,"projects_error_plugin"))
    _,has_pins=ui.widget_rect(&ctx,ui.id(&ctx,"projects_error_packages"))
    testing.expect(t,!has_plugin && !has_pins,"no plugin or pins error: neither button shows")
    p.error_length,p.failed_opening[0]=0,0

    // Extracting a git plugin from a compiler error matches only declared git sources.
    with_source:=project.manifest_default("Game")
    base.text_set(with_source.sources[0].name[:],"unreal")
    base.text_set(with_source.sources[0].url[:],"https://github.com/tomaszbk/mirai-unreal.git")
    base.text_set(with_source.sources[0].commit[:],"0123456789abcdef0123456789abcdef01234567")
    testing.expect_value(t,project.manifest_write(project.path(second,project.PROJECT_FILE,allocator=context.temp_allocator),&with_source).code,project.Error_Code.None)
    Plugin_Case :: struct {text,want:string}
    for c in ([]Plugin_Case{
        {"C:/proj//plugins/unreal/plugins/unreal_vfx/editor/cooked_bridge.odin(165:9) Unknown field 'shadows'","unreal"},
        {"C:\\proj\\plugins\\unreal\\editor\\unreal.odin(12:1) Syntax error","unreal"},
        {"C:/proj/plugins/local_only/runtime/a.odin(1:1) Error",""},
        {"C:/proj/game/game.odin(1:1) Error",""},
    }) {
        testing.expect_value(t,projects_error_plugin(second,c.text),c.want)
    }
    testing.expect_value(t,project.manifest_write(project.path(second,project.PROJECT_FILE,allocator=context.temp_allocator),&m).code,project.Error_Code.None)

    // A right click opens the row's menu.
    frame(t,&ctx,s,{size=size,pointer_absent=true})
    row,has_row:=ui.widget_rect(&ctx,ui.id(&ctx,"project_row",0))
    if !testing.expect(t,has_row,"the row is laid out") {return}
    frame(t,&ctx,s,{size=size,pointer=ui.rect_center(row),down={.Right},pressed={.Right}})
    frame(t,&ctx,s,{size=size,pointer=ui.rect_center(row),released={.Right}})
    testing.expect(t,ui.popup_is_open(&ctx,projects_menu_id(s)),"the right click opens the row menu")
    projects_remove_ask(s,second)
    second_removal,second_asked:=p.removing.?
    testing.expect(t,second_asked && project.path_same(base.text_get(second_removal.folder[:]),second) && second_removal.kai && !second_removal.unpublished,"a synced workspace asks without the warning")
    for _ in 0..<2 {frame(t,&ctx,s,{size=size,pointer_absent=true})}
    _,has_confirm:=ui.widget_rect(&ctx,shell_id(s.gui,"projects_remove_confirm"))
    testing.expect(t,has_confirm,"the confirmation shows")
    p.removing=nil
}
