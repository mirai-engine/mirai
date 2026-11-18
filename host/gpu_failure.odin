package host

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "mirai:core"
import "mirai:rhi"

// A GPU that stops working (rhi.device_failure) does not end the application
// by itself: the frames go on without drawing, the worlds keep running, and
// the failure is reported once with where the GPU stopped. Whoever runs the
// application decides what follows: the player ends with PLAYER_GPU_LOST, the
// editor starts again with its documents.

// Frames after the shaders of the project were replaced in which a failure
// names them as its likely cause.
GPU_FAILURE_SHADER_FRAMES :: 600
GPU_FAILURE_TEXT :: 1024

// The failure of the GPU of the application and what it says of where the
// GPU stopped; None and "" while it works or without one.
app_gpu_failure :: proc(app:^App) -> (failure:rhi.Device_Failure,text:string) {
    if app.device==nil {return}
    failure,_=rhi.device_failure(app.device)
    if failure==.None {return}
    app_gpu_failure_check(app)
    return failure,string(app.gpu_failure[:app.gpu_failure_length])
}

// What the record of a late GPU submission (App_Desc.gpu_late_record) held
// when the application started: a run before that never saw a submission of
// its GPU finish, as a machine that froze or reset leaves it; "" when none.
app_gpu_late_before :: proc(app:^App) -> string {
    return string(app.gpu_late_before[:app.gpu_late_before_length])
}

// Keeps what a run before left in the record and removes it, before the
// device that writes it again is made, whose folder it makes.
@(private)
app_gpu_late_take :: proc(app:^App,path:string) {
    if path=="" {return}
    if data,error:=os.read_entire_file(path,context.temp_allocator);error==nil {
        app.gpu_late_before_length=copy(app.gpu_late_before[:],strings.trim_space(string(data)))
        _=os.remove(path)
    }
    _=os.make_directory_all(filepath.dir(path))
}

// The first frame that sees the failure reports it: in the log, and as a
// problem of the world of the player.
@(private)
app_gpu_failure_check :: proc(app:^App) {
    if app.gpu_failure_length>0 || app.device==nil {return}
    failure,text:=rhi.device_failure(app.device)
    if failure==.None {return}
    sh:=&app.shaders
    since:=app.stats.frames-sh.published_frame
    replaced:=fmt.tprintf("; the shaders of the project were replaced %d frames before: one of their stages is the likely cause",since) if sh.reloads>0 && since<GPU_FAILURE_SHADER_FRAMES else ""
    message:=fmt.bprintf(app.gpu_failure[:],"the GPU device stopped working (%v): %s%s",failure,text,replaced)
    app.gpu_failure_length=len(message)
    log.error(message)
    if app.world!=nil {core.report(app_world_storage(app,app.world,core.Problems),core.NONE,"gpu.failure","%s. Nothing is drawn any more: start the application again",message)}
}
