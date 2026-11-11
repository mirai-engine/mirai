package render

import "base:runtime"
import "core:testing"
import "core:mem"
import "mirai:core"
import "mirai:host"
import gpu "mirai:render"
import "mirai:rhi"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"

@(test)
shared_generated_chunks_survive_world_layout_changes_and_local_preview_retirement :: proc(t:^testing.T) {
    settings:=gpu.DEFAULT_SETTINGS
    settings.gi_enabled,settings.taa=false,false
    app,error:=host.app_create({gpu=true,gpu_validation=true,assets_root="assets",window_desc={size={160,120}},threads=1,render_settings=settings})
    if !testing.expect_value(t,error,host.App_Error.None) || app==nil {return}
    defer host.app_destroy(app)
    w:Render_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    sync:Render_Sync;defer sync_free(&sync)
    w.view.position,w.view.rotation,w.view.size={8,8,12},mm.quat_look({-8,-8,-12},{0,1,0}),{160,120}
    w.view.fov=50*mm.RAD_PER_DEG
    grid:geom.Mesh_Buffer
    geom.mesh_buffer_init(&grid)
    defer geom.mesh_buffer_destroy(&grid)
    centers:=[4]geom.Vec3{{-16,0,-16},{16,0,-16},{-16,0,16},{16,0,16}}
    source:[4]base.Asset_Id
    chunks:[8]core.Entity
    owners:=[2]core.Entity{core.create(&w.entities),core.create(&w.entities)}
    make_chunk :: proc(a:^host.Assets,grid:^geom.Mesh_Buffer,center:geom.Vec3,height:f32=0) -> (base.Asset_Id,bool) {
        geom.mesh_buffer_clear(grid)
        geom.plane_build(grid,{32,32},32,32)
        for &position in grid.positions {position+=center;position.y+=height}
        values:=[33*33]f32{}
        field:=host.Assets_Heightfield{heights=values[:],columns=33,rows=33,cell={1,1,1},origin={center.x-16,height,center.z-16}}
        return host.assets_mesh_generate(a,geom.mesh_buffer_view(grid),{base.Asset_Id{}},grid.uvs[:],{no_lods=true,collision=true,heightfield=&field})
    }
    reference:[]u8;defer delete(reference)
    preview:base.Asset_Id
    id:core.World_Id
    for pass in 0..<7 {
        if pass==0 || pass==2 || pass==4 {
            if pass==2 {for id in source {testing.expect(t,host.assets_mesh_release(app.assets,id))};id.generation+=1}
            for center,i in centers {
                previous:=source[i]
                made:bool
                source[i],made=make_chunk(app.assets,&grid,center)
                if !testing.expect(t,made) {return}
                if pass==4 {testing.expect(t,host.assets_mesh_release(app.assets,previous))}
            }
        }
        if pass==0 || pass==1 {
            owner:=pass
            for i in 0..<4 {
                e:=core.create(&w.entities);chunks[owner*4+i]=e
                transform:=mm.TRANSFORM_IDENTITY
                transform.position.x=f32(owner)*72
                core.add(&w.worlds,e,core.World_Transform{transform,transform})
                core.add(&w.parents,e,core.Parent{entity=owners[owner]})
                core.add(&w.meshes,e,Mesh_Renderer{mesh=source[i]})
                core.add(&w.tints,e,Tint{color=owner==0?[4]f32{1,1,1,1}:{0,1,0,1},emission={3,3,3}})
            }
            core.test_world_settle(&w)
        } else if pass==2 || pass==4 {
            for e,i in chunks {core.edit(&w.meshes,e).mesh=source[i%4]}
        }
        for frame in 0..<3 {
            host.app_frame_begin(app)
            if pass==3 || pass==5 {
                if frame==0 {
                    previous:=preview
                    made:bool
                    preview,made=make_chunk(app.assets,&grid,centers[0],0.05*f32(pass))
                    testing.expect(t,made)
                    if previous!={} {testing.expect(t,host.assets_mesh_release(app.assets,previous))}
                }
                for index in ([2]int{0,4}) {
                    e:=chunks[index]
                    world,_:=core.get(&w.worlds,e)
                    tint,_:=core.get(&w.tints,e)
                    instance,usable:=mesh_instance(app.assets,{mesh=preview},mm.transform_matrix(world.transform),tint)
                    testing.expect(t,usable)
                    instance.object_id,instance.copy_owner,instance.copy_variant,instance.replace_source=u64(e),99,1,true
                    testing.expect(t,host.extras_instance_add(&app.extras,instance))
                }
            } else if preview!={} && frame==0 {
                testing.expect(t,host.assets_mesh_release(app.assets,preview));preview={}
            }
            host.app_camera_set(app,host.camera_from_view(w.view),w.view.cut,w.view.carried)
            world_sync(&w,&sync,app,id)
            host.app_frame_end(app)
        }
        if pass==3 || pass==5 {continue}
        pixels,_,_,captured:=host.app_capture_pixels(app)
        if !testing.expect(t,captured) {delete(pixels);return}
        if pass==0 {
            reference=pixels
            camera:=host.camera_from_view(w.view)
            vp:=mm.perspective(camera.fov_y*mm.RAD_PER_DEG,160.0/120.0,camera.near,camera.far)*mm.look_at(camera.position,camera.position+camera.forward,camera.up)
            for point in ([4]geom.Vec3{{-2,0,-2},{2,0,-2},{-2,0,2},{2,0,2}}) {
                pixel,_,visible:=mm.world_to_screen(point,{160,120},vp)
                at:=(int(pixel.y)*160+int(pixel.x))*4
                // The view meters what glows over the black backdrop: middle gray.
                if testing.expect(t,visible && at>=0 && at+3<len(reference)) {testing.expectf(t,reference[at]>60,"each generated quadrant is present: %d",reference[at])}
            }
        } else {
            testing.expectf(t,mem.compare(pixels,reference)==0,"shared generated source keeps all quadrants after layout, cold reset or preview retirement (pass %d)",pass)
            delete(pixels)
        }
    }
    testing.expect_value(t,rhi.device_validation_errors(app.device),0)
}

