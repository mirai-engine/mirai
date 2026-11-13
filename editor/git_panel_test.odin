package editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:editor/git"
import "mirai:std/base"
import "mirai:ui"

// A long list of changes builds only the rows in sight, each cut inside the
// list beside its bar, and leaves the frame room for what is built after it:
// the text of a dialog over the panel is drawn.
@(test)
the_git_changes_build_the_rows_in_sight_cut_inside_the_list :: proc(t:^testing.T) {
    ctx:ui.Context
    if !testing.expect(t,test_ui_init(&ctx)) {return}
    defer ui.context_destroy(&ctx)
    gui:=Editor_Ui{ctx=&ctx}
    repo:=new(Git)
    defer free(repo)
    defer delete(repo.changes)
    repo.checked,repo.available,repo.repository=true,true,true
    for i in 0..<2000 {
        change:=git.Change{status='A',pending=true}
        base.text_set(change.path[:],fmt.tprintf("assets/a/folder/deep/enough/to/run/past/the/edge/of/the/panel/file_%d.txt",i))
        append(&repo.changes,change)
    }
    s:=Session{gui=&gui,git=repo}
    WIDTH :: 280
    list:ui.Rect
    for _ in 0..<3 {
        ui.frame_begin(&ctx,{size={1440,900},pointer_absent=true,dt=1.0/60})
        if ui.panel(&ctx,ui.id(&ctx,"git_test_panel"),{width=ui.fixed(WIDTH),height=ui.fixed(600),offset={0,0}}) {
            git_panel_build(&s,WIDTH,600)
            list,_=ui.widget_rect(&ctx,ui.id(&ctx,"git_changes"))
        }
        frame:=ui.frame_end(&ctx)
        testing.expect(t,!frame.overflow && ctx.stats.dropped_text+ctx.stats.dropped_elements+ctx.stats.dropped_paints+ctx.stats.dropped_widgets==0)
    }
    built:=0
    for i in 0..<len(repo.changes) {
        ui.id_push(&ctx,ui.id(&ctx,"git_pending"))
        ui.id_push(&ctx,ui.id(&ctx,"change",i))
        row,found:=ui.widget_rect(&ctx,ui.id(&ctx,"row"))
        ui.id_pop(&ctx)
        ui.id_pop(&ctx)
        if !found {continue}
        built+=1
        testing.expectf(t,row.x>=list.x-0.5 && row.x+row.w<=list.x+list.w-ui.SCROLL_GUTTER+0.5,"row %d %v ends inside the list %v, beside its bar",i,row,list)
    }
    testing.expect(t,built>0 && f32(built)*ui.metric(&ctx,"row")<list.h+3*ui.metric(&ctx,"row"),"only the rows in sight are built")
}

// Keep all in the dialog the editor shows before it ends keeps every pending
// change, more than a command line names, and then the editor ends; one git
// refuses is told, and the editor stays.
@(test)
keep_all_before_the_editor_ends_keeps_and_then_ends :: proc(t:^testing.T) {
    root:=base.test_folder(t,"git-quit")
    if root=="" {return}
    context.allocator=context.temp_allocator
    gui:Editor_Ui
    g:=new(Git)
    s:=Session{gui=&gui,git=g,has_project=true,project_root=root,engine_root=root}
    run :: proc(s:^Session) {
        for _ in 0..<4000 {
            git_poll(s)
            if s.git.operation==.None && s.git.finished==.None {return}
            time.sleep(5*time.Millisecond)
        }
    }
    git.start(g,git_roots(&s),.Check)
    run(&s)
    if !g.available {return}
    git.start(g,git_roots(&s),.Init)
    run(&s)
    if !testing.expect(t,g.repository && gui.modal==.None,"the repository is made with nothing pending") {return}
    folder:=fmt.tprintf("%s/a_folder_whose_name_is_long_enough_that_its_files_fill_a_command_line",root)
    testing.expect(t,os.make_directory(folder)==nil)
    MANY :: 600
    for i in 0..<MANY {testing.expect(t,os.write_entire_file(fmt.tprintf("%s/the_file_number_%d_of_the_many.txt",folder,i),transmute([]u8)string("many"))==nil)}
    git.start(g,git_roots(&s),.Refresh)
    run(&s)
    testing.expect_value(t,git_pending_count(&s),MANY)

    // The index is held by another git: Keep all fails, says so, and the editor stays.
    lock:=fmt.tprintf("%s/.git/index.lock",root)
    testing.expect(t,os.write_entire_file(lock,nil)==nil)
    documents_quit(&s)
    testing.expect(t,gui.modal==.Pending && g.notice==.Quit && !s.quit,"the pending changes are asked about first")
    git_pending_take(&s,.Keep)
    run(&s)
    testing.expect(t,!s.quit && strings.contains(string(s.toast[:s.toast_length]),"could not be kept"),"a keep git refuses says why and the editor stays")
    testing.expect_value(t,git_pending_count(&s),MANY)

    testing.expect(t,os.remove(lock)==nil)
    documents_quit(&s)
    testing.expect(t,gui.modal==.Pending,"the changes are still pending")
    git_pending_take(&s,.Keep)
    run(&s)
    testing.expect(t,s.quit,"kept, the editor ends")
    testing.expect_value(t,git_pending_count(&s),0)
}
