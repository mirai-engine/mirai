package mirai_render

import "core:math"
import "core:mem"
import "core:testing"
import "mirai:rhi"

// The values of ColorGrade by its parameters, in the order of its source.
@(private="file")
Grade :: struct {
    tint:[3]f32,
    saturation,contrast:[3]f32,
    shadows_saturation,shadows_contrast:[3]f32,
    shadows_end:f32,
    midtones_saturation,midtones_contrast:[3]f32,
    highlights_saturation,highlights_contrast:[3]f32,
    highlights_start,highlights_end:f32,
}

@(private="file")
GRADE_DEFAULT :: Grade{
    tint=1,saturation=1,contrast=1,shadows_saturation=1,shadows_contrast=1,shadows_end=0.09,
    midtones_saturation=1,midtones_contrast=1,highlights_saturation=1,highlights_contrast=1,highlights_start=0.5,highlights_end=1,
}

// The effect of the built-in ColorGrade with the values of g, each at the
// offset of its parameter.
@(private="file")
grade_desc :: proc(r:^Renderer,g:Grade) -> (desc:Postprocess_Desc) {
    program:=program_find(r,"ColorGrade",.Postprocess)
    if program==nil {return}
    desc.program,desc.enabled=program.id,true
    words:=(^[64]f32)(&desc.params)
    words[int(program_parameter(program,"strength").offset)/4]=1
    g:=g
    values:=[?]struct{name:string,value:[]f32}{
        {"tint",g.tint[:]},{"saturation",g.saturation[:]},{"contrast",g.contrast[:]},
        {"shadows_saturation",g.shadows_saturation[:]},{"shadows_contrast",g.shadows_contrast[:]},{"shadows_end",([^]f32)(&g.shadows_end)[:1]},
        {"midtones_saturation",g.midtones_saturation[:]},{"midtones_contrast",g.midtones_contrast[:]},
        {"highlights_saturation",g.highlights_saturation[:]},{"highlights_contrast",g.highlights_contrast[:]},
        {"highlights_start",([^]f32)(&g.highlights_start)[:1]},{"highlights_end",([^]f32)(&g.highlights_end)[:1]},
    }
    for v in values {
        parameter:=program_parameter(program,v.name)
        if parameter==nil || int(parameter.components)!=len(v.value) {return {}}
        for x,i in v.value {words[int(parameter.offset)/4+i]=x}
    }
    return
}

// What ColorGrade gives c: Unreal's correction of the exposed image, with
// the luminance of the working space.
@(private="file")
grade_reference :: proc(c:[3]f32,g:Grade) -> [3]f32 {
    color:=c*g.tint
    luma:=0.2126*color.r+0.7152*color.g+0.0722*color.b
    corrected :: proc(color:[3]f32,luma:f32,saturation,contrast:[3]f32) -> (out:[3]f32) {
        for i in 0..<3 {
            v:=max(luma+(color[i]-luma)*saturation[i],1e-8)
            out[i]=math.pow(v/0.18,contrast[i])*0.18
        }
        return
    }
    smooth :: proc(a,b,x:f32) -> f32 {t:=clamp((x-a)/(b-a),0,1);return t*t*(3-2*t)}
    shadows:=1-smooth(0,g.shadows_end,luma)
    highlights:=smooth(g.highlights_start,g.highlights_end,luma)
    return corrected(color,luma,g.saturation*g.shadows_saturation,g.contrast*g.shadows_contrast)*shadows+
        corrected(color,luma,g.saturation*g.midtones_saturation,g.contrast*g.midtones_contrast)*(1-shadows-highlights)+
        corrected(color,luma,g.saturation*g.highlights_saturation,g.contrast*g.highlights_contrast)*highlights
}

@(test)
postprocess_gpu_order_stage_filter_and_hdr_ldr_precision :: proc(t:^testing.T) {
    settings:=DEFAULT_SETTINGS;settings.gi_enabled=false;settings.taa=false;settings.trace_mode=.Software
    f:Fixture
    if !fixture_init(t,&f,8,8,settings,hardware_rt=false) {return}
    defer fixture_destroy(&f)
    r,d:=f.renderer,f.device
    // The passes run on the targets of the scene of the window, which its first frame makes.
    if !testing.expect(t,scene_targets(r,&r.main),r.error) {return}
    doubled,raised,halved:=GRADE_DEFAULT,GRADE_DEFAULT,GRADE_DEFAULT
    doubled.tint,raised.contrast,halved.tint=2,.5,.5
    a,b,after:=grade_desc(r,doubled),grade_desc(r,raised),grade_desc(r,halved)
    after.after_tonemap=true
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
    // b raises each channel to its contrast around middle gray: 0.18·(c/0.18)^0.5.
    expected:=Vec3{.268328,.379473,.464758}
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
    expected={.379473,.536656,.657267}
    for axis in 0..<3 {testing.expectf(t,abs(f32(pixels[0][axis])-expected[axis])<.003,"Reordered axis%d got%v expected%v",axis,f32(pixels[0][axis]),expected[axis])}
    target=execute(t,r,r.targets.ldr,true)
    testing.expect_value(t,target,r.targets.post_ldr[0])
    testing.expect(t,golden_read_texture(d,target,mem.slice_data_cast([]u8,ldr[:])))
    testing.expectf(t,abs(int(ldr[0][0])-26)<=1 && abs(int(ldr[0][1])-51)<=1 && abs(int(ldr[0][2])-77)<=1,"After-tonemap got%v expected26,51,77",ldr[0])
    after.enabled=false;renderer_set_postprocesses(r,{count=1,entries={0=after}})
    testing.expect_value(t,execute(t,r,r.targets.ldr,true),r.targets.ldr)
    testing.expect_value(t,rhi.device_validation_errors(d),0)
}

