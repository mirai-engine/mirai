package platform

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"
import "mirai:std/base"

@(private="file")
write :: proc(t:^testing.T,folder,name,text:string) {
    path,_:=filepath.join({folder,name},context.temp_allocator)
    directory:=filepath.dir(path)
    _=os.make_directory_all(directory)
    testing.expect(t,os.write_entire_file(path,text)==nil,name)
}
@(private="file")
remove :: proc(folder,name:string) {
    path,_:=filepath.join({folder,name},context.temp_allocator)
    _=os.remove(path)
}
// Polls until a pass completes and returns its events as sorted "<kind> <path>" lines.
@(private="file")
pass :: proc(t:^testing.T,p:^Platform,watch:Watch,budget:=64,capacity:=16) -> (lines:[]string,polls:int) {
    result:=make([dynamic]string,context.temp_allocator)
    events:=make([]Watch_Event,capacity,context.temp_allocator)
    for polls<100000 {
        count,done:=watch_poll(p,watch,budget,events)
        polls+=1
        for event in events[:count] {append(&result,fmt.tprintf("%v %s",event.kind,event.path))}
        if done {break}
    }
    testing.expect(t,polls<100000,"The pass never completed")
    slice.sort(result[:])
    return result[:],polls
}
@(private="file")
expect_lines :: proc(t:^testing.T,lines:[]string,expected:..string,loc:=#caller_location) {
    joined:=strings.join(lines,", ",context.temp_allocator)
    wanted:=strings.join(expected,", ",context.temp_allocator)
    testing.expect_value(t,joined,wanted,loc)
}

@(test)
watch_reports_created_changed_and_removed_files :: proc(t:^testing.T) {
    p:=test_headless(t)
    defer destroy(p)
    folder:=base.test_folder(t,"watch")
    write(t,folder,"a.txt","one")
    write(t,folder,"sub/b.txt","two")
    write(t,folder,"sub/deep/c.txt","three")
    watch,error:=watch_create(p,{path=folder,recursive=true})
    testing.expect_value(t,error,Watch_Error.None)
    defer watch_destroy(p,watch)
    // What was already there is learned without being reported.
    lines,_:=pass(t,p,watch)
    expect_lines(t,lines)
    testing.expect_value(t,watch_stats(p,watch).files,3)
    lines,_=pass(t,p,watch)
    expect_lines(t,lines)

    write(t,folder,"new.txt","four")
    write(t,folder,"sub/b.txt","two and more")
    remove(folder,"sub/deep/c.txt")
    lines,_=pass(t,p,watch)
    expect_lines(t,lines,"Changed sub/b.txt","Created new.txt","Removed sub/deep/c.txt")
    // Each change is reported once.
    lines,_=pass(t,p,watch)
    expect_lines(t,lines)
    testing.expect_value(t,watch_stats(p,watch).files,3)
    testing.expect_value(t,watch_stats(p,watch).passes,u64(4))

    // The same size written later is a change too: the time of the file says so.
    sleep_coarse(30_000_000)
    write(t,folder,"a.txt","eno")
    lines,_=pass(t,p,watch)
    expect_lines(t,lines,"Changed a.txt")
    // A folder that goes away takes its files with it; one that appears brings them.
    remove(folder,"sub/b.txt")
    write(t,folder,"other/x.bin","x")
    write(t,folder,"other/y.bin","y")
    lines,_=pass(t,p,watch)
    expect_lines(t,lines,"Created other/x.bin","Created other/y.bin","Removed sub/b.txt")
}

@(test)
watch_follows_its_options :: proc(t:^testing.T) {
    p:=test_headless(t)
    defer destroy(p)
    folder:=base.test_folder(t,"watch-options")
    write(t,folder,"a.txt","a")
    write(t,folder,".hidden.txt","h")
    write(t,folder,".cache/data.bin","d")
    write(t,folder,"sub/b.txt","b")
    flat,flat_error:=watch_create(p,{path=folder,report_existing=true})
    testing.expect_value(t,flat_error,Watch_Error.None)
    lines,_:=pass(t,p,flat)
    expect_lines(t,lines,"Created a.txt")
    deep,deep_error:=watch_create(p,{path=folder,recursive=true,report_existing=true})
    testing.expect_value(t,deep_error,Watch_Error.None)
    lines,_=pass(t,p,deep)
    expect_lines(t,lines,"Created a.txt","Created sub/b.txt")
    // A trailing separator names the same folder.
    all,all_error:=watch_create(p,{path=fmt.tprintf("%s/",folder),recursive=true,hidden=true,report_existing=true})
    testing.expect_value(t,all_error,Watch_Error.None)
    lines,_=pass(t,p,all)
    expect_lines(t,lines,"Created .cache/data.bin","Created .hidden.txt","Created a.txt","Created sub/b.txt")
    // Existing files are reported by the first pass only.
    lines,_=pass(t,p,all)
    expect_lines(t,lines)
    watch_destroy(p,flat);watch_destroy(p,deep);watch_destroy(p,all)
}

