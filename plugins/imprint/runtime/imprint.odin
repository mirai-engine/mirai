package imprint

import "core:math"
import "core:math/linalg"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import phys "plugins:physics/runtime"
import vfx "plugins:vfx/runtime"

// Snow, mud and sand that keep where bodies pass. The imprints are a field
// of heights over the rest of the ground on the cells of a grid of the vfx
// plugin, named IMPRINT_GRID and flat along y, that follows the view
// (Particle_Grid.follow_view): its region wraps in place, a clipmap of the
// ground around the camera whose cells start fresh as they come into it. The
// Vfx program Imprint (shaders/imprint.slang) presses the stamps of the
// channel CHANNEL_STAMPS into it, raises their rims, lets it fill back and
// takes what a fluid of the grid fluid deposits. A Particle_World_Texture of
// its layer 0 hands it to the vertices and to the materials. The meshes of an
// Imprint_Ground near the view are drawn through deformable copies whose
// vertices a Geometry stage moves up or down by the field
// (shaders/imprint_displace.comp.slang), so the raster, the shadows, the
// reflections, the indirect light and the motion vectors see the
// footprints; what is finer than the vertices the Surface program
// Imprint_Surface draws in the normal. Physics does not see them: the
// colliders keep the ground at rest, and a body that presses is the one that
// stands on it.

IMPRINT_GRID :: "imprint"
CHANNEL_STAMPS :: vfx.Particle_Channel_Name(6)

GROUND_CAPACITY :: 256  // meshes drawn displaced at once, over every Imprint_Ground
STAMP_CAPACITY :: 64    // stamps that walk with a stride at once
DEPTH :: 4              // of the entities under an Imprint_Ground whose meshes it displaces
SETTLE :: f64(1.5)      // seconds the vertices are written every frame after the last stamp
REFRESH :: u64(16)      // frames between the writes of a field that only fills back

// The meshes of its entity and of those under it (the chunks of a terrain)
// that the region of the grid imprint reaches show its imprints.
@(component,description="Shows the imprints of the grid imprint on its mesh and on those under it, as a terrain's chunks: snow, mud or sand that keeps where bodies pass. Shadows, reflections and motion see them.")
Imprint_Ground :: struct {
    depth_max:f32 `mirai:"min=0,unit=m"`, // the deepest the surface goes under its rest: its boxes grow by it
    rise_max:f32 `mirai:"min=0,unit=m"`,  // the highest it rises over its rest
    live:bool,                            // written every frame: a fluid deposits into the grid without stamps
}

IMPRINT_GROUND_DEFAULT :: Imprint_Ground{depth_max=0.4,rise_max=0.15}

// A stamp presses the ground under it while it is near: depth at its
// bottom on the ground, nothing reach over it. The ground is what the
// physics has under its bottom (the colliders, at rest).
@(component,description="Presses into the imprints of the world where it touches the ground: a rut while it slides or rolls, footprints with a stride.")
Imprint_Stamp :: struct {
    radius:f32 `mirai:"min=0,unit=m"`,
    depth:f32 `mirai:"min=0,unit=m"`,  // how far it presses the ground it stands on
    bottom:f32 `mirai:"unit=m"`,       // how far under its entity it touches the ground
    reach:f32 `mirai:"min=0,unit=m"`,  // over the ground from where it starts to press
    berm:f32 `mirai:"min=0,max=2"`,    // of what it presses, the share that rises in a rim around it
    stride:f32 `mirai:"min=0,unit=m"`, // between footprints; 0: a rut
    gait:f32 `mirai:"min=0,unit=m"`,   // between the left and the right footprints
    length:f32 `mirai:"min=0,unit=m"`, // of a footprint along where it goes
}

IMPRINT_STAMP_DEFAULT :: Imprint_Stamp{radius=0.3,depth=0.15,reach=0.1,berm=0.3}

// What a stamp is in the channel (shaders/imprint.slang): values.x how far
// it presses, y its berm, z STAMP_RUT or STAMP_PRINT and w the length of a
// print; velocity the motion of a rut, or where a print points.
STAMP_RUT :: 0
STAMP_PRINT :: 1

