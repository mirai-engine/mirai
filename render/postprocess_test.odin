package mirai_render

import "core:mem"
import "core:testing"
import "mirai:rhi"

@(test)
postprocess_gpu_order_stage_filter_and_hdr_ldr_precision :: proc(t:^testing.T) {
    settings:=DEFAULT_SETTINGS;settings.gi_enabled=false;settings.taa=false;settings.trace_mode=.Software
    f:Fixture
    if !fixture_init(t,&f,8,8,settings,hardware_rt=false) {return}
    defer fixture_destroy(&f)
    r,d:=f.renderer,f.device
    // Embedded ColorGrade: float3 tint at byte0, strength12, contrast16.
    a:=Postprocess_Desc{program=1,enabled=true};a.params[0]={2,2,2,1};a.params[1].x=1
    b:=Postprocess_Desc{program=1,enabled=true};b.params[0]={1,1,1,1};b.params[1].x=2
    after:=Postprocess_Desc{program=1,enabled=true,after_tonemap=true};after.params[0]={.5,.5,.5,1};after.params[1].x=1
    hdr:[8*8][4]f16;ldr:[8*8][4]u8
    for i in 0..<len(hdr) {hdr[i]={.2,.4,.6,1};ldr[i]={51,102,153,255}}
    testing.expect(t,rhi.texture_upload(d,r.targets.display,mem.slice_data_cast([]u8,hdr[:]),8*8))
    testing.expect(t,rhi.texture_upload(d,r.targets.ldr,mem.slice_data_cast([]u8,ldr[:]),8*4))
    execute :: proc(t:^testing.T,r:^Renderer,input:rhi.Texture,after:bool,inspection:=View_Inspection{})->rhi.Texture {
        cmd,ok:=rhi.frame_begin(r.device);testing.expect(t,ok,rhi.device_error(r.device));if !ok {return input}
        frame:=Gpu_Frame{resolution={8,8},inv_resolution={.125,.125}}
        rhi.cmd_set_constants(cmd,SLOT_FRAME,&frame,size_of(frame))
        rhi.cmd_bind_sampler(cmd,SLOT_LINEAR_SAMPLER,r.linear_sampler);rhi.cmd_bind_sampler(cmd,SLOT_POINT_SAMPLER,r.point_sampler)
        pass:=Pass{r=r,cmd=cmd,view=&r.main,t=&r.main.targets,inspection=inspection}
        target:=postprocess_passes(&pass,input,after)
        testing.expect(t,rhi.frame_end(r.device,cmd),rhi.device_error(r.device))
        return target
    }
    // An exposure of one: the effects before the tonemap see the values as they are.
    made:=rhi.immediate_begin(d);testing.expect(t,view_exposure_buffers(r,made,&r.main));testing.expect(t,rhi.immediate_end(d,made))
    one:=[1]Gpu_Exposure{{exposure=1,valid=1}};testing.expect(t,rhi.buffer_upload_slice(d,r.main.exposure,0,one[:]))
    renderer_set_postprocesses(r,{count=3,entries={0=a,1=after,2=b}})
    target:=execute(t,r,r.targets.display,false)
    testing.expect_value(t,target,r.targets.post_hdr[1])
    pixels:[8*8][4]f16;testing.expect(t,golden_read_texture(d,target,mem.slice_data_cast([]u8,pixels[:])))
    expected:=Vec3{.3,1.1,1.9}
    for axis in 0..<3 {testing.expectf(t,abs(f32(pixels[0][axis])-expected[axis])<.003,"HDR axis%d got%v expected%v",axis,f32(pixels[0][axis]),expected[axis])}
    // A view inspected after the first effect of its side shows the image it leaves.
    target=execute(t,r,r.targets.display,false,{postprocess={limited=true,effects={1,0}}})
    testing.expect_value(t,target,r.targets.post_hdr[0])
    testing.expect(t,golden_read_texture(d,target,mem.slice_data_cast([]u8,pixels[:])))
    expected={.4,.8,1.2}
    for axis in 0..<3 {testing.expectf(t,abs(f32(pixels[0][axis])-expected[axis])<.003,"Inspected axis%d got%v expected%v",axis,f32(pixels[0][axis]),expected[axis])}
    testing.expect_value(t,execute(t,r,r.targets.display,false,{postprocess={limited=true}}),r.targets.display)
    // A faded effect leaves that share of the image as it read it: half at 0.5; at 1 it does not run.
    half:=a;half.fade=.5
    renderer_set_postprocesses(r,{count=1,entries={0=half}})
    target=execute(t,r,r.targets.display,false)
    testing.expect(t,golden_read_texture(d,target,mem.slice_data_cast([]u8,pixels[:])))
    expected={.3,.6,.9}
    for axis in 0..<3 {testing.expectf(t,abs(f32(pixels[0][axis])-expected[axis])<.003,"Faded axis%d got%v expected%v",axis,f32(pixels[0][axis]),expected[axis])}
    gone:=a;gone.fade=1
    renderer_set_postprocesses(r,{count=1,entries={0=gone}})
    faded:=Pass{r=r}
    testing.expect(t,!postprocess_active(&faded,false),"an effect faded out is none to run")
    testing.expect_value(t,execute(t,r,r.targets.display,false),r.targets.display)
    renderer_set_postprocesses(r,{count=3,entries={0=b,1=after,2=a}})
    target=execute(t,r,r.targets.display,false)
    testing.expect(t,golden_read_texture(d,target,mem.slice_data_cast([]u8,pixels[:])))
    expected={-.2,.6,1.4}
    for axis in 0..<3 {testing.expectf(t,abs(f32(pixels[0][axis])-expected[axis])<.003,"Reordered axis%d got%v expected%v",axis,f32(pixels[0][axis]),expected[axis])}
    target=execute(t,r,r.targets.ldr,true)
    testing.expect_value(t,target,r.targets.post_ldr[0])
    testing.expect(t,golden_read_texture(d,target,mem.slice_data_cast([]u8,ldr[:])))
    testing.expectf(t,abs(int(ldr[0][0])-26)<=1 && abs(int(ldr[0][1])-51)<=1 && abs(int(ldr[0][2])-77)<=1,"After-tonemap got%v expected26,51,77",ldr[0])
    after.enabled=false;renderer_set_postprocesses(r,{count=1,entries={0=after}})
    testing.expect_value(t,execute(t,r,r.targets.ldr,true),r.targets.ldr)
    testing.expect_value(t,rhi.device_validation_errors(d),0)
}

