package build

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:project"
import "mirai:std/base"

@(test)
build_fingerprint_ignores_tests_and_tracks_runtime_source_changes :: proc(t:^testing.T) {
    folder,error:=os.make_directory_temp("","mirai-fingerprint-*",context.temp_allocator)
    if !testing.expect(t,error==nil) {return}
    folder=project.path_absolute(folder,context.temp_allocator)
    defer os.remove_all(folder)
    source:=project.path(folder,"main.odin",allocator=context.temp_allocator)
    added:=project.path(folder,"added.odin",allocator=context.temp_allocator)
    tests:=project.path(folder,"main_test.odin",allocator=context.temp_allocator)
    compiler:=project.path(folder,"compiler","odin",allocator=context.temp_allocator)
    if !testing.expect(t,os.write_entire_file(source,"package main")==nil) {return}
    original,latest:=fingerprint(folder,compiler,nil,{source})

    for text in ([]string{"package main","package main\n@(test) example :: proc() {}"}) {
        if !testing.expect(t,os.write_entire_file(tests,text)==nil) {return}
        current,current_latest:=fingerprint(folder,compiler,nil,{source})
        testing.expect_value(t,current,original)
        testing.expect_value(t,time.diff(latest,current_latest),time.Duration(0))
    }
    if !testing.expect(t,os.remove(tests)==nil) {return}
    without_tests,_:=fingerprint(folder,compiler,nil,{source})
    testing.expect_value(t,without_tests,original)

    if !testing.expect(t,os.write_entire_file(added,"package main")==nil) {return}
    with_added,_:=fingerprint(folder,compiler,nil,{source})
    testing.expect(t,with_added!=original)
    if !testing.expect(t,os.write_entire_file(added,"package main\nvalue :: 1")==nil) {return}
    with_edit,_:=fingerprint(folder,compiler,nil,{source})
    testing.expect(t,with_edit!=with_added)
    if !testing.expect(t,os.remove(added)==nil) {return}
    with_removed,_:=fingerprint(folder,compiler,nil,{source})
    testing.expect_value(t,with_removed,original)
}

@(test)
build_fingerprint_follows_content_not_dates_checkouts_or_thread_counts :: proc(t:^testing.T) {
    roots:[2]string
    for &root in roots {
        folder,error:=os.make_directory_temp("","mirai-fingerprint-root-*",context.temp_allocator)
        if !testing.expect(t,error==nil) {return}
        root=project.path_absolute(folder,context.temp_allocator)
        if !testing.expect(t,os.make_directory_all(project.path(root,"core",allocator=context.temp_allocator))==nil) {return}
    }
    defer for root in roots {os.remove_all(root)}
    hashes:[2]u64
    for root,i in roots {
        source:=project.path(root,"core","core.odin",allocator=context.temp_allocator)
        if !testing.expect(t,os.write_entire_file(source,"package core")==nil) {return}
        if !testing.expect(t,os.change_times(source,time.unix(i64(100+i),0),time.unix(i64(100+i),0))==nil) {return}
        flags:=[]string{"-o:speed",fmt.tprintf("-collection:mirai=%s",root)}
        hashes[i],_=fingerprint(root,"odin",flags,{source})
    }
    testing.expect_value(t,hashes[1],hashes[0])
    source:=project.path(roots[0],"core","core.odin",allocator=context.temp_allocator)
    threaded,_:=fingerprint(roots[0],"odin",{"-o:speed",fmt.tprintf("-collection:mirai=%s",roots[0]),"-thread-count:2"},{source})
    testing.expect_value(t,threaded,hashes[0])
    if !testing.expect(t,os.write_entire_file(source,"package core\nvalue :: 1")==nil) {return}
    edited,_:=fingerprint(roots[0],"odin",{"-o:speed",fmt.tprintf("-collection:mirai=%s",roots[0])},{source})
    testing.expect(t,edited!=hashes[0])
}

