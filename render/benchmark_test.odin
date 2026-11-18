package mirai_render

import "core:fmt"
import "core:math"
import "core:testing"
import "core:time"
import "mirai:rhi"
import "mirai:rhi/shared_device"

// -define:RENDER_BENCHMARK=true, with --release and without validation: GPU time
// of each pass of a fixed scene at 1280x720, averaged over 300 frames.
RENDER_BENCHMARK :: #config(RENDER_BENCHMARK, false)
MATERIAL_BENCHMARK :: #config(MATERIAL_BENCHMARK, false)

@(test)
render_benchmark_reports_gpu_time_by_pass :: proc(t:^testing.T) {
    shared_device.hold(t)
    when !RENDER_BENCHMARK {return} else {
        device,err:=rhi.device_create({app_name="mirai render benchmark",allow_hardware_ray_tracing=true,upload_bytes_per_frame=16<<20})
        if device==nil {testing.expectf(t,false,"no GPU device: %s",err);return}
        defer rhi.device_destroy(device)
        r:Renderer
        if !renderer_init(&r,{device=device,width=1280,height=720}) {testing.expect(t,false,r.error);return}
        defer renderer_destroy(&r)
        metal:=DEFAULT_MATERIAL
        metal.metallic,metal.roughness=1,0.1
        when MATERIAL_BENCHMARK {
            pixels:[64*64*4]u8
            for y in 0..<64 {for x in 0..<64 {
                i:=(y*64+x)*4
                pixels[i],pixels[i+1],pixels[i+2]=u8(64+x*3),u8(64+y*3),192
                pixels[i+3]=255 if (x/8+y/8)%2==0 else 0
            }}
            texture,ok:=texture_add(&r,{pixels=pixels[:],width=64,height=64,srgb=true,alpha_coverage=0.5,name="material benchmark"})
            testing.expect(t,ok,r.error)
            metal.textures[.Base_Color]=texture
            masked:=metal;masked.alpha_mode=.Mask;masked.metallic=0;masked.roughness=0.7
            transformed:=metal;transformed.maps.base_color={scale={1.5,0.75},rotation=0.4,uv_set=1}
            materials_set(&r,{metal,masked,transformed})
        } else {materials_set(&r,{metal})}
        vertices:[24]Mesh_Vertex
        indices:[36]u32
        normals:=[6]Vec3{{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}}
        for n,face in normals {
            u:=Vec3{n.y,n.z,n.x}
            v:=Vec3{n.y*u.z-n.z*u.y,n.z*u.x-n.x*u.z,n.x*u.y-n.y*u.x}
            corners:=[4]Vec3{n-u-v,n+u-v,n+u+v,n-u+v}
            for c,i in corners {
                vertices[face*4+i]={position=c*0.5,normal=n,color={1,1,1}}
                when MATERIAL_BENCHMARK {
                    uv:=[4]Vec2{{0,0},{1,0},{1,1},{0,1}}
                    vertices[face*4+i].uv,vertices[face*4+i].uv1=uv[i],{1-uv[i].x,uv[i].y}
                }
            }
            base:=u32(face*4)
            quad:=[6]u32{base,base+1,base+2,base,base+2,base+3}
            for q,i in quad {indices[face*6+i]=q}
        }
        cube,_:=mesh_add(&r,vertices[:],indices[:])
        instances:[65]Instance_Desc
        place :: proc(position,scale:Vec3) -> Mat4 {
            m:=Mat4(1)
            m[0,0],m[1,1],m[2,2]=scale.x,scale.y,scale.z
            m[0,3],m[1,3],m[2,3]=position.x,position.y,position.z
            return m
        }
        instances[0]={object_id=1,mesh=cube,transform=place({0,-0.1,0},{40,0.2,40}),tint={0.7,0.7,0.7}}
        for i in 0..<64 {
            x,z:=f32(i%8)-3.5,f32(i/8)-3.5
            instances[i+1]={object_id=u64(i+2),mesh=cube,transform=place({x*2,0.5+f32(i%3)*0.25,z*2},{1,1+f32(i%3)*0.5,1}),tint={0.3+f32(i%5)*0.15,0.4+f32(i%7)*0.08,0.9-f32(i%4)*0.2},material=Material_Handle(1 if i%6==0 else 0)}
        }
        when MATERIAL_BENCHMARK {for &instance,i in instances {if i>0 {instance.material=Material_Handle(1+i%3)}}}
        lights:[6]Light_Desc
        for &light,i in lights {light={position={f32(i%3)*6-6,3,f32(i/3)*8-4},color={1,0.8-f32(i)*0.1,0.5+f32(i)*0.08},intensity=6 * math.PI,range=12}}
        scene_given(&r,instances[:],lights[:],{direction={0.3,1,0.2},color={1,1,1},illuminance=1.2 * math.PI,enabled=true},{sky={0.3,0.4,0.6}})
        camera:=Camera{position={0,7,14},forward={0,-6.5,-14},up={0,1,0},fov_y=60,near=0.05,far=200,exposure=UNIT_EXPOSURE}
        Pass :: struct {name:string,ms:f64}
        passes:[rhi.MAX_TIMESTAMPS]Pass
        count,frames:=0,0
        for _ in 0..<120 {testing.expect(t,renderer_frame(&r,{camera=camera}),r.error)}
        started:=time.now()
        for _ in 0..<300 {
            testing.expect(t,renderer_frame(&r, {camera = camera}),r.error)
            frames+=1
            for timing in renderer_stats(&r).timings {
                found:=false
                for &pass in passes[:count] {if pass.name==timing.name {pass.ms+=f64(timing.ms);found=true;break}}
                if !found && count<len(passes) {passes[count]={timing.name,f64(timing.ms)};count+=1}
            }
        }
        rhi.device_wait_idle(device)
        elapsed:=time.duration_milliseconds(time.since(started))
        total:f64
        fmt.printfln("device: %s, hardware rt: %v, 1280x720, %d frames",rhi.device_info(device).name,r.hardware_rt,frames)
        for pass in passes[:count] {
            if pass.name=="end" {continue}
            fmt.printfln("| %s | %.3f |",pass.name,pass.ms/f64(frames))
            total+=pass.ms/f64(frames)
        }
        fmt.printfln("| GPU total | %.3f |",total)
        fmt.printfln("| frame (CPU wall, uncapped) | %.3f |",elapsed/f64(frames))

        // The same frames with what is drawn over the image: two screen layers
        // of 2000 quads, 64 panels of 20 quads and 4096 debug lines.
        layer:=make([]Ui_Vertex,2000*6)
        defer delete(layer)
        for i in 0..<2000 {
            x,y:=f32(i%50)*25,f32(i/50)*18
            corners:=[4]Vec2{{x,y},{x+20,y},{x+20,y+14},{x,y+14}}
            for corner,k in ([6]int{0,1,2,0,2,3}) {layer[i*6+k]={position={corners[corner].x,corners[corner].y,0},color={0.2,0.6,1,0.1}}}
        }
        draws:=[]Ui_Draw{{first=0,count=6000,scissor={0,0,640,720}},{first=6000,count=6000}}
        sign:[20*6]Ui_Vertex
        for i in 0..<20 {
            y:=f32(i)*5
            corners:=[4]Vec2{{0,y},{100,y},{100,y+4},{0,y+4}}
            for corner,k in ([6]int{0,1,2,0,2,3}) {sign[i*6+k]={position={corners[corner].x,corners[corner].y,0},color={1,1,0.3,0.8}}}
        }
        panels:[64]World_Panel
        for &panel,i in panels {
            panel={vertices=sign[:],origin={f32(i%8)*2-7,2.5,f32(i/8)*2-7},right={0.01,0,0},down={0,-0.01,0},pivot={50,50},billboard=i%2==0,depth_test=true}
        }
        storage:=make([]Debug_Vertex,8192)
        defer delete(storage)
        lines:=debug_lines_make(storage)
        for i in 0..<64 {debug_sphere(&lines,{f32(i%8)*2-7,1,f32(i/8)*2-7},0.8,{0,1,0.5,1},21)}
        frame:=Frame_Desc{camera=camera,ui={{vertices=layer},{vertices=layer,draws=draws}},panels=panels[:],debug={lines}}
        overlay_ms,overlay_total:f64
        for i in 0..<420 {
            testing.expect(t,renderer_frame(&r,frame),r.error)
            if i<120 {continue}
            for timing in renderer_stats(&r).timings {
                if timing.name=="tonemap ui" {overlay_ms+=f64(timing.ms)}
                if timing.name!="end" {overlay_total+=f64(timing.ms)}
            }
        }
        rhi.device_wait_idle(device)
        fmt.printfln("| tonemap ui, with overlays (%d UI vertices, %d panels, %d lines) | %.3f |",len(layer)*2+len(panels)*len(sign),len(panels),lines.count/2,overlay_ms/300)
        fmt.printfln("| GPU total, with overlays | %.3f |",overlay_total/300)
        testing.expect_value(t,renderer_stats(&r).ui_vertices_dropped,u32(0))
        testing.expect_value(t,renderer_stats(&r).debug_vertices_dropped,u32(0))
    }
}