@(private)
Stride :: struct {
    entity:core.Entity,
    travelled:f32, // since its last print
    right:bool,    // the side of its next print
    seen:u64,
}

@(storage)
Imprint_Steps :: struct {
    strides:[STAMP_CAPACITY]Stride,
    pressed:u64, // stamps pushed to the channel since the world began
    tick:u64,
}

// How far a stamp whose bottom is `over` metres above the ground presses it.
stamp_press :: proc "contextless" (stamp:Imprint_Stamp,over:f32) -> f32 {
    if !(stamp.depth>0) {return 0}
    if !(stamp.reach>0) {return over<=0?stamp.depth:0}
    return stamp.depth*clamp(1-over/stamp.reach,0,1)
}

// Where the next print of a stride goes, if the stamp went far enough since
// the last one: `moved` metres along `forward` (level, unit) this tick.
// Returns the print and whether there is one; prints alternate sides.
stride_print :: proc "contextless" (stride:^Stride,stamp:Imprint_Stamp,at,forward:[3]f32,moved:f32) -> (print:[3]f32,ok:bool) {
    stride.travelled+=moved
    if stride.travelled<stamp.stride {return}
    stride.travelled=math.mod(stride.travelled,stamp.stride)
    side:=[3]f32{forward.z,0,-forward.x}*(stamp.gait*0.5)
    print=at+(stride.right?side:-side)
    stride.right=!stride.right
    return print,true
}

// The stamps of the world to the channel of the imprints, every tick: each
// one near the ground under it presses as far as stamp_press says, a rut
// swept from where it was the tick before or, with a stride, a print each
// stride it goes.
@(step="fixed",loops="game editor",stage="end")
imprint_stamps :: proc(steps:^Imprint_Steps,stamps:core.Read(Imprint_Stamp),worlds:core.Read(core.World_Transform),physics:core.Ref(phys.Physics_State),channels:^vfx.Particle_Channels,time:core.Time,frame:core.Frame_Time) {
    dt:=time.dt if time.playing else frame.dt
    steps.tick+=1
    if !(dt>0) || core.count(stamps)==0 {return}
    for row in 0..<core.count(stamps) {
        e:=core.entity_at(stamps,row)
        stamp:=core.at(stamps,row)
        world,placed:=core.get(worlds,e)
        if !placed || !(stamp.radius>0) || !(stamp.depth>0) {continue}
        bottom:=world.transform.position-{0,stamp.bottom,0}
        // From a little over its bottom, down to what it stands on.
        lift:=min(stamp.radius,0.25)
        hit,found:=phys.raycast(physics,bottom+{0,lift,0},{0,-1,0},lift+max(stamp.reach,0)+0.01,e)
        if !found {continue}
        press:=stamp_press(stamp,lift-hit.distance)
        motion:=(world.transform.position-world.previous.position)
        motion.y=0
        moved:=linalg.length(motion)
        if stamp.stride>0 {
            stride:=stride_of(steps,e)
            if stride==nil {continue}
            forward:=moved>1e-6?motion/moved:mm.FORWARD
            if press<=0 {stride.travelled=0;continue}
            print,ok:=stride_print(stride,stamp,hit.point,forward,moved)
            if !ok {continue}
            vfx.channel_emit(channels,CHANNEL_STAMPS,vfx.Channel_Birth{
                position=print,velocity=forward,size=stamp.radius,count=1,
                values={press,stamp.berm,STAMP_PRINT,max(stamp.length,2*stamp.radius)},
            })
            steps.pressed+=1
            continue
        }
        if press<=0 {continue}
        vfx.channel_emit(channels,CHANNEL_STAMPS,vfx.Channel_Birth{
            position=hit.point,velocity=motion/dt,size=stamp.radius,count=1,values={press,stamp.berm,STAMP_RUT,0},
        })
        steps.pressed+=1
    }
    // The strides of stamps that went are let go.
    for &stride in steps.strides {
        if stride.entity!=core.NONE && stride.seen+2<steps.tick {stride={}}
    }
}

