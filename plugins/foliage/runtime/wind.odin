package foliage

import "core:math"
import "core:math/linalg"
import "mirai:core"
import render "mirai:engine/render"
import scene "mirai:engine/scene"
import volume "mirai:engine/volume"
import mm "mirai:std/math"

// The wind of a type that casts shadows sways a few variants of its meshes,
// whose vertices a compute writes each frame from their shape at rest and
// whose BLAS the renderer refits (render.deformable_create): its instances
// are drawn and cast their shadows with the variant they take, so the raster
// and the shadow rays see the same leaves. A variant sways the mesh along
// the wind turned into its own space by the turn of the variant, so an
// instance takes the variant whose turn about up is nearest its own, and it
// sways downwind within half the turn between variants; each variant sways
// in a phase of its own. The wind is the one where the first streaming source
// is (the view), with its speed held to WIND_SPEED_MAX, which the boxes of the
// variants hold: a frame of wind changes no box and marks no light. What the
// rays of reflections and probes see is the mesh at rest (batch of
// Rays_Only). A type without shadows sways in the vertex hook of its batches
// (foliage_vertex.slang), with a phase of each instance; no ray meets it
// swaying. Both sway as foliage_sway.slang says.

WIND_VARIANTS :: 4      // variants of a type whose wind_variants is 0
WIND_VARIANTS_MAX :: 16
WIND_SPEED_MAX :: f32(20) // m/s: the strongest wind a variant sways with
FOLIAGE_SWAY :: f32(0.08) // metres a plant leans per m/s of wind and 10 metres of height, before its type

BENDERS :: 8                 // the benders nearest the view that bend foliage in a frame
BEND_LEAN_MAX :: f32(1.4)    // radians, the most a bender leans foliage
BEND_RADIUS_MAX :: f32(4)    // metres

// Leans the foliage that sways in the hook (types without shadows: grass)
// away from it, by its lean at its middle falling to none at the radius of
// the Volume of its entity, a Sphere of BEND_RADIUS_MAX at most: grass where
// a body passes. Each point leans by the red of its vertex color, as the wind
// moves it. The boxes the views cull those types by hold the most a bender
// can lean them (BEND_LEAN_MAX, Batch_Desc.reach); no ray sees it.
@(component,description="Leans the grass and the foliage that sways without shadows away from it, as where a body passes, as far as the Volume of its entity reaches, up to 4 m.")
Foliage_Bender :: struct {
    lean:f32 `mirai:"min=0,max=1.4,unit=rad"`,  // how far foliage at its middle leans
}

FOLIAGE_BENDER_DEFAULT :: Foliage_Bender{lean=1}

// foliage_wind.slang: what the hook reads in the constants of each view.
Gpu_Bender :: struct {
    position:[3]f32, // relative to the origin of the view
    radius:f32,
    previous:[3]f32, // where it was the frame before
    lean:f32,
}
Gpu_Wind_Frame :: struct {
    wind:volume.Gpu_Wind,
    benders:[BENDERS]Gpu_Bender,
    count:[4]u32, // x: of benders
}

Bender_Shown :: struct {
    entity:core.Entity,
    position,previous:[3]f32, // in the world
    radius,lean:f32,
}

// Metres a point of a type that sways in the hook moves at most: along the
// strongest wind, and leaned by a bender, `height` metres over its place.
hook_reach :: proc "contextless" (amount,height:f32) -> f32 {return height*(WIND_SPEED_MAX*amount+BEND_LEAN_MAX)}

// Metres a point of a type moves per m/s of wind and metre of its height:
// what its batches give the hook (Batch_Desc.vertex.x) and its variants the compute.
sway_amount :: proc "contextless" (t:Foliage_Type) -> f32 {return t.wind*FOLIAGE_SWAY*0.1}

// How many variants a type sways with; 0 for one that sways in the hook, or not at all.
wind_variants :: proc "contextless" (t:Foliage_Type) -> u32 {
    if !(t.wind>0) || !t.casts_shadow {return 0}
    return t.wind_variants if t.wind_variants>0 else WIND_VARIANTS
}

// The variant of `count` an instance with this rotation takes: the one
// whose turn about up is nearest the turn of its forward.
wind_variant :: proc "contextless" (rotation:mm.Quat,count:u32) -> u32 {
    if count<=1 {return 0}
    forward:=mm.quat_forward(rotation)
    turn:=mm.yaw_of_direction(forward)
    step:=2*math.PI/f32(count)
    at:=int(math.round(turn/step))%int(count)
    return u32(at+int(count) if at<0 else at)
}

