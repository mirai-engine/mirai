package editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:editor/api"
import "mirai:host"
import gpu "mirai:render"
import "mirai:std/jobs"
import "mirai:std/base"
import mm "mirai:std/math"

@(test)
capture_paths_take_git_bash_drives_and_are_relative_to_the_project :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    root:="C:/games/demo" when ODIN_OS==.Windows else "/games/demo"
    resolved :: proc(t:^testing.T,root,path,expected:string,loc:=#caller_location) {
        file,problem:=api_file_path(root,path)
        testing.expectf(t,problem=="" && file==expected,"%s: %s %s",path,file,problem,loc=loc)
    }
    resolved(t,root,"shots/a.png",fmt.tprintf("%s/shots/a.png",root))
    resolved(t,root,"shots/../a.png",fmt.tprintf("%s/a.png",root))
    when ODIN_OS==.Windows {
        resolved(t,root,"/c/Users/me/shots/a.png","C:/Users/me/shots/a.png")
        resolved(t,root,"D:\\shots\\b.png","D:/shots/b.png")
        _,rooted:=api_file_path(root,"/tmp/a.png")
        testing.expect(t,strings.contains(rooted,"C:/...") && strings.contains(rooted,"the folder of the project, C:/games/demo"),rooted)
    } else {
        resolved(t,root,"/tmp/a.png","/tmp/a.png")
    }
    _,problem:=api_file_path(root,"")
    testing.expect(t,strings.contains(problem,"path is required"),problem)
}

@(test)
a_capture_given_a_path_answers_where_it_is_and_no_image :: proc(t:^testing.T) {
    file:="C:/shots/a.png"
    seen:=Api_Capture_Seen{textures_pending=2,instances_culled=5}
    for shown in ([2]bool{false,true}) {
        method:=api.Method{result_id=Api_Capture_Result}
        result:Api_Capture_Result
        play:=api.Call{method=&method,result=&result,allocator=context.temp_allocator}
        api_capture_reply(&play,file,64,32,shown,seen)
        testing.expect(t,result.path==file && result.width==64 && result.height==32 && result.seen==seen)
        testing.expect_value(t,play.image,shown?file:"")
    }
}

@(test)
a_capture_without_a_path_goes_under_the_captures_of_its_project :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    root:=base.test_folder(t,"capture-default")
    if root=="" {return}
    call:=api.Call{allocator=context.temp_allocator}
    inside:=Session{project_root=root}
    file,ok:=api_capture_file(&inside,&call,"","editor.png")
    testing.expect(t,ok && file==fmt.tprintf("%s/.mirai/captures/editor.png",root),file)
    alone:Session
    _,ok=api_capture_file(&alone,&call,"","editor.png")
    testing.expect(t,!ok && call.error.code==api.INVALID_PARAMS && strings.contains(call.error.message,"path is required"),call.error.message)
}

@(test)
a_scaled_capture_averages_what_each_pixel_covers :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    source:=[]u8{0,0,0,255, 100,100,100,255, 100,100,100,255, 200,200,200,255}
    cases:=[?]struct{size:[2]i32,first:[4]u8}{
        {{1,1},{100,100,100,255}},
        {{2,1},{50,50,50,255}},
        {{2,2},{0,0,0,255}},
        {{4,4},{0,0,0,255}},
    }
    for c in cases {
        scaled,ok:=api_pixels_scale(source,2,2,c.size,context.allocator)
        testing.expectf(t,ok && len(scaled)==int(c.size.x*c.size.y)*4,"%v",c.size)
        if ok {testing.expectf(t,[4]u8{scaled[0],scaled[1],scaled[2],scaled[3]}==c.first,"%v: %v",c.size,scaled[:4])}
    }
    _,ok:=api_pixels_scale(source,3,3,{1,1},context.allocator)
    testing.expect(t,!ok,"pixels shorter than their size")
}