@(test)
meshes_created_before_their_world_transform_become_visible_and_visual_instances_stay_transient :: proc(t:^testing.T) {
    settings:=gpu.DEFAULT_SETTINGS
    settings.gi_enabled,settings.taa=false,false
    app,error:=host.app_create({gpu=true,gpu_validation=true,assets_root="assets",window_desc={size={160,120}},fixed_dt=1.0/60,threads=1,render_settings=settings})
    testing.expect_value(t,error,host.App_Error.None)
    if app==nil {return}
    defer host.app_destroy(app)
    w:Render_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    {sky_entity:=core.create(&w.entities);core.add(&w.skies,sky_entity,SKY_DEFAULT);core.test_world_settle(&w)}
    sync:Render_Sync
    defer {
        sync_free(&sync)
    }
    w.view.position,w.view.rotation,w.view.size={0,0,5},1,{160,120}
    e:=core.create(&w.entities)
    core.add(&w.meshes,e,Mesh_Renderer{shape=.Cube})
    core.add(&w.tints,e,Tint{color={1,0,0,1},emission={3,0,0}})
    core.test_world_settle(&w)
    for pass in 0..<5 {
        host.app_frame_begin(app)
        if pass==1 {core.add(&w.worlds,e,core.World_Transform{mm.TRANSFORM_IDENTITY,mm.TRANSFORM_IDENTITY});core.test_world_settle(&w)}
        if pass==2 || pass==3 {
            transform:=mm.TRANSFORM_IDENTITY
            transform.position.x=pass==2?1.5:-1.5
            preview,ok:=mesh_instance(app.assets,{shape=.Cube},mm.transform_matrix(transform),Tint{color={0,1,0,0.8},emission={0,3,0}})
            testing.expect(t,ok)
            preview.copy_owner,preview.copy_variant=1,1
            testing.expect(t,host.extras_instance_add(&app.extras,preview))
        }
        host.app_camera_set(app,host.camera_from_view(w.view),w.view.cut,w.view.carried)
        world_sync(&w,&sync,app)
        host.app_frame_end(app)
        pixels,width,_,captured:=host.app_capture_pixels(app)
        testing.expect(t,captured)
        if !captured {return}
        red,green,green_x:=0,0,0
        for pixel in 0..<len(pixels)/4 {
            color:=pixels[pixel*4:][:3]
            if int(color[0])>int(color[1])+60 && int(color[0])>int(color[2])+60 {red+=1}
            if int(color[1])>int(color[0])+60 && int(color[1])>int(color[2])+60 {green+=1;green_x+=pixel%width}
        }
        delete(pixels)
        testing.expectf(t,pass==0?red==0:red>100,"pass %d: the added mesh is drawn (%d red pixels)",pass,red)
        if pass==2 || pass==3 {
            testing.expectf(t,green>100,"the transient preview has geometry (%d green pixels)",green)
            if green>0 {testing.expect(t,pass==2?green_x/green>width/2:green_x/green<width/2)}
            testing.expect_value(t,len(app.renderer.scene.instances),2)
            testing.expect(t,app.assets.stats.derived>0)
            testing.expect_value(t,len(sync.drawn.entities),1)
        } else {testing.expect_value(t,green,0)}
        testing.expect_value(t,w.entities.alive,2) // the mesh and the sky
    }
    testing.expect_value(t,len(app.renderer.scene.instances),1)
    testing.expect_value(t,app.assets.stats.derived,0)
    positions:=[4]geom.Vec3{{-0.5,-0.5,0},{0.5,-0.5,0},{-0.5,0.5,0},{0.5,0.5,0}}
    indices:=[6]u32{0,1,2,2,1,3}
    uv0:=[4]geom.Vec2{{0.25,0.5},{0.25,0.5},{0.25,0.5},{0.25,0.5}}
    uv1:=[4]geom.Vec2{{0.75,0.5},{0.75,0.5},{0.75,0.5},{0.75,0.5}}
    geometry:=geom.Mesh{positions=positions[:],indices=indices[:],uvs=uv0[:]}
    _,bad:=host.assets_mesh_generate(app.assets,geometry,uv1s=uv1[:1])
    testing.expect(t,!bad && app.assets.stats.generated==0)
    generated,made:=host.assets_mesh_generate(app.assets,geometry,uv1s=uv1[:])
    testing.expect(t,made)
    image:=[8]u8{255,0,0,255,0,255,0,255}
    texture,loaded:=gpu.texture_add(app.renderer,{pixels=image[:],width=2,height=1,srgb=true,name="generated preview UV sets"})
    testing.expect(t,loaded)
    material:=gpu.DEFAULT_MATERIAL
    material.emission={3,3,3}
    material.textures[.Base_Color],material.textures[.Emission]=texture,texture
    material.maps.base_color.uv_set,material.maps.emission.uv_set=1,1
    mesh_version,tint_version:=w.meshes.version,w.tints.version
    for pass in 0..<5 {
        host.app_frame_begin(app)
        if pass==3 {
            previous:=generated
            positions[0].y-=0.2;positions[1].y-=0.2;positions[2].y+=0.2;positions[3].y+=0.2
            generated,made=host.assets_mesh_generate(app.assets,geometry,uv1s=uv1[:],options={no_lods=true})
            testing.expect(t,made && generated!=previous)
            testing.expect(t,host.assets_mesh_release(app.assets,previous))
        }
        if pass<4 {
            if pass>0 {material.opacity,material.alpha_mode=0.8,.Blend}
            row,derived:=host.assets_material_derive(app.assets,material)
            testing.expect(t,derived)
            transform:=mm.TRANSFORM_IDENTITY
            transform.position.x=pass==2?-1.5:1.5
            preview,usable:=mesh_instance(app.assets,{mesh=generated},mm.transform_matrix(transform))
            testing.expect(t,usable)
            preview.material,preview.object_id=gpu.Material_Handle(row),u64(e)
            preview.copy_owner,preview.copy_variant,preview.replace_source=2,1,true
            testing.expect(t,host.extras_instance_add(&app.extras,preview))
        } else {
            testing.expect(t,host.assets_mesh_release(app.assets,generated))
        }
        host.app_camera_set(app,host.camera_from_view(w.view),w.view.cut,w.view.carried)
        world_sync(&w,&sync,app)
        host.app_frame_end(app)
        pixels,width,_,captured:=host.app_capture_pixels(app)
        testing.expect(t,captured)
        if !captured {return}
        red,green,green_x:=0,0,0
        for pixel in 0..<len(pixels)/4 {
            color:=pixels[pixel*4:][:3]
            if int(color[0])>int(color[1])+60 && int(color[0])>int(color[2])+60 {red+=1}
            if int(color[1])>int(color[0])+60 && int(color[1])>int(color[2])+60 {green+=1;green_x+=pixel%width}
        }
        delete(pixels)
        if pass<4 {
            testing.expectf(t,red==0 && green>100,"replacement %d hides the source and samples UV1 (%d red, %d green)",pass,red,green)
            if green>0 {testing.expect(t,pass==2?green_x/green<width/2:green_x/green>width/2)}
            testing.expect_value(t,app.renderer.scene.hidden_count,1)
            testing.expect_value(t,app.renderer.scene.instances[1].meta.z,u32(u64(e)))
        } else {
            testing.expect(t,red>100 && green==0,"retiring the generated preview restores the source")
            testing.expect_value(t,app.renderer.scene.hidden_count,0)
            testing.expect_value(t,app.assets.stats.generated,0)
            testing.expect_value(t,app.assets.stats.derived,0)
        }
        testing.expect(t,w.meshes.version==mesh_version && w.tints.version==tint_version && w.entities.alive==2)
    }
    cube:geom.Mesh_Buffer
    geom.mesh_buffer_init(&cube)
    defer geom.mesh_buffer_destroy(&cube)
    geom.cube_build(&cube)
    source:base.Asset_Id
    for pass in 0..<4 {
        host.app_frame_begin(app)
        if pass<2 {
            previous:=source
            source,made=host.assets_mesh_generate(app.assets,geom.mesh_buffer_view(&cube),options={no_lods=true})
            testing.expect(t,made)
            core.edit(&w.meshes,e).mesh=source
            if previous!={} {testing.expect(t,host.assets_mesh_release(app.assets,previous))}
        }
        if pass==2 {
            empty,usable:=mesh_instance(app.assets,{mesh=source},mm.Mat4(1))
            testing.expect(t,usable)
            empty.object_id,empty.copy_owner,empty.replace_source,empty.hidden=u64(e),3,true,true
            testing.expect(t,host.extras_instance_add(&app.extras,empty))
        }
        host.app_camera_set(app,host.camera_from_view(w.view),w.view.cut,w.view.carried)
        world_sync(&w,&sync,app)
        host.app_frame_end(app)
        pixels,_,_,captured:=host.app_capture_pixels(app)
        testing.expect(t,captured)
        red:=0
        for pixel in 0..<len(pixels)/4 {color:=pixels[pixel*4:][:3];if int(color[0])>int(color[1])+60 && int(color[0])>int(color[2])+60 {red+=1}}
        delete(pixels)
        testing.expectf(t,pass==2?red==0:red>100,"source patch or empty replacement %d: %d red pixels",pass,red)
        users,known:=sync.mesh_users[source]
        testing.expect(t,known && len(users)==1 && users[0]==e)
    }
    testing.expect_value(t,rhi.device_validation_errors(app.device),0)
}

