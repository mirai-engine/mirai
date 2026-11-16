package scene

@(require) import "core:fmt"
@(require) import "core:log"
@(require) import "core:slice"
@(require) import "core:testing"
@(require) import "core:time"
@(require) import "mirai:asset"
@(require) import "mirai:core"
@(require) import "mirai:host"
@(require) import "mirai:std/base"

// ./mirai test engine/scene bench_the_longest_frame_of_a_section_that_loads --release -define:MIRAI_BENCH=true
BENCH :: #config(MIRAI_BENCH,false)

when BENCH {

// The longest a frame of the main thread lasts while a section with many
// meshes, materials and textures loads apart, with three job threads and
// frames 4 ms apart; without a renderer, so the uploads are not in it.
@(test)
bench_the_longest_frame_of_a_section_that_loads :: proc(t:^testing.T) {
    testing.set_fail_timeout(t,300*time.Second)
    p:Loading_Project
    if !loading_open(t,&p,"bench",3) {return}
    defer loading_close(&p)
    MESHES :: 48
    TEXTURES :: 16
    OTHERS :: 200 // scenes of the registry the section does not use
    ROOM :: base.Asset_Id{0xbe,1}
    meshes:[MESHES]base.Asset_Id
    for i in 0..<TEXTURES {
        texture,material:=base.Asset_Id{0xbf,u64(i+1)},base.Asset_Id{0xc0,u64(i+1)}
        mips:=make([dynamic][]u8,context.temp_allocator)
        for side:=512;side>=1;side/=2 {append(&mips,make([]u8,side*side*4,context.temp_allocator))}
        testing.expect_value(t,asset.texture_save(fmt.tprintf("%s/t%d.tex",p.folder,i),&p.types,{id=texture,width=512,height=512,format=.RGBA8,mips=mips[:]}),asset.Error.None)
        info:=asset.MATERIAL_DEFAULTS
        info.maps.base_color.texture=texture
        testing.expect_value(t,asset.material_save(fmt.tprintf("%s/m%d.mat",p.folder,i),&p.types,{id=material,info=info}),asset.Error.None)
    }
    for &mesh,i in meshes {
        mesh={0xbd,u64(i+1)}
        loading_mesh(t,&p,mesh,256<<10,{0xc0,u64(i%TEXTURES+1)})
    }
    loading_scene(t,&p,ROOM,meshes[:])
    // The same with a mesh larger than the bytes of a frame.
    LARGE :: base.Asset_Id{0xbe,2}
    loading_mesh(t,&p,{0xbd,0xff},24<<20)
    with_large:[MESHES+1]base.Asset_Id
    copy(with_large[:],meshes[:])
    with_large[MESHES]={0xbd,0xff}
    loading_scene(t,&p,LARGE,with_large[:])
    for i in 0..<OTHERS {loading_scene(t,&p,{0xc1,u64(i+1)},nil)}

    ROUNDS :: 5
    for scene in ([2]base.Asset_Id{ROOM,LARGE}) {
        longest,total,frames:[ROUNDS]f64
        for round in 0..<ROUNDS {
            // Nothing loaded: the Assets and the World start again.
            host.assets_destroy(&p.assets)
            if !testing.expect(t,host.assets_init(&p.assets,{root=p.folder,capacity=256})) {return}
            host.app_world_free(&p.app,p.world)
            p.world=cast(^Loading_World)host.app_world_create(&p.app)
            world:=host.app_world_ref(&p.app,p.world)
            e:=core.create(&p.world.entities)
            core.add(&p.world.ids,e,core.Id{7})
            core.add(&p.world.references,e,Scene_Reference{scene=scene,rule=.Manual})
            core.settle(&p.info,p.world,nil)
            started:=time.tick_now()
            job,error:=section_load_begin(&p.app,world,e)
            if !testing.expect_value(t,error,Error.None) {return}
            frame:=time.duration_milliseconds(time.tick_since(started))
            done:=false
            for {
                longest[round]=max(longest[round],frame)
                total[round]+=frame
                if done {break}
                frames[round]+=1
                time.sleep(4*time.Millisecond)
                p.app.stats.frames+=1
                started=time.tick_now()
                if done=load_step(job);done {
                    _,error=section_load_end(job,world,e)
                    testing.expect_value(t,error,Error.None)
                }
                frame=time.duration_milliseconds(time.tick_since(started))
            }
            core.settle(&p.info,p.world,nil)
            testing.expect_value(t,core.count(&p.world.models),scene==ROOM?MESHES:MESHES+1)
        }
        slice.sort(longest[:]);slice.sort(total[:]);slice.sort(frames[:])
        log.infof("%s: longest frame %.3f ms (%.3f to %.3f), main thread %.3f ms in %v frames, medians of %d",scene==ROOM?"48 meshes, 16 textures":"and a 24 MiB mesh",longest[ROUNDS/2],longest[0],longest[ROUNDS-1],total[ROUNDS/2],frames[ROUNDS/2],ROUNDS)
    }
}

}
