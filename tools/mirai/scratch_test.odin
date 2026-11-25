package main

import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:cook/workspace"
import "mirai:project"
import "mirai:std/base"

// Beside the session copies, a sweep deletes an entry of the scratch only
// when nothing in it changed for SCRATCH_AGE and no lock keeps it: one at
// its top or in its .mirai/, or beside a file. A lock that is not held keeps
// nothing, and the lock of the sweep stays. While another sweep runs, it
// deletes nothing.
@(test)
a_sweep_deletes_only_the_scratch_no_lock_holds_and_unchanged_for_its_age :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    folder:=base.test_folder(t,"scratch")
    if folder=="" {return}
    temporary:=scratch_folder(folder)
    now:=time.now()
    old,recent:=time.time_add(now,-SCRATCH_AGE-time.Hour),time.time_add(now,-SCRATCH_AGE+time.Hour)
    Entry :: struct {
        file:string,  // under the scratch: the first part is the entry
        newer:string, // a file inside it changed within the age
        lock:string,  // a lock this test holds, under the scratch
        stays:bool,
    }
    entries:=[]Entry{
        {file="old.png"},
        {file="recent.png",newer="recent.png",stays=true},
        {file="experiment/out/run.tsv"},
        {file="long/deep/log.txt",newer="long/deep/now.txt",stays=true},
        {file="held/data.bin",lock="held/run.lock",stays=true},
        {file="opened/data.bin",lock="opened/.mirai/editor.lock",stays=true},
        {file="beside.bin",lock="beside.bin.lock",stays=true},
        {file="stale.lock"},
        {file="stale.lock.owner"},
    }
    locks:=make([dynamic]workspace.Lock)
    defer for &lock in locks {workspace.lock_release(&lock)}
    for e in entries {
        path:=project.path(temporary,e.file)
        testing.expect(t,base.make_directory_all(os.dir(path))==nil)
        testing.expect(t,os.write_entire_file(path,e.file)==nil)
        if e.newer!="" {testing.expect(t,os.write_entire_file(project.path(temporary,e.newer),e.newer)==nil)}
        if e.lock=="" {continue}
        lock,locked:=workspace.lock_acquire(project.path(temporary,e.lock),"the test")
        testing.expect(t,locked)
        append(&locks,lock)
    }
    // Everything old, deepest first, so that its folder keeps the time; then what is newer.
    paths:=make([dynamic]string)
    walker:=os.walker_create(temporary)
    for info in os.walker_walk(&walker) {append(&paths,strings.clone(info.fullpath))}
    os.walker_destroy(&walker)
    slice.sort_by(paths[:],proc(a,b:string) -> bool {return len(a)>len(b)})
    for path in paths {testing.expect(t,os.change_times(path,old,old)==nil)}
    for e in entries {
        if e.newer!="" {testing.expect(t,os.change_times(project.path(temporary,e.newer),recent,recent)==nil)}
    }

    other,taken:=workspace.lock_acquire(project.path(temporary,SCRATCH_LOCK),"another sweep")
    testing.expect(t,taken)
    swept,kept:=scratch_sweep(folder,now)
    testing.expect(t,swept==0 && kept==0 && os.exists(project.path(temporary,"old.png")),"while another sweep runs, nothing goes")
    workspace.lock_release(&other)

    swept,kept=scratch_sweep(folder,now)
    testing.expect_value(t,kept,0)
    gone:=0
    for e in entries {
        top,_,_:=strings.partition(e.file,"/")
        exists:=os.exists(project.path(temporary,top))
        testing.expectf(t,exists==e.stays,"%s %s",top,e.stays?"stays":"goes")
        if !e.stays {gone+=1}
    }
    testing.expect_value(t,swept,gone)
    testing.expect(t,os.exists(project.path(temporary,"beside.bin.lock")) && os.exists(project.path(temporary,"beside.bin.lock.owner")),"a lock held stays, with its owner")
    testing.expect(t,os.exists(project.path(temporary,SCRATCH_LOCK)),"the lock of the sweep stays")
}
