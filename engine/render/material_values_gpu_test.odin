package render

import "core:testing"
import "mirai:core"
import "mirai:host"
import gpu "mirai:render"
import "mirai:rhi"
import mm "mirai:std/math"

// The values entities give their materials by name are held by their
// instances: each one shows its own, no row of the material table is made for
// them, and another value is given in place, without making the instance
// again. What changes the passes that draw a surface still takes a row.
@(test)
values_of_an_entity_show_from_its_instance_without_a_row_of_their_own :: proc(t:^testing.T) {
    settings:=gpu.DEFAULT_SETTINGS
    settings.gi_enabled,settings.taa=false,false
    app,error:=host.app_create({gpu=true,gpu_validation=true,assets_root="assets",window_desc={size={160,120}},threads=1,render_settings=settings})
    if !testing.expect_value(t,error,host.App_Error.None) || app==nil {return}
    defer host.app_destroy(app)
    gpu.renderer_set_display_transform(app.renderer,.ACES_2)
    w:Render_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    sync:Render_Sync;defer sync_free(&sync)
    w.view.position,w.view.rotation,w.view.size={0,0,5},1,{160,120}
    COUNT :: 64
    entities:[COUNT]core.Entity
    for &e,i in entities {
        e=core.create(&w.entities)
        pose:=mm.TRANSFORM_IDENTITY
        // Two cubes before the camera, the others behind it.
        pose.position=i<2?[3]f32{f32(i)*2-1,0,0}:{f32(i%8)*2-8,f32(i/8)*2-8,20}
        core.add(&w.worlds,e,core.World_Transform{pose,pose})
        core.add(&w.meshes,e,Mesh_Renderer{shape=.Cube})
        values:=MATERIAL_VALUES_DEFAULT
        color:=i==0?[3]f32{1,0,0}:i==1?[3]f32{0,1,0}:[3]f32{f32(i)/COUNT,0.5,0.5}
        testing.expect(t,material_value(&values,"base_color",{color.r,color.g,color.b,0}) && material_value(&values,"emission",{color.r*3,color.g*3,color.b*3,0}) && material_value(&values,"roughness",f32(i+1)/COUNT))
        core.add(&w.values,e,values)
    }
    core.test_world_settle(&w)
    draw :: proc(sync:^Render_Sync,app:^host.App,w:^Render_World) {
        host.app_camera_set(app,host.camera_from_view(w.view),w.view.cut,w.view.carried)
        host.app_frame_begin(app)
        world_sync(w,sync,app)
        host.app_frame_end(app)
    }
    // Pixels where red, green or blue is the strongest channel by half.
    count :: proc(t:^testing.T,app:^host.App) -> (found:[3]int) {
        pixels,_,_,captured:=host.app_capture_pixels(app)
        defer delete(pixels)
        if !testing.expect(t,captured) {return}
        for at in 0..<len(pixels)/4 {
            c:=pixels[at*4:][:3]
            for channel in 0..<3 {
                a,b:=int(c[(channel+1)%3]),int(c[(channel+2)%3])
                if int(c[channel])>20 && 2*int(c[channel])>3*max(a,b) {found[channel]+=1}
            }
        }
        return
    }
    rows:=len(app.assets.material_descs)
    draw(&sync,app,&w)
    testing.expect_value(t,len(app.assets.material_descs),rows)
    testing.expect_value(t,app.assets.stats.derived,0)
    shown:=count(t,app)
    testing.expectf(t,shown.r>100 && shown.g>100 && shown.b==0,"each cube shows the color and the light its instance holds: %v",shown)

    // A frame where nothing changes gives the renderer nothing again.
    draw(&sync,app,&w)
    testing.expect(t,len(sync.made)==0 && len(sync.tinted)==0)
    // Then only a value of an entity: given in place, the instance is not made again and no row is.
    testing.expect(t,material_value(core.edit(&w.values,entities[0]),"base_color",{0,0,1,0}) && material_value(core.edit(&w.values,entities[0]),"emission",{0,0,3,0}))
    draw(&sync,app,&w)
    testing.expect(t,len(sync.made)==0 && len(sync.tinted)==1)
    testing.expect(t,len(app.assets.material_descs)==rows && app.assets.stats.derived==0)
    shown=count(t,app)
    testing.expectf(t,shown.r==0 && shown.g>100 && shown.b>100,"the value given in place shows: %v",shown)

    // A layer and unlit are given in place too.
    testing.expect(t,material_value(core.edit(&w.values,entities[1]),"unlit",1) && material_value(core.edit(&w.values,entities[1]),"coat",1))
    draw(&sync,app,&w)
    testing.expect(t,len(sync.made)==0 && len(sync.tinted)==1 && app.assets.stats.derived==0)
    shown=count(t,app)
    testing.expectf(t,shown.g>100 && shown.b>100,"%v",shown)

    // A value that changes the passes that draw the surface makes the entity show a row of its own.
    testing.expect(t,material_value(core.edit(&w.values,entities[1]),"ior",1.8))
    draw(&sync,app,&w)
    testing.expect_value(t,len(sync.made),1)
    testing.expect_value(t,app.assets.stats.derived,1)
    shown=count(t,app)
    testing.expectf(t,shown.g>100 && shown.b>100,"it keeps the color and the light its instance holds over that row: %v",shown)

    // Without its values an entity shows its material again.
    core.remove(&w.values,entities[0]);core.test_world_settle(&w)
    draw(&sync,app,&w)
    shown=count(t,app)
    testing.expectf(t,shown.b==0 && shown.g>100,"%v",shown)
    testing.expect_value(t,rhi.device_validation_errors(app.device),0)
}