// GPU time of the same scene with a sphere of 295 000 triangles shown, hidden
// and scaled to zero inside the box of the floor, traced by software
// (MIRAI_RT=software): an instance without an inverse costs what a hidden one does.
@(test)
render_benchmark_an_instance_scaled_to_zero :: proc(t:^testing.T) {
    shared_device.hold(t)
    when !RENDER_BENCHMARK {return} else {
        device,err:=rhi.device_create({app_name="mirai render benchmark",allow_hardware_ray_tracing=true,upload_bytes_per_frame=64<<20})
        if device==nil {testing.expectf(t,false,"no GPU device: %s",err);return}
        defer rhi.device_destroy(device)
        r:Renderer
        if !renderer_init(&r,{device=device,width=1280,height=720}) {testing.expect(t,false,r.error);return}
        defer renderer_destroy(&r)
        rhi.timestamps_want(device,true)
        materials_set(&r,{DEFAULT_MATERIAL})
        N :: 384
        vertices:=make([]Mesh_Vertex,(N+1)*(N+1))
        indices:=make([]u32,N*N*6)
        defer {delete(vertices);delete(indices)}
        for y in 0..=N {for x in 0..=N {
            around,down:=f32(x)/N*2*math.PI,f32(y)/N*math.PI
            n:=Vec3{math.sin(down)*math.cos(around),math.cos(down),math.sin(down)*math.sin(around)}
            vertices[y*(N+1)+x]={position=n,normal=n,color={1,1,1}}
        }}
        for y in 0..<N {for x in 0..<N {
            a:=u32(y*(N+1)+x)
            quad:=[6]u32{a,a+N+1,a+1,a+1,a+N+1,a+N+2}
            copy(indices[(y*N+x)*6:],quad[:])
        }}
        sphere,_:=mesh_add(&r,vertices,indices)
        box:[24]Mesh_Vertex
        box_indices:[36]u32
        normals:=[6]Vec3{{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}}
        for n,face in normals {
            u:=Vec3{n.y,n.z,n.x}
            v:=Vec3{n.y*u.z-n.z*u.y,n.z*u.x-n.x*u.z,n.x*u.y-n.y*u.x}
            corners:=[4]Vec3{n-u-v,n+u-v,n+u+v,n-u+v}
            for c,i in corners {box[face*4+i]={position=c*0.5,normal=n,color={1,1,1}}}
            base:=u32(face*4)
            quad:=[6]u32{base,base+1,base+2,base,base+2,base+3}
            copy(box_indices[face*6:],quad[:])
        }
        cube,_:=mesh_add(&r,box[:],box_indices[:])
        place :: proc(position,scale:Vec3) -> Mat4 {
            m:=Mat4(1)
            m[0,0],m[1,1],m[2,2]=scale.x,scale.y,scale.z
            m[0,3],m[1,3],m[2,3]=position.x,position.y,position.z
            return m
        }
        instances:[66]Instance_Desc
        instances[0]={object_id=1,mesh=cube,transform=place({0,-0.1,0},{40,0.2,40}),tint={0.7,0.7,0.7}}
        for i in 0..<64 {
            x,z:=f32(i%8)-3.5,f32(i/8)-3.5
            instances[i+1]={object_id=u64(i+2),mesh=cube,transform=place({x*2,0.5,z*2},{1,1,1}),tint={0.5,0.6,0.7}}
        }
        lights:[6]Light_Desc
        for &light,i in lights {light={position={f32(i%3)*6-6,3,f32(i/3)*8-4},color={1,0.8,0.6},intensity=6 * math.PI,range=12}}
        camera:=Camera{position={0,7,14},forward={0,-6.5,-14},up={0,1,0},fov_y=60,near=0.05,far=200,exposure=UNIT_EXPOSURE}
        fmt.printfln("device: %s, hardware rt: %v, 1280x720",rhi.device_info(device).name,r.hardware_rt)
        for variant in ([]string{"shown","hidden","zero"}) {
            instances[65]={object_id=100,mesh=sphere,transform=place({0,1.5,0},{1.5,1.5,1.5}),tint={0.8,0.3,0.3},hidden=variant=="hidden"}
            if variant=="zero" {instances[65].transform=place({0,-0.1,0},{0,0,0})}
            scene_given(&r,instances[:],lights[:],{direction={0.3,1,0.2},color={1,1,1},illuminance=1.2 * math.PI,enabled=true},{sky={0.3,0.4,0.6}})
            for _ in 0..<120 {testing.expect(t,renderer_frame(&r,{camera=camera}),r.error)}
            total,contact:f64
            for _ in 0..<200 {
                testing.expect(t,renderer_frame(&r,{camera=camera}),r.error)
                for timing in renderer_stats(&r).timings {
                    if timing.name=="end" {continue}
                    total+=f64(timing.ms)
                    if timing.name=="contact" {contact+=f64(timing.ms)}
                }
            }
            fmt.printfln("| %s | %.3f | %.3f |",variant,contact/200,total/200)
        }
    }
}
