package save

import "base:runtime"
import "core:c"
import "core:math"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/jobs"
import "mirai:std/serial"
import stbi "vendor:stb/image"

// A slot is captured at once and written later: with a renderer it waits for
// its thumbnail, the view of the player drawn without the interfaces of the
// scene into a texture that comes back to the CPU a few frames after, without
// waiting for the GPU; then a job makes the PNG and writes the file, one slot
// at a time, so two writes of a slot end as the last one asked. Its Result
// comes once the file is written. A load or a delete first writes what is
// pending, and so does a world that goes, without the thumbnails it waits for.

THUMBNAIL_SIZE :: [2]u32{320,180} // pixels of the thumbnail of a slot, drawn at twice that and halved
THUMBNAIL_WAIT :: 30              // frames a slot waits for its thumbnail before it is written without one
WRITES_CAPACITY :: 4              // slots captured and not written yet; past it a save is Busy
SECTIONS_TRACKED :: 32            // Manual sections on at once that autosave_section follows

@(private)
Write_Phase :: enum u8 {Thumbnail,Ready,Writing}

@(private)
Write :: struct {
    result:Result,
    phase:Write_Phase,
    path:string,   // allocator of the application
    data:[]u8,     // the slot without its thumbnail, as capture writes it
    asked:u64,     // Save_Work.frame when it was captured
    pixels:[]u8,   // RGBA8 at twice THUMBNAIL_SIZE; nil: none
    allocator:runtime.Allocator,
    counter:jobs.Counter,
    error:Error,   // of the job
}

// What the save library keeps of each world and does not copy with it: the
// slots it writes, the texture of their thumbnails and what the autosaves follow.
@(storage,host,by_world,free="work_free")
Save_Work :: struct {
    writes:[dynamic]^Write,
    frame:u64,     // frames this world served
    texture:erender.Texture_Handle,
    drawn:u64,     // the frame the thumbnail was drawn for the slots captured by then; 0: none under way
    seen:u64,      // the frame of the renderer of the image the texture brought back before that one
    scene:base.Asset_Id, // the scene the world was (scene.Scene_Root), and how many times one replaced it
    changes:u32,
    sections:[SECTIONS_TRACKED]core.Entity, // the Manual sections on
    section_count:int,
    sections_seen:bool, // some Manual section was on since a scene last replaced the world
    due:bool,           // an autosave waits for room
    watching:bool,      // the files of the player have been looked at (kept_watch)
    kept:[Kept_File]project.Rest,
}

work_free :: proc(work:^Save_Work) {
    for w in work.writes {write_free(w)}
    delete(work.writes)
    work.writes=nil
}

@(private)
write_free :: proc(w:^Write) {
    delete(w.path,w.allocator)
    mem.free_bytes(w.data,w.allocator)
    delete(w.pixels,w.allocator)
    free(w,w.allocator)
}

// Queues the bytes of a slot captured now, which it takes, to be written to path.
@(private)
write_queue :: proc(work:^Save_Work,renderer:^erender.Renderer,allocator:runtime.Allocator,result:Result,path:string,data:[]u8) -> Error {
    if len(work.writes)>=WRITES_CAPACITY {
        mem.free_bytes(data,allocator)
        return .Busy
    }
    if work.writes==nil {work.writes=make([dynamic]^Write,allocator)}
    w,no_write:=new(Write,allocator)
    kept,no_path:=strings.clone(path,allocator)
    if no_write!=nil || no_path!=nil || reserve(&work.writes,len(work.writes)+1)!=nil {
        delete(kept,allocator)
        free(w,allocator)
        mem.free_bytes(data,allocator)
        return .Failed
    }
    w^={result=result,phase=renderer!=nil?.Thumbnail:.Ready,path=kept,data=data,asked=work.frame,allocator=allocator}
    append(&work.writes,w)
    return .None
}

// Whether the slot at path waits to be written.
@(private)
writes_of :: proc(work:^Save_Work,path:string) -> bool {
    if work==nil {return false}
    for w in work.writes {if w.path==path {return true}}
    return false
}

// Takes the thumbnail that came back, starts the next write and collects the
// one that ended, pushing its Result.
@(private)
writes_step :: proc(work:^Save_Work,renderer:^erender.Renderer,job_system:^jobs.Job_System,results:^Save_Results,problems:^core.Problems) {
    if work.drawn!=0 {
        pixels,frame,came:=erender.view_texture_pixels(renderer,work.texture)
        came&&=frame>work.seen
        if came {
            for w in work.writes {
                if w.phase!=.Thumbnail || w.asked>work.drawn {continue}
                no_pixels:runtime.Allocator_Error
                if w.pixels,no_pixels=slice.clone(pixels,w.allocator);no_pixels!=nil {
                    core.report(problems,core.NONE,"save.thumbnail","the slot %s is written without its thumbnail: there is no memory for the image; free memory and save again",base.text_get(w.result.slot[:]))
                }
                w.phase=.Ready
            }
        }
        if came || work.frame-work.drawn>THUMBNAIL_WAIT {work.drawn=0}
    }
    // A world that is not drawn, or a renderer that did not bring the image back.
    for w in work.writes {
        if w.phase==.Thumbnail && work.frame-w.asked>THUMBNAIL_WAIT {w.phase=.Ready}
    }
    for len(work.writes)>0 {
        w:=work.writes[0]
        switch w.phase {
        case .Thumbnail: return
        case .Ready:
            w.phase=.Writing
            if jobs.worker_count(job_system)>1 {jobs.run(job_system,jobs.OWNER,write_job,w,&w.counter)} else {write_job(w,0)}
        case .Writing:
            if jobs.pending(&w.counter) {return}
            write_end(work,w,results)
        }
    }
}