@(test)
a_capture_makes_its_folder_and_says_why_it_cannot_write :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    folder:=base.test_folder(t,"capture-output")
    if folder=="" {return}
    file:=fmt.tprintf("%s/new/deeper/a.png",folder)
    problem,_:=api_output_prepare(file)
    testing.expect_value(t,problem,"")
    testing.expect(t,os.is_dir(fmt.tprintf("%s/new/deeper",folder)),"the folder is made")
    testing.expect(t,!os.exists(file),"nothing is left where the image goes")
    code:int
    problem,code=api_output_prepare(fmt.tprintf("%s/new",folder))
    testing.expect(t,code==api.INVALID_PARAMS && strings.contains(problem,"is a folder"),problem)
    blocker:=fmt.tprintf("%s/blocker",folder)
    testing.expect(t,os.write_entire_file(blocker,"x")==nil)
    problem,code=api_output_prepare(fmt.tprintf("%s/inside/a.png",blocker))
    testing.expectf(t,code==api.SERVER_ERROR && strings.contains(problem,"could not be made: "),"a file where a folder goes: %s",problem)

    // The file is taken after the check: the write says why it could not, and leaves no part of it.
    app:=host.App{allocator=context.allocator}
    if !testing.expect(t,jobs.system_init(&app.jobs,{threads=0,allocator=context.allocator})) {return}
    defer jobs.system_destroy(&app.jobs)
    session:=Session{app=&app}
    taken:=fmt.tprintf("%s/inside/a.png",blocker)
    problem=api_png_write(&session,taken,make([]u8,4),1,1)
    testing.expectf(t,strings.contains(problem,taken) && strings.contains(problem,"could not be written: "),"%s",problem)
    written:=fmt.tprintf("%s/new/a.png",folder)
    testing.expect_value(t,api_png_write(&session,written,make([]u8,4),1,1),"")
    testing.expect(t,os.is_file(written),"and it writes the file")
}

// The lines of debug: the world box of each mesh drawn, those of the entity
// followed in their own color, the path and the overlays plugins register by
// name; a name no overlay has fails listing those there are.
@(test)
capture_debug_draws_the_overlays_it_names_and_refuses_a_name_none_has :: proc(t:^testing.T) {
    f:=new(Spatial_Fixture);defer free(f)
    if !spatial_open(t,f) {return}
    defer spatial_close(f)
    core.add(&f.w.hidden,f.boulder,{})
    core.settle(&f.info,&f.w,nil)
    storage:[1024]gpu.Debug_Vertex
    lines:=gpu.debug_lines_make(storage[:],depth_test=false)
    call:=api.Call{allocator=context.temp_allocator}
    w:=edited_world(&f.s)
    names:[3][API_CAPTURE_OVERLAY_NAME]u8
    base.text_set(names[0][:],"bounds");base.text_set(names[1][:],"marks");base.text_set(names[2][:],"trajectory")
    overlays,known:=api_capture_overlays(&f.s,&call,names[:])
    if !testing.expect(t,known,call.error.message) {return}
    testing.expect(t,overlays.bounds && overlays.trajectory && overlays.count==1,"bounds, trajectory and the overlay of the plugin")
    trail:=[][3]f32{{0,0,0},{1,0,0},{2,0,1}}
    api_capture_debug_draw(&f.s,w,&overlays,f.crate,trail,&lines)
    followed,boxed,path,marks:=0,0,0,0
    for vertex in storage[:lines.count] {
        switch vertex.color {
        case mm.rgba8_pack(API_CAPTURE_FOLLOWED):  followed+=1
        case mm.rgba8_pack(API_CAPTURE_BOUNDS):    boxed+=1
        case mm.rgba8_pack(API_CAPTURE_TRAIL):     path+=1
        case mm.rgba8_pack(SPATIAL_OVERLAY_COLOR): marks+=1
        }
    }
    // Floor and ramp, and crate with its lid; the hidden boulder draws none.
    testing.expectf(t,boxed==2*24 && followed==2*24,"boxes: %d of others, %d followed",boxed,followed)
    testing.expectf(t,path>2*2,"the path and its end: %d",path)
    testing.expect_value(t,marks,2)
    // Only what it names: the overlay of the plugin alone.
    only:[1][API_CAPTURE_OVERLAY_NAME]u8
    base.text_set(only[0][:],"marks")
    overlays,known=api_capture_overlays(&f.s,&call,only[:])
    testing.expect(t,known && !overlays.bounds && !overlays.trajectory && overlays.count==1)
    unknown:[2][API_CAPTURE_OVERLAY_NAME]u8
    base.text_set(unknown[0][:],"bounds");base.text_set(unknown[1][:],"skeleton")
    _,known=api_capture_overlays(&f.s,&call,unknown[:])
    testing.expect(t,!known && call.failed && call.error.code==api.INVALID_PARAMS,call.error.message)
    testing.expectf(t,strings.contains(call.error.message,`"skeleton"`) && strings.contains(call.error.message,"bounds, trajectory, marks"),"%s",call.error.message)
}
