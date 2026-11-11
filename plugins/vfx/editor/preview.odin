package vfx_editor

import "core:math"
import "core:math/linalg"
import "core:mem"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import vfx "plugins:vfx/runtime"
import "plugins:vfx/runtime/effect"

// The particles of an effect as the game shows them, simulated and drawn by
// the GPU: an emitter alone in a World of its own, under a sun and the sky of
// a new world, which the renderer draws into a texture between the frames of
// the window (host.app_world_draw). The document shows that texture at the
// time of its playback; a thumbnail reads it back once into its cell. The
// emitter goes to a time in frames of vfx.FRAME_MAX from where it is, or from
// its start when the time goes back or what it shows changed.

PREVIEW_PITCH :: f32(0.35)          // radians the camera looks down at the effect
PREVIEW_FOV :: f32(30)              // degrees, vertical
PREVIEW_FRAMES :: 40                // that take the emitter to a time at most: past them each one takes more
PREVIEW_CAPACITY :: u32(65536)      // particles of a preview world at least
PREVIEW_REACH :: f32(100)           // metres from the emitter the camera frames at most
PREVIEW_IDLE :: u64(600)            // frames a preview of thumbnails waits for another before it goes
PREVIEW_THUMBNAIL :: 512            // pixels of a side of what a thumbnail is reduced from: a multiple of the side of every cell

Effect_Preview :: struct {
    app:^host.App,          // that made world
    world:rawptr,           // nil until something is shown
    emitter:core.Entity,
    texture:erender.Texture_Handle,
    side:u32,               // pixels of a side of texture
    shows:u64,              // what the emitter shows: the effect, the assets and the values over it; 0: nothing yet
    time:f32,               // seconds since the emitter started
    used:u64,               // the frame of the editor it was last drawn in
}

// The World, its emitter and the texture go.
@(private)
preview_free :: proc(p:^Effect_Preview) {
    if p.app!=nil {
        if p.texture!=0 {erender.view_texture_remove(p.app.renderer,p.texture)}
        if p.world!=nil {host.app_world_free(p.app,p.world)}
    }
    p^={}
}

// Draws the effect id, with values over those of its file (nil: none), time
// seconds after its emitter started, into the texture of the preview, side
// pixels square. info is what the emitter shows, for the camera to frame.
// Between frames.
@(private)
preview_draw :: proc(s:^editor.Session,p:^Effect_Preview,id:base.Asset_Id,info:^effect.Particle_Info,override:^vfx.Particle_Override,given:^vfx.Particle_Parameters,time:f32,side:u32) -> bool {
    app:=s.app
    if app.renderer==nil || app.assets==nil || s.editor_world==nil {return false}
    if p.world==nil && !preview_make(s,p) {return false}
    w:=host.app_world_ref(app,p.world)
    if p.side!=side {
        if p.texture!=0 {erender.view_texture_remove(app.renderer,p.texture)}
        p.texture,p.side=0,0
        texture,made:=erender.view_texture_add(app.renderer,side,side,"vfx.preview")
        if !made {return false}
        p.texture,p.side=texture,side
    }
    keys:=[3]u64{base.hash_combine(id[0],id[1]),app.assets.revision,app.shaders.reloads}
    shows:=base.hash_combine(base.hash64(mem.slice_to_bytes(keys[:])),base.hash64(mem.ptr_to_bytes(info)))
    if override!=nil {shows=base.hash_combine(shows,base.hash64(mem.ptr_to_bytes(override)))}
    if given!=nil {shows=base.hash_combine(shows,base.hash64(mem.ptr_to_bytes(given)))}
    shows|=1
    cut:=shows!=p.shows || time<p.time
    if cut {
        emitters,overrides,parameters:=core.world_table_of(w,vfx.Particle_Emitter),core.world_table_of(w,vfx.Particle_Override),core.world_table_of(w,vfx.Particle_Parameters)
        requests,settings,view:=core.world_storage_of(w,vfx.Particle_Requests),core.world_storage_of(w,vfx.Particle_Settings),core.world_storage_of(w,core.View)
        if emitters==nil || overrides==nil || parameters==nil || requests==nil || settings==nil || view==nil {return false}
        emitter:=vfx.PARTICLE_EMITTER_DEFAULT
        emitter.particle,emitter.active=id,true
        core.add(emitters,p.emitter,emitter)
        if override!=nil && override.count>0 {core.add(overrides,p.emitter,override^)} else if core.has(overrides,p.emitter) {core.remove(overrides,p.emitter)}
        if given!=nil && given.count>0 {core.add(parameters,p.emitter,given^)} else if core.has(parameters,p.emitter) {core.remove(parameters,p.emitter)}
        settings.capacity=max(PREVIEW_CAPACITY,2*info.max_particles)
        view^=preview_view(app.assets,info,side)
        core.world_settle(w)
        vfx.restart(requests,p.emitter)
        p.shows,p.time=shows,0
    }
    ahead:=max(time-p.time,0)
    frames:=clamp(int(math.ceil(ahead/vfx.FRAME_MAX)),1,PREVIEW_FRAMES)
    p.used=s.frame
    if !host.app_world_draw(app,p.world,s.editor_world,p.texture,{i32(side),i32(side)},frames,ahead/f32(frames),cut) {
        p.shows=0
        return false
    }
    p.time=time
    return true
}