// ColorGrade holds Unreal's correction of the exposed image: each channel
// pulled from the luminance by its saturation and raised to its contrast
// around middle gray, for the whole image times its shadows, midtones and
// highlights by luminance; its defaults leave the image as it is.
@(test)
the_color_grade_saturates_around_luminance_and_contrasts_around_middle_gray :: proc(t:^testing.T) {
    settings:=DEFAULT_SETTINGS;settings.gi_enabled=false;settings.taa=false;settings.trace_mode=.Software
    f:Fixture
    if !fixture_init(t,&f,8,8,settings,hardware_rt=false) {return}
    defer fixture_destroy(&f)
    r,d:=f.renderer,f.device
    // The passes run on the targets of the scene of the window, which its first frame makes.
    if !testing.expect(t,scene_targets(r,&r.main),r.error) {return}
    // Each row holds these colors.
    colors:=[8][3]f32{{.01,.02,.005},{.05,.04,.03},{.2,.4,.6},{.18,.18,.18},{.9,.6,.3},{.7,.75,.8},{2,1.5,1},{0,0,0}}
    hdr:[8*8][4]f16
    for i in 0..<len(hdr) {c:=colors[i%8];hdr[i]={f16(c.r),f16(c.g),f16(c.b),1}}
    made:=rhi.immediate_begin(d);testing.expect(t,view_exposure_buffers(r,made,&r.main));testing.expect(t,rhi.immediate_end(d,made))
    one:=[1]Gpu_Exposure{{exposure=1,valid=1}};testing.expect(t,rhi.buffer_upload_slice(d,r.main.exposure,0,one[:]))
    gray,vivid,zones:=GRADE_DEFAULT,GRADE_DEFAULT,GRADE_DEFAULT
    gray.saturation=0
    vivid.saturation,vivid.contrast={2,1.5,1},{1.5,1,.5}
    zones.contrast=1.25
    zones.shadows_saturation,zones.midtones_contrast,zones.highlights_saturation,zones.highlights_contrast={0,0,0},{.8,.8,.8},{.5,.5,.5},{2,2,2}
    zones.shadows_end,zones.highlights_start,zones.highlights_end=.06,.3,1.2
    cases:=[?]struct{name:string,grade:Grade}{{"defaults",GRADE_DEFAULT},{"gray",gray},{"vivid",vivid},{"zones",zones}}
    for c in cases {
        testing.expect(t,rhi.texture_upload(d,r.targets.display,mem.slice_data_cast([]u8,hdr[:]),8*8))
        renderer_set_postprocesses(r,{count=1,entries={0=grade_desc(r,c.grade)}})
        cmd,began:=rhi.frame_begin(d);testing.expect(t,began,rhi.device_error(d));if !began {return}
        frame:=Gpu_Frame{resolution={8,8},inv_resolution={.125,.125}}
        rhi.cmd_set_constants(cmd,SLOT_FRAME,&frame,size_of(frame))
        rhi.cmd_bind_sampler(cmd,SLOT_LINEAR_SAMPLER,r.linear_sampler);rhi.cmd_bind_sampler(cmd,SLOT_POINT_SAMPLER,r.point_sampler)
        pass:=Pass{r=r,cmd=cmd,view=&r.main,t=&r.main.targets}
        target:=postprocess_passes(&pass,r.targets.display,false)
        testing.expect(t,rhi.frame_end(d,cmd),rhi.device_error(d))
        pixels:[8*8][4]f16;testing.expect(t,golden_read_texture(d,target,mem.slice_data_cast([]u8,pixels[:])))
        for color,i in colors {
            input:=[3]f32{f32(hdr[i].r),f32(hdr[i].g),f32(hdr[i].b)}
            expected:=grade_reference(input,c.grade)
            if c.name=="defaults" {expected=input}
            for axis in 0..<3 {
                got:=f32(pixels[i][axis])
                testing.expectf(t,abs(got-expected[axis])<=.002+.002*abs(expected[axis]),"%s: %v axis %d got %v expected %v",c.name,color,axis,got,expected[axis])
            }
        }
    }
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
    // The passes run on the targets of the scene of the window, which its first frame makes.
    if !testing.expect(t,scene_targets(r,&r.main),r.error) {return}
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