// Writes what is pending now, the thumbnails it still waits for aside, and
// pushes their Results: for a world whose next frames may not come.
writes_flush :: proc(work:^Save_Work,job_system:^jobs.Job_System,results:^Save_Results) {
    if work==nil {return}
    for len(work.writes)>0 {
        w:=work.writes[0]
        switch w.phase {
        case .Thumbnail,.Ready: write_job(w,0)
        case .Writing: if jobs.pending(&w.counter) {jobs.wait(job_system,jobs.OWNER,&w.counter)}
        }
        write_end(work,w,results)
    }
    work.drawn=0
}

@(private)
write_end :: proc(work:^Save_Work,w:^Write,results:^Save_Results) {
    result:=w.result
    result.error=w.error
    if results!=nil {core.push(&results.queue,result)}
    write_free(w)
    ordered_remove(&work.writes,0)
}

@(private)
write_job :: proc(w:^Write,worker:int) {
    w.error=slot_file_write(w.path,w.data,w.pixels)
}

// Writes the bytes of a slot as capture made them, with the PNG of pixels
// (RGBA8 at twice THUMBNAIL_SIZE) after the header, replacing the file.
@(private)
slot_file_write :: proc(path:string,data:[]u8,pixels:[]u8) -> Error {
    png:[]u8
    if pixels!=nil {
        made:bool
        if png,made=thumbnail_png(pixels,context.temp_allocator);!made {return .Write_Failed}
    }
    out:serial.Writer
    serial.writer_init(&out,len(data)+len(png)+2*serial.WRITER_ALIGNMENT,context.temp_allocator)
    header:=(cast(^Header)raw_data(data))^
    header.thumbnail=u32(len(png))
    serial.write_bytes(&out,mem.ptr_to_bytes(&header))
    serial.write_align(&out,serial.WRITER_ALIGNMENT)
    serial.write_bytes(&out,png)
    serial.write_align(&out,serial.WRITER_ALIGNMENT)
    serial.write_bytes(&out,data[mem.align_forward_int(size_of(Header),serial.WRITER_ALIGNMENT):])
    if out.overflow!=0 {return .Write_Failed}
    dir:=filepath.dir(path)
    if os.make_directory_all(dir)!=nil && !os.is_dir(dir) {return .Write_Failed}
    return serial.file_write_atomic(path,serial.writer_bytes(&out))==.None?.None:.Write_Failed
}

// The PNG of the thumbnail: the pixels halved, averaging each four in a
// gamma of 2, which keeps the light of their edges, and without alpha. None,
// and made, for pixels of another size; not made without memory for it.
@(private)
thumbnail_png :: proc(pixels:[]u8,allocator:runtime.Allocator) -> (png:[]u8,made:bool) {
    width,height:=int(THUMBNAIL_SIZE.x),int(THUMBNAIL_SIZE.y)
    if len(pixels)!=width*height*16 {return nil,true}
    image,no_image:=make([]u8,width*height*3,allocator)
    if no_image!=nil {return nil,false}
    for y in 0..<height {
        for x in 0..<width {
            for channel in 0..<3 {
                sum:f32
                for corner in 0..<4 {
                    v:=f32(pixels[((2*y+corner/2)*2*width+2*x+corner%2)*4+channel])
                    sum+=v*v
                }
                image[(y*width+x)*3+channel]=u8(math.sqrt(sum/4)+0.5)
            }
        }
    }
    Sink :: struct {bytes:[dynamic]u8,cut:bool}
    sink:=Sink{bytes=make([dynamic]u8,allocator)}
    sink_write :: proc "c" (user,data:rawptr,size:c.int) {
        sink:=cast(^Sink)user
        context=runtime.default_context()
        if _,error:=append(&sink.bytes,..([^]u8)(data)[:size]);error!=nil {sink.cut=true}
    }
    if stbi.write_png_to_func(sink_write,&sink,c.int(width),c.int(height),3,raw_data(image),c.int(width*3))==0 {return nil,true}
    if sink.cut {return nil,false}
    return sink.bytes[:],true
}

// Draws the view of the player for the slots that wait for their thumbnail:
// into a texture of the save library, without the interfaces of the scene,
// as a cut: it owes nothing to its last image, and meters its exposure at once.
@(step="render",loops="game")
saves_thumbnail :: proc(renderer:^erender.Renderer,extras:^host.Frame_Extras,work:^Save_Work,view:core.Ref(core.View)) {
    if work==nil || work.drawn!=0 {return}
    waiting:=false
    for w in work.writes {waiting||=w.phase==.Thumbnail}
    if !waiting {return}
    size:=THUMBNAIL_SIZE*2
    if work.texture==0 {work.texture,_=erender.view_texture_add(renderer,size.x,size.y,"save thumbnail")}
    seen:=view.ptr^
    seen.size={f32(size.x),f32(size.y)}
    _,work.seen,_=erender.view_texture_pixels(renderer,work.texture)
    if work.texture==0 || !erender.view_texture_draw(extras,work.texture,seen,size.x,size.y,cut=true,readback=true) {
        for w in work.writes {if w.phase==.Thumbnail {w.phase=.Ready}}
        return
    }
    work.drawn=work.frame
}

// A world that goes writes the slots it holds and what the files of the player
// have not got yet, and lets go of the thumbnails it showed.
@(step="release")
saves_release :: proc(world:core.World_Ref,work:^Save_Work,thumbnails:^Save_Thumbnails,app:^host.App,state:^Save_State,problems:^core.Problems) {
    thumbnails_release(thumbnails,app.assets)
    if work==nil {return}
    writes_flush(work,&app.jobs,nil)
    kept_flush(work,world,app,state,problems)
    if work.texture!=0 {erender.view_texture_remove(app.renderer,work.texture)}
    work.texture=0
}