// An effect reads the image of the stack around its pixel: the Blur program
// spreads an edge between black and white and leaves what is far from it.
@(test)
postprocess_reads_the_image_around_its_pixel :: proc(t:^testing.T) {
    settings:=DEFAULT_SETTINGS;settings.gi_enabled=false;settings.taa=false;settings.trace_mode=.Software
    f:Fixture
    if !fixture_init(t,&f,16,8,settings,hardware_rt=false) {return}
    defer fixture_destroy(&f)
    r,d:=f.renderer,f.device
    blur:=program_find(r,"Blur",.Postprocess)
    if !testing.expect(t,blur!=nil,"the Blur program is built in") {return}
    // radius at byte 0, strength at 4.
    effect:=Postprocess_Desc{program=blur.id,enabled=true};effect.params[0]={2,1,0,0}
    hdr:[16*8][4]f16
    for y in 0..<8 {for x in 0..<16 {v:=f16(1 if x>=8 else 0);hdr[y*16+x]={v,v,v,1}}}
    testing.expect(t,rhi.texture_upload(d,r.targets.display,mem.slice_data_cast([]u8,hdr[:]),16*8))
    made:=rhi.immediate_begin(d);testing.expect(t,view_exposure_buffers(r,made,&r.main));testing.expect(t,rhi.immediate_end(d,made))
    one:=[1]Gpu_Exposure{{exposure=1,valid=1}};testing.expect(t,rhi.buffer_upload_slice(d,r.main.exposure,0,one[:]))
    renderer_set_postprocesses(r,{count=1,entries={0=effect}})
    cmd,began:=rhi.frame_begin(d);testing.expect(t,began,rhi.device_error(d));if !began {return}
    frame:=Gpu_Frame{resolution={16,8},inv_resolution={1.0/16,.125}}
    rhi.cmd_set_constants(cmd,SLOT_FRAME,&frame,size_of(frame))
    rhi.cmd_bind_sampler(cmd,SLOT_LINEAR_SAMPLER,r.linear_sampler);rhi.cmd_bind_sampler(cmd,SLOT_POINT_SAMPLER,r.point_sampler)
    pass:=Pass{r=r,cmd=cmd,view=&r.main,t=&r.main.targets}
    target:=postprocess_passes(&pass,r.targets.display,false)
    testing.expect(t,rhi.frame_end(d,cmd),rhi.device_error(d))
    pixels:[16*8][4]f16;testing.expect(t,golden_read_texture(d,target,mem.slice_data_cast([]u8,pixels[:])))
    at :: proc(pixels:[16*8][4]f16,x:int) -> f32 {return f32(pixels[4*16+x][0])}
    testing.expectf(t,at(pixels,0)<.01 && at(pixels,15)>.99,"far from the edge the image stays: %v and %v",at(pixels,0),at(pixels,15))
    testing.expectf(t,at(pixels,7)>.05 && at(pixels,7)<.5,"black beside the edge takes some white: %v",at(pixels,7))
    testing.expectf(t,at(pixels,8)>.5 && at(pixels,8)<.95,"white beside the edge takes some black: %v",at(pixels,8))
    testing.expect_value(t,rhi.device_validation_errors(d),0)
}
