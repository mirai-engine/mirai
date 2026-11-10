package physics

import "core:math"
import "core:math/linalg"
import "mirai:core"
import volume "mirai:engine/volume"
import "mirai:std/base"
import mm "mirai:std/math"
import sim "plugins:physics/runtime/sim"

Fluid_Shape :: sim.Fluid_Shape
Fluid_Desc :: sim.Fluid_Desc
Fluid_Sample :: sim.Fluid_Sample
Fluid_Flag :: sim.Fluid_Flag
Fluid_Flags :: sim.Fluid_Flags
Fluid_Wave :: sim.Fluid_Wave
Wave_Term :: sim.Wave_Term
FLUID_WAVES :: sim.FLUID_WAVES
wave_terms :: sim.wave_terms
wave_point :: sim.wave_point
wave_surface :: sim.wave_surface
Surface_Waves :: sim.Fluid_Waves

// How far the waves reach over and under the still surface.
waves_reach :: proc "contextless" (waves:Surface_Waves) -> f32 {
    w:=waves
    return sim.waves_reach(&w)
}

// Water, or another fluid, that bodies float in by their density and
// characters swim in, where the Volume of its entity says: a Plane is
// everything under the height of the entity (a sea), a Box its volume with
// the top as the surface (a lake in its basin, a pool, a stretch of river).
// The yaw of the entity turns a box and its current; tilting the entity
// slopes the surface and the floor of a box, whose walls stay upright, so a
// river is boxes that follow its bed down, each with its current. With
// density zero, the air of a box that takes the fluid of lower priority
// (Volume.priority) out of where it is: a base under the sea, a room that
// floods as the floor of its air rises. Where two fluids meet, or two dry
// boxes, the one of higher priority decides. A fluid ends at its border: the
// blend and the mode of its Volume do nothing to it.
@(component,replicated,description="Water or another fluid in the Volume of its entity, a Plane (a sea) or a Box (a lake, a pool, a stretch of river whose tilt slopes its surface): bodies float in it by their density and characters swim in it. With density 0, a dry box that takes out the fluid of lower priority, as the air of a base under the sea.")
Fluid :: struct {
    density:f32 `mirai:"min=0,unit=kg/m3"`, // 1000 fresh water, 1025 the sea; 0: dry, only in a box
    current:[3]f32 `mirai:"unit=m/s"`,      // in the frame of the entity
}

FLUID_DEFAULT :: Fluid{density=1000}

// The waves on the surface of a Fluid, waves of Gerstner: those the Wind of
// the world raises where the volume is, as a sea that has felt it long
// (Pierson-Moskowitz), and its own, as a swell from far away. Bodies float on
// them, characters swim in them and the water draws them, all from the one
// surface of the simulation.
@(component,replicated,description="The waves of the Fluid of this entity: those the Wind of the world raises where it is, and its own. Bodies float on them, characters swim in them and the water draws them.")
Fluid_Waves :: struct {
    wind:f32 `mirai:"min=0,max=2"`,      // of the height of the sea the Wind where the volume is raises when it has blown long, the share it has; 0: no waves of the wind
    spread:f32 `mirai:"min=0,max=1"`,    // how far the waves of the wind stray from where it blows: 0 all along it, 1 up to across it
    steepness:f32 `mirai:"min=0,max=1"`, // how sharp the crests are: 0 round as sines, 1 as sharp as they go without folding
    speed:f32 `mirai:"min=0"`,           // of the speed of waves of their length in deep water, the share they go at
    seed:u32,                            // tells apart two seas that would rise as one
    waves:[FLUID_WAVES]Wave_Train `mirai:"section=Waves"`, // of its own besides those of the wind, which take the places these leave
}

// A wave of a Fluid_Waves of its own; an amplitude or a length of zero is none.
Wave_Train :: struct {
    amplitude:f32 `mirai:"min=0,unit=m"`, // from the still surface to a crest
    length:f32 `mirai:"min=0,unit=m"`,    // crest to crest
    yaw:f32 `mirai:"unit=rad"`,           // where it travels, about +Y from the forward (-Z) of the entity
}

FLUID_WAVES_DEFAULT :: Fluid_Waves{wind=1,spread=0.5,steepness=0.6,speed=1}

@(private) WAVE_GRAVITY :: f32(9.81) // m/s2 of the deep-water speed of the waves
@(private) WAVE_PEAK_LOW :: f32(0.8) // of the frequency at the peak of the sea of the wind, the lowest of its waves
@(private) WAVE_PEAK_HIGH :: f32(4)  // and the highest