// Hiding or showing an entity updates its instances and those of what hangs
// from it, without setting the scene again.
@(test)
hiding_and_showing_update_what_hangs_from_it_without_a_new_scene :: proc(t:^testing.T) {
    settings:=gpu.DEFAULT_SETTINGS
    settings.gi_enabled,settings.taa=false,false
    app,error:=host.app_create({gpu=true,gpu_validation=true,assets_root="assets",window_desc={size={160,120}},fixed_dt=1.0/60,threads=1,render_settings=settings})
    testing.expect_value(t,error,host.App_Error.None)
    if app==nil {return}
    defer host.app_destroy(app)
    w:Render_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    {sky_entity:=core.create(&w.entities);core.add(&w.skies,sky_entity,SKY_DEFAULT);core.test_world_settle(&w)}
    sync:Render_Sync;defer sync_free(&sync)
    w.view.position,w.view.rotation,w.view.size={0,0,6},1,{160,120}
    parent,child:=core.create(&w.entities),core.create(&w.entities)
    for e,i in ([]core.Entity{parent,child}) {
        place:=mm.TRANSFORM_IDENTITY
        place.position.x=i==0?-1.5:1.5
        core.add(&w.worlds,e,core.World_Transform{place,place})
        core.add(&w.meshes,e,Mesh_Renderer{shape=.Cube})
        core.add(&w.tints,e,Tint{color={1,0,0,1},emission={3,0,0}})
    }
    core.add(&w.parents,child,core.Parent{parent,0})
    core.test_world_settle(&w)
    testing.expect(t,core.hierarchy_settle(&w.hierarchy,&w.parents,&w.entities))
    sets:u64
    for pass in 0..<4 {
        host.app_frame_begin(app)
        switch pass {
        case 1: core.add(&w.hidden,parent,Hidden{})
        case 2: core.remove(&w.hidden,parent)
        case 3: core.add(&w.hidden,child,Hidden{})
        }
        core.test_world_settle(&w)
        host.app_camera_set(app,host.camera_from_view(w.view),w.view.cut,w.view.carried)
        world_sync(&w,&sync,app,hierarchy=core.ref(&w.hierarchy))
        host.app_frame_end(app)
        pixels,_,_,captured:=host.app_capture_pixels(app)
        testing.expect(t,captured)
        if !captured {return}
        red:=0
        for pixel in 0..<len(pixels)/4 {
            color:=pixels[pixel*4:][:3]
            if int(color[0])>int(color[1])+60 && int(color[0])>int(color[2])+60 {red+=1}
        }
        delete(pixels)
        testing.expect_value(t,len(app.renderer.scene.instances),2)
        hidden_count:=[4]int{0,2,0,1}
        testing.expectf(t,app.renderer.scene.hidden_count==hidden_count[pass],"pass %d hides %d instances",pass,app.renderer.scene.hidden_count)
        testing.expectf(t,pass==1?red==0:red>100,"pass %d draws %d red pixels",pass,red)
    }
    testing.expect_value(t,rhi.device_validation_errors(app.device),0)
}