@(private)
stride_of :: proc(steps:^Imprint_Steps,e:core.Entity) -> ^Stride {
    free:^Stride
    for &stride in steps.strides {
        if stride.entity==e {stride.seen=steps.tick;return &stride}
        if stride.entity==core.NONE && free==nil {free=&stride}
    }
    if free!=nil {free^={entity=e,seen=steps.tick}}
    return free
}

// imprint_displace.comp.slang
@(private)
Gpu_Params :: struct {
    rest,written,count,texture:u32,
    place:[3][4]f32,  // rows: from the space of the mesh to metres from the lowest corner of the region
    up:[3]f32,        // the up of the world in the space of the mesh, as long as a metre of the world there
    cell_size:f32,
    start,cells:[2]i32, // the texel of the lowest corner of the region, and the cells of the region along x and z
    depth_max,rise_max:f32,
    spacing:f32,      // metres between the vertices of the mesh
    pad:f32,
}
#assert(size_of(Gpu_Params)==112)

@(private)
Displaced :: struct {
    entity:core.Entity,
    source,mesh:erender.Mesh_Handle, // the mesh of the entity, and the copy the pass writes
    rest_min,rest_max:[3]f32,
    area:f32,          // of its box in the world, level, in square metres: with its vertices, their spacing
    params:Gpu_Params, // what it was last written with, but its places in the vertex pool
    made:u64,          // of the vertex buffer it was last written in
    seen:u64,
    valid:bool,
}

// What each world draws displaced: a world keeps its own copies, which go
// with it (imprint_release).
@(storage,host,by_world)
Imprint_Gpu :: struct {
    world:u64,       // as the renderer names it: its passes write only the copies of that world
    displaced:[GROUND_CAPACITY]Displaced,
    jobs:[GROUND_CAPACITY]Gpu_Params, // of this frame; rest holds the row of displaced until the pass is recorded
    job_count:int,
    frame:u64,
    pressed:u64,     // the stamps of the world last frame
    pressed_at:f64,  // seconds of the application when they last changed
    pipeline:erender.Pipeline, // of the stage of this frame; 0 while the shaders in use have none
}

// The meshes of the Imprint_Ground into the frame: each one the region of
// the imprints reaches drawn through a deformable copy, and the copies whose
// field may have changed written in the Geometry stage.
@(step="render",loops="game editor",before="render_sync")
imprint_render :: proc(
    state:^Imprint_Gpu,grounds:core.Read(Imprint_Ground),meshes:core.Read(erender.Mesh_Renderer),worlds:core.Read(core.World_Transform),
    parents:core.Read(core.Parent),hierarchy:core.Ref(core.Hierarchy),tints:core.Read(erender.Tint),overrides:core.Read(erender.Material_Override),
    hidden:core.Read(erender.Hidden),highlights:core.Read(erender.Highlight),outlines:core.Read(erender.Outline),offsets:core.Read(erender.Draw_Offset),
    layers:core.Read(erender.Layers),locals:core.Read(core.Transform),cameras:core.Read(erender.Camera),
    steps:core.Ref(Imprint_Steps),sync:core.Ref(vfx.Particle_Sync),app:^host.App,frame:core.Frame_Time,id:core.World_Id,
) {
    if state==nil || app.renderer==nil || app.assets==nil {return}
    state.world=erender.world_key(id)
    state.frame+=1
    state.job_count=0
    if steps.ptr!=nil && steps.ptr.pressed!=state.pressed {state.pressed,state.pressed_at=steps.ptr.pressed,app.seconds}
    place,has_field:=vfx.world_texture_place(sync.ptr,IMPRINT_GRID)
    state.pipeline=erender.stage_pipeline(app.renderer,{stage=.Geometry,shader="imprint_displace",name="imprint"})
    if has_field && state.pipeline!=0 && core.count(grounds)>0 && hierarchy.ptr!=nil {
        settling:=app.seconds-state.pressed_at<SETTLE
        made:=erender.vertices_made(app.renderer)
        cell:=f64(place.cell_size)
        low:=[2]f64{f64(place.first.x)*cell,f64(place.first.y)*cell}
        high:=low+{f64(place.cells.x)*cell,f64(place.cells.y)*cell}
        start:=[2]i32{
            (place.first.x%max(place.cells.x,1)+place.cells.x)%max(place.cells.x,1),
            (place.first.y%max(place.cells.y,1)+place.cells.y)%max(place.cells.y,1),
        }
        h:=hierarchy.ptr
        for row in 0..<core.count(grounds) {
            root:=core.entity_at(grounds,row)
            ground:=core.at(grounds,row)
            if erender.is_hidden(hidden,parents,root) {continue}
            write:=settling || ground.live || state.frame%REFRESH==u64(row)%REFRESH
            // The entity and those under it, depth first, DEPTH deep at most.
            e,depth:=root,0
            for e!=core.NONE {
                displace(state,e,ground,write,meshes,worlds,parents,tints,overrides,hidden,highlights,outlines,offsets,layers,locals,cameras,app.assets,app.renderer,&app.extras,frame,place,start,low,high,made)
                i:=core.entity_index(e)
                if depth<DEPTH && i<len(h.first_child) && h.first_child[i]!=core.NONE {e,depth=h.first_child[i],depth+1;continue}
                // Up to the nearest that has a next sibling, never past the root.
                for e!=core.NONE {
                    if e==root {e=core.NONE;break}
                    j:=core.entity_index(e)
                    if j<len(h.next_sibling) && h.next_sibling[j]!=core.NONE {e=h.next_sibling[j];break}
                    e=h.parent[j] if j<len(h.parent) else core.NONE
                    depth-=1
                }
            }
        }
    }
    for &displaced in state.displaced {
        if !displaced.valid || displaced.seen==state.frame {continue}
        erender.mesh_remove(app.renderer,displaced.mesh)
        displaced={}
    }
    if state.job_count>0 {erender.frame_pass(app.renderer,.Geometry,imprint_record,state)}
}

