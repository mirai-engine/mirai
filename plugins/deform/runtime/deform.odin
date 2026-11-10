package deform

import "core:math/linalg"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"

// Meshes deformed on the GPU: the vertices of each one are written every
// frame it moves by a compute pass, from those of its rest shape, into a mesh
// of its own that the renderer draws and traces as any other. What is drawn,
// its shadows, its reflections and its motion follow the shape. The shape is
// an equation in a stage of the shaders: those of Deform_Kind are the stage
// of this plugin, and a project or another plugin adds its own with a stage
// that includes deform.slang and defines deform_shape.

CAPACITY :: 64
SHAPE_CAPACITY :: 32

Deform_Kind :: enum u8 {
    Wave,   // a wave that travels along the axis and moves the surface along the direction: a flag, a sheet
    Sway,   // what stands along the axis leans towards the direction and swings: a plant, a mast in the wind
    Twist,  // turns around the axis, more the further along it
    Ripple, // rings that leave the axis and move the surface along it: water, a membrane
}

@(component,description="Deforms the mesh of this entity on the GPU. Its shadows and reflections follow the shape.")
Deform :: struct {
    kind:Deform_Kind,
    shape:[SHAPE_CAPACITY]u8 `mirai:"text"`, // the stage with an equation of its own, <shape>.comp.slang; empty: that of `kind`
    axis:[3]f32,      // in the space of the mesh
    direction:[3]f32, // Wave and Sway: where the surface moves to, in the space of the mesh
    amplitude:f32 `mirai:"min=0"`,         // metres; Twist: radians at the far end of the axis
    wavelength:f32 `mirai:"min=0,unit=m"`, // Wave and Ripple
    speed:f32,        // cycles a second; 0: a shape that stays
    offset:f32,       // cycles: tells apart two that would move as one
    pin:f32 `mirai:"min=0,max=1"`, // the share of the mesh, from where the axis starts, that eases in from still; Ripple: the share of its rim where the rings die
    values:[4]f32,    // what the equation of `shape` reads besides
    reach:f32 `mirai:"min=0,unit=m"`, // how far the equation of `shape` takes a vertex from where it rests, at most; 0: 1.3 times the amplitude
}

DEFORM_DEFAULT :: Deform{kind=.Wave,axis={1,0,0},direction={0,1,0},amplitude=0.1,wavelength=1,speed=0.5,pin=0.2}

// deform.slang
@(private)
Gpu_Params :: struct {
    rest,written,count:u32,
    kind:u32,
    axis:[3]f32,
    amplitude:f32,
    direction:[3]f32,
    wavelength:f32,
    bounds_min:[3]f32,
    phase:f32,
    bounds_max:[3]f32,
    pin:f32,
    values:[4]f32,
}
#assert(size_of(Gpu_Params)==96)

@(private)
Shaped :: struct {
    entity:core.Entity,
    source,mesh:erender.Mesh_Handle, // the mesh of the entity, and the copy of it the pass writes
    rest_min,rest_max:[3]f32,
    params:Gpu_Params, // what it was last written with
    pipeline:erender.Pipeline, // of the stage with its equation
    made:u64,          // of the vertex buffer it was last written in
    seen:u64,
    valid:bool,
}

// What each world deforms: a world keeps its own copies, which go with it
// (deform_release). One for all would let a world that draws no Deform (a
// preview) take the copies of another away while its pass writes them.
@(storage,host,by_world)
Deform_Gpu :: struct {
    world:u64, // as the renderer names it: its passes write only the copies of that world
    shaped:[CAPACITY]Shaped,
    jobs:[CAPACITY]Gpu_Params, // of this frame; rest holds the row of shaped until the pass is recorded
    job_count:int,
    frame:u64,
}

@(private)
unit :: proc "contextless" (v,fallback:[3]f32) -> [3]f32 {
    length:=linalg.length(v)
    return length>1e-6?v/length:fallback
}

