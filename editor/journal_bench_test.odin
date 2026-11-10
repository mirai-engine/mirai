package editor

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:testing"
import "core:time"
import "mirai:core"
import erender "mirai:engine/render"

// The memory the editor keeps to compare a large scene, and the time of a
// structural commit, its undo and a tick of collaboration. Run with
//   mirai test editor journal_memory_of_a_large_scene --release -define:EDITOR_JOURNAL_BENCH=true

@(private="file") EDITOR_JOURNAL_BENCH :: #config(EDITOR_JOURNAL_BENCH,false)
@(private="file") ENTITIES :: #config(EDITOR_JOURNAL_ENTITIES,20000)

@(private="file")
Bench_World :: struct {
    entities:core.Entities,
    ids:core.Table(core.Id),
    names:core.Table(core.Name),
    transforms:core.Table(core.Transform),
    poses:core.Table(core.World_Transform),
    parents:core.Table(core.Parent),
    meshes:core.Table(erender.Mesh_Renderer),
}

@(private="file")
bench_settle :: proc(data,shared,editor:rawptr) {
    w:=(^Bench_World)(data)
    core.table_settle(&w.ids,&w.entities);core.table_settle(&w.names,&w.entities);core.table_settle(&w.transforms,&w.entities)
    core.table_settle(&w.poses,&w.entities);core.table_settle(&w.parents,&w.entities);core.table_settle(&w.meshes,&w.entities)
    core.entities_settle(&w.entities)
}

// A cube: authored with an Id and a Name, or derived without them.
@(private="file")
bench_create :: proc(w:^Bench_World,id:u64,parent:core.Entity,authored:bool) -> core.Entity {
    e:=core.create(&w.entities)
    if authored {
        core.add(&w.ids,e,{value=type_of(core.Id{}.value)(id)})
        name:core.Name
        text_put(name.text[:],fmt.tprintf("Cube %d",id))
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
    core.entities_init(&world.entities)
    core.table_init(&world.ids,"Id");core.table_init(&world.names,"Name");core.table_init(&world.transforms,"Transform")
    core.table_init(&world.poses,"World_Transform");core.table_init(&world.parents,"Parent");core.table_init(&world.meshes,"Mesh_Renderer")
    tables:=[]core.Table_Info{
        {name="Id",type=core.Id,info=type_info_of(core.Id),offset=offset_of(Bench_World,ids)},
        {name="Name",type=core.Name,info=type_info_of(core.Name),offset=offset_of(Bench_World,names)},
        {name="Transform",type=core.Transform,info=type_info_of(core.Transform),offset=offset_of(Bench_World,transforms)},
        {name="World_Transform",type=core.World_Transform,info=type_info_of(core.World_Transform),offset=offset_of(Bench_World,poses)},
        {name="Parent",type=core.Parent,info=type_info_of(core.Parent),offset=offset_of(Bench_World,parents)},
        {name="Mesh_Renderer",type=erender.Mesh_Renderer,info=type_info_of(erender.Mesh_Renderer),offset=offset_of(Bench_World,meshes)},
    }
    info:=core.World_Info{entities=offset_of(Bench_World,entities),tables=tables}
    w:=core.world_ref(world,&info)
    // Groups of ten cubes under the first, and a derived cube in each group.
    group:=core.NONE
    for i in 0..<ENTITIES {
        if i%10==0 {group=bench_create(world,u64(i+1),core.NONE,true)} else {bench_create(world,u64(i+1),group,true)}
        if i%10==9 {bench_create(world,0,group,false)}
    }
    bench_settle(world,nil,nil)
    // Room for what the steps add, so that the World does not grow while the editor is measured.
    for &table in tables {
        t:=core.world_table_at(w,&table)
        rows:=len(t.entities)+256
        runtime.__dynamic_array_reserve(&t.values,table.info.size,table.info.align,rows)
        reserve(&t.entities,rows);reserve(&t.stamps,rows);reserve(&t.off,rows);reserve(&t.rows,len(world.entities.generation)+256)
        reserve(&t.pending,16);runtime.__dynamic_array_reserve(&t.added,table.info.size,table.info.align,16)
    }
    reserve(&world.entities.generation,len(world.entities.generation)+256)
    free_all(context.temp_allocator)
    world_bytes:=tracking.current_memory_allocated
    edits:Edits
    selection:Selection
    image,history,cancel,collab_bytes:i64
    step_bytes:int
    reset_ms,commit_ms,undo_ms,tick_ms:f64
    {
        start:=time.tick_now()
        edits_reset(&edits,w)
        reset_ms=time.duration_milliseconds(time.tick_since(start))
        image=tracking.current_memory_allocated-world_bytes
        base:=tracking.current_memory_allocated
        for k in 0..<100 {
            edits_begin(&edits,&selection,"Move")
            core.get(&world.transforms,world.transforms.entities[k*7]).position.y+=1
            edits_end(&edits)
            edits_commit(&edits,w,&selection)
            edits_begin(&edits,&selection,"Add")
            bench_create(world,u64(ENTITIES+k+1),core.NONE,true)
            bench_settle(world,nil,nil)
            edits_end(&edits)
            edits_commit(&edits,w,&selection)
        }
        free_all(context.temp_allocator)
        history=tracking.current_memory_allocated-base
        step_bytes=edits.bytes
        base=tracking.current_memory_allocated
        edits_begin(&edits,&selection,"Cancelled")
        edits_cancel_prepare(&edits,w)
        edits_cancel(&edits,w)
        cancel=tracking.current_memory_allocated-base
        edits_begin(&edits,&selection,"Delete")
        core.destroy(&world.entities,world.ids.entities[ENTITIES/2])
        bench_settle(world,nil,nil)
        edits_end(&edits)
        start=time.tick_now()
        edits_commit(&edits,w,&selection)
        commit_ms=time.duration_milliseconds(time.tick_since(start))
        start=time.tick_now()
        undo(&edits,w,&selection)
        undo_ms=time.duration_milliseconds(time.tick_since(start))
        redo(&edits,w,&selection)
        free_all(context.temp_allocator)
        base=tracking.current_memory_allocated
        s:=Session{info=&info,edit_world=world,edits=&edits,selection=&selection}
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
        edits_free(&edits)
        delete(selection.entities)
    }
    MB::1024.0*1024.0
    fmt.printfln("journal: %d entities, World %.2f MB; image %.2f MB; 200 steps %.2f MB (%.2f MB in the steps); cancel reserve %.2f MB; collab %.2f MB; reset %.2f ms; delete commit %.3f ms; undo %.3f ms; collab tick %.3f ms",
        ENTITIES,f64(world_bytes)/MB,f64(image)/MB,f64(history)/MB,f64(step_bytes)/MB,f64(cancel)/MB,f64(collab_bytes)/MB,reset_ms,commit_ms,undo_ms,tick_ms)
    core.table_destroy(&world.ids);core.table_destroy(&world.names);core.table_destroy(&world.transforms)
    core.table_destroy(&world.poses);core.table_destroy(&world.parents);core.table_destroy(&world.meshes)
    core.entities_destroy(&world.entities)
}