// The World of a preview: the emitter where it starts and a sun.
@(private="file")
preview_make :: proc(s:^editor.Session,p:^Effect_Preview) -> bool {
    app:=s.app
    data:=host.app_world_create(app)
    if data==nil {return false}
    p^={app=app,world=data}
    w:=host.app_world_ref(app,data)
    transforms,suns:=core.world_table_of(w,core.Transform),core.world_table_of(w,erender.Sun)
    if transforms==nil || suns==nil {
        preview_free(p)
        return false
    }
    p.emitter=core.create(core.world_entities(w))
    core.add(transforms,p.emitter,core.TRANSFORM_IDENTITY)
    sun:=core.create(core.world_entities(w))
    core.add(transforms,sun,core.Transform{rotation=mm.quat_look(-erender.SUN_DIRECTION,{0,1,0}),scale={1,1,1}})
    core.add(suns,sun,erender.SUN_DEFAULT)
    core.world_settle(w)
    return true
}

// The view that frames what the particles of an effect reach, a little from
// above, side pixels square.
@(private="file")
preview_view :: proc(a:^host.Assets,info:^effect.Particle_Info,side:u32) -> core.View {
    low,high:=effect_reach(a,info)
    center:=(low+high)*0.5
    radius:=max(linalg.length(high-low)*0.5,0.1)
    fov:=PREVIEW_FOV*mm.RAD_PER_DEG
    distance:=radius/math.sin(fov*0.5)
    toward:=[3]f32{0,math.sin(PREVIEW_PITCH),math.cos(PREVIEW_PITCH)}
    return {
        position=center+toward*distance,rotation=mm.quat_look(-toward,{0,1,0}),fov=fov,
        near=max(distance-radius*1.5,0.01),far=distance+radius*2,size={f32(side),f32(side)},
        camera=core.NONE,projection=.Perspective,
    }
}

// The box an effect reaches in the longest life of its particles, around
// its emitter: its shape, where its speed, its velocity and its forces carry
// a particle as drag slows it, and its largest particle. Noise, attractors
// and programs take particles further than it says.
effect_reach :: proc(a:^host.Assets,info:^effect.Particle_Info) -> (low,high:[3]f32) {
    shape:=max(info.shape_size.x,info.shape_size.y,info.shape_size.z,0)
    low,high=-shape,shape
    if info.shape==.Surface || info.shape==.Bones {
        low,high={-0.5,-0.5,-0.5},{0.5,0.5,0.5}
        if mesh:=host.assets_mesh(a,info.surface_mesh) if a!=nil else nil;mesh!=nil && !mesh.failed {low,high=mesh.bounds_min,mesh.bounds_max}
    }
    life:=max(info.lifetime[0],info.lifetime[1],0.05)
    speed:=max(abs(info.speed[0]),abs(info.speed[1]))
    pull:=info.acceleration+vfx.GRAVITY*info.gravity
    size:f32=0
    for value in info.size_over_life.values {size=max(size,value)}
    size*=max(info.size[0],info.size[1],0)*0.5
    if info.render==.Mesh {
        _,_,scale:=effect.particle_mesh_placement(info.spin_axis,info.mesh_rotation,info.mesh_scale)
        size*=max(scale.x,scale.y,scale.z)
    }
    start_low,start_high:=low,high
    for axis in 0..<3 {
        fastest:=[2]f32{min(info.velocity[0][axis],info.velocity[1][axis])-speed,max(info.velocity[0][axis],info.velocity[1][axis])+speed}
        for velocity in fastest {
            for k in 1..=4 {
                age:=life*f32(k)/4
                moved:=(velocity*age+0.5*pull[axis]*age*age)/(1+max(info.drag,0)*age)
                low[axis]=min(low[axis],start_low[axis]+moved)
                high[axis]=max(high[axis],start_high[axis]+moved)
            }
        }
    }
    low=linalg.clamp(low-size,-PREVIEW_REACH,PREVIEW_REACH)
    high=linalg.clamp(high+size,-PREVIEW_REACH,PREVIEW_REACH)
    return
}