// The waves of the simulation for a Fluid_Waves of a fluid whose yaw is `yaw`, under a wind of `wind` m/s
// (x and z of the world): the waves of its own first, then those of the wind in the places left, from the
// longest. The height of these is that of the sea of Pierson-Moskowitz under that wind, by Fluid_Waves.wind.
fluid_waves_of :: proc "contextless" (waves:Fluid_Waves,yaw:f32,wind:[2]f32) -> (out:sim.Fluid_Waves) {
    rng:=base.rng_make(u64(waves.seed),0x57415645)
    unit :: proc "contextless" (rng:^base.Rng) -> f32 {return f32(base.rng_u32(rng)>>8)/f32(1<<24)}
    toward :: proc "contextless" (angle:f32) -> [2]f32 {return {-math.sin(angle),-math.cos(angle)}}
    deep :: proc "contextless" (length:f32) -> f32 {return math.sqrt(WAVE_GRAVITY*length/(2*math.PI))}
    speed:=max(waves.speed,0)
    out.steepness=clamp(waves.steepness,0,1)
    for train in waves.waves {
        if !(train.amplitude>0) || !(train.length>0) || out.count==FLUID_WAVES {continue}
        out.waves[out.count]={direction=toward(yaw+train.yaw),length=train.length,amplitude=train.amplitude,speed=speed*deep(train.length),phase=2*math.PI*unit(&rng)}
        out.count+=1
    }
    blowing:=math.sqrt(wind.x*wind.x+wind.y*wind.y)
    left:=int(FLUID_WAVES-out.count)
    if !(waves.wind>0) || !(blowing>0.1) || left==0 {return}
    // The spectrum of Pierson-Moskowitz under the wind, in bands of equal ratio from below its peak to above it.
    peak:=0.877*WAVE_GRAVITY/blowing
    height:=0.21*blowing*blowing/WAVE_GRAVITY*waves.wind
    ratio:=left>1?math.pow(WAVE_PEAK_HIGH/WAVE_PEAK_LOW,1/f32(left-1)):1
    band:=left>1?math.sqrt(ratio)-1/math.sqrt(ratio):1
    along:=math.atan2(-wind.x,-wind.y)
    energy:f32
    first:=int(out.count)
    for i in 0..<left {
        w:=peak*WAVE_PEAK_LOW*math.pow(ratio,f32(i))
        density:=0.0081*WAVE_GRAVITY*WAVE_GRAVITY/math.pow(w,5)*math.exp(-1.25*math.pow(peak/w,4))
        amplitude:=math.sqrt(2*density*w*band)
        length:=2*math.PI*WAVE_GRAVITY/(w*w)
        stray:=clamp(waves.spread,0,1)*0.5*math.PI*(2*unit(&rng)-1)
        out.waves[first+i]={direction=toward(along+stray),length=length,amplitude=amplitude,speed=speed*deep(length),phase=2*math.PI*unit(&rng)}
        energy+=0.5*amplitude*amplitude
    }
    // The significant height of a sea is 4 sqrt(m0), m0 the sum of a^2/2 of its waves.
    scale:=energy>0?height/(4*math.sqrt(energy)):0
    for &wave in out.waves[first:first+left] {wave.amplitude*=scale}
    out.count+=u32(left)
    return
}

// What the simulation made for a Fluid and the description it was made from.
@(private)
Fluid_Link :: struct {
    fluid:sim.Fluid_Handle,
    desc:sim.Fluid_Desc,
    refused:bool,
}

// A volume as the simulation has it, for those that look at the fluids of a region: navigation, drawing.
Fluid_Info :: struct {
    entity:core.Entity,
    fluid:sim.Fluid_Handle,
    desc:sim.Fluid_Desc, // world position and yaw, half extents with the scale
    bounds:mm.Aabb,
    top:f32,             // the height of the highest point of its still surface, or of the top of a dry box; desc.waves move it
}

// The fluid at a point, through the one surface query the physics reads too: the surface over a point in
// the fluid or under a point above it, its normal, the current and the density at the point (zero above
// the surface or in a dry box), and the entity of the fluid. false where there is none.
fluid_at :: proc(physics:core.Ref(Physics_State),point:[3]f32) -> (sample:Fluid_Sample,entity:core.Entity,ok:bool) {
    if physics.ptr==nil || !physics.ready {return}
    sample=sim.fluid_sample(&physics.world,point) or_return
    desc,_:=sim.fluid_desc(&physics.world,sample.fluid)
    return sample,core.Entity(desc.user_data),true
}

