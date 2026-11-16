package fsr

import "core:testing"
import render "mirai:engine/render"

// RENDER_PASS_CAPACITY and RENDER_USE_CAPACITY of the renderer.
@(private="file")
PIPELINE_PASSES :: 40
@(private="file")
PASS_USES :: 16

@(test)
fsr_pipelines_fit_the_renderer_and_use_only_the_resources_they_declare :: proc(t:^testing.T) {
    state:Fsr_Runtime
    for sharpness in ([]f32{0,0.5}) {
        state.sharpness=sharpness
        for generate in ([]bool{false,true}) {
            desc:=fsr_pipeline(&state,generate)
            testing.expectf(t,len(desc.passes)<=PIPELINE_PASSES,"generate %v: %d passes",generate,len(desc.passes))
            testing.expect(t,desc.jitter==.Upscale)
            declared:bit_set[render.Render_Resource]
            for resource in desc.resources {
                testing.expectf(t,resource.id>=.Custom0 && resource.id not_in declared,"%v declared twice or not custom",resource.id)
                declared+={resource.id}
            }
            output:=-1
            generated:=false
            for pass,at in desc.passes {
                if pass.stage==.Output {output=at}
                testing.expectf(t,len(pass.uses)<=PASS_USES,"%s: %d uses",pass.name,len(pass.uses))
                for use in pass.uses {
                    testing.expectf(t,use.resource<.Custom0 || use.resource in declared,"%s uses %v undeclared",pass.name,use.resource)
                    if use.resource==.Generated {generated=true;testing.expect(t,output>=0 && at>output)}
                }
            }
            testing.expect(t,generated==generate)
        }
    }
}

@(test)
fsr_framegen_spd_matches_ffx_spd_setup :: proc(t:^testing.T) {
    groups_x,groups_y,levels:=fg_spd(1920,1080)
    testing.expect(t,groups_x==30 && groups_y==17 && levels==10)
    groups_x,groups_y,levels=fg_spd(1280,720)
    testing.expect(t,groups_x==20 && groups_y==12 && levels==10)
    s:render.Pass
    s.output_width,s.output_height=1920,1080
    testing.expect(t,fi_pyramid_levels(&s)==10)
    s.output_width,s.output_height=2560,1440
    testing.expect(t,fi_pyramid_levels(&s)==11)
}