// The turn of variant k of count about up, radians, and its phase.
wind_variant_turn :: proc "contextless" (k,count:u32) -> f32 {return 2*math.PI*f32(k)/f32(max(count,1))}
wind_variant_phase :: proc "contextless" (k:u32) -> f32 {return f32(k)*2.3999632} // the golden angle: phases that do not line up

// The wind of the world in the space of a variant: turned back by its turn about up.
wind_variant_local :: proc "contextless" (wind:[3]f32,k,count:u32) -> [3]f32 {
    turn:=-wind_variant_turn(k,count)
    c,s:=math.cos(turn),math.sin(turn)
    return {c*wind.x+s*wind.z,wind.y,-s*wind.x+c*wind.z}
}

// The box the variants of a mesh with this box stay in: the box at rest
// grown by the most a point of it moves, at WIND_SPEED_MAX.
wind_bounds :: proc "contextless" (low,high:[3]f32,amount:f32) -> (grown_low,grown_high:[3]f32) {
    corner:=linalg.max(linalg.abs(low),linalg.abs(high))
    reach:=WIND_SPEED_MAX*amount*linalg.length(corner)
    return low-reach,high+reach
}

// The variants of a mesh for the types that sway it as much and in as many.
Wind_Set :: struct {
    source:render.Mesh_Handle,
    count:u32,
    amount:f32,
    variants:[WIND_VARIANTS_MAX]render.Mesh_Handle,
    low,high:[3]f32, // the box they stay in
    made:bool,       // every variant was made
    still:bool,      // written at rest the last frame, with no wind
}

// The set of a mesh, swayed by this many variants this much; made the first
// time, with the levels of the mesh (a load transaction). -1 when the
// renderer cannot make them: the type is drawn at rest.
wind_set :: proc(resident:^Foliage_Resident,renderer:^render.Renderer,source:render.Mesh_Handle,count:u32,amount:f32) -> int {
    for &set,i in resident.winds {if set.source==source && set.count==count && set.amount==amount {return set.made?i:-1}}
    set:=Wind_Set{source=source,count=min(count,WIND_VARIANTS_MAX),amount=amount}
    low,high,known:=render.mesh_bounds(renderer,source)
    if known {
        set.low,set.high=wind_bounds(low,high,amount)
        set.made=true
        for k in 0..<set.count {
            mesh,made:=render.deformable_create(renderer,source,true)
            if !made {set.made=false;break}
            set.variants[k]=mesh
            render.deformable_update(renderer,mesh,set.low,set.high)
        }
    }
    if !set.made {wind_set_free(renderer,&set)}
    append(&resident.winds,set)
    return len(resident.winds)-1 if set.made else -1
}

wind_set_free :: proc(renderer:^render.Renderer,set:^Wind_Set) {
    for mesh in set.variants[:set.count] {if mesh!=0 {render.mesh_remove(renderer,mesh)}}
    set.variants={}
    set.made=false
}

// The wind of each frame: the hook of the types without shadows reads all of
// it in the constants of each view, and the variants of those with shadows
// sway with the wind at the first streaming source. The benders nearest that
// source go to the hook too.
@(step="render",loops="game editor")
foliage_wind :: proc(resident:^Foliage_Resident,winds:core.Read(volume.Wind),volumes:core.Read(volume.Volume),worlds:core.Read(core.World_Transform),parents:core.Read(core.Parent),sections:core.Read(scene.Scene_Reference),sources:core.Ref(scene.Streaming_Sources),benders:core.Read(Foliage_Bender),frame:core.Frame_Time,renderer:^render.Renderer) {
    if resident==nil || len(resident.owners)==0 {return}
    zones:=volume.Where{volumes,worlds,parents,sections}
    resident.wind=volume.gpu_wind(winds,zones)
    at:=[3]f32{}
    if sources.ptr!=nil && sources.ptr.count>0 {at=sources.ptr.items[0].position} else if len(resident.owners)>0 {at=resident.owners[0].transform.position}
    benders_gather(resident,benders,volumes,worlds,frame,at)
    render.frame_pass(renderer,.Mask,foliage_wind_record,resident)
    if len(resident.winds)>0 {
        value:=volume.wind_at(winds,zones,at)
        velocity:=value.xyz
        if speed:=linalg.length(velocity);speed>WIND_SPEED_MAX {velocity*=WIND_SPEED_MAX/speed}
        resident.sway={velocity.x,velocity.y,velocity.z,value.w}
        still:=velocity=={}
        sway:=false
        for &set in resident.winds {
            if !set.made || still && set.still {continue}
            for mesh in set.variants[:set.count] {render.deformable_update(renderer,mesh,set.low,set.high)}
            set.still=still
            sway=true
        }
        if sway {render.frame_pass(renderer,.Geometry,foliage_sway_record,resident)}
    }
    if resident.impostors.count>0 {render.frame_pass(renderer,.Gbuffer,foliage_impostors_record,resident)}
}