// The meshes with Deform into the frame: each one drawn through its copy, and
// the copies that move this frame written in its Geometry stage.
@(step="render",loops="game editor",before="render_sync")
deform_render :: proc(
    state:^Deform_Gpu,deforms:core.Read(Deform),meshes:core.Read(erender.Mesh_Renderer),worlds:core.Read(core.World_Transform),
    parents:core.Read(core.Parent),tints:core.Read(erender.Material_Values),overrides:core.Read(erender.Material_Values),
    hidden:core.Read(erender.Hidden),highlights:core.Read(erender.Highlight),outlines:core.Read(erender.Outline),offsets:core.Read(erender.Draw_Offset),
    layers:core.Read(erender.Layers),app:^host.App,time:core.Time,frame:core.Frame_Time,
    locals:core.Read(core.Transform),cameras:core.Read(erender.Camera),id:core.World_Id,
) {
    if state==nil || app.renderer==nil || app.assets==nil {return}
    state.world=erender.world_key(id)
    state.frame+=1
    state.job_count=0
    if core.count(deforms)>0 {
        seconds:=time.playing?f32(time.seconds)+frame.alpha*time.dt:f32(app.seconds)
        made:=erender.vertices_made(app.renderer)
        for row in 0..<core.count(deforms) {
            e:=core.entity_at(deforms,row)
            deform:=core.at(deforms,row)
            static,has_mesh:=core.get(meshes,e)
            world,placed:=core.get(worlds,e)
            if !has_mesh || !placed || erender.is_hidden(hidden,parents,e) {continue}
            own:=base.text_get(deform.shape[:])
            // The stage with the equation of the shape, that of this plugin without a name; 0 while the shaders in use have none.
            pipeline:=erender.stage_pipeline(app.renderer,{stage=.Geometry,shader=own!=""?own:"deform",name="deform"})
            if pipeline==0 {continue}
            tint:=erender.MATERIAL_VALUES_DEFAULT
            if value,exists:=core.get(tints,e);exists {tint=value}
            override,_:=core.get(overrides,e)
            anchor,transform:=erender.instance_place(world,frame,offsets,parents,worlds,locals,cameras,e)
            shown,usable:=erender.mesh_instance(app.assets,static,transform,tint,override)
            shown.anchor=anchor
            if !usable {continue}
            at:=-1
            for &shaped,i in state.shaped {
                if shaped.valid && shaped.entity==e {at=i;break}
                if !shaped.valid && at<0 {at=i}
            }
            if at<0 {continue}
            shaped:=&state.shaped[at]
            if shaped.valid && (shaped.entity!=e || shaped.source!=shown.mesh) {
                erender.mesh_remove(app.renderer,shaped.mesh)
                shaped^={}
            }
            if !shaped.valid {
                rest_min,rest_max,known:=erender.mesh_bounds(app.renderer,shown.mesh)
                if !known {continue}
                mesh,created:=erender.deformable_create(app.renderer,shown.mesh)
                if !created {continue}
                shaped^={entity=e,source=shown.mesh,mesh=mesh,rest_min=rest_min,rest_max=rest_max,valid=true}
            }
            shaped.seen=state.frame
            params:=Gpu_Params{
                kind=u32(deform.kind),axis=unit(deform.axis,{0,1,0}),direction=unit(deform.direction,{1,0,0}),
                amplitude=deform.amplitude,wavelength=deform.wavelength,phase=deform.offset+deform.speed*seconds,
                bounds_min=shaped.rest_min,bounds_max=shaped.rest_max,pin=deform.pin,values=deform.values,
            }
            if deform.speed!=0 || params!=shaped.params || pipeline!=shaped.pipeline || made!=shaped.made {
                // The box the shape stays in: that of the mesh at rest and how far a vertex can leave it.
                reach:=own!="" && deform.reach>0?deform.reach:deform.amplitude*1.3
                bounds_min,bounds_max:=shaped.rest_min-reach,shaped.rest_max+reach
                if own=="" && deform.kind==.Twist {
                    center,radius:=0.5*(shaped.rest_min+shaped.rest_max),0.5*linalg.length(shaped.rest_max-shaped.rest_min)
                    bounds_min,bounds_max=center-radius,center+radius
                }
                if erender.deformable_update(app.renderer,shaped.mesh,bounds_min,bounds_max) {
                    shaped.params,shaped.pipeline,shaped.made=params,pipeline,made
                    params.rest=u32(at)
                    state.jobs[state.job_count]=params
                    state.job_count+=1
                }
            }
            shown.mesh,shown.object_id=shaped.mesh,u64(e)
            shown.copy_owner,shown.replace_source=base.name_hash("deform"),true
            shown.highlight=erender.instance_outline(highlights,outlines,e)
            if in_layers,exists:=core.get(layers,e);exists {shown.layers=in_layers.mask}
            erender.instance_add(&app.extras,shown)
        }
    }
    for &shaped in state.shaped {
        if !shaped.valid || shaped.seen==state.frame {continue}
        erender.mesh_remove(app.renderer,shaped.mesh)
        shaped={}
    }
    if state.job_count>0 {erender.frame_pass(app.renderer,.Geometry,deform_record,state)}
}

@(private)
deform_record :: proc(pass:^erender.Pass,user:rawptr) {
    state:=cast(^Deform_Gpu)user
    if pass.world!=state.world {return}
    if !erender.pass_vertices_begin(pass,"deform") {return}
    bound:=erender.Pipeline(0)
    for &job in state.jobs[:state.job_count] {
        shaped:=&state.shaped[job.rest]
        written,rest,count,_,known:=erender.pass_deformable(pass,shaped.mesh)
        if !known || shaped.pipeline==0 {continue}
        if bound!=shaped.pipeline {
            erender.pass_pipeline(pass,shaped.pipeline)
            bound=shaped.pipeline
        }
        job.rest,job.written,job.count=rest,written,count
        if erender.pass_params(pass,&job,size_of(Gpu_Params)) {erender.pass_dispatch(pass,(count+63)/64)}
    }
}

// The copies of a world that goes.
@(step="release")
deform_release :: proc(state:^Deform_Gpu,renderer:^erender.Renderer) {
    if state==nil {return}
    for &shaped in state.shaped {
        if shaped.valid && renderer!=nil {erender.mesh_remove(renderer,shaped.mesh)}
        shaped={}
    }
    state.job_count=0
}