// Meshes turned off, on, removed or added change their instances in place,
// the visual instances of the application moving with them, without setting
// the scene again.
@(test)
meshes_that_come_and_go_change_only_their_instances :: proc(t:^testing.T) {
    settings:=gpu.DEFAULT_SETTINGS
    settings.gi_enabled,settings.taa=false,false
    app,error:=host.app_create({gpu=true,gpu_validation=true,assets_root="assets",window_desc={size={160,120}},fixed_dt=1.0/60,threads=1,render_settings=settings})
    testing.expect_value(t,error,host.App_Error.None)
    if app==nil {return}
    defer host.app_destroy(app)
    w:Render_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    {sky_entity:=core.create(&w.entities);core.add(&w.skies,sky_entity,SKY_DEFAULT);core.test_world_settle(&w)}
    sync:Render_Sync;defer sync_free(&sync)
    w.view.position,w.view.rotation,w.view.size={0,0,8},1,{160,120}
    cube :: proc(w:^Render_World,x:f32) -> core.Entity {
        e:=core.create(&w.entities)
        place:=mm.TRANSFORM_IDENTITY
        place.position.x=x
        core.add(&w.worlds,e,core.World_Transform{place,place})
        core.add(&w.meshes,e,Mesh_Renderer{shape=.Cube})
        core.add(&w.tints,e,Tint{color={1,0,0,1},emission={3,0,0}})
        return e
    }
    a,b:=cube(&w,-2.5),cube(&w,0)
    c:=cube(&w,2.5)
    core.test_world_settle(&w)
    counts:=[6]int{3,2,3,2,3,2}
    for pass in 0..<6 {
        host.app_frame_begin(app)
        switch pass {
        case 1: core.disable(&w.meshes,b)
        case 2: core.enable(&w.meshes,b)
        case 3: core.remove(&w.meshes,a)
        case 4: _=cube(&w,-2.5)
        case 5: core.destroy(&w.entities,c)
        }
        core.test_world_settle(&w)
        extra,usable:=mesh_instance(app.assets,{shape=.Cube},mm.transform_matrix({{0,2,0},1,{0.5,0.5,0.5}}),Tint{color={0,1,0,1},emission={0,3,0}})
        testing.expect(t,usable)
        extra.copy_owner,extra.copy_variant=1,1
        testing.expect(t,host.extras_instance_add(&app.extras,extra))
        host.app_camera_set(app,host.camera_from_view(w.view),w.view.cut,w.view.carried)
        world_sync(&w,&sync,app)
        host.app_frame_end(app)
        pixels,_,_,captured:=host.app_capture_pixels(app)
        testing.expect(t,captured)
        if !captured {return}
        red,green:=0,0
        for pixel in 0..<len(pixels)/4 {
            color:=pixels[pixel*4:][:3]
            if int(color[0])>int(color[1])+60 && int(color[0])>int(color[2])+60 {red+=1}
            if int(color[1])>int(color[0])+60 && int(color[1])>int(color[2])+60 {green+=1}
        }
        delete(pixels)
        testing.expectf(t,len(sync.drawn.entities)==counts[pass],"pass %d draws %d meshes",pass,len(sync.drawn.entities))
        testing.expect_value(t,len(app.renderer.scene.instances),len(sync.drawn.entities)+1)
        for e,at in sync.drawn.entities {
            testing.expect_value(t,instance_of(&sync,e),at)
            testing.expect_value(t,app.renderer.scene.instances[at].meta.z,u32(u64(e)))
        }
        testing.expectf(t,red>100 && green>30,"pass %d: %d red and %d green pixels",pass,red,green)
    }
    testing.expect_value(t,rhi.device_validation_errors(app.device),0)
}

