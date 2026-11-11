package git

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"
import "mirai:std/base"

@(test)
status_and_log_are_read_as_git_prints_them :: proc(t:^testing.T) {
    r:Repository
    defer delete(r.changes)
    defer delete(r.history)
    base.text_set(r.prefix[:],"game/")
    status_read(&r,"# branch.oid 1234\x00# branch.head main\x00# branch.upstream origin/main\x00# branch.ab +2 -3\x00"+
        "1 .M N... 100644 100644 100644 aaa bbb game/assets/a.scene\x00"+
        "1 AM N... 000000 100644 100644 000 ccc game/new file.mat\x00"+
        "1 D. N... 100644 000000 000000 ddd 000 game/gone.tex\x00"+
        "2 R. N... 100644 100644 100644 eee fff R100 game/renamed.mesh\x00game/old.mesh\x00"+
        "u UU N... 100644 100644 100644 100644 a b c game/assets/b.scene\x00"+
        "? game/untracked.txt\x00")
    testing.expect(t,base.text_get(r.branch[:])=="main" && r.upstream && r.ahead==2 && r.behind==3)
    testing.expect(t,r.merging,"a file in conflict is a merge that waits")
    Expected :: struct {path:string,status:u8,pending,kept,tracked:bool}
    expected:=[?]Expected{
        {"game/assets/a.scene",'M',true,false,true},
        {"game/new file.mat",'A',true,true,true},
        {"game/gone.tex",'D',false,true,true},
        {"game/renamed.mesh",'M',false,true,true},
        {"game/assets/b.scene",'U',false,false,true},
        {"game/untracked.txt",'A',true,false,false},
    }
    testing.expect_value(t,len(r.changes),len(expected))
    for want,index in expected {
        if index>=len(r.changes) {break}
        got:=&r.changes[index]
        testing.expectf(t,base.text_get(got.path[:])==want.path && got.status==want.status && got.pending==want.pending && got.kept==want.kept && got.tracked==want.tracked,
            "%s was read as %v",want.path,got^)
    }
    testing.expect_value(t,change_path(&r,&r.changes[0]),"assets/a.scene")

    log_read(&r,"abc123\x1fAna\x1f2 days ago\x1fFix the door\nnot a commit\n")
    testing.expect(t,len(r.history)==1 && base.text_get(r.history[0].subject[:])=="Fix the door" && base.text_get(r.history[0].author[:])=="Ana")
}

@(test)
a_load_reads_the_three_stages_of_each_file_and_a_failure_says_what_git_said :: proc(t:^testing.T) {
    r:Repository
    defer delete(r.load_paths)
    append(&r.load_paths,"game/a.scene","game/b.scene")
    r.operation=.Load
    testing.expect_value(t,steps(&r),6)
    arguments:=command(&r,{},.Load,4)
    testing.expect(t,len(arguments)==2 && arguments[0]=="show" && arguments[1]==":2:game/b.scene")
    testing.expect(t,command(&r,{},.Load,6)==nil)

    fail_text(&r,"hint: set the upstream\nfatal: no upstream branch\n","The push failed")
    testing.expect_value(t,base.text_get(r.error[:]),"The push failed: no upstream branch")
    end(&r)
    operation,failed:=ended(&r)
    testing.expect(t,operation==.Load && failed && !busy(&r))
    operation,_=ended(&r)
    testing.expect_value(t,operation,Operation.None)
}

// Runs an operation to its end, as the editor does between frames.
@(private="file")
test_run :: proc(t:^testing.T,r:^Repository,roots:Roots,operation:Operation,paths:[]string=nil) {
    if operation==.Keep || operation==.Unkeep || operation==.Discard {start_paths(r,roots,operation,paths)} else {start(r,roots,operation)}
    for _ in 0..<4000 {
        if r.operation==.None {break}
        if exited,code:=poll(r);exited {advance(r,roots,code)} else {time.sleep(5*time.Millisecond)}
    }
    testing.expectf(t,r.operation==.None && base.text_get(r.error[:])=="","%v ended: %s",operation,base.text_get(r.error[:]))
    ended(r)
}

@(private="file")
test_change :: proc(r:^Repository,path:string) -> Change {
    for change in r.changes {
        change:=change
        if base.text_get(change.path[:])==path {return change}
    }
    return {}
}

// With the git installed: what the work tree has and the index does not is
// pending; keeping it makes the index the base that a later discard puts back.
@(test)
keeping_makes_the_index_the_base_a_discard_puts_back :: proc(t:^testing.T) {
    root:=base.test_folder(t,"git-keep")
    if root=="" {return}
    r:Repository
    defer {
        for path in r.paths {delete(path)}
        delete(r.paths);delete(r.changes);delete(r.history);delete(r.out);delete(r.err)
    }
    roots:=Roots{engine=root,project=root}
    test_run(t,&r,roots,.Check)
    if !r.available {return}
    test_run(t,&r,roots,.Init)
    file:=fmt.tprintf("%s/a.txt",root)
    write :: proc(t:^testing.T,file,text:string) {testing.expect(t,os.write_entire_file(file,transmute([]u8)text)==nil)}
    read :: proc(file:string) -> string {
        data,_:=os.read_entire_file(file,context.temp_allocator)
        return string(data)
    }
    write(t,file,"one")
    test_run(t,&r,roots,.Refresh)
    change:=test_change(&r,"a.txt")
    testing.expect(t,r.repository && change.pending && !change.kept && !change.tracked,"a new file is pending and git does not track it")

    test_run(t,&r,roots,.Keep,{"a.txt"})
    test_run(t,&r,roots,.Refresh)
    change=test_change(&r,"a.txt")
    testing.expect(t,change.kept && !change.pending && change.tracked,"kept, it is the base")

    write(t,file,"two")
    write(t,fmt.tprintf("%s/b.txt",root),"new")
    test_run(t,&r,roots,.Discard)
    testing.expect_value(t,read(file),"one")
    change=test_change(&r,"b.txt")
    testing.expect(t,takes(&r,&change) && !change.tracked && os.exists(fmt.tprintf("%s/b.txt",root)),"a file git does not track is told to whoever asked, who removes it")

    test_run(t,&r,roots,.Unkeep)
    test_run(t,&r,roots,.Refresh)
    change=test_change(&r,"a.txt")
    testing.expect(t,change.pending && !change.kept,"out of what is kept, it is pending again")
    testing.expect_value(t,read(file),"one")
}