// A checkout tells its compiler by its date. Unpacking a package of the
// engine dates its compiler anew: that one counts by the manifest of the
// package, so the plugin libraries the package brings stand. An installed
// engine compiles with its own compiler, whatever MIRAI_ODIN names.
@(test)
the_compiler_of_an_installed_engine_counts_by_its_manifest_not_its_date :: proc(t:^testing.T) {
    folder,error:=os.make_directory_temp("","mirai-installed-compiler-*",context.temp_allocator)
    if !testing.expect(t,error==nil) {return}
    root:=project.path_absolute(folder,context.temp_allocator)
    defer os.remove_all(root)
    compiler:=project.path(root,".deps","odin","dist",strings.concatenate({"odin",EXECUTABLE_EXTENSION},context.temp_allocator),allocator=context.temp_allocator)
    if !testing.expect(t,os.make_directory_all(project.path(root,".deps","odin","dist",allocator=context.temp_allocator))==nil) {return}
    if !testing.expect(t,os.write_entire_file(compiler,"compiler")==nil) {return}
    dated :: proc(t:^testing.T,root,compiler:string,at:i64) -> u64 {
        testing.expect(t,os.change_times(compiler,time.unix(at,0),time.unix(at,0))==nil)
        hash,_:=fingerprint(root,compiler,nil,nil)
        return hash
    }
    testing.expect(t,dated(t,root,compiler,100)!=dated(t,root,compiler,200))
    m:project.Engine_Manifest
    base.text_set(m.version[:],project.ENGINE_VERSION)
    base.text_set(m.commit[:],"one")
    if !testing.expect_value(t,project.engine_manifest_write(root,&m).code,project.Error_Code.None) {return}
    found,ok:=compiler_find(root,context.temp_allocator)
    testing.expect(t,ok && found==compiler,found)
    installed:=dated(t,root,compiler,300)
    testing.expect_value(t,dated(t,root,compiler,400),installed)
    base.text_set(m.commit[:],"another")
    if !testing.expect_value(t,project.engine_manifest_write(root,&m).code,project.Error_Code.None) {return}
    testing.expect(t,dated(t,root,compiler,400)!=installed,"another package is another compiler")
}

@(test)
tool_refresh_ignores_newer_tests_and_tracks_runtime_and_loaded_files :: proc(t:^testing.T) {
    folder,error:=os.make_directory_temp("","mirai-refresh-*",context.temp_allocator)
    if !testing.expect(t,error==nil) {return}
    folder=project.path_absolute(folder,context.temp_allocator)
    defer os.remove_all(folder)
    source:=project.path(folder,"main.odin",allocator=context.temp_allocator)
    tests:=project.path(folder,"main_test.odin",allocator=context.temp_allocator)
    imported:=project.path(folder,"lib","lib.odin",allocator=context.temp_allocator)
    imported_tests:=project.path(folder,"lib","lib_test.odin",allocator=context.temp_allocator)
    if !testing.expect(t,os.make_directory(project.path(folder,"lib",allocator=context.temp_allocator))==nil) {return}
    loaded:=project.path(folder,"data.txt",allocator=context.temp_allocator)
    output:=project.path(folder,"mirai",allocator=context.temp_allocator)
    dependencies:=project.path(folder,"sources.json",allocator=context.temp_allocator)
    for file in ([]string{source,tests,imported,imported_tests,loaded,output}) {
        if !testing.expect(t,os.write_entire_file(file,"data")==nil) {return}
        if !testing.expect(t,os.change_times(file,time.unix(100,0),time.unix(100,0))==nil) {return}
    }
    export:=struct {source_files,load_files:[]string}{source_files={source,imported},load_files={loaded}}
    data,marshal_error:=json.marshal(export,allocator=context.temp_allocator)
    if !testing.expect(t,marshal_error==nil && os.write_entire_file(dependencies,data)==nil) {return}
    if !testing.expect(t,os.change_times(output,time.unix(200,0),time.unix(200,0))==nil) {return}
    if !testing.expect(t,os.change_times(tests,time.unix(300,0),time.unix(300,0))==nil) {return}
    newer,known:=sources_newer(dependencies,output,folder)
    testing.expect(t,known && !newer)

    for file in ([]string{source,loaded}) {
        if !testing.expect(t,os.change_times(file,time.unix(300,0),time.unix(300,0))==nil) {return}
        newer,known=sources_newer(dependencies,output,folder)
        testing.expect(t,known && newer)
        if !testing.expect(t,os.change_times(file,time.unix(100,0),time.unix(100,0))==nil) {return}
    }
    // A build of tests compiled them, and those of the packages it imports.
    newer,known=sources_newer(dependencies,output,folder,tests=true)
    testing.expect(t,known && newer)
    if !testing.expect(t,os.change_times(tests,time.unix(100,0),time.unix(100,0))==nil) {return}
    newer,known=sources_newer(dependencies,output,folder,tests=true)
    testing.expect(t,known && !newer)
    if !testing.expect(t,os.change_times(imported_tests,time.unix(300,0),time.unix(300,0))==nil) {return}
    newer,known=sources_newer(dependencies,output,folder,tests=true)
    testing.expect(t,known && newer,"a test file of an imported package is a source of a build of tests")
    if !testing.expect(t,os.remove(source)==nil) {return}
    newer,known=sources_newer(dependencies,output,folder)
    testing.expect(t,known && newer)
}