@(test)
watch_spreads_a_pass_over_many_small_polls :: proc(t:^testing.T) {
    p:=test_headless(t)
    defer destroy(p)
    folder:=base.test_folder(t,"watch-budget")
    for i in 0..<40 {write(t,folder,fmt.tprintf("d%d/file%d.txt",i%4,i),"x")}
    watch,error:=watch_create(p,{path=folder,recursive=true,report_existing=true})
    testing.expect_value(t,error,Watch_Error.None)
    defer watch_destroy(p,watch)
    // One entry per poll and room for one event: nothing is lost, it only takes longer.
    lines,polls:=pass(t,p,watch,budget=1,capacity=1)
    testing.expect_value(t,len(lines),40)
    testing.expect(t,polls>=40,"40 files cannot be listed in fewer polls of one file each")
    // A poll never hands out more events than fit.
    for i in 0..<40 {remove(folder,fmt.tprintf("d%d/file%d.txt",i%4,i))}
    events:[3]Watch_Event
    removed:=0
    for attempt:=0;attempt<100000;attempt+=1 {
        count,done:=watch_poll(p,watch,1000,events[:])
        testing.expect(t,count<=len(events))
        for event in events[:count] {
            testing.expect_value(t,event.kind,Watch_Event_Kind.Removed)
            testing.expect(t,strings.has_suffix(event.path,".txt"))
            removed+=1
        }
        if done {break}
    }
    testing.expect_value(t,removed,40)
    testing.expect_value(t,watch_stats(p,watch).files,0)
    // No budget, no work.
    count,done:=watch_poll(p,watch,0,events[:])
    testing.expect(t,count==0 && !done)
    count,done=watch_poll(p,watch,100,nil)
    testing.expect(t,count==0 && !done)
}

@(test)
watch_keeps_working_when_its_capacity_is_exhausted :: proc(t:^testing.T) {
    p:=test_headless(t)
    defer destroy(p)
    folder:=base.test_folder(t,"watch-capacity")
    for i in 0..<6 {write(t,folder,fmt.tprintf("file%d.txt",i),"x")}
    watch,error:=watch_create(p,{path=folder,file_capacity=4,report_existing=true})
    testing.expect_value(t,error,Watch_Error.None)
    defer watch_destroy(p,watch)
    lines,_:=pass(t,p,watch)
    testing.expect_value(t,len(lines),4)
    testing.expect_value(t,watch_stats(p,watch).files,4)
    testing.expect_value(t,watch_stats(p,watch).untracked,u64(2))
    // The files that did not fit are simply not watched; the others still are.
    lines,_=pass(t,p,watch)
    expect_lines(t,lines)
    after:=watch_stats(p,watch)
    testing.expect_value(t,after.untracked,2*(after.passes-after.quiet))

    // Too few bytes for the paths: the same, counted the same way.
    tight,tight_error:=watch_create(p,{path=folder,file_capacity=16,path_bytes=25,report_existing=true})
    testing.expect_value(t,tight_error,Watch_Error.None)
    defer watch_destroy(p,tight)
    lines,_=pass(t,p,tight)
    testing.expect_value(t,len(lines),2) // "fileN.txt" takes 9 bytes and 2 of length
    testing.expect_value(t,watch_stats(p,tight).untracked,u64(4))
}