// The fluids and dry boxes whose bounds meet a box, in the order of the simulation; writes up to len(out) and
// returns how many there are.
fluids_in :: proc(physics:core.Ref(Physics_State),box:mm.Aabb,out:[]Fluid_Info) -> int {
    if physics.ptr==nil || !physics.ready {return 0}
    w:=&physics.world
    found:[64]sim.Fluid_Handle
    count,written:=0,0
    for {
        count=sim.fluids_overlap(w,box,found[:],written)
        batch:=min(count-written,len(out)-written,len(found))
        if batch<=0 {break}
        for handle,i in found[:batch] {
            desc,_:=sim.fluid_desc(w,handle)
            bounds:=sim.fluid_bounds(w,handle)
            top:=desc.shape==.Box?bounds.max.y-waves_reach(desc.waves):desc.position.y
            out[written+i]={entity=core.Entity(desc.user_data),fluid=handle,desc=desc,bounds=bounds,top=top}
        }
        written+=batch
    }
    return count
}

// Seconds the simulation has stepped: the time of the waves of its fluids.
fluid_time :: proc(physics:core.Ref(Physics_State)) -> f64 {
    return physics.ptr!=nil && physics.ready?sim.world_time(&physics.world):0
}

// Whether a point is in the volume of a fluid or a dry box (Fluid_Info.fluid), whatever dry boxes take out of it.
fluid_holds :: proc(physics:core.Ref(Physics_State),fluid:sim.Fluid_Handle,point:[3]f32) -> bool {
    return physics.ptr!=nil && physics.ready && sim.fluid_holds(&physics.world,fluid,point)
}

// A body the last step found in a fluid, for what shows the water moving: splashes, wakes. Nothing of it
// goes back to the simulation.
Fluid_Body :: struct {
    entity:core.Entity,
    center:[3]f32,   // of mass
    velocity:[3]f32,
    volume:f32,      // m3 under the surface
    whole:f32,       // m3 of the body
    surface:f32,     // height of the surface of its fluid over its center
    reach:f32,       // m from its center to the farthest point of its shapes
}

// The awake bodies the last step found in a fluid, in the order of the simulation; writes up to len(out)
// and returns how many there are.
fluid_bodies :: proc(physics:core.Ref(Physics_State),out:[]Fluid_Body) -> int {
    if physics.ptr==nil || !physics.ready {return 0}
    found:[64]sim.Fluid_Body
    count,written:=0,0
    for {
        count=sim.fluid_bodies(&physics.world,found[:],written)
        batch:=min(count-written,len(out)-written,len(found))
        if batch<=0 {break}
        for b,i in found[:batch] {
            out[written+i]={entity=core.Entity(b.user_data),center=b.center,velocity=b.velocity,volume=b.volume,whole=b.whole,surface=b.surface,reach=b.reach}
        }
        written+=batch
    }
    return count
}