// A mesh under an Imprint_Ground: drawn through its copy while the region
// reaches its box, and the copy written when its field may have changed.
@(private)
displace :: proc(
    state:^Imprint_Gpu,e:core.Entity,ground:Imprint_Ground,write:bool,meshes:core.Read(erender.Mesh_Renderer),worlds:core.Read(core.World_Transform),
    parents:core.Read(core.Parent),tints:core.Read(erender.Tint),overrides:core.Read(erender.Material_Override),hidden:core.Read(erender.Hidden),
    highlights:core.Read(erender.Highlight),outlines:core.Read(erender.Outline),offsets:core.Read(erender.Draw_Offset),layers:core.Read(erender.Layers),
    locals:core.Read(core.Transform),cameras:core.Read(erender.Camera),assets:^host.Assets,renderer:^erender.Renderer,extras:^host.Frame_Extras,frame:core.Frame_Time,
    place:vfx.World_Texture_Place,start:[2]i32,low,high:[2]f64,made:u64,
) {
    static,has_mesh:=core.get(meshes,e)
    world,placed:=core.get(worlds,e)
    if !has_mesh || !placed || core.has(hidden,e) {return}
    tint:=erender.TINT_DEFAULT
    if value,exists:=core.get(tints,e);exists {tint=value}
    override,_:=core.get(overrides,e)
    anchor,transform:=erender.instance_place(world,frame,offsets,parents,worlds,locals,cameras,e)
    shown,usable:=erender.mesh_instance(assets,static,transform,tint,override)
    shown.anchor=anchor
    // A mesh whose geometry still goes to the GPU has no vertices to copy yet: it is drawn as it is.
    if !usable || erender.mesh_uploading(renderer,shown.mesh) {return}
    rest_min,rest_max,known:=erender.mesh_bounds(renderer,shown.mesh)
    if !known {return}
    // The box of the mesh in the world, level: whether the region reaches it.
    corner_low,corner_high:=[2]f64{max(f64),max(f64)},[2]f64{-max(f64),-max(f64)}
    for k in 0..<8 {
        p:=[3]f32{(k&1)!=0?rest_max.x:rest_min.x,(k&2)!=0?rest_max.y:rest_min.y,(k&4)!=0?rest_max.z:rest_min.z}
        q:=transform*[4]f32{p.x,p.y,p.z,1}
        x,z:=f64(q.x)+f64(anchor.x),f64(q.z)+f64(anchor.z)
        corner_low,corner_high=linalg.min(corner_low,[2]f64{x,z}),linalg.max(corner_high,[2]f64{x,z})
    }
    if corner_high.x<=low.x || corner_low.x>=high.x || corner_high.y<=low.y || corner_low.y>=high.y {return}
    at:=-1
    for &displaced,i in state.displaced {
        if displaced.valid && displaced.entity==e {at=i;break}
        if !displaced.valid && at<0 {at=i}
    }
    if at<0 {return}
    displaced:=&state.displaced[at]
    if displaced.valid && (displaced.entity!=e || displaced.source!=shown.mesh) {
        erender.mesh_remove(renderer,displaced.mesh)
        displaced^={}
    }
    fresh:=false
    if !displaced.valid {
        mesh,created:=erender.deformable_create(renderer,shown.mesh)
        if !created {return}
        displaced^={entity=e,source=shown.mesh,mesh=mesh,rest_min=rest_min,rest_max=rest_max,valid=true}
        fresh=true
    }
    displaced.seen=state.frame
    // The linear part of the transform and its inverse: up of the world in the mesh, as long as a metre there.
    linear:=matrix[3,3]f32{
        transform[0,0],transform[0,1],transform[0,2],
        transform[1,0],transform[1,1],transform[1,2],
        transform[2,0],transform[2,1],transform[2,2],
    }
    up:=linalg.inverse(linear)*[3]f32{0,1,0}
    displaced.area=f32((corner_high.x-corner_low.x)*(corner_high.y-corner_low.y))
    params:=Gpu_Params{
        texture=place.texture,up=up,cell_size=place.cell_size,start=start,cells=place.cells,
        depth_max=ground.depth_max,rise_max=ground.rise_max,
    }
    for r in 0..<3 {
        params.place[r]={transform[r,0],transform[r,1],transform[r,2],f32(f64(transform[r,3])+f64(anchor[r])-(r==0?low.x:r==2?low.y:0))}
    }
    if fresh || write || params!=displaced.params || made!=displaced.made {
        // The box the surface stays in: that at rest and how far it can leave it along up.
        reach:=linalg.abs(up)*max(ground.depth_max,ground.rise_max)
        if erender.deformable_update(renderer,displaced.mesh,displaced.rest_min-reach,displaced.rest_max+reach) {
            displaced.params,displaced.made=params,made
            params.rest=u32(at)
            if state.job_count<len(state.jobs) {
                state.jobs[state.job_count]=params
                state.job_count+=1
            }
        }
    }
    shown.mesh,shown.object_id=displaced.mesh,u64(e)
    shown.copy_owner,shown.replace_source=base.name_hash("imprint"),true
    shown.highlight=erender.instance_outline(highlights,outlines,e)
    if in_layers,exists:=core.get(layers,e);exists {shown.layers=in_layers.mask}
    erender.instance_add(extras,shown)
}

@(private)
imprint_record :: proc(pass:^erender.Pass,user:rawptr) {
    state:=cast(^Imprint_Gpu)user
    if pass.world!=state.world {return}
    if state.pipeline==0 || !erender.pass_vertices_begin(pass,"imprint") {return}
    erender.pass_pipeline(pass,state.pipeline)
    for &job in state.jobs[:state.job_count] {
        displaced:=&state.displaced[job.rest]
        written,rest,count,_,known:=erender.pass_deformable(pass,displaced.mesh)
        if !known {continue}
        job.rest,job.written,job.count=rest,written,count
        // The vertices of a ground spread over its box about evenly: a grid, as the chunks of a terrain.
        job.spacing=math.sqrt(displaced.area/f32(max(count,1)))
        if erender.pass_params(pass,&job,size_of(Gpu_Params)) {erender.pass_dispatch(pass,(count+63)/64)}
    }
}

// The copies of a world that goes.
@(step="release")
imprint_release :: proc(state:^Imprint_Gpu,renderer:^erender.Renderer) {
    if state==nil {return}
    for &displaced in state.displaced {
        if displaced.valid && renderer!=nil {erender.mesh_remove(renderer,displaced.mesh)}
        displaced={}
    }
    state.job_count=0
}