// The cap of each process of the compiler: half the memory of the machine
// within its bounds, or the GiB that MIRAI_COMPILER_MEMORY asks for.
@(test)
compiler_memory_is_half_the_machine_within_bounds_or_what_is_asked :: proc(t:^testing.T) {
    GIB :: u64(1)<<30
    Case :: struct {value:string,set:bool,ram:i64,bytes:u64,ok:bool}
    cases:=[?]Case{
        {"",false,32<<30,8*GIB,true},
        {"",false,12<<30,6*GIB,true},
        {"",false,6<<30,4*GIB,true},
        {"",false,0,8*GIB,true},
        {"0",true,32<<30,0,true},
        {"2.5",true,32<<30,GIB*5/2,true},
        {" 12 ",true,6<<30,12*GIB,true},
        {"x",true,32<<30,8*GIB,false},
        {"-1",true,32<<30,8*GIB,false},
        {"nan",true,32<<30,8*GIB,false},
    }
    for c in cases {
        bytes,ok:=compiler_memory_of(c.value,c.set,c.ram)
        testing.expectf(t,bytes==c.bytes && ok==c.ok,"%q with %d bytes of memory: %d %v",c.value,c.ram,bytes,ok)
    }
}

// A job runs one compiler per physical core, as many as the free memory
// holds, at least one, or the count MIRAI_COMPILERS asks for.
@(test)
compilers_at_once_follow_the_cores_and_the_memory_or_what_is_asked :: proc(t:^testing.T) {
    Case :: struct {value:string,set:bool,cores:int,available:i64,count:int,ok:bool}
    cases:=[?]Case{
        {"",false,8,64<<30,8,true},
        {"",false,8,5<<30,2,true},
        {"",false,8,1<<30,1,true},
        {"",false,8,0,8,true},
        {"",false,0,0,1,true},
        {"3",true,8,1<<30,3,true},
        {"0",true,8,64<<30,8,false},
        {"x",true,8,64<<30,8,false},
    }
    for c in cases {
        count,ok:=compilers_at_once_of(c.value,c.set,c.cores,c.available)
        testing.expectf(t,count==c.count && ok==c.ok,"%q with %d cores and %d bytes: %d %v",c.value,c.cores,c.available,count,ok)
    }
}

// A job that built removes the old files other jobs of its target left, but
// not those of a job whose process still runs, however long it takes.
@(test)
a_finished_job_leaves_the_files_of_a_job_that_still_runs :: proc(t:^testing.T) {
    folder,error:=os.make_directory_temp("","mirai-job-files-*",context.temp_allocator)
    if !testing.expect(t,error==nil) {return}
    defer os.remove_all(folder)
    job:=Job{work=folder,target=.Editor,prefix=fmt.tprintf("editor-2-%d",os.get_pid()),started=time.now()}
    job.result.status=.Built
    // Windows numbers processes by fours, and no system goes as far.
    running,ended:=fmt.tprintf("editor-1-%d.err",os.get_pid()),"editor-1-999999999.err"
    old:=time.time_add(job.started,-2*STALE_AFTER)
    for name in ([]string{running,ended}) {
        path:=fmt.tprintf("%s/%s",folder,name)
        testing.expect(t,os.write_entire_file(path,"")==nil && os.change_times(path,old,old)==nil)
    }
    job_files_remove(&job)
    testing.expect(t,os.exists(fmt.tprintf("%s/%s",folder,running)),"the files of a job that runs stay")
    testing.expect(t,!os.exists(fmt.tprintf("%s/%s",folder,ended)),"those of a job that ended go")
}
