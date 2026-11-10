package editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:time"
import "mirai:editor/history"
import "mirai:std/base"

@(private="file")
code_test_root :: proc(name:string) -> string {
    folder,_:=os.get_working_directory(context.temp_allocator)
    return fmt.tprintf("%s/.mirai/tmp/ai-code-%s-%d",folder,name,os.get_pid())
}

@(private="file")
code_test_write :: proc(t:^testing.T,root,path,text:string) {
    full:=fmt.tprintf("%s/%s",root,path)
    _=os.make_directory_all(filepath.dir(full))
    testing.expect(t,os.write_entire_file(full,transmute([]u8)text)==nil)
}

@(private="file")
code_test_file :: proc(task:^Ai_Task,path:string) -> ^history.Change_File {
    for &set in task.review.transactions {
        for &file in set.files {if file.path==path {return &file}}
    }
    return nil
}

@(test)
a_turn_keeps_what_the_files_it_changed_held_before_it :: proc(t:^testing.T) {
    root:=code_test_root("turn")
    defer os.remove_all(root)
    code_test_write(t,root,"game/player.odin","package game // before\n")
    code_test_write(t,root,"game/gone.odin","package game // gone\n")
    code_test_write(t,root,"assets/scene.scene","not code")
    m:=new(Ai);defer free(m)
    defer ai_code_free(m)
    m.task_count=2
    task:=&m.tasks[0];task.id=1;base.text_set(task.title[:],"Make the player jump")
    defer ai_review_free(&task.review)
    s:=Session{ai=m,project_root=root}
    ai_code_begin(&s,m,task)
    testing.expect(t,len(m.code)==2,"The code of the project is kept, the assets are not")
    // A file the agent wrote with its own tools has another time.
    time.sleep(20*time.Millisecond)
    code_test_write(t,root,"game/player.odin","package game // after, longer\n")
    code_test_write(t,root,"game/jump.odin","package game // new\n")
    testing.expect(t,os.remove(fmt.tprintf("%s/game/gone.odin",root))==nil)
    code_test_write(t,root,"assets/scene.scene","changed by the API")
    testing.expect(t,ai_code_end(&s,m,task),"Every file it changed is kept")
    testing.expect(t,task.code==nil && len(m.code)==0,"What only the turn needed goes")
    changed:=code_test_file(task,"game/player.odin")
    created:=code_test_file(task,"game/jump.odin")
    removed:=code_test_file(task,"game/gone.odin")
    testing.expect(t,changed!=nil && changed.before_present && changed.after_present && string(changed.before)=="package game // before\n" && string(changed.after)=="package game // after, longer\n")
    testing.expect(t,created!=nil && !created.before_present && created.after_present)
    testing.expect(t,removed!=nil && removed.before_present && !removed.after_present && string(removed.before)=="package game // gone\n")
    testing.expect(t,code_test_file(task,"assets/scene.scene")==nil,"The assets are the review of the API")
    testing.expect(t,task.review.pending && len(task.review.changed_files)==3)

    // Another turn that changes the same file says so.
    other:=&m.tasks[1];other.id=2
    defer ai_review_free(&other.review)
    ai_code_begin(&s,m,other)
    time.sleep(20*time.Millisecond)
    code_test_write(t,root,"game/player.odin","package game // third\n")
    testing.expect(t,ai_code_end(&s,m,other))
    testing.expect(t,ai_code_other(m,other,"game/player.odin")==task)
    testing.expect(t,other.transcript.count>0,"Its transcript names the turn that changed the file before")
}

@(test)
a_turn_that_changes_a_file_too_large_to_keep_cannot_be_reverted :: proc(t:^testing.T) {
    root:=code_test_root("large")
    defer os.remove_all(root)
    code_test_write(t,root,"game/small.odin","package game\n")
    m:=new(Ai);defer free(m)
    defer ai_code_free(m)
    m.task_count=1
    task:=&m.tasks[0];task.id=1
    defer ai_review_free(&task.review)
    s:=Session{ai=m,project_root=root}
    ai_code_begin(&s,m,task)
    large:=make([]u8,AI_CODE_FILE_BYTES+1,context.temp_allocator)
    testing.expect(t,os.write_entire_file(fmt.tprintf("%s/game/data.bin",root),large)==nil)
    testing.expect(t,!ai_code_end(&s,m,task))
}
