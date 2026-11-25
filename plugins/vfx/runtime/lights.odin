package vfx

import "mirai:core"
import erender "mirai:engine/render"
import scene "mirai:engine/scene"
import "mirai:host"
import mm "mirai:std/math"

// The point lights of particle layers (effect.Particle_Light): one per layer
// that gives one, at the entity of its emitter or its offset, while its
// particles live. Its intensity and color follow color_over_life at the mean
// age of the particles alive, as the clock of the layer resolved them with its
// effect; its range stays, so the renderer keeps it in its reach class and
// refits its light tree instead of building it again. They go to the frame
// (erender.light_add), the nearest a simulation source first; no entity
// holds them. Only the emitters the last tick found with a light are visited.

PARTICLE_LIGHTS_MAX :: 32 // of a world at once

@(private="file")
Light_Candidate :: struct {
    owner:core.Entity,
    layer:u8,
    distance:f32,
    light:erender.Light_Desc,
}

@(step="render",loops="game editor",before="render_sync")
particles_lights :: proc(
    worlds:^core.Table(core.World_Transform,.Read),
    hidden:^core.Table(erender.Hidden,.Read),
    parents:^core.Table(core.Parent,.Read),
    clocks:core.Ref(Particle_Clocks),
    settings:core.Ref(Particle_Settings),
    sources:core.Ref(scene.Simulation_Sources),
    extras:^host.Frame_Extras,
    problems:^core.Problems,
) {
    if clocks.ptr==nil || len(clocks.lit)==0 || extras==nil {return}
    budget:=PARTICLE_LIGHTS_MAX
    if settings.ptr!=nil {budget=min(int(settings.max_lights),PARTICLE_LIGHTS_MAX)}
    if budget<=0 {return}

    candidates:[PARTICLE_LIGHTS_MAX]Light_Candidate
    count,wanted:=0,0
    for e in clocks.lit {
        primary:=clock_find(clocks.ptr,e)
        if primary==nil || primary.culled {continue}
        world,placed:=core.get(worlds,e)
        if !placed {continue}
        shown:=false
        for layer in 0..=int(primary.layers) {
            clock:=clock_find(clocks.ptr,e,layer)
            if clock==nil || !clock.emission.has_light {continue}
            light,gives:=clock_light(clock,world.transform)
            if !gives {continue}
            // Hidden is asked only of an emitter whose layer gives a light now.
            if !shown {
                if erender.is_hidden(hidden,parents,e) {break}
                shown=true
            }
            wanted+=1
            candidate_insert(&candidates,&count,budget,{owner=e,layer=u8(layer),distance=scene.sources_distance(sources.ptr,light.position,light.position),light=light})
        }
    }
    for candidate in candidates[:count] {
        if !erender.light_add(extras,candidate.light) {
            core.report(problems,candidate.owner,"vfx.light_dropped","The frame holds no more local lights (host.FRAME_LIGHT_CAPACITY, %d): the light of particle layer %d is not shown. Give fewer layers a light, or lower Particle_Settings.max_lights to leave room for other lights",host.FRAME_LIGHT_CAPACITY,candidate.layer)
        }
    }
    if wanted>count {
        core.report(problems,core.NONE,"vfx.lights_over","%d particle layers give a light at once and %d are shown, those nearest a simulation source (Particle_Settings.max_lights, at most %d). Raise max_lights, or give fewer layers a light",wanted,count,PARTICLE_LIGHTS_MAX)
    }
}

// The light a layer gives now from its entity placed at world: none once its
// particles are gone, or while what it gives is black.
clock_light :: proc(clock:^Emitter_Clock,world:mm.Transform) -> (desc:erender.Light_Desc,gives:bool) {
    light:=&clock.emission.light
    longest:=f64(clock.emission.longest)
    if longest<=0 || clock.done {return}
    // The ages of the youngest and of the oldest particle alive.
    youngest,oldest:=max(f64),f64(-1)
    for b in clock.births[:clock.birth_count] {
        first:=b.time
        last:=b.time+f64(birth_instants(b)-1)*f64(b.spacing)
        if clock.time<first || clock.time-last>=longest {continue}
        youngest=min(youngest,max(clock.time-last,0))
        oldest=max(oldest,min(clock.time-first,longest))
    }
    // A program that starts particles on the GPU, or the births of a channel the
    // emitter listens to, give only the time of the last birth.
    if oldest<0 && clock.last>-max(f64)*0.5 {
        age:=clock.time-clock.last
        if age>=0 && age<longest {youngest,oldest=age,age}
    }
    if oldest<0 {return}
    life:=clamp(f32(0.5*(youngest+oldest)/longest),0,1)
    over:=keys_at(light.color_over_life.times[:],light.color_over_life.colors[:],life)
    desc={
        position=mm.transform_point(world,light.offset),
        color={max(light.tint.r*over.r,0),max(light.tint.g*over.g,0),max(light.tint.b*over.b,0)},
        intensity=light.intensity*clamp(over.a,0,1),
        range=light.range,
        radius=light.radius,
        indirect=light.indirect,
        scattering=light.scattering,
        shadowless=!light.shadows,
    }
    return desc,desc.intensity>0 && desc.range>0 && desc.color!={}
}

// Keeps the first `budget` candidates in order: nearest a simulation source,
// then brightest, then by entity and layer.
@(private="file")
candidate_insert :: proc "contextless" (candidates:^[PARTICLE_LIGHTS_MAX]Light_Candidate,count:^int,budget:int,candidate:Light_Candidate) {
    limit:=min(budget,PARTICLE_LIGHTS_MAX)
    at:=count^
    for at>0 && candidate_before(candidate,candidates[at-1]) {at-=1}
    if at>=limit {return}
    kept:=min(count^+1,limit)
    for i:=kept-1;i>at;i-=1 {candidates[i]=candidates[i-1]}
    candidates[at]=candidate
    count^=kept
}

@(private="file")
candidate_before :: proc "contextless" (a,b:Light_Candidate) -> bool {
    if a.distance!=b.distance {return a.distance<b.distance}
    if a.light.intensity!=b.light.intensity {return a.light.intensity>b.light.intensity}
    if a.owner!=b.owner {return a.owner<b.owner}
    return a.layer<b.layer
}
