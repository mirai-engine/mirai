package host

import "core:mem"
import "core:os"
import "core:time"
import "mirai:asset"
import "mirai:project"
import render "mirai:render"
import "mirai:std/base"
import "mirai:std/serial"

// What the lists of the renderer that grow (render.Capacity_Marks) asked for
// in each scene, so that a scene opened again starts its lists there and drops
// nothing the first time a view of it fills one: on its load and on entering a
// denser part of it. They live in the cache of the project
// (project.CAPACITY_CACHE); a game ships the one of its project, which its
// cook copies, and goes on filling it. The host of each run is its one writer:
// it writes when a scene opens and when a mark of the scene open grows, and
// takes in first what other runs wrote. A mark only grows, up to what the
// renderer takes of one; the file holds the scenes opened last
// (CAPACITY_SCENES), and a scene that shrinks for good keeps its marks until
// it is the oldest of them.

CAPACITY_SCENES :: 256
@(private="file") CAPACITY_MAGIC :: 0x5041434d

Capacity_Entry :: struct {
    scene:base.Asset_Id,
    marks:render.Capacity_Marks,
    opened:i64, // unix seconds when a run last opened it: the oldest gives way to a scene not kept
}

Capacities :: struct {
    entries:[CAPACITY_SCENES]Capacity_Entry,
    count:int,
    open:int, // 1 + the entry of the scene open, whose marks the lists of the renderer count from; 0: none
}

@(private="file")
Capacity_Header :: struct {magic,entry_size,count,pad:u32}

// A scene opens as the document or the world, by its path in the registry:
// the lists of the renderer start from what they asked for in it before.
// Another path, or none, leaves no scene open.
capacities_open :: proc(app:^App,path:string) {
    c:=&app.capacities
    c.open=0
    r:=app.renderer
    if r==nil {return}
    render.renderer_capacity_marks_set(r,{})
    if app.root=="" || app.assets==nil || path=="" {return}
    file,found:=asset.registry_find_path(&app.assets.registry,path)
    if !found || file.kind!=asset.KIND_SCENE || file.id=={} {return}
    stored:=capacities_path(app)
    capacities_take(c,stored)
    at,kept:=capacities_find(c,file.id)
    now:=time.time_to_unix(time.now())
    if !kept {
        if at=capacities_slot(c,now);at<0 {return}
        c.entries[at]={scene=file.id}
    }
    c.entries[at].opened=now
    c.open=at+1
    render.renderer_capacity_marks_set(r,c.entries[at].marks)
    capacities_write(c,stored)
}

// At the end of a frame: the marks of the scene open that grew are written.
capacities_frame :: proc(app:^App) {
    c:=&app.capacities
    if c.open==0 || app.renderer==nil {return}
    if !capacity_marks_grow(&c.entries[c.open-1].marks,render.renderer_capacity_marks(app.renderer)) {return}
    capacities_write(c,capacities_path(app))
}

// Raises each mark of into to that of from; whether one rose.
capacity_marks_grow :: proc "contextless" (into:^render.Capacity_Marks,from:render.Capacity_Marks) -> (grew:bool) {
    for &mark,list in into.cull {
        if from.cull[list]>mark {mark,grew=from.cull[list],true}
    }
    if from.points>into.points {into.points,grew=from.points,true}
    if from.mesh_draws>into.mesh_draws {into.mesh_draws,grew=from.mesh_draws,true}
    return
}

@(private="file")
capacities_path :: proc(app:^App) -> string {
    return project.cache_path(app.root,project.CAPACITY_CACHE,allocator=context.temp_allocator)
}

@(private="file")
capacities_find :: proc(c:^Capacities,scene:base.Asset_Id) -> (at:int,found:bool) {
    for e,i in c.entries[:c.count] {
        if e.scene==scene {return i,true}
    }
    return -1,false
}

// Where a scene not kept goes that was opened at opened: a free entry, or the
// oldest but the one open when it is older; -1 when none is.
@(private="file")
capacities_slot :: proc(c:^Capacities,opened:i64) -> int {
    if c.count<CAPACITY_SCENES {
        c.count+=1
        return c.count-1
    }
    oldest:=-1
    for e,i in c.entries {
        if i==c.open-1 {continue}
        if oldest<0 || e.opened<c.entries[oldest].opened {oldest=i}
    }
    return oldest if oldest>=0 && c.entries[oldest].opened<opened else -1
}

// What other runs wrote to the file since, taken in: their marks raise these,
// and their scenes not kept take the place of older ones.
capacities_take :: proc(c:^Capacities,path:string) {
    data,read_error:=os.read_entire_file(path,context.temp_allocator)
    if read_error!=nil || len(data)<size_of(Capacity_Header) {return}
    header:Capacity_Header
    mem.copy(&header,raw_data(data),size_of(header))
    if header.magic!=CAPACITY_MAGIC || header.entry_size!=size_of(Capacity_Entry) {return}
    count:=min(int(header.count),(len(data)-size_of(header))/size_of(Capacity_Entry),CAPACITY_SCENES)
    for i in 0..<count {
        theirs:Capacity_Entry
        mem.copy(&theirs,&data[size_of(header)+i*size_of(Capacity_Entry)],size_of(theirs))
        if theirs.scene=={} {continue}
        at,kept:=capacities_find(c,theirs.scene)
        if !kept {
            if at=capacities_slot(c,theirs.opened);at<0 {continue}
            c.entries[at]={scene=theirs.scene}
        }
        e:=&c.entries[at]
        capacity_marks_grow(&e.marks,theirs.marks)
        e.opened=max(e.opened,theirs.opened)
    }
}

// The file of path holds the entries of c, with what other runs wrote taken
// in. False when it cannot be written: the marks stay for this run.
capacities_write :: proc(c:^Capacities,path:string) -> bool {
    capacities_take(c,path)
    folder:=os.dir(path)
    if os.make_directory_all(folder)!=nil && !os.is_dir(folder) {return false}
    data:=make([]u8,size_of(Capacity_Header)+c.count*size_of(Capacity_Entry),context.temp_allocator)
    header:=Capacity_Header{magic=CAPACITY_MAGIC,entry_size=size_of(Capacity_Entry),count=u32(c.count)}
    mem.copy(raw_data(data),&header,size_of(header))
    if c.count>0 {mem.copy(&data[size_of(header)],&c.entries[0],c.count*size_of(Capacity_Entry))}
    return serial.file_write_atomic(path,data)==.None
}