@(test)
watch_does_not_walk_a_folder_nobody_touched :: proc(t:^testing.T) {
    p:=test_headless(t)
    defer destroy(p)
    folder:=base.test_folder(t,"watch-quiet")
    write(t,folder,"a.txt","a")
    write(t,folder,"sub/b.txt","b")
    watch,error:=watch_create(p,{path=folder,recursive=true})
    testing.expect_value(t,error,Watch_Error.None)
    defer watch_destroy(p,watch)
    // The system may still tell of what was written before the first pass.
    for _ in 0..<3 {
        lines,_:=pass(t,p,watch)
        expect_lines(t,lines)
    }
    // Where it tells that nothing changed, a pass is one poll that lists nothing.
    settled:=watch_stats(p,watch)
    polls:=0
    for _ in 0..<3 {
        lines,count:=pass(t,p,watch,1)
        expect_lines(t,lines)
        polls+=count
    }
    quiet:=watch_stats(p,watch).quiet-settled.quiet
    testing.expect_value(t,watch_stats(p,watch).passes,u64(6))
    testing.expectf(t,settled.quiet==0 && quiet==0 || quiet==3 && polls==3,"%d quiet passes in %d polls after %d",quiet,polls,settled.quiet)
    lines:[]string
    // What changes afterwards is found wherever it is.
    write(t,folder,"sub/b.txt","changed")
    lines,_=pass(t,p,watch)
    expect_lines(t,lines,"Changed sub/b.txt")
    write(t,folder,"sub/deep/c.txt","c")
    lines,_=pass(t,p,watch)
    expect_lines(t,lines,"Created sub/deep/c.txt")
    remove(folder,"a.txt")
    lines,_=pass(t,p,watch)
    expect_lines(t,lines,"Removed a.txt")
    write(t,folder,"sub/deep/c.txt","c again")
    lines,_=pass(t,p,watch)
    expect_lines(t,lines,"Changed sub/deep/c.txt")
}

@(test)
watch_reuses_the_room_of_removed_files :: proc(t:^testing.T) {
    p:=test_headless(t)
    defer destroy(p)
    folder:=base.test_folder(t,"watch-churn")
    // Room for three paths at a time; files come and go many times over.
    watch,error:=watch_create(p,{path=folder,file_capacity=8,path_bytes=40})
    testing.expect_value(t,error,Watch_Error.None)
    defer watch_destroy(p,watch)
    write(t,folder,"keep.txt","k")
    lines,_:=pass(t,p,watch)
    expect_lines(t,lines)
    for round in 0..<30 {
        name:=fmt.tprintf("round%02d.txt",round)
        write(t,folder,name,"r")
        lines,_=pass(t,p,watch)
        // The text is compacted between two polls: the file is created in this pass or the next.
        if len(lines)==0 {lines,_=pass(t,p,watch)}
        expect_lines(t,lines,fmt.tprintf("Created %s",name))
        remove(folder,name)
        lines,_=pass(t,p,watch)
        expect_lines(t,lines,fmt.tprintf("Removed %s",name))
    }
    testing.expect_value(t,watch_stats(p,watch).files,1)
    testing.expect_value(t,watch_stats(p,watch).untracked,u64(0))
    write(t,folder,"keep.txt","kept and changed")
    lines,_=pass(t,p,watch)
    expect_lines(t,lines,"Changed keep.txt")
}

@(test)
watch_survives_the_loss_of_its_folder :: proc(t:^testing.T) {
    p:=test_headless(t,{watch_capacity=1})
    defer destroy(p)
    folder:=base.test_folder(t,"watch-gone")
    inner,_:=filepath.join({folder,"project"},context.temp_allocator)
    none,error:=watch_create(p,{path=inner})
    testing.expect(t,none==0 && error==.Not_Found)
    none,error=watch_create(p,{})
    testing.expect(t,none==0 && error==.Not_Found)
    write(t,inner,"a.txt","a")
    write(t,inner,"b.txt","b")
    watch,watch_error:=watch_create(p,{path=inner})
    testing.expect_value(t,watch_error,Watch_Error.None)
    none,error=watch_create(p,{path=inner})
    testing.expect(t,none==0 && error==.Capacity_Exhausted)
    testing.expect_value(t,stats(p).watches_exhausted,u64(1))
    lines,_:=pass(t,p,watch)
    expect_lines(t,lines)
    testing.expect(t,base.remove_all(inner)==nil)
    lines,_=pass(t,p,watch)
    expect_lines(t,lines,"Removed a.txt","Removed b.txt")
    lines,_=pass(t,p,watch)
    expect_lines(t,lines)
    write(t,inner,"a.txt","again")
    lines,_=pass(t,p,watch)
    expect_lines(t,lines,"Created a.txt")
    // A destroyed watch is a dead handle, and its place is free again.
    watch_destroy(p,watch)
    events:[4]Watch_Event
    count,done:=watch_poll(p,watch,100,events[:])
    testing.expect(t,count==0 && !done)
    testing.expect_value(t,watch_stats(p,watch),Watch_Stats{})
    again,again_error:=watch_create(p,{path=inner})
    testing.expect(t,again!=0 && again!=watch && again_error==.None)
}