// The values of a document its file does not have yet, as those of an
// instance: what the emitter of its preview shows over the file until they
// are written. The assets and the program are written at once.
@(private)
preview_values :: proc(held,file:^Effect_Values) -> (override:vfx.Particle_Override,given:vfx.Particle_Parameters) {
    Gather :: struct {held,file:^effect.Particle_Info,override:^vfx.Particle_Override}
    gather:=Gather{&held.info,&file.info,&override}
    visit :: proc(value:effect.Particle_Value,user:rawptr) -> bool {
        g:=cast(^Gather)user
        if value.kind==.Asset {return true}
        now:=span_of(g.held,value.offset,value.size)
        if mem.compare(now,span_of(g.file,value.offset,value.size))==0 {return true}
        if int(g.override.count)>=vfx.PARTICLE_OVERRIDE_CAPACITY {return false}
        g.override.names[g.override.count]=base.name_hash(value.path)
        copy(g.override.values[g.override.count][:],now)
        g.override.count+=1
        return true
    }
    effect.particle_values_visit(visit,&gather)
    if !parameters_same(held,file) {
        given.count=u32(min(held.parameter_count,vfx.PARTICLE_PARAMETER_CAPACITY))
        copy(given.values[:],held.parameters[:given.count])
    }
    return
}

// ---------------------------------------------------------------- thumbnails

// What a thumbnail of an effect shows: the effect, or the default one, and
// its values, which are part of the signature of the thumbnail.
@(private)
Effect_Shown :: struct {
    id:base.Asset_Id,
    info:effect.Particle_Info,
}

#assert(size_of(Effect_Shown)<=editor.THUMBNAIL_DATA)
#assert(PREVIEW_THUMBNAIL%editor.THUMBNAIL_SIZE==0 && PREVIEW_THUMBNAIL%editor.THUMBNAIL_LARGE==0)

// The thumbnail of an effect, or of the default one without a file: its
// particles once they lived half their life.
@(private)
effect_subject :: proc(s:^editor.Session,file:^asset.Registry_File,clip:u32,subject:^editor.Thumbnail_Subject) -> bool {
    shown:=Effect_Shown{info=effect.PARTICLE_DEFAULTS}
    if file!=nil {
        if clip>0 || s.app.assets==nil {return false}
        view,ok:=vfx.effect_view(s.app.assets,file.id)
        if !ok {return false}
        shown.id,shown.info=file.id,view.info^
    }
    subject.provider=effect.PARTICLE_KIND
    mem.copy(&subject.data,&shown,size_of(shown))
    return true
}

// Draws the particles at PREVIEW_THUMBNAIL pixels, whatever the cell, reads
// them back and reduces them. Between frames.
@(private)
effect_image :: proc(s:^editor.Session,subject:^editor.Thumbnail_Subject,side:int,out:[]u8) -> bool {
    v:=vfx_editor_of(s)
    if v==nil || side<=0 || PREVIEW_THUMBNAIL%side!=0 || len(out)<side*side*4 {return false}
    shown:=(cast(^Effect_Shown)&subject.data)^
    drawn:=PREVIEW_THUMBNAIL
    n:=drawn/side
    if !preview_draw(s,&v.thumbnail,shown.id,&shown.info,nil,nil,max(shown.info.lifetime[0],shown.info.lifetime[1])*0.5,u32(drawn)) {return false}
    pixels,width,height,ok:=erender.view_texture_capture(s.app.renderer,v.thumbnail.texture,context.temp_allocator)
    if !ok || width!=drawn || height!=drawn {return false}
    for y in 0..<side {
        for x in 0..<side {
            sum:[3]u32
            for sy in 0..<n {
                for sx in 0..<n {
                    at:=((y*n+sy)*drawn+x*n+sx)*4
                    for channel in 0..<3 {sum[channel]+=u32(pixels[at+channel])}
                }
            }
            cell:=out[(y*side+x)*4:][:4]
            for channel in 0..<3 {cell[channel]=u8(sum[channel]/u32(n*n))}
            cell[3]=255
        }
    }
    return true
}