// Keeps the fluids of the simulation equal to the Fluid rows, in the Volume of their entities and where they
// are. Runs in both loops, before the step; does nothing while no row nor pose changed. Whoever steps the
// physics by hand without fluids can leave fluids zero.
@(private)
fluids_sync :: proc(
    state:^Physics_State,fluids:core.Read(Fluid),volumes:core.Read(volume.Volume),locals:core.Read(core.Transform),parents:core.Read(core.Parent),problems:^core.Problems,
    waves:core.Read(Fluid_Waves)={},winds:core.Read(volume.Wind)={},worlds:core.Read(core.World_Transform)={},
) {
    if fluids.table==nil {return}
    seen:=core.version(fluids)+core.layout(fluids)+core.version(locals)+core.layout(locals)+core.version(parents)+core.layout(parents)+u64(state.epoch)
    if volumes.table!=nil {seen+=core.version(volumes)+core.layout(volumes)}
    // The wind changes only the fluids with waves.
    if waves.table!=nil {
        seen+=core.version(waves)+core.layout(waves)
        if core.count(waves)>0 && winds.table!=nil && volumes.table!=nil && worlds.table!=nil {
            seen+=core.version(winds)+core.layout(winds)+core.version(worlds)+core.layout(worlds)
        }
    }
    if seen==state.fluids_synced {return}
    w:=&state.world
    #reverse for &link,at in state.fluids.values {
        if core.has(fluids,state.fluids.entities[at]) {continue}
        sim.fluid_destroy(w,link.fluid)
        core.entity_map_remove_at(&state.fluids,at)
    }
    most:=0
    for row in 0..<core.count(fluids) {most=max(most,core.entity_index(core.entity_at(fluids,row)))}
    if !core.entity_map_reserve(&state.fluids,len(state.fluids.values)+core.count(fluids),most+1) {
        memory_problem(problems,core.NONE,"the links from entities to the fluids of the simulation, so no fluid changes in this tick")
        return
    }
    changed:=false
    for row in 0..<core.count(fluids) {
        e:=core.entity_at(fluids,row)
        fluid:=core.at(fluids,row)
        region:volume.Volume
        has_region:=false
        if volumes.table!=nil {region,has_region=core.get(volumes,e)}
        // The simulation has a sea and a pool: the fluid of a region of another shape is not made.
        shaped:=has_region && (region.shape==.Plane || region.shape==.Box)
        world,_:=core.world_of(locals,parents,e)
        desc:=sim.Fluid_Desc{
            shape=region.shape==.Plane?.Plane:.Box,position=world.position,yaw=yaw_of(world.rotation),
            density=fluid.density,current=fluid.current,priority=region.priority,user_data=u64(e),
        }
        if shaped && region.shape==.Box {
            desc.half_extents=region.extents*linalg.abs(world.scale)
            // Where the tilted up of the entity says the surface goes.
            up:=mm.quat_rotate(world.rotation,{0,1,0})
            desc.slope={-up.x/up.y,-up.z/up.y} if up.y>0 else {max(f32),max(f32)}
        }
        raised:Fluid_Waves
        has_waves:=false
        if waves.table!=nil {raised,has_waves=core.get(waves,e)}
        if has_waves && shaped {desc.waves=fluid_waves_of(raised,desc.yaw,volume_wind(winds,volumes,worlds,world.position))}
        l:=core.entity_map_get(&state.fluids,e)
        if l==nil {
            if held:=core.entity_map_held(&state.fluids,e);held!=core.NONE {
                sim.fluid_destroy(w,core.entity_map_get(&state.fluids,held).fluid)
            }
            l,_=core.entity_map_put(&state.fluids,e,Fluid_Link{})
        }
        if sim.fluid_valid(w,l.fluid) {
            if l.desc==desc {continue}
            if sim.fluid_set(w,l.fluid,desc) {
                // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
                l.desc=desc
                l.refused,changed=false,true
                continue
            }
            sim.fluid_destroy(w,l.fluid)
            l.fluid={}
        } else if l.refused && l.desc==desc {continue}
        l.fluid=sim.fluid_create(w,desc)
        // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
        l.desc=desc
        l.refused=l.fluid=={}
        changed=true
        if !l.refused {continue}
        if !shaped {
            core.report(problems,e,"physics.fluid","its Fluid is not made: a fluid fills a Volume of shape Plane (a sea: everything under its entity) or Box (a pool); add that Volume to its entity (volume.plane, volume.box)")
        } else if region.shape==.Plane && fluid.density<=0 || region.shape==.Box && (desc.half_extents.x<=0 || desc.half_extents.y<=0 || desc.half_extents.z<=0) {
            core.report(problems,e,"physics.fluid","its Fluid is not made: %s; give it %s",region.shape==.Plane?"a plane of density 0 would be dry everywhere":"a box needs extents above 0 on every axis","a density above 0, or a Volume of shape Box for a dry volume" if region.shape==.Plane else "extents")
        } else if !(abs(desc.slope.x)<=sim.FLUID_SLOPE && abs(desc.slope.y)<=sim.FLUID_SLOPE) {
            core.report(problems,e,"physics.fluid","its Fluid is not made: its entity is tilted so far that the surface would fall more than %v m a metre; tilt it less, or split the fall into stretches",sim.FLUID_SLOPE)
        } else {
            core.report(problems,e,"physics.fluids","its Fluid is not made: the %d fluids of Physics_Settings.fluids are in use, or its values are not finite; raise fluids",len(w.fluids))
        }
    }
    if changed {fluids_overlaps_report(state,problems)}
    state.fluids_synced=seen
}

// The wind over a point of the water, x and z of the world.
@(private)
volume_wind :: proc(winds:core.Read(volume.Wind),volumes:core.Read(volume.Volume),worlds:core.Read(core.World_Transform),point:[3]f32) -> [2]f32 {
    if winds.table==nil || volumes.table==nil || worlds.table==nil || core.count(winds)==0 {return {}}
    blowing:=volume.wind_at(winds,volumes,worlds,point)
    return {blowing.x,blowing.z}
}

// Fluids that meet fluids, or dry boxes that meet dry boxes, at the same priority: nothing says which of
// the two decides where they meet.
@(private)
fluids_overlaps_report :: proc(state:^Physics_State,problems:^core.Problems) {
    w:=&state.world
    links:=state.fluids.values
    for &a,i in links {
        if !sim.fluid_valid(w,a.fluid) {continue}
        for &b in links[i+1:] {
            if !sim.fluid_valid(w,b.fluid) || (a.desc.density>0)!=(b.desc.density>0) || a.desc.priority!=b.desc.priority {continue}
            if !mm.aabb_overlaps(sim.fluid_bounds(w,a.fluid),sim.fluid_bounds(w,b.fluid)) {continue}
            kind:=a.desc.density>0?"fluid":"dry box"
            core.report(problems,core.Entity(b.desc.user_data),"physics.fluid_overlap","its Fluid meets another %s (%v) of the same priority, so either may decide where they meet; give the Volume of the one that decides a higher priority, or move them apart",kind,core.Entity(a.desc.user_data))
        }
    }
}
