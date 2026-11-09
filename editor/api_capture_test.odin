package editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:editor/api"
import "mirai:host"
import "mirai:project"
import "mirai:std/jobs"
import "mirai:std/base"
import "mirai:std/serial"

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
    context.allocator=context.temp_allocator
    file:="C:/shots/a.png"
    cases:=[?]struct{seen:Api_Capture_Seen,counted:bool}{
        {{textures_pending=2,instances_culled=5},true},
        {{textures_pending=1,instances_drawn=3},true},
        {{},true},
        {{instances_drawn=3,instances_culled=5,instances_occluded=2},false},
    }
    for c in cases {
        for shown in ([2]bool{false,true}) {
            out:serial.Writer
            serial.writer_init(&out)
            defer serial.writer_destroy(&out)
            play:=api.Call{out=&out,allocator=context.temp_allocator}
            api_capture_reply(&play,file,64,32,shown,c.seen)
            text:=string(serial.writer_bytes(&out))
            api_result_shape_expect(t,text,Api_Capture_Result)
            testing.expect(t,strings.contains(text,file) && !strings.contains(text,"content") && !strings.contains(text,"data"),text)
            for key in ([?]string{`"textures_pending"`,`"instances_drawn"`,`"instances_culled"`,`"instances_occluded"`}) {
                testing.expectf(t,strings.contains(text,key)==c.counted,"%v: %s",c.seen,text)
            }
            testing.expect_value(t,play.image,shown?file:"")
        }
    }
}

@(test)
a_capture_without_a_path_goes_under_the_captures_of_its_project :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    root:=project.path_absolute(fmt.tprintf(".mirai/test-capture-default-%d",os.get_pid()))
    defer os.remove_all(root)
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
    folder:=project.path_absolute(fmt.tprintf(".mirai/test-capture-output-%d",os.get_pid()))
    defer os.remove_all(folder)
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