// The editor's Highlight outlines an entity in place of the Outline the game gives it.
@(test)
the_editor_outlines_an_entity_in_place_of_the_game :: proc(t:^testing.T) {
    w:Render_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    plain,outlined,both:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    core.add(&w.outlines,outlined,Outline{style=2});core.add(&w.outlines,both,Outline{style=2})
    core.add(&w.highlights,both,Highlight{level=1})
    core.test_world_settle(&w)
    testing.expect_value(t,instance_outline(core.read(&w.highlights),core.read(&w.outlines),plain),u8(0))
    testing.expect_value(t,instance_outline(core.read(&w.highlights),core.read(&w.outlines),outlined),u8(HIGHLIGHT_LEVELS+2))
    testing.expect_value(t,instance_outline(core.read(&w.highlights),core.read(&w.outlines),both),u8(1))
    styles:=OUTLINE_STYLES_DEFAULT
    styles.styles[1]={color={2,0,0,1},fill=-1,behind=0.5}
    style:=outline_style_of(styles)
    testing.expect_value(t,style.colors[1],[4]f32{1,0,0,1})
    testing.expect_value(t,style.fill[1],0)
    testing.expect_value(t,style.behind[1],0.5)
}

@(test)
the_meshes_of_a_body_are_marked_with_the_local_player_whose_view_hides_it :: proc(t:^testing.T) {
    w:Render_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    body,arm,hand,other:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    core.add(&w.parents,arm,core.Parent{entity=body})
    core.add(&w.parents,hand,core.Parent{entity=arm})
    core.test_world_settle(&w)
    tables:Sync_Tables
    tables.parents=core.read(&w.parents)
    testing.expect(t,body_owner(tables,hand)==0,"without bodies, no mesh is marked")
    tables.owned[2]=body
    testing.expect(t,body_owner(tables,body)==3 && body_owner(tables,hand)==3,"the body and what hangs from it are of slot 2")
    testing.expect(t,body_owner(tables,other)==0)
    core.add(&w.layers,hand,Layers{mask=1<<15})
    core.test_world_settle(&w)
    tables.layers=core.read(&w.layers)
    extras:=[3]gpu.Instance_Desc{{object_id=u64(hand),replace_source=true},{object_id=u64(hand)},{object_id=u64(hand),replace_source=true,layers=2}}
    extras_inherit(tables,extras[:])
    testing.expect(t,extras[0].layers==1<<15 && extras[0].owner==3,"what replaces a mesh is in its layers and of its body")
    testing.expect(t,extras[1].layers==0 && extras[1].owner==0,"a copy that does not replace it keeps its own")
    testing.expect(t,extras[2].layers==2 && extras[2].owner==3,"layers a replacement gives stay")
}

