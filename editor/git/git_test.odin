package git

import "core:testing"
import "mirai:std/base"

@(test)
status_and_log_are_read_as_git_prints_them :: proc(t:^testing.T) {
    r:Repository
    defer delete(r.changes)
    defer delete(r.history)
    base.text_set(r.prefix[:],"game/")
    left_out:=Change{left_out=true}
    base.text_set(left_out.path[:],"game/assets/a.scene")
    append(&r.changes,left_out)
    status_read(&r,"# branch.oid 1234\x00# branch.head main\x00# branch.upstream origin/main\x00# branch.ab +2 -3\x00"+
        "1 .M N... 100644 100644 100644 aaa bbb game/assets/a.scene\x00"+
        "1 A. N... 000000 100644 100644 000 ccc game/new file.mat\x00"+
        "1 D. N... 100644 000000 000000 ddd 000 game/gone.tex\x00"+
        "2 R. N... 100644 100644 100644 eee fff R100 game/renamed.mesh\x00game/old.mesh\x00"+
        "u UU N... 100644 100644 100644 100644 a b c game/assets/b.scene\x00"+
        "? game/untracked.txt\x00")
    testing.expect(t,base.text_get(r.branch[:])=="main" && r.upstream && r.ahead==2 && r.behind==3)
    testing.expect(t,r.merging,"a file in conflict is a merge that waits")
    Expected :: struct {path:string,status:u8,left_out,tracked,staged:bool}
    expected:=[?]Expected{
        {"game/assets/a.scene",'M',true,true,false},
        {"game/new file.mat",'A',false,false,true},
        {"game/gone.tex",'D',false,true,false},
        {"game/renamed.mesh",'M',false,true,false},
        {"game/assets/b.scene",'U',false,true,false},
        {"game/untracked.txt",'A',false,false,false},
    }
    testing.expect_value(t,len(r.changes),len(expected))
    for want,index in expected {
        if index>=len(r.changes) {break}
        got:=&r.changes[index]
        testing.expectf(t,base.text_get(got.path[:])==want.path && got.status==want.status && got.left_out==want.left_out && got.tracked==want.tracked && got.staged==want.staged,
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
