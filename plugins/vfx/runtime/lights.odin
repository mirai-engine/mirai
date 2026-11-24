package vfx

import "core:math"
import "mirai:core"
import erender "mirai:engine/render"
import scene "mirai:engine/scene"
import "mirai:host"
import mm "mirai:std/math"
import "plugins:vfx/runtime/effect"

// Dynamic point lights emitted by particle effects.
//
// Each emitter whose resolved Particle_Info sets light.intensity > 0 and
// light.range > 0 contributes up to EMITTER_LIGHTS_MAX bounded per-frame lights
// (up to PARTICLE_LIGHTS_MAX per world) directly into host.Frame_Extras via
// erender.light_add before render_sync. No entities or component tables are
// created or written, so games keep exclusive ownership of Point_Light and
// steady frames allocate nothing. When clocks.lit_count == 0, particles_lights
// returns in O(1) with zero work.

PARTICLE_LIGHTS_MAX :: 32 // hard world cap on particle-emitted point lights
EMITTER_LIGHTS_MAX :: 4   // hard per-emitter cap on concurrent point lights

@(private="file")
Light_Candidate :: struct {
    owner:core.Entity,
    layer:u8,
    sample:u8,
    distance:f32,
    light:erender.Light_Desc,
}

// Submits bounded per-frame particle lights into host.Frame_Extras before
// render_sync. Zero cost when disabled; zero allocations always.
@(step="render",loops="game editor",before="render_sync")
particles_lights :: proc(
    emitters:^core.Table(Particle_Emitter,.Read),
    overrides:^core.Table(Particle_Override,.Read),
    worlds:^core.Table(core.World_Transform,.Read),
    hidden:^core.Table(erender.Hidden,.Read),
    parents:^core.Table(core.Parent,.Read),
    clocks:core.Ref(Particle_Clocks),
    settings:core.Ref(Particle_Settings),
    sources:core.Ref(scene.Simulation_Sources),
    assets:^host.Assets,
    extras:^host.Frame_Extras,
) {
    if clocks.ptr==nil || clocks.lit_count==0 || extras==nil {return}

    budget:=PARTICLE_LIGHTS_MAX
    if settings.ptr!=nil {budget=min(int(settings.max_lights),PARTICLE_LIGHTS_MAX)}
    if budget<=0 {return}

    candidates:[PARTICLE_LIGHTS_MAX]Light_Candidate
    cand_count:=0
    placed:=core.join(emitters,worlds)
    for e,emitter,wt in core.each_joined(&placed) {
        primary:=clock_find(clocks.ptr,e)
        if primary==nil || primary.culled {continue}
        if erender.is_hidden(hidden,parents,e) {continue}
        override,_:=core.get(overrides,e)
        for layer in 0..=int(primary.layers) {
            clock:=clock_find(clocks.ptr,e,layer)
            if clock==nil || !clock.emission.has_light || clock.done || clock.last<=-max(f64)*0.5 {continue}
            info:=particle_resolve(assets,emitter.particle,&override,emitter.preset,u8(layer))
            if info.light.intensity<=0 || info.light.range<=0 {continue}
            emitter_light_candidates(e,u8(layer),wt.transform,clock,&info,sources.ptr,budget,&candidates,&cand_count)
        }
    }

    for i in 0..<cand_count {
        _=erender.light_add(extras,candidates[i].light)
    }
}

