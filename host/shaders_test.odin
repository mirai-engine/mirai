package host

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import render "mirai:render"
import "mirai:rhi"
import "mirai:rhi/shared_device"

@(private="file")
GENERATION :: #directory+"/../shaders/build"

// A copy of the generation of the engine whose manifest names a stage
// otherwise: for the renderer its code is another one.
@(private="file")
generation_renamed :: proc(t:^testing.T,stage,name:string) -> string {
    folder,err:=os.make_directory_temp("","mirai-host-shaders-*",context.temp_allocator)
    testing.expect(t,err==nil)
    entries,_:=os.read_all_directory_by_path(GENERATION,context.temp_allocator)
    for entry in entries {
        if os.is_directory(entry.fullpath) {continue}
        data,_:=os.read_entire_file(entry.fullpath,context.temp_allocator)
        if entry.name=="manifest.json" && stage!="" {
            changed,_:=strings.replace(string(data),fmt.tprintf("\"name\": \"%s\"",stage),fmt.tprintf("\"name\": \"%s\"",name),1,context.temp_allocator)
            data=transmute([]u8)changed
        }
        testing.expect(t,os.write_entire_file(fmt.tprintf("%s/%s",folder,entry.name),data)==nil)
    }
    return folder
}

// Between frames until the loads end.
@(private="file")
loads_settle :: proc(app:^App) {
    started:=time.tick_now()
    for len(app.shaders.loads)>0 && time.duration_seconds(time.tick_since(started))<60 {
        app_shaders_poll(app)
        time.sleep(5*time.Millisecond)
    }
}

@(test)
generations_load_off_the_frames_in_the_order_they_were_asked_for :: proc(t:^testing.T) {
    device:=shared_device.take_or_skip(t,hardware_rt=false)
    if device==nil {return}
    r:=new(render.Renderer);defer free(r)
    if !render.renderer_init(r,{device=device,width=64,height=64}) {testing.expect(t,false,r.error);return}
    defer render.renderer_destroy(r)
    app:App
    app.allocator=context.allocator
    app.renderer=r
    app.shaders.loads=make([dynamic]^Shaders_Load,app.allocator)
    defer app_shaders_close(&app)
    same:=generation_renamed(t,"","")
    defer os.remove_all(same)
    capture:=generation_renamed(t,"thumbnail_values.frag","changed capture")
    defer os.remove_all(capture)
    compositor:=generation_renamed(t,"composite.comp","changed compositor")
    defer os.remove_all(compositor)

    // The codes the renderer runs: the catalog alone, without new pipelines.
    pipelines:=r.pipelines
    first:=app_shaders_load(&app,same)
    testing.expect(t,first!=0)
    loads_settle(&app)
    testing.expect_value(t,app.shaders.published,first)
    testing.expect_value(t,r.pipelines,pipelines)

    // Two that change code: a dropped one never gets in, and asking again
    // for one that loads is the same load.
    dropped:=app_shaders_load(&app,capture)
    later:=app_shaders_load(&app,compositor)
    testing.expect(t,dropped!=0 && later>dropped)
    testing.expect_value(t,app_shaders_load(&app,compositor),later)
    testing.expect(t,app_shaders_loading(&app,dropped) && app_shaders_loading(&app,later))
    app_shaders_drop(&app,dropped)
    loads_settle(&app)
    testing.expect(t,!app_shaders_loading(&app,dropped) && !app_shaders_loading(&app,later))
    testing.expect_value(t,app.shaders.published,later)
    testing.expect_value(t,r.shader_codes[.Composite_Comp].name,"changed compositor")
    testing.expect_value(t,r.shader_codes[.Thumbnail_Values_Frag].name,"thumbnail_values.frag")
    testing.expect(t,r.pipelines[.Composite]!=pipelines[.Composite] && r.pipelines[.Composite]!=0,"the code that changed has new pipelines")
    testing.expect_value(t,app.shaders.reloads,u64(2))
    testing.expect_value(t,app.shaders.state,Shaders_State.Loaded)

    // Closing waits for the pipeline the driver compiles and publishes nothing.
    pending:=app_shaders_load(&app,capture)
    testing.expect(t,app_shaders_loading(&app,pending))
    app_shaders_close(&app)
    testing.expect_value(t,r.shader_codes[.Thumbnail_Values_Frag].name,"thumbnail_values.frag")
    testing.expectf(t,rhi.device_validation_errors(device)==0,"validation: %s",rhi.device_validation_message(device))
}
