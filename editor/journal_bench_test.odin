package editor

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:testing"
import "core:time"
import "mirai:core"
import "mirai:editor/history"
import erender "mirai:engine/render"

// The memory the editor keeps to compare a large scene, and the time of a
// structural commit, its undo and a tick of collaboration. Run with
//   mirai test editor journal_memory_of_a_large_scene --release -define:EDITOR_JOURNAL_BENCH=true

@(private="file") EDITOR_JOURNAL_BENCH :: #config(EDITOR_JOURNAL_BENCH,false)
@(private="file") ENTITIES :: #config(EDITOR_JOURNAL_ENTITIES,20000)

@(private="file")
Bench_World :: struct {
    using world:core.Test_World,
    ids:core.Table(core.Id),
    names:core.Table(core.Name),
    transforms:core.Table(core.Transform),
    poses:core.Table(core.World_Transform),
    parents:core.Table(core.Parent),
    meshes:core.Table(erender.Mesh_Renderer),
}

// A cube: authored with an Id and a Name, or derived without them.
@(private="file")
bench_create :: proc(w:^Bench_World,id:u64,parent:core.Entity,authored:bool) -> core.Entity {
    e:=core.create(&w.entities)
    if authored {
        core.add(&w.ids,e,{value=type_of(core.Id{}.value)(id)})
        name:core.Name
        history.text_put(name.text[:],fmt.tprintf("Cube %d",id))
        core.add(&w.names,e,name)
    }
    core.add(&w.transforms,e,core.Transform{{f32(id),0,0},1,{1,1,1}})
    core.add(&w.poses,e,{})
    core.add(&w.meshes,e,{shape=.Cube})
    if parent!=core.NONE {core.add(&w.parents,e,{entity=parent})}
    return e
}

@(test)
journal_memory_of_a_large_scene :: proc(t:^testing.T) {
    when !EDITOR_JOURNAL_BENCH {return}
    tracking:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracking,context.allocator)
    defer mem.tracking_allocator_destroy(&tracking)
    context.allocator=mem.tracking_allocator(&tracking)
    world:=new(Bench_World);defer free(world)
    if !core.test_world_init(t,world,test_types) {return}
    defer core.test_world_destroy(world)
    info:=core.test_world_info(world)
    w:=core.test_world_ref(world)
    // Groups of ten cubes under the first, and a derived cube in each group.
    group:=core.NONE
    for i in 0..<ENTITIES {
        if i%10==0 {group=bench_create(world,u64(i+1),core.NONE,true)} else {bench_create(world,u64(i+1),group,true)}
        if i%10==9 {bench_create(world,0,group,false)}
    }
    core.test_world_settle(world)
    // Room for what the steps add, so that the World does not grow while the editor is measured.
    for &table in info.tables {
        t:=core.world_table_at(w,&table)
        rows:=len(t.entities)+256
        runtime.__dynamic_array_reserve(&t.values,table.info.size,table.info.align,rows)
        reserve(&t.entities,rows);reserve(&t.stamps,rows);reserve(&t.off,rows);reserve(&t.rows,len(world.entities.generation)+256)
        reserve(&t.pending,16);runtime.__dynamic_array_reserve(&t.added,table.info.size,table.info.align,16)
    }
    reserve(&world.entities.generation,len(world.entities.generation)+256)
    free_all(context.temp_allocator)
    world_bytes:=tracking.current_memory_allocated
    edits:history.Edits
    selection:history.Selection
    image,steps,cancel,collab_bytes:i64
    step_bytes:int
    reset_ms,commit_ms,undo_ms,tick_ms:f64
    {
        start:=time.tick_now()
        history.edits_reset(&edits,w)
        reset_ms=time.duration_milliseconds(time.tick_since(start))
        image=tracking.current_memory_allocated-world_bytes
        base:=tracking.current_memory_allocated
        for k in 0..<100 {
            history.edits_begin(&edits,&selection,"Move")
            core.get(&world.transforms,world.transforms.entities[k*7]).position.y+=1
            history.edits_end(&edits)
            history.edits_commit(&edits,w,&selection)
            history.edits_begin(&edits,&selection,"Add")
            bench_create(world,u64(ENTITIES+k+1),core.NONE,true)
            core.test_world_settle(world)
            history.edits_end(&edits)
            history.edits_commit(&edits,w,&selection)
        }
        free_all(context.temp_allocator)
        steps=tracking.current_memory_allocated-base
        step_bytes=edits.bytes
        base=tracking.current_memory_allocated
        history.edits_begin(&edits,&selection,"Cancelled")
        history.edits_cancel_prepare(&edits,w)
        history.edits_cancel(&edits,w)
        cancel=tracking.current_memory_allocated-base
        history.edits_begin(&edits,&selection,"Delete")
        core.destroy(&world.entities,world.ids.entities[ENTITIES/2])
        core.test_world_settle(world)
        history.edits_end(&edits)
        start=time.tick_now()
        history.edits_commit(&edits,w,&selection)
        commit_ms=time.duration_milliseconds(time.tick_since(start))
        start=time.tick_now()
        history.undo(&edits,w,&selection)
        undo_ms=time.duration_milliseconds(time.tick_since(start))
        history.redo(&edits,w,&selection)
        free_all(context.temp_allocator)
        base=tracking.current_memory_allocated
        s:=Session{info=info,edit_world=world,edits=&edits,selection=&selection}
        st:=new(Collab_State)
        st.role,st.phase=.Guest,.Joined
        collab_tables_build(&s,st)
        collab_journal_reset(&s,st)
        collab_bytes=tracking.current_memory_allocated-base
        core.get(&world.transforms,world.transforms.entities[3]).position.z+=1
        start=time.tick_now()
        collab_edits_send(&s,st)
        tick_ms=time.duration_milliseconds(time.tick_since(start))
        for message in st.peers[0].out {delete(message)}
        clear(&st.peers[0].out)
        free_all(context.temp_allocator)
        delete(st.peers[0].out)
        collab_tables_free(st)
        free(st)
        history.edits_free(&edits)
        delete(selection.entities)
    }
    MB::1024.0*1024.0
    fmt.printfln("journal: %d entities, World %.2f MB; image %.2f MB; 200 steps %.2f MB (%.2f MB in the steps); cancel reserve %.2f MB; collab %.2f MB; reset %.2f ms; delete commit %.3f ms; undo %.3f ms; collab tick %.3f ms",
        ENTITIES,f64(world_bytes)/MB,f64(image)/MB,f64(steps)/MB,f64(step_bytes)/MB,f64(cancel)/MB,f64(collab_bytes)/MB,reset_ms,commit_ms,undo_ms,tick_ms)
}
