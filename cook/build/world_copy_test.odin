package build

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:project"
import "mirai:std/base"

@(test)
a_generated_world_says_how_core_copies_and_swaps_each_storage :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"copy")
    if folder=="" {return}
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
@(storage,copy="state_copy",copy_kept="state_copy_kept",swap="state_swap",diff="state_diff")
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
        // Making, copying, swapping and clearing a World are loops of core over what info says of
        // each table and storage: none is written for a world.
        for name in ([]string{"init_World","destroy_World","copy_world","swap_world","clear_world","table_init","table_copy","table_swap"}) {
            testing.expectf(t,!strings.contains(text,name),"%s is written for the world",name)
        }
        // A lock is the distance from its table to the one whose rows it takes.
        testing.expect(t,strings.contains(text,"locks_owner[0]={int(offset_of(World,transform))-int(offset_of(World,owner)),1,LOCK_NAMES[:],\"Transform\"}"),text)
        testing.expect(t,strings.contains(text,",true,locks_owner,false}\n") && strings.contains(text,",true,nil,false}\n"),"a component of core is the base of every entity")
        // The procedures the attributes of a storage name, as core calls them.
        testing.expect(t,strings.contains(text,"copy_state :: proc(a,b:rawptr) -> bool {return p_core.state_copy(cast(^p_core.State)a,cast(^p_core.State)b)}"),text)
        testing.expect(t,strings.contains(text,"copy_kept_state :: proc(a,b:rawptr) -> bool {return p_core.state_copy_kept(cast(^p_core.State)a,cast(^p_core.State)b)}"))
        testing.expect(t,strings.contains(text,"swap_state :: proc(a,b:rawptr) {p_core.state_swap(cast(^p_core.State)a,cast(^p_core.State)b)}"))
        testing.expect(t,strings.contains(text,"diff_state :: proc(a,b:rawptr,buf:[]byte) -> string {return p_core.state_diff(cast(^p_core.State)a,cast(^p_core.State)b,buf)}"))
        testing.expect(t,strings.contains(text,"free_local :: proc(value:rawptr) {p_core.local_free(cast(^p_core.Local)value)}"))
        testing.expect(t,strings.contains(text,"offset_of(World,state),.World,.None,nil,false,nil,false,false,\"\",false,false,{copy=copy_state,copy_kept=copy_kept_state,swap=swap_state,diff=diff_state},false}"),text)
        testing.expect(t,strings.contains(text,"offset_of(World,plain),.World,.None,nil,false,nil,false,false,\"\",false,false,{},false}"))
        // What says copy=false is local: no copy or swap of the World touches it.
        testing.expect(t,strings.contains(text,"offset_of(World,local),.World,.None,nil,false,nil,false,false,\"\",false,true,{free=free_local},false}"))
        // A World holds a revision for each storage of info.storages; Local is 0, State 1, Plain 2.
        testing.expect(t,strings.contains(text,"storage_revisions:[6]u64,"),text)
        testing.expect(t,strings.contains(text,"info.entities,info.revisions=offset_of(World,entities),offset_of(World,storage_revisions)"))
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
        testing.expect(t,strings.contains(text,"local:p_core.Local"))
    }
}