@(test)
watch_polls_without_allocating :: proc(t:^testing.T) {
    p:=test_headless(t)
    defer destroy(p)
    folder:=base.test_folder(t,"watch-memory")
    for i in 0..<20 {write(t,folder,fmt.tprintf("s%d/f%d.txt",i%3,i),"x")}
    watch,error:=watch_create(p,{path=folder,recursive=true})
    testing.expect_value(t,error,Watch_Error.None)
    defer watch_destroy(p,watch)
    write(t,folder,"late.txt","x")
    count:=0
    events:[8]Watch_Event
    found,passes:=0,0
    {
        context.allocator=test_no_allocator(&count)
        context.temp_allocator=test_no_allocator(&count)
        for passes<4 {
            n,done:=watch_poll(p,watch,7,events[:])
            found+=n
            if done {passes+=1}
        }
    }
    testing.expect_value(t,count,0)
    testing.expect_value(t,found,0)
    testing.expect_value(t,watch_stats(p,watch).files,21)
}

@(test)
paths_of_the_system_exist :: proc(t:^testing.T) {
    executable,ok:=path_executable_folder(context.temp_allocator)
    testing.expect(t,ok && os.is_dir(executable),executable)
    temporary,temporary_ok:=path_temporary_folder(context.temp_allocator)
    testing.expect(t,temporary_ok && os.is_dir(temporary),temporary)
    name:=fmt.tprintf("platform-test-%d",os.get_pid())
    data,data_ok:=path_user_data_folder("Mirai Tests",name,context.temp_allocator)
    testing.expect(t,data_ok && os.is_dir(data),data)
    testing.expect(t,strings.has_suffix(data,name) && strings.contains(data,"Mirai Tests"))
    // Asking again finds the same folder.
    again,again_ok:=path_user_data_folder("Mirai Tests",name,context.temp_allocator)
    testing.expect(t,again_ok && again==data)
    testing.expect(t,os.remove(data)==nil)
    testing.expect(t,os.remove(filepath.dir(data))==nil || os.is_dir(filepath.dir(data)))
    plain,plain_ok:=path_user_data_folder("",name,context.temp_allocator)
    testing.expect(t,plain_ok && os.is_dir(plain) && !strings.contains(plain,"Mirai Tests"))
    testing.expect(t,os.remove(plain)==nil)
    _,empty_ok:=path_user_data_folder("Mirai Tests","",context.temp_allocator)
    testing.expect(t,!empty_ok)
}

PLATFORM_BENCHMARK :: #config(PLATFORM_BENCHMARK,false)

// Cost of a pass over a real tree (the core library of the compiler), next to
// walking the same tree with core:os, which opens every file it lists.
@(test)
benchmark_watch_pass :: proc(t:^testing.T) {
    when !PLATFORM_BENCHMARK {return} else {
        p:=test_headless(t)
        defer destroy(p)
        root:=ODIN_ROOT+"core"
        watch,error:=watch_create(p,{path=root,recursive=true,file_capacity=16384})
        testing.expect_value(t,error,Watch_Error.None)
        defer watch_destroy(p,watch)
        events:[64]Watch_Event
        run :: proc(p:^Platform,watch:Watch,events:[]Watch_Event,budget:int) -> (ns:u64,polls:int,worst:u64) {
            start:=clock_ns()
            for {
                poll_start:=clock_ns()
                _,done:=watch_poll(p,watch,budget,events)
                worst=max(worst,clock_ns()-poll_start)
                polls+=1
                if done {break}
            }
            return clock_ns()-start,polls,worst
        }
        first,_,_:=run(p,watch,events[:],1<<30)
        files:=watch_stats(p,watch).files
        best:=max(u64)
        for _ in 0..<10 {
            ns,_,_:=run(p,watch,events[:],1<<30)
            best=min(best,ns)
        }
        budgeted,polls,worst:=run(p,watch,events[:],256)
        walker:=os.walker_create(root)
        defer os.walker_destroy(&walker)
        walk_start:=clock_ns()
        walked:=0
        for info in os.walker_walk(&walker) {
            if info.type!=.Directory {walked+=1}
        }
        walk:=clock_ns()-walk_start
        fmt.printfln("watch: %d files; first pass %.2f ms; steady pass %.2f ms (%.0f ns per file)",files,f64(first)/1e6,f64(best)/1e6,f64(best)/f64(files))
        fmt.printfln("watch: budget 256 per poll: %d polls, %.2f ms in all, worst poll %.3f ms",polls,f64(budgeted)/1e6,f64(worst)/1e6)
        fmt.printfln("core:os walker over the same tree: %d files, %.2f ms (%.0f ns per file)",walked,f64(walk)/1e6,f64(walk)/f64(max(walked,1)))
    }
}
