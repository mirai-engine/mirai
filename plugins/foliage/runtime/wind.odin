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
// and the shadow rays see the same leaves. A variant is a turn about up and a
// phase: an instance takes the turn nearest its own, and sways downwind
// within half the turn between them, and the phase of the band of the gust
// wave (WIND_WAVE) it stands in, so that gusts cross a forest as they cross
// its grass. The wind of the variants is the one where the first streaming
// source is (the view), with its speed held to WIND_SPEED_MAX, which their
// boxes hold: a frame of wind changes no box and marks no light. What the
// rays of reflections and probes see is the mesh at rest (batch of
// Rays_Only). A type without shadows sways in the vertex hook of its batches
// (foliage_vertex.slang), with the wind where each instance stands and the
// phase of its place; no ray meets it swaying. Both bend about where the
// plant stands as foliage_sway.slang says, and the hook bends every batch of
// foliage where bodies trampled it (Foliage_Trample).

WIND_VARIANTS :: 8      // variants of a type whose wind_variants is 0: four turns of two phases
WIND_VARIANTS_MAX :: 16
WIND_TURNS :: 4         // the most turns the variants of a type take; past them, phases of each
WIND_SPEED_MAX :: f32(20) // m/s: the strongest wind a variant sways with
WIND_WAVE :: [2]f64{0.37,0.71} // radians a metre along x and z of the world of the gust wave (FOLIAGE_WAVE)
FOLIAGE_SWAY :: f32(0.08) // metres a plant leans per m/s of wind and 10 metres of height, before its type

BEND_LEAN_MAX :: f32(1.4)    // radians, the most a bender leans foliage
BEND_RADIUS_MAX :: f32(4)    // metres

// Leans the foliage around it away from it, by its lean at its middle
// falling to none at the radius of the Volume of its entity, a Sphere of
// BEND_RADIUS_MAX at most: grass where a body passes. What it leans stays
// leaned after it goes and stands back up over TRAMPLE_RECOVER seconds. Each
// point leans by the red of its vertex color, as the wind moves it. The boxes
// the views cull foliage by hold the most a bender can lean it
// (BEND_LEAN_MAX, Batch_Desc.reach); no ray sees it.
@(component,description="Leans the foliage around it away from it, as where a body passes, as far as the Volume of its entity reaches, up to 4 m; what it leaned stands back up over a few seconds.")
Foliage_Bender :: struct {
    lean:f32 `mirai:"min=0,max=1.4,unit=rad"`,  // how far foliage at its middle leans
}

FOLIAGE_BENDER_DEFAULT :: Foliage_Bender{lean=1}

TRAMPLE_SIDE :: 128          // texels a side of the field of trampled foliage
TRAMPLE_TEXEL :: f32(0.5)    // metres
TRAMPLE_RECOVER :: f32(2)    // seconds in which trampled foliage stands back up by all but 1/e of its lean
TRAMPLE_STEP :: f32(32)      // metres between the heights the texels keep theirs from
TRAMPLE_QUIET :: f32(1e-3)   // radians: a lean below it is none
TRAMPLE_TEXTURE :: "foliage trample"
TRAMPLE_BEFORE :: "foliage trample before"
TRAMPLE_BUFFER :: "foliage trample"

// The foliage trampled around the first streaming source, which every
// Foliage_Bender writes: each texel of the world, TRAMPLE_TEXEL metres a
// side, keeps the lean of what stands in it (radians along x and z of the
// world), the height of the centre of the bender that leaned it times that
// lean, and the length of the lean, so that heights blend weighted by how
// much each leaned; the hook reads them. Texel (i,j) of the world is at (i,j)
// modulo TRAMPLE_SIDE: the field follows the view in place, and what enters
// it enters standing.
Foliage_Trample :: struct {
    texels:[][4]f16, // made the first frame a source is known
    low:[2]i64,      // the texel of the world at the lowest corner of the field
    height:f32,      // metres: the height the texels keep theirs from, a multiple of TRAMPLE_STEP
    writes:int,      // frames still to write: two after one that changed it, for the texture of the frame before
    written:u64,     // frames written: the half of the buffer the last one wrote is its parity
    now,before:u32,  // the textures of the field and of the frame before (render.table_texture); max(u32) none
}