// The BENDERS benders nearest `at` where they are drawn this frame, each
// with where it was the frame before (the motion vectors of what it bends).
benders_gather :: proc(resident:^Foliage_Resident,benders:core.Read(Foliage_Bender),volumes:core.Read(volume.Volume),worlds:core.Read(core.World_Transform),frame:core.Frame_Time,at:[3]f32) {
    before:=resident.benders
    count:=resident.bender_count
    resident.bender_count=0
    for row in 0..<core.count(benders) {
        e:=core.entity_at(benders,row)
        bender:=core.at(benders,row)
        world,placed:=core.get(worlds,e)
        if !placed || !(bender.lean>0) {continue}
        // As far as the box of its Volume reaches; without one, as far as a bender can.
        reach,_:=core.get(volumes,e)
        box:=volume.bounds(reach,world.transform)
        radius:=max(box.max.x-box.min.x,box.max.y-box.min.y,box.max.z-box.min.z)*0.5
        if !(radius>0) {continue}
        shown:=Bender_Shown{
            entity=e,position=render.drawn_transform(world,frame).position,
            radius=min(radius,BEND_RADIUS_MAX),lean=min(bender.lean,BEND_LEAN_MAX),
        }
        shown.previous=shown.position
        for old in before[:count] {if old.entity==e {shown.previous=old.position;break}}
        distance:=linalg.length(shown.position-at)
        // Kept nearest first: the farthest gives way.
        n:=resident.bender_count
        if n==BENDERS {
            if distance>=linalg.length(resident.benders[n-1].position-at) {continue}
            n-=1
        }
        i:=n
        for i>0 && linalg.length(resident.benders[i-1].position-at)>distance {resident.benders[i]=resident.benders[i-1];i-=1}
        resident.benders[i]=shown
        resident.bender_count=n+1
    }
}

@(private)
foliage_wind_record :: proc(pass:^render.Pass,user:rawptr) {
    resident:=cast(^Foliage_Resident)user
    data:=render.pass_extension_data(pass,"foliage_wind")
    if len(data)<size_of(Gpu_Wind_Frame) {return}
    frame:Gpu_Wind_Frame
    frame.wind=volume.gpu_wind_relative(resident.wind,pass.origin)
    frame.count={u32(resident.bender_count),0,0,0}
    for bender,i in resident.benders[:resident.bender_count] {
        frame.benders[i]={render.origin_point(bender.position,pass.origin),bender.radius,render.origin_point(bender.previous,pass.origin),bender.lean}
    }
    copy(data,([^]u8)(&frame)[:size_of(Gpu_Wind_Frame)])
}

// The vertices of every variant, swayed by the wind of the frame.
@(private)
foliage_sway_record :: proc(pass:^render.Pass,user:rawptr) {
    resident:=cast(^Foliage_Resident)user
    if pass.world!=render.world_key(resident.world) {return}
    pipeline:=render.stage_pipeline(resident.app.renderer,{stage=.Geometry,shader="foliage_sway",name="foliage wind"})
    if pipeline==0 || !render.pass_vertices_begin(pass,"foliage wind") {return}
    render.pass_pipeline(pass,pipeline)
    Params :: struct {written,rest,count,mesh:u32,wind,sway:[4]f32}
    for &set in resident.winds {
        if !set.made {continue}
        for mesh,k in set.variants[:set.count] {
            written,rest,count,row,known:=render.pass_deformable(pass,mesh)
            if !known {continue}
            local:=wind_variant_local(resident.sway.xyz,u32(k),set.count)
            params:=Params{written=written,rest=rest,count=count,mesh=row,wind={local.x,local.y,local.z,resident.sway.w},sway={set.amount,wind_variant_phase(u32(k)),pass.time,0}}
            if render.pass_params(pass,&params,size_of(Params)) {render.pass_dispatch(pass,(count+63)/64)}
        }
    }
}
