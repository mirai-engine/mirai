package editor

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:asset"
import img "mirai:cook/image"
import "mirai:cook/install"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

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
    project.recent_add(&p.recent,p_zeta,100)
    s:=Session{projects=p,engine_root=engine}

    // Recent view shows only what is in recent.
    p.show_all=false
    projects_rows_read(&s)
    testing.expect_value(t,p.row_count,1)
    testing.expect_value(t,base.text_get(p.rows[0].name[:]),"Zeta")

    // All projects keeps recent first, then adds siblings & engine demo alphabetically without duplicates.
    p.show_all=true
    projects_rows_read(&s)
    testing.expect_value(t,p.row_count,4)
    testing.expect_value(t,base.text_get(p.rows[0].name[:]),"Zeta")
    testing.expect_value(t,base.text_get(p.rows[1].name[:]),"Alpha")
    testing.expect_value(t,base.text_get(p.rows[2].name[:]),"Beta")
    testing.expect_value(t,base.text_get(p.rows[3].name[:]),"Demo")
}