// foliage_wind.slang: what the hook reads in the constants of each view.
Gpu_Wind_Frame :: struct {
    wind:volume.Gpu_Wind,
    trample:[4]f32,  // xy: the centre of the field along x and z, z: the height its texels are from, relative to the origin of the view; w: metres a side
    textures:[4]u32, // x: of the field, y: of the frame before
}

// Metres a point of a type that sways in the hook moves at most: along the
// strongest wind, and leaned by a bender, `height` metres over its place.
hook_reach :: proc "contextless" (amount,height:f32) -> f32 {return height*(WIND_SPEED_MAX*amount+BEND_LEAN_MAX)}

// Metres a point of a type moves per m/s of wind and metre of its height:
// what its batches give the hook (Batch_Desc.vertex.x) and its variants the compute.
sway_amount :: proc "contextless" (t:Foliage_Type) -> f32 {return t.wind*FOLIAGE_SWAY*0.1}

// How many variants a type sways with: turns times phases; 0 for one that
// sways in the hook, or not at all.
wind_variants :: proc "contextless" (t:Foliage_Type) -> u32 {
    if !(t.wind>0) || !t.casts_shadow {return 0}
    n:=min(t.wind_variants if t.wind_variants>0 else WIND_VARIANTS,WIND_VARIANTS_MAX)
    turns,_:=wind_turns(n)
    return n-n%turns
}

// The turns about up and the phases of each turn of `count` variants.
wind_turns :: proc "contextless" (count:u32) -> (turns,phases:u32) {
    turns=clamp(count,1,WIND_TURNS)
    return turns,max(count/turns,1)
}

// The phase of the gust wave at a place of the world, radians from 0 to 2π,
// as foliage_sway.slang foliage_wave gives it.
wind_wave :: proc "contextless" (at:[3]f32) -> f64 {
    p:=f64(at.x)*WIND_WAVE.x+f64(at.z)*WIND_WAVE.y
    return p-math.floor(p/math.TAU)*math.TAU
}

// The variant of `count` an instance with this rotation, at this place of
// the world, takes: of the turn about up nearest the turn of its forward, the
// phase of the band of the gust wave its place is in.
wind_variant :: proc "contextless" (rotation:mm.Quat,at:[3]f32,count:u32) -> u32 {
    if count<=1 {return 0}
    turns,phases:=wind_turns(count)
    turn:=u32(0)
    if turns>1 {
        yaw:=mm.yaw_of_direction(mm.quat_forward(rotation))
        step:=2*math.PI/f32(turns)
        k:=int(math.round(yaw/step))%int(turns)
        turn=u32(k+int(turns) if k<0 else k)
    }
    band:=min(u32(wind_wave(at)/math.TAU*f64(phases)),phases-1)
    return turn+turns*band
}

// The variant an instance of a cell whose Foliage is placed by `owner` takes.
wind_variant_of :: proc "contextless" (owner:mm.Transform,p:Placed,count:u32) -> u32 {
    return wind_variant(owner.rotation*p.rotation,mm.transform_point(owner,p.position),count)
}

// The turn of variant k of count about up, radians, and its phase: that of
// the gust wave at the middle of its band.
wind_variant_turn :: proc "contextless" (k,count:u32) -> f32 {
    turns,_:=wind_turns(count)
    return 2*math.PI*f32(k%turns)/f32(turns)
}
wind_variant_phase :: proc "contextless" (k,count:u32) -> f32 {
    turns,phases:=wind_turns(count)
    return 2*math.PI*(f32(k/turns)+0.5)/f32(phases)
}

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