// What render_sync asks memory for to make the scene, with the memory ending
// at each request in turn: a scene it has no memory for is empty and is made
// again by a later frame, and with memory enough it holds every instance.
@(test)
a_scene_without_memory_is_empty_until_a_frame_makes_it :: proc(t:^testing.T) {
    settings:=gpu.DEFAULT_SETTINGS
    settings.gi_enabled,settings.taa=false,false
    app,error:=host.app_create({gpu=true,gpu_validation=true,assets_root="assets",window_desc={size={160,120}},fixed_dt=1.0/60,threads=1,render_settings=settings})
    testing.expect_value(t,error,host.App_Error.None)
    if app==nil {return}
    defer host.app_destroy(app)
    w:Render_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    {sky_entity:=core.create(&w.entities);core.add(&w.skies,sky_entity,SKY_DEFAULT);core.test_world_settle(&w)}
    w.view.position,w.view.rotation,w.view.size={0,0,8},1,{160,120}
    cube :: proc(w:^Render_World,x:f32) -> core.Entity {
        e:=core.create(&w.entities)
        place:=mm.TRANSFORM_IDENTITY
        place.position.x=x
        core.add(&w.worlds,e,core.World_Transform{place,place})
        core.add(&w.meshes,e,Mesh_Renderer{shape=.Cube})
        core.add(&w.tints,e,Tint{color={1,0,0,1},emission={3,0,0}})
        return e
    }
    a:=cube(&w,-2.5)
    _=cube(&w,0)
    core.test_world_settle(&w)
    limit:=Memory_Limit{owner=context.allocator,remaining=max(int)}
    limited:=runtime.Allocator{memory_limit_proc,&limit}
    sync:Render_Sync
    defer {context.allocator=limited;sync_free(&sync)}
    done,refused:=false,false
    for served in 0..<128 {
        host.app_frame_begin(app)
        // An instance of the application drawn in place of the first cube.
        extra,usable:=mesh_instance(app.assets,{shape=.Cube},mm.transform_matrix({{0,2,0},1,{0.5,0.5,0.5}}),Tint{color={0,1,0,1}})
        testing.expect(t,usable)
        extra.object_id,extra.replace_source=u64(a),true
        testing.expect(t,host.extras_instance_add(&app.extras,extra))
        host.app_camera_set(app,host.camera_from_view(w.view),w.view.cut,w.view.carried)
        {
            context.allocator=limited
            limit.remaining=served
            world_sync(&w,&sync,app)
            limit.remaining=max(int)
        }
        host.app_frame_end(app)
        if done=sync.synced;done {break}
        refused=true
        testing.expectf(t,len(app.renderer.scene.instances)==0,"a scene refused with %d requests served is empty",served)
    }
    testing.expect(t,done && refused,"refused without memory, and with it it is made")
    testing.expect_value(t,len(app.renderer.scene.instances),3)
    testing.expect_value(t,rhi.device_validation_errors(app.device),0)
}
