package mirai_render

import "core:math"
import "core:strings"
import "core:testing"
import "mirai:rhi"

@(test)
render_draws_the_same_image_with_a_generation_loaded_from_disk :: proc(t:^testing.T) {
    settings:=DEFAULT_SETTINGS
    settings.trace_mode=.Software
    settings.probe_budget,settings.probe_rays,settings.probe_grid,settings.probe_cascades=64,32,4,2
    // Six frames of one triangle under the sun, from a renderer just made.
    capture :: proc(t:^testing.T,r:^Renderer) -> []u8 {
        vertices:=[3]Mesh_Vertex{
            {position={-1,0,-1},normal={0,1,0},color={1,0.5,0.2}},{position={1,0,-1},normal={0,1,0},color={1,0.5,0.2}},{position={0,0,1},normal={0,1,0},color={1,0.5,0.2}},
        }
        mesh,added:=mesh_add(r,vertices[:],[]u32{0,2,1})
        testing.expect(t,added)
        scene_set(r,{{object_id=1,mesh=mesh,transform=Mat4(1),tint={1,1,1}}},nil,{direction={0.2,1,0.1},color={1,1,1},illuminance=1 * math.PI,enabled=true},{sky={0.3,0.4,0.6}})
        camera:=Camera{position={0,3,2},forward={0,-3,-2},up={0,1,0},fov_y=60,near=0.05,far=50,exposure=UNIT_EXPOSURE}
        for _ in 0..<6 {testing.expect(t,renderer_frame(r, {camera = camera}),r.error)}
        rhi.device_wait_idle(r.device)
        pixels,_,_,ok:=renderer_capture(r)
        testing.expect(t,ok,r.error)
        return pixels
    }
    f:Fixture
    if !fixture_init(t,&f,96,64,settings,hardware_rt=false) {return}
    defer fixture_destroy(&f)
    r,device:=f.renderer,f.device
    embedded:=capture(t,r)
    defer delete(embedded)
    lit:=false
    for value in embedded {lit||=value>40}
    testing.expect(t,lit,"the scene is drawn")
    {
        assets,problem:=shader_assets_load(GENERATION)
        testing.expect_value(t,problem,"")
        if problem!="" {return}
        started:=new(Renderer);defer free(started)
        if !renderer_init(started,{device=device,width=96,height=64,settings=settings,shaders=&assets}) {testing.expect(t,false,started.error);shader_assets_destroy(&assets);return}
        defer renderer_destroy(started)
        testing.expect(t,!assets.owned && started.shader_assets.owned,"a renderer takes the generation it starts with")
        loaded:=capture(t,started)
        defer delete(loaded)
        testing.expect(t,string(embedded)==string(loaded),"the same shaders draw the same image")
    }
    assets,problem:=shader_assets_load(GENERATION)
    testing.expect_value(t,problem,"")
    if problem!="" {return}
    pipelines:=r.pipelines
    targets,probes:=r.targets,r.ddgi
    previous:=r.has_previous
    testing.expect(t,program_find(r,"ColorGrade",.Postprocess)!=nil,"the previous catalog is cached before reload")
    testing.expect(t,renderer_reload_shaders(r,&assets),r.error)
    testing.expect(t,!assets.owned && r.shader_assets.owned,"the renderer takes the generation it reloads")
    testing.expect_value(t,r.pipelines,pipelines)
    testing.expect_value(t,r.targets,targets)
    testing.expect_value(t,r.ddgi,probes)
    testing.expect_value(t,r.has_previous,previous)
    testing.expect(t,shader_assets_match_codes(&r.shader_assets,&r.shader_codes),"the active codes belong to the new storage")
    metadata,metadata_error:=shader_assets_load(GENERATION)
    testing.expect_value(t,metadata_error,"")
    if metadata_error!="" {return}
    changed,_:=strings.replace(string(metadata.catalog),"\"default\": 1,","\"default\": 0.25,",1,metadata.allocator)
    delete(metadata.catalog,metadata.allocator);metadata.catalog=transmute([]u8)changed
    testing.expect(t,renderer_reload_shaders(r,&metadata),r.error)
    testing.expect_value(t,r.pipelines,pipelines)
    testing.expect_value(t,r.targets,targets)
    testing.expect_value(t,r.ddgi,probes)
    program:=program_find(r,"ColorGrade",.Postprocess)
    testing.expect(t,program!=nil)
    testing.expect_value(t,r.has_previous,previous)
    if program!=nil {
        parameter:=program_parameter(program,"strength")
        testing.expect(t,parameter!=nil && parameter.defaults[0]==0.25,"metadata publishes the new catalog")
    }
    invalid,invalid_error:=shader_assets_load(GENERATION)
    testing.expect_value(t,invalid_error,"")
    if invalid_error!="" {return}
    defer shader_assets_destroy(&invalid)
    delete(invalid.catalog,invalid.allocator);invalid.catalog=transmute([]u8)strings.clone("{invalid",invalid.allocator)
    testing.expect(t,!renderer_reload_shaders(r,&invalid),"invalid metadata cannot replace a generation")
    testing.expect_value(t,r.pipelines,pipelines)
    testing.expect_value(t,r.ddgi,probes)
    different,different_error:=shader_assets_load(GENERATION)
    testing.expect_value(t,different_error,"")
    if different_error!="" {return}
    delete(different.codes[.Composite_Comp].name,different.allocator)
    different.codes[.Composite_Comp].name=strings.clone("changed compositor",different.allocator)
    testing.expect(t,renderer_reload_shaders(r,&different),r.error)
    testing.expect(t,r.pipelines[.Composite]!=pipelines[.Composite] && r.pipelines[.Composite]!=0,"a changed GPU contract gets new pipelines")
    testing.expect(t,!r.targets.taa_valid && r.ddgi.probes==0,"changed GPU code resets accumulation")
    camera:=Camera{position={0,3,2},forward={0,-3,-2},up={0,1,0},fov_y=60,near=0.05,far=50,exposure=UNIT_EXPOSURE}
    for _ in 0..<3 {testing.expect(t,renderer_frame(r, {camera = camera}),r.error)}
    rhi.device_wait_idle(device)
    // Only a stage of the previews changes: its pipelines are new, the
    // accumulation of the scene stands.
    preview,preview_error:=shader_assets_load(GENERATION)
    testing.expect_value(t,preview_error,"")
    if preview_error!="" {return}
    for id in ([]Shader_Id{.Composite_Comp,.Thumbnail_Values_Frag}) {delete(preview.codes[id].name,preview.allocator)}
    preview.codes[.Composite_Comp].name=strings.clone("changed compositor",preview.allocator)
    preview.codes[.Thumbnail_Values_Frag].name=strings.clone("changed capture",preview.allocator)
    accumulated,before,volume:=r.targets,r.pipelines,r.ddgi.probes
    testing.expect(t,accumulated.taa_valid,"the scene has accumulated")
    testing.expect(t,renderer_reload_shaders(r,&preview),r.error)
    testing.expect(t,r.pipelines[.Thumbnail_Values]!=before[.Thumbnail_Values] && r.pipelines[.Thumbnail_Values]!=0)
    testing.expectf(t,r.targets.taa_valid && r.ddgi.probes==volume,"a stage of the previews keeps the accumulation of the scene: %v %v %v",r.targets.taa_valid,r.ddgi.probes,volume)
    // A generation the renderer did not load is refused and changes nothing.
    borrowed:Shader_Assets
    current:=r.pipelines
    testing.expect(t,!renderer_reload_shaders(r,&borrowed))
    testing.expect_value(t,r.pipelines,current)
    testing.expectf(t,rhi.device_validation_errors(device)==0,"validation: %s",rhi.device_validation_message(device))
}