// The wind of each frame: the hook reads all of it in the constants of each
// view, with the trampled field, and the variants of the types with shadows
// sway with the wind at the first streaming source, around which every
// bender tramples the field.
@(step="render",loops="game editor")
foliage_wind :: proc(resident:^Foliage_Resident,winds:^core.Table(volume.Wind,.Read),volumes:^core.Table(volume.Volume,.Read),worlds:^core.Table(core.World_Transform,.Read),parents:^core.Table(core.Parent,.Read),sections:^core.Table(scene.Scene_Reference,.Read),splines:^core.Table(volume.Spline,.Read),sources:core.Ref(scene.Streaming_Sources),benders:^core.Table(Foliage_Bender,.Read),frame:core.Frame_Time,renderer:^render.Renderer) {
    if resident==nil || len(resident.owners)==0 {return}
    zones:=volume.Where{volumes,worlds,parents,sections,splines}
    resident.wind=volume.gpu_wind(winds,zones)
    at:=[3]f32{}
    if sources.ptr!=nil && sources.ptr.count>0 {at=sources.ptr.items[0].position} else if len(resident.owners)>0 {at=resident.owners[0].transform.position}
    trample_draw(resident,benders,volumes,worlds,frame,at,renderer)
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

// The field of this frame around `at`: what left it is forgotten, what was
// trampled stands back up for the frame's time, and every bender whose
// entity is placed tramples it again where it is drawn, as far as the box of
// its Volume reaches, each texel keeping the strongest lean. A bender without
// a Volume, radius or lean tramples nothing; radius and lean are held to
// their limits.
trample_update :: proc(f:^Foliage_Trample,benders:^core.Table(Foliage_Bender,$A),volumes:^core.Table(volume.Volume,$B),worlds:^core.Table(core.World_Transform,$C),frame:core.Frame_Time,at:[3]f32) {
    if f.texels==nil {
        texels,error:=make([][4]f16,TRAMPLE_SIDE*TRAMPLE_SIDE)
        if error!=nil {return}
        f.texels=texels
        f.low=trample_low(at)
        f.height=trample_height(at.y)
        f.now,f.before=max(u32),max(u32)
    }
    changed:=trample_follow(f,at)
    changed|=trample_recover(f,frame.dt)
    for row in 0..<core.count(benders) {
        e:=core.entity_at(benders,row)
        bender:=core.at(benders,row)
        world,placed:=core.get(worlds,e)
        if !placed || !(bender.lean>0) {continue}
        reach,_:=core.get(volumes,e)
        box:=volume.bounds(reach,world.transform)
        radius:=max(box.max.x-box.min.x,box.max.y-box.min.y,box.max.z-box.min.z)*0.5
        if !(radius>0) {continue}
        position:=render.drawn_transform(world,frame).position
        changed|=trample_bend(f,position,min(radius,BEND_RADIUS_MAX),min(bender.lean,BEND_LEAN_MAX))
    }
    if changed {f.writes=2}
}

// The field of this frame around `at`, and its textures, written by the
// frame while it changes.
trample_draw :: proc(resident:^Foliage_Resident,benders:^core.Table(Foliage_Bender,$A),volumes:^core.Table(volume.Volume,$B),worlds:^core.Table(core.World_Transform,$C),frame:core.Frame_Time,at:[3]f32,renderer:^render.Renderer) {
    f:=&resident.trample
    trample_update(f,benders,volumes,worlds,frame,at)
    trample_textures(resident,renderer)
    if f.writes>0 && f.now!=max(u32) && render.frame_pass(renderer,.Geometry,foliage_trample_record,resident) {
        f.writes-=1
        f.written+=1
    }
}

// The texel of the world at the lowest corner of the field around `at`, and
// the height its texels keep theirs from.
trample_low :: proc "contextless" (at:[3]f32) -> [2]i64 {
    return {i64(math.floor(f64(at.x)/f64(TRAMPLE_TEXEL)))-TRAMPLE_SIDE/2,i64(math.floor(f64(at.z)/f64(TRAMPLE_TEXEL)))-TRAMPLE_SIDE/2}
}
trample_height :: proc "contextless" (y:f32) -> f32 {return math.round(y/TRAMPLE_STEP)*TRAMPLE_STEP}

// Where texel i of the world is kept, along one side.
@(private)
trample_wrap :: proc "contextless" (i:i64) -> int {
    m:=i%TRAMPLE_SIDE
    return int(m+TRAMPLE_SIDE if m<0 else m)
}

// Moves the field to `at`: the texels of the world that enter it enter
// standing, and its heights keep theirs from the step nearest it. True when
// a texel changed.
@(private)
trample_follow :: proc(f:^Foliage_Trample,at:[3]f32) -> (changed:bool) {
    low:=trample_low(at)
    height:=trample_height(at.y)
    if height!=f.height {
        shift:=f.height-height
        for &v in f.texels {
            if v[3]==0 {continue}
            v[2]=f16(f32(v[2])+shift*f32(v[3]))
            changed=true
        }
        f.height=height
    }
    move:=low-f.low
    if move=={} {return}
    clear_column :: proc(f:^Foliage_Trample,x:int) -> (changed:bool) {
        for y in 0..<TRAMPLE_SIDE {
            v:=&f.texels[y*TRAMPLE_SIDE+x]
            if v[3]!=0 {v^={};changed=true}
        }
        return
    }
    clear_row :: proc(f:^Foliage_Trample,y:int) -> (changed:bool) {
        for &v in f.texels[y*TRAMPLE_SIDE:][:TRAMPLE_SIDE] {
            if v[3]!=0 {v={};changed=true}
        }
        return
    }
    if abs(move.x)>=TRAMPLE_SIDE || abs(move.y)>=TRAMPLE_SIDE {
        for &v in f.texels {
            if v[3]!=0 {v={};changed=true}
        }
    } else {
        // What enters past the side the field moves toward.
        from,to:=f.low.x+TRAMPLE_SIDE,low.x+TRAMPLE_SIDE
        if move.x<0 {from,to=low.x,f.low.x}
        for x in from..<to {changed|=clear_column(f,trample_wrap(x))}
        from,to=f.low.y+TRAMPLE_SIDE,low.y+TRAMPLE_SIDE
        if move.y<0 {from,to=low.y,f.low.y}
        for y in from..<to {changed|=clear_row(f,trample_wrap(y))}
    }
    f.low=low
    return
}

// What was trampled stands back up for dt seconds. True when a texel changed.
@(private)
trample_recover :: proc(f:^Foliage_Trample,dt:f32) -> (changed:bool) {
    if !(dt>0) {return}
    keep:=math.exp(-dt/TRAMPLE_RECOVER)
    for &v in f.texels {
        if v[3]==0 {continue}
        lean:=f32(v[3])*keep
        v=lean<TRAMPLE_QUIET?{}:{f16(f32(v[0])*keep),f16(f32(v[1])*keep),f16(f32(v[2])*keep),f16(lean)}
        changed=true
    }
    return
}

// A bender at `position` tramples the texels within `radius` of it along x
// and z, by `lean` at its middle falling to none at the radius, away from
// it; a texel keeps the stronger of its lean and the bender's. True when a
// texel changed.
trample_bend :: proc(f:^Foliage_Trample,position:[3]f32,radius,lean:f32) -> (changed:bool) {
    lo:=[2]i64{i64(math.floor(f64(position.x-radius)/f64(TRAMPLE_TEXEL))),i64(math.floor(f64(position.z-radius)/f64(TRAMPLE_TEXEL)))}
    hi:=[2]i64{i64(math.floor(f64(position.x+radius)/f64(TRAMPLE_TEXEL))),i64(math.floor(f64(position.z+radius)/f64(TRAMPLE_TEXEL)))}
    lo=linalg.max(lo,f.low)
    hi=linalg.min(hi,f.low+TRAMPLE_SIDE-1)
    height:=position.y-f.height
    for j in lo.y..=hi.y {
        for i in lo.x..=hi.x {
            away:=[2]f32{f32((f64(i)+0.5)*f64(TRAMPLE_TEXEL)-f64(position.x)),f32((f64(j)+0.5)*f64(TRAMPLE_TEXEL)-f64(position.z))}
            d:=linalg.length(away)
            m:=lean*(1-mm.smoothstep(0.4*radius,radius,d))
            if m<TRAMPLE_QUIET {continue}
            v:=&f.texels[trample_wrap(j)*TRAMPLE_SIDE+trample_wrap(i)]
            if m<=f32(v[3]) {continue}
            side:=away/d if d>1e-4 else [2]f32{1,0}
            v^={f16(side.x*m),f16(side.y*m),f16(height*m),f16(m)}
            changed=true
        }
    }
    return
}

// The lean the field keeps at a place of the world, radians along x and z,
// and the height of what leaned it; none outside the field.
trample_at :: proc(f:^Foliage_Trample,at:[3]f32) -> (lean:[2]f32,height:f32,inside:bool) {
    if f.texels==nil {return}
    i,j:=i64(math.floor(f64(at.x)/f64(TRAMPLE_TEXEL))),i64(math.floor(f64(at.z)/f64(TRAMPLE_TEXEL)))
    if i<f.low.x || j<f.low.y || i>=f.low.x+TRAMPLE_SIDE || j>=f.low.y+TRAMPLE_SIDE {return}
    v:=f.texels[trample_wrap(j)*TRAMPLE_SIDE+trample_wrap(i)]
    m:=f32(v[3])
    return {f32(v[0]),f32(v[1])},f.height+(f32(v[2])/m if m>0 else 0),true
}

// The textures of the field, made the first time (a load transaction): the
// field is written again into new ones.
@(private)
trample_textures :: proc(resident:^Foliage_Resident,renderer:^render.Renderer) {
    f:=&resident.trample
    if f.texels==nil {return}
    key:=render.world_key(resident.world)
    now,made,ok:=render.table_texture(renderer,key,{name=TRAMPLE_TEXTURE,width=TRAMPLE_SIDE,height=TRAMPLE_SIDE})
    before,made_before,ok_before:=render.table_texture(renderer,key,{name=TRAMPLE_BEFORE,width=TRAMPLE_SIDE,height=TRAMPLE_SIDE})
    if !ok || !ok_before {f.now,f.before=max(u32),max(u32);return}
    if made || made_before {f.writes=2}
    f.now,f.before=now,before
}

trample_free :: proc(resident:^Foliage_Resident) {
    if resident.app!=nil {
        render.buffer_release(resident.app.renderer,resident.world,TRAMPLE_BUFFER)
        render.table_texture_release(resident.app.renderer,resident.world,TRAMPLE_TEXTURE)
        render.table_texture_release(resident.app.renderer,resident.world,TRAMPLE_BEFORE)
    }
    delete(resident.trample.texels)
    resident.trample={}
}

@(private)
foliage_wind_record :: proc(pass:^render.Pass,user:rawptr) {
    resident:=cast(^Foliage_Resident)user
    data:=render.pass_extension_data(pass,"foliage_wind")
    if len(data)<size_of(Gpu_Wind_Frame) {return}
    frame:Gpu_Wind_Frame
    frame.wind=volume.gpu_wind_relative(resident.wind,pass.origin)
    frame.textures={max(u32),max(u32),0,0}
    if f:=&resident.trample;f.texels!=nil && f.now!=max(u32) {
        side:=f32(TRAMPLE_SIDE)*TRAMPLE_TEXEL
        centre:=[3]f32{f32(f64(f.low.x)*f64(TRAMPLE_TEXEL))+side*0.5,f.height,f32(f64(f.low.y)*f64(TRAMPLE_TEXEL))+side*0.5}
        at:=render.origin_point(centre,pass.origin)
        frame.trample={at.x,at.z,at.y,side}
        frame.textures={f.now,f.before,0,0}
    }
    copy(data,([^]u8)(&frame)[:size_of(Gpu_Wind_Frame)])
}

// The field into the half of its buffer of this frame, and into its texture;
// the half the frame before wrote into the texture of the frame before.
@(private)
foliage_trample_record :: proc(pass:^render.Pass,user:rawptr) {
    resident:=cast(^Foliage_Resident)user
    f:=&resident.trample
    if pass.world!=render.world_key(resident.world) || f.texels==nil || f.written==0 {return}
    bytes:=u64(len(f.texels)*size_of([4]f16))
    desc:=render.Buffer_Desc{name=TRAMPLE_BUFFER,size=2*bytes}
    bound,made:=render.pass_buffer(pass,0,desc)
    if !bound {return}
    if made {render.pass_buffer_fill(pass,desc,0,desc.size)}
    at:=((f.written-1)&1)*bytes
    if !render.pass_buffer_write(pass,desc,at,raw_data(f.texels),int(bytes)) {return}
    texture:=render.Table_Texture_Desc{name=TRAMPLE_TEXTURE,width=TRAMPLE_SIDE,height=TRAMPLE_SIDE}
    render.pass_table_texture_copy(pass,desc,at,texture)
    texture.name=TRAMPLE_BEFORE
    render.pass_table_texture_copy(pass,desc,bytes-at,texture)
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
            params:=Params{written=written,rest=rest,count=count,mesh=row,wind={local.x,local.y,local.z,resident.sway.w},sway={set.amount,wind_variant_phase(u32(k),set.count),pass.time,0}}
            if render.pass_params(pass,&params,size_of(Params)) {render.pass_dispatch(pass,(count+63)/64)}
        }
    }
}
