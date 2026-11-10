package build

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:project"

@(test)
generated_world_copy_reports_failure_and_publication_keeps_local_storage :: proc(t:^testing.T) {
    folder,error:=os.make_directory_temp("","mirai-copy-*",context.temp_allocator)
    if !testing.expect(t,error==nil) {return}
    defer os.remove_all(folder)
    engine:=project.path(folder,"engine",allocator=context.temp_allocator)
    game:=project.path(folder,"project",allocator=context.temp_allocator)
    for path in ([]string{project.path(engine,"core",allocator=context.temp_allocator),project.path(game,"game",allocator=context.temp_allocator)}) {
        if !testing.expect(t,os.make_directory_all(path)==nil) {return}
    }
    source:=`package core
@(component,shared)
Transform :: struct {value:f32}
@(component,locks="Transform")
Owner :: struct {}
@(component)
Id :: struct {value:u64}
@(storage,copy=false,free="local_free")
Local :: struct {socket:rawptr}
@(storage,copy="state_copy",copy_kept="state_copy_kept",swap="state_swap")
State :: struct {value:i32}
@(storage)
Plain :: struct {values:[512]f32}
@(storage,queue)
Asked :: struct {count:i32}
@(storage)
Network :: struct {role:enum {Alone,Client}}
@(storage,host)
Shown :: struct {value:i32}
@(params)
Both :: struct {plain:^Plain,state:Ref(State)}
@(step="fixed") takes_state :: proc(state:^State) {}
@(step="fixed") reads_state :: proc(state:Ref(State),plain:Plain,ids:^Table(Id)) {}
@(step="fixed") asks :: proc(asked:^Asked) {}
@(step="fixed") takes_both :: proc(both:Both) {}
@(step="fixed") takes_shown :: proc(shown:^Shown,local:^Local) {}
@(step="fixed",server) rules :: proc(state:^State,plain:^Plain) {}
@(step="fixed") reaches_all :: proc(w:World_Ref,commands:Commands) {}
`
    testing.expect(t,os.write_entire_file(project.path(engine,"core","data.odin",allocator=context.temp_allocator),source)==nil)
    p:=project.Project{root=game,engine_root=engine}
    output:=world_generate(&p,context.temp_allocator)
    if !testing.expect_value(t,len(output.errors),0) {return}
    for text in ([]string{output.game_world,output.editor_world}) {
        testing.expect(t,strings.contains(text,"init_World :: proc(data:rawptr,allocator:runtime.Allocator) -> bool"))
        testing.expect(t,strings.contains(text,"if error!=nil || raw_data(locks)==nil {return false}"))
        testing.expect(t,strings.contains(text,"w.owner.locks[0]={p_core.lock_offset(&w.owner,&w.transform),1,LOCK_NAMES[:],\"Transform\"}"))
        testing.expect(t,strings.contains(text,"if !p_core.entities_copy("))
        // The index of the entities by Id goes on following the table of Id that comes with it.
        testing.expect(t,strings.contains(text,"synced:=p_core.ids_synced(&src.entities,p_core.read(&src.id))"),text)
        testing.expect(t,strings.contains(text,"p_core.ids_moved(&dst.entities,p_core.read(&dst.id),synced)"))
        testing.expect(t,strings.contains(text,"p_core.ids_moved(&a.entities,p_core.read(&a.id),b_synced)"))
        // The copy a history keeps takes the copy_kept of the storage; the others its copy.
        whole,_,changed:=strings.partition(text,"copy_changed_world :: proc")
        changed,_,_=strings.partition(changed,"swap_world :: proc")
        testing.expect(t,strings.contains(whole,"if !p_core.state_copy(&dst.state,&src.state)") && !strings.contains(whole,"state_copy_kept"))
        testing.expect(t,strings.contains(changed,"if !p_core.state_copy_kept(&dst.state,&src.state)"))
        // A World holds a revision for each storage of info.storages; Local is 0, State 1, Plain 2.
        testing.expect(t,strings.contains(text,"storage_revisions:[6]u64,"),text)
        testing.expect(t,strings.contains(text,"info.entities,info.revisions=offset_of(World,entities),offset_of(World,storage_revisions)"))
        // The copy of what changed takes a storage only when its revision moved since its mark, which
        // follows those of the 3 tables; without a mark for each, it copies whole.
        testing.expect(t,strings.contains(changed,"if len(marks)<9 {return copy_world(dst_data,src_data)}"),changed)
        testing.expect(t,strings.contains(changed,"    if p_core.storage_changed(&marks[4],src.storage_revisions[1]) {\n        if !p_core.state_copy_kept(&dst.state,&src.state) {return false}\n        p_core.storage_copied(&marks[4],&dst.storage_revisions[1],src.storage_revisions[1])\n    }\n"),changed)
        testing.expect(t,strings.contains(changed,"    if p_core.storage_changed(&marks[5],src.storage_revisions[2]) {\n        if !p_core.value_copy(&dst.plain,&src.plain,type_info_of(p_core.Plain)) {return false}"),changed)
        testing.expect_value(t,strings.count(changed,"p_core.storage_changed("),4)
        // A storage with a copy of its own holds what a comparison of values does not read.
        testing.expect(t,strings.contains(changed,"when p_core.CHECK_WRITES {p_core.storage_check(&dst.plain,&src.plain,type_info_of(p_core.Plain),\"Plain\")}"))
        testing.expect(t,!strings.contains(changed,"storage_check(&dst.state"))
        testing.expect(t,!strings.contains(whole,"storage_changed") && strings.contains(whole,"p_core.revisions_copied(dst.storage_revisions[:],src.storage_revisions[:])"))
        testing.expect(t,strings.contains(text,"p_core.revisions_swapped(a.storage_revisions[:],b.storage_revisions[:])"))
        testing.expect(t,strings.contains(text,"p_core.revisions_moved(w.storage_revisions[:])"))
        // Whoever receives a storage of the World to write moves its revision, before it runs.
        Case :: struct {step:string,moves:[]string,call:string}
        cases:=[]Case{
            {"takes_state",{"w.storage_revisions[1]+=1"},"p_core.takes_state(&w.state)"},
            {"reads_state",{},"p_core.reads_state(p_core.ref(&w.state),w.plain,&w.id)"},
            {"asks",{"w.storage_revisions[3]+=1"},"p_core.asks(&w.asked)"},
            {"takes_both",{"w.storage_revisions[2]+=1"},"p_core.takes_both(p_core.Both{plain=&w.plain,state=p_core.ref(&w.state)})"},
            {"takes_shown",{},"p_core.takes_shown(&s.shown,&w.local)"},
            {"rules",{"w.storage_revisions[1]+=1","w.storage_revisions[2]+=1"},"p_core.rules(&w.state,&w.plain)"},
            // What reaches the World whole asks core for each storage, which moves it (core.world_storage).
            {"reaches_all",{},"p_core.reaches_all(p_core.world_ref(w,app.info),p_core.commands(w,app.info))"},
        }
        for c in cases {
            _,_,rest:=strings.partition(text,fmt.tprintf("call_%s :: proc(",c.step))
            body,_,_:=strings.partition(rest,"\n}\n")
            before,found,_:=strings.partition(body,c.call)
            testing.expectf(t,found!="","%s: %s",c.step,body)
            testing.expectf(t,strings.count(body,"storage_revisions[")==len(c.moves),"%s moves other revisions than those of what it receives to write: %s",c.step,body)
            for move in c.moves {testing.expectf(t,strings.contains(before,move),"%s runs before %s: %s",c.step,move,body)}
        }
        // A client does not run what the server decides: nothing of it is written.
        _,_,rules:=strings.partition(text,"call_rules :: proc(")
        role,_,moved:=strings.partition(rules,"w.storage_revisions[1]+=1")
        testing.expect(t,strings.contains(role,"if w.network.role==.Client {return}") && moved!="")
        testing.expect(t,strings.contains(text,"p_core.state_swap("))
        testing.expect(t,strings.contains(text,"p_core.table_swap("))
        // A multiple assignment of storages keeps LLVM optimizing for a minute (odin-lang/Odin#7937).
        testing.expect(t,strings.contains(text,"gen_slice.ptr_swap_non_overlapping(&a.plain,&b.plain,size_of(a.plain))"),text)
        testing.expect(t,strings.contains(text,"gen_slice.ptr_swap_non_overlapping(&a.entities,&b.entities,size_of(a.entities))"))
        testing.expect(t,!strings.contains(text,"a.plain,b.plain=") && !strings.contains(text,"a.entities,b.entities="))
        testing.expect(t,strings.contains(text,"local:p_core.Local"))
        testing.expect(t,!strings.contains(text,"&dst.local") && !strings.contains(text,"a.local,b.local="))
        testing.expect(t,strings.contains(text,"p_core.local_free(&w.local)"))
        testing.expect(t,strings.contains(text,"info.swap=swap_world"))
    }
}