// Samples up to EMITTER_LIGHTS_MAX live light candidates for one emitter layer
// from its clock births, effect light config, color_over_life and size_over_life.
@(private="file")
emitter_light_candidates :: proc(
    owner:core.Entity,layer:u8,owner_world:mm.Transform,clock:^Emitter_Clock,info:^effect.Particle_Info,
    sources:^scene.Simulation_Sources,budget:int,candidates:^[PARTICLE_LIGHTS_MAX]Light_Candidate,count:^int,
) {
    longest:=max(info.lifetime[0],info.lifetime[1])
    if longest<=0 {return}
    min_age:=max(f64)
    max_age:=f64(-1)
    live_particles:=u64(0)
    for b in clock.births[:clock.birth_count] {
        instants:=birth_instants(b)
        t_first:=b.time
        t_last:=b.time+f64(instants-1)*f64(b.spacing)
        if clock.time<t_first {continue}
        newest_age:=max(clock.time-t_last,0)
        if newest_age>=f64(longest) {continue}
        oldest_age:=min(clock.time-t_first,f64(longest))
        min_age=min(min_age,newest_age)
        max_age=max(max_age,oldest_age)
        live_particles+=u64(b.count)
    }
    if live_particles==0 {
        // Program-driven GPU births track clock.last without CPU birth groups.
        if clock.emission.program_births && clock.last>-max(f64)*0.5 {
            age:=clock.time-clock.last
            if age>=0 && age<f64(longest) {
                min_age,max_age,live_particles=age,age,1
            }
        }
    }
    if live_particles==0 || min_age>=f64(longest) {return}

    want:=int(info.light.max_lights) if info.light.max_lights>0 else 1
    want=clamp(want,1,EMITTER_LIGHTS_MAX)
    if u64(want)>live_particles {want=int(live_particles)}

    base_color:=info.light.color
    if base_color=={} {base_color=0.5*(info.colors[0].rgb+info.colors[1].rgb)}
    avg_speed:=0.5*(info.speed[0]+info.speed[1])
    local_v0:=0.5*(info.velocity[0]+info.velocity[1])+[3]f32{0,avg_speed,0}

    for k in 0..<want {
        age:f64
        if want==1 {
            age=0.5*(min_age+max_age) if max_age>min_age+1e-4 else min_age
        } else {
            frac:=(f64(k)+0.5)/f64(want)
            age=min_age+(max_age-min_age)*frac
        }
        if age<0 || age>=f64(longest) {continue}
        u:=clamp(f32(age)/longest,0,1)
        grad:=keys_at(info.color_over_life.times[:],info.color_over_life.colors[:],u)
        size_mul:=keys_at(info.size_over_life.times[:],info.size_over_life.values[:],u)
        envelope:=clamp(grad.a,0,1)
        if envelope<=1e-4 || size_mul<=0 {continue}
        intensity:=info.light.intensity*envelope
        range:=info.light.range*clamp(size_mul,0.1,4)
        if intensity<=1e-4 || range<=1e-4 {continue}

        color:=[3]f32{
            max(base_color.r*grad.r,0),
            max(base_color.g*grad.g,0),
            max(base_color.b*grad.b,0),
        }
        if color.r+color.g+color.b<=1e-6 {continue}

        spread:=light_shape_spread(info,k,want)
        t:=f32(age)
        world_pos:mm.Vec3
        if info.local_space {
            local_pos:=spread+local_v0*t+0.5*info.acceleration*(t*t)
            world_pos=mm.transform_point(owner_world,local_pos)
        } else {
            world_v0:=mm.quat_rotate(owner_world.rotation,local_v0)
            world_spread:=mm.quat_rotate(owner_world.rotation,owner_world.scale*spread)
            world_pos=owner_world.position+world_spread+world_v0*t+0.5*info.acceleration*(t*t)
        }

        cand:=Light_Candidate{
            owner=owner,
            layer=layer,
            sample=u8(k),
            distance=scene.sources_distance(sources,world_pos,world_pos),
            light={
                position=world_pos,
                color=color,
                intensity=intensity,
                range=range,
                radius=info.light.radius,
                indirect=info.light.indirect,
                scattering=info.light.scattering,
                shadowless=!info.light.shadows,
            },
        }
        candidate_insert(candidates,count,budget,cand)
    }
}

// Deterministic spread across the emitter shape when emitting >1 light.
// shape_size.x is already the radius or half-extent (effect.Particle_Info).
@(private="file")
light_shape_spread :: proc "contextless" (info:^effect.Particle_Info,index,total:int) -> [3]f32 {
    if total<=1 || info.shape==.Point {return {}}
    t:=f32(index)/f32(total-1)*2-1 // -1..1
    #partial switch info.shape {
    case .Line: return {0,info.shape_size.x*t,0}
    case .Box:  return {info.shape_size.x*t,0,0}
    case .Circle,.Sphere,.Hemisphere,.Cone:
        angle:=f32(index)*math.TAU/f32(total)
        r:=info.shape_size.x
        return {math.cos(angle)*r,0,math.sin(angle)*r}
    }
    return {}
}

// Keeps the top `budget` candidates in deterministic priority order: nearest
// simulation source, then brightest intensity, then entity/layer/sample.
@(private="file")
candidate_insert :: proc "contextless" (candidates:^[PARTICLE_LIGHTS_MAX]Light_Candidate,count:^int,budget:int,cand:Light_Candidate) {
    limit:=min(budget,PARTICLE_LIGHTS_MAX)
    if limit<=0 {return}
    pos:=count^
    for pos>0 && candidate_before(cand,candidates[pos-1]) {pos-=1}
    if pos>=limit {return}
    new_count:=min(count^+1,limit)
    for i:=new_count-1;i>pos;i-=1 {candidates[i]=candidates[i-1]}
    candidates[pos]=cand
    count^=new_count
}

@(private="file")
candidate_before :: proc "contextless" (a,b:Light_Candidate) -> bool {
    if a.distance!=b.distance {return a.distance<b.distance}
    if a.light.intensity!=b.light.intensity {return a.light.intensity>b.light.intensity}
    if a.owner!=b.owner {return a.owner<b.owner}
    if a.layer!=b.layer {return a.layer<b.layer}
    return a.sample<b.sample
}
